// Command june-usb-cli prepares a June Local USB stick from the command line.
// It shares all logic with the GUI and exists for Linux users and for tests.
//
//	june-usb-cli -list [-all]
//	june-usb-cli -device /dev/sdX [-iso june-local-live.iso] [-update] [-yes]
package main

import (
	"bufio"
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"strings"

	"june-usb/stick"
)

func main() {
	list := flag.Bool("list", false, "list drives and exit")
	all := flag.Bool("all", false, "include non-USB and large drives")
	device := flag.String("device", "", "drive to prepare (ID from -list)")
	isoPath := flag.String("iso", "", "use this ISO instead of downloading the latest release")
	manifest := flag.String("manifest", stick.DefaultManifestURL, "release manifest URL")
	update := flag.Bool("update", false, "only replace the installer on an existing June stick")
	yes := flag.Bool("yes", false, "do not ask for confirmation")
	flag.Parse()

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()
	if err := run(ctx, *list, *all, *device, *isoPath, *manifest, *update, *yes); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, list, all bool, device, isoPath, manifest string, update, yes bool) error {
	drives, err := stick.ListDrives(all || device != "")
	if err != nil {
		return err
	}
	if list || device == "" {
		for _, d := range drives {
			state := "ok"
			if !d.Eligible {
				state = d.Reason
			}
			june := ""
			if d.JuneStick {
				june = " [June stick]"
			}
			fmt.Printf("%-14s %-28s %9s %-5s %s%s\n", d.ID, d.Name, stick.HumanSize(d.Size), d.Bus, state, june)
		}
		if device == "" && !list {
			return fmt.Errorf("choose a drive with -device")
		}
		return nil
	}
	var drive *stick.Drive
	for i := range drives {
		if drives[i].ID == device {
			drive = &drives[i]
		}
	}
	if drive == nil {
		return fmt.Errorf("%s is not an available drive (see -list -all)", device)
	}
	if !drive.Eligible {
		return fmt.Errorf("%s cannot be used: %s", device, drive.Reason)
	}

	if isoPath == "" {
		rel, err := stick.FetchRelease(ctx, manifest)
		if err != nil {
			return err
		}
		if isoPath, err = stick.CachePath(rel); err != nil {
			return err
		}
		fmt.Printf("Downloading June Local %s (%s)\n", rel.Version, stick.HumanSize(rel.Size))
		if err := stick.Download(ctx, rel, isoPath, func(done, total int64) {
			fmt.Printf("\r  %3.0f%%", 100*float64(done)/float64(total))
		}); err != nil {
			return err
		}
		fmt.Println()
	}

	mode := stick.Fresh
	var vols []string
	for _, v := range drive.Volumes {
		if s := strings.TrimSpace(v.Mount + " " + v.Label); s != "" {
			vols = append(vols, s)
		}
	}
	what := fmt.Sprintf("ERASE everything on %s (%s, %s; volumes: %s)", drive.Name, stick.HumanSize(drive.Size), drive.Device, strings.Join(vols, ", "))
	if update {
		mode = stick.Update
		what = fmt.Sprintf("replace the installer on %s (backups are kept)", drive.Device)
	}
	if !yes {
		fmt.Printf("This will %s. Type yes to continue: ", what)
		line, _ := bufio.NewReader(os.Stdin).ReadString('\n')
		if strings.TrimSpace(line) != "yes" {
			return fmt.Errorf("cancelled")
		}
	}
	last := -1
	res, err := stick.Prepare(ctx, stick.Options{
		Drive: *drive, ISOPath: isoPath, Mode: mode,
		Log: func(s string) { fmt.Println("  " + s) },
		Progress: func(p stick.Progress) {
			if p.Step != last {
				last = p.Step
				fmt.Printf("[%d/%d] %s\n", p.Step+1, len(stick.Steps), stick.Steps[p.Step])
			}
		},
	})
	if err == nil {
		if res.Ejected {
			fmt.Println("Done. The stick is ejected and can be unplugged.")
		} else {
			fmt.Println("Done, but it was not ejected: " + res.EjectError + ". Eject it before unplugging.")
		}
		if stick.HostIsARM() {
			fmt.Println("This computer has an ARM processor, so it can't start the installer; use the stick on an Intel or AMD laptop.")
		}
	}
	return err
}
