package stick

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// Mode says whether the stick is erased or only its boot partition replaced.
type Mode string

const (
	// Fresh erases the whole drive and creates both partitions.
	Fresh Mode = "fresh"
	// Update replaces the installer on an existing June stick and leaves the
	// JUNE partition (backups, logs, certificates) untouched.
	Update Mode = "update"
)

// Steps are the stages shown in the progress tracker.
var Steps = []string{"Prepare the stick", "Copy the installer", "Verify the copy", "Make it bootable", "Finish"}

// Progress is one progress report.
type Progress struct {
	Step     int     `json:"step"`     // index into Steps
	Fraction float64 `json:"fraction"` // within the step, 0..1, or -1 when unknown
	Overall  float64 `json:"overall"`  // whole job, 0..1
	Detail   string  `json:"detail"`
}

var stepWeight = []float64{0.05, 0.55, 0.33, 0.02, 0.05}

// Options describes one preparation run.
type Options struct {
	Drive    Drive
	ISOPath  string
	Mode     Mode
	Progress func(Progress)
	// Log receives a line per action, for the details pane and support.
	Log func(string)
}

// mounts are the two partitions of a stick, mounted.
type mounts struct {
	Boot, Data string
	// release unmounts anything this tool mounted itself.
	release func()
}

// Marker is written to the boot partition so an update can tell what is on
// the stick.
type Marker struct {
	Version  string    `json:"version"`
	Prepared time.Time `json:"prepared"`
	Tool     string    `json:"tool"`
}

// MarkerFile is the marker's name in the root of the boot partition.
const MarkerFile = "june-usb.json"

// ToolVersion is set by main from the build.
var ToolVersion = "dev"

// Result says how a successful run ended.
type Result struct {
	// Ejected is true when the stick was flushed and ejected (or, on Linux,
	// unmounted), so it can be unplugged right away.
	Ejected bool `json:"ejected"`
	// EjectError explains why it was not, e.g. a program still using it.
	EjectError string `json:"ejectError"`
}

// Prepare runs the whole job.
func Prepare(ctx context.Context, o Options) (Result, error) {
	var r Result
	err := prepare(ctx, o, &r)
	return r, err
}

func prepare(ctx context.Context, o Options, r *Result) error {
	logf := func(format string, a ...any) {
		if o.Log != nil {
			o.Log(fmt.Sprintf(format, a...))
		}
	}
	report := func(step int, frac float64, detail string) {
		if o.Progress == nil {
			return
		}
		overall := 0.0
		for i := 0; i < step; i++ {
			overall += stepWeight[i]
		}
		if frac > 0 {
			overall += stepWeight[step] * frac
		}
		o.Progress(Progress{Step: step, Fraction: frac, Overall: overall, Detail: detail})
	}

	iso, err := OpenISO(o.ISOPath)
	if err != nil {
		return err
	}
	defer iso.Close()
	var blob []byte
	if iso.HasBIOSBoot() {
		if blob, err = iso.ReadFile(BIOSBootFile); err != nil {
			return fmt.Errorf("reading the BIOS boot code from the ISO: %w", err)
		}
	} else {
		logf("This ISO has no %s; the stick will boot on UEFI computers only.", BIOSBootFile)
	}

	report(0, -1, "Checking the drive")
	now, err := lookupDrive(o.Drive.ID)
	if err != nil {
		return err
	}
	if err := sameDrive(o.Drive, now); err != nil {
		return err
	}
	judge(&now)
	if !now.Eligible {
		return errors.New(now.Reason)
	}

	var m *mounts
	switch o.Mode {
	case Fresh:
		report(0, -1, "Erasing and partitioning "+now.Name)
		logf("Erasing %s (%s, %s) and creating %s + %s", now.Name, HumanSize(now.Size), now.Device, BootLabel, DataLabel)
		m, err = partition(ctx, now, logf)
	case Update:
		if !now.JuneStick {
			return errors.New("this drive is not a June stick; choose \"Erase\" instead")
		}
		report(0, -1, "Finding the June partitions")
		m, err = locate(ctx, now, logf)
		if err == nil {
			logf("Removing the old installer from %s (%s is kept)", m.Boot, DataLabel)
			err = ClearDir(m.Boot)
		}
	default:
		return fmt.Errorf("unknown mode %q", o.Mode)
	}
	if err != nil {
		return err
	}
	released := false
	release := func() {
		if !released && m.release != nil {
			released = true
			m.release()
		}
	}
	defer release()
	logf("Boot partition: %s, data partition: %s", m.Boot, m.Data)

	report(1, 0, "")
	sums, err := iso.CopyTo(ctx, m.Boot, func(done, total int64, name string) {
		report(1, float64(done)/float64(total), name)
	})
	if err != nil {
		return err
	}
	mk, _ := json.MarshalIndent(Marker{Version: iso.Version(), Prepared: time.Now().UTC(), Tool: ToolVersion}, "", "  ")
	if err := os.WriteFile(filepath.Join(m.Boot, MarkerFile), append(mk, '\n'), 0o644); err != nil {
		return err
	}
	for _, dir := range []string{"june-logs", "june-certs"} {
		if err := os.MkdirAll(filepath.Join(m.Data, dir), 0o755); err != nil {
			return fmt.Errorf("creating %s on %s: %w", dir, DataLabel, err)
		}
	}
	if err := flush(ctx, now, m, logf); err != nil {
		return err
	}
	logf("Copied %d files (%s)", len(iso.Files), HumanSize(iso.Total))

	report(2, 0, "")
	if err := VerifyCopy(ctx, m.Boot, iso.Files, sums, iso.Total, func(done, total int64, name string) {
		report(2, float64(done)/float64(total), name)
	}); err != nil {
		return err
	}
	logf("All files verified")

	report(3, -1, "Installing the boot code")
	if blob != nil {
		release()
		if err := writeBootCode(ctx, now, blob, logf); err != nil {
			return err
		}
		logf("Legacy BIOS boot code installed")
	}

	// The stick is complete and verified at this point; failing to eject is
	// reported, not treated as a failed run.
	report(4, -1, "Writing out and ejecting")
	release()
	if err := finish(ctx, now, logf); err != nil {
		r.EjectError = err.Error()
		logf("Could not eject automatically: %v", err)
	} else {
		r.Ejected = true
		logf("Ejected; safe to unplug")
	}
	report(4, 1, "Done")
	return nil
}
