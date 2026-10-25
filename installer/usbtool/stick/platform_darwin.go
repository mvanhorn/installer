package stick

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"syscall"

	"howett.net/plist"
)

// The macOS backend uses diskutil, which can erase external disks without
// an administrator password.  Only writing the BIOS boot code to the raw
// disk needs root; the app re-runs itself for that step through osascript,
// which shows the standard macOS password prompt.

func init() {
	// fsync(2) does not work on raw disks on macOS: /dev/rdisk* returns
	// ENOTTY.  The boot-code helper uses sync(2) instead (syncBootDevice).
	// sync(2) cannot fail in a way that matters here: the writes are already
	// on the stick and read back, so a failure is ignored.
	syncAll = func() { _ = syscall.Sync() }
}

func diskutil(ctx context.Context, args ...string) ([]byte, error) {
	out, err := exec.CommandContext(ctx, "/usr/sbin/diskutil", args...).CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("diskutil %s: %s", strings.Join(args, " "), strings.TrimSpace(string(out)))
	}
	return out, nil
}

func diskutilPlist(ctx context.Context, v any, args ...string) error {
	out, err := diskutil(ctx, args...)
	if err != nil {
		return err
	}
	_, err = plist.Unmarshal(out, v)
	return err
}

type duPartition struct {
	DeviceIdentifier string `plist:"DeviceIdentifier"`
	VolumeName       string `plist:"VolumeName"`
	Content          string `plist:"Content"`
	MountPoint       string `plist:"MountPoint"`
	Size             int64  `plist:"Size"`
}

type duList struct {
	AllDisksAndPartitions []struct {
		DeviceIdentifier string        `plist:"DeviceIdentifier"`
		Size             int64         `plist:"Size"`
		Partitions       []duPartition `plist:"Partitions"`
	} `plist:"AllDisksAndPartitions"`
}

type duInfo struct {
	DeviceIdentifier string `plist:"DeviceIdentifier"`
	MediaName        string `plist:"MediaName"`
	IORegistryName   string `plist:"IORegistryEntryName"`
	Size             int64  `plist:"Size"`
	TotalSize        int64  `plist:"TotalSize"`
	BusProtocol      string `plist:"BusProtocol"`
	Internal         bool   `plist:"Internal"`
	Removable        bool   `plist:"RemovableMediaOrExternalDevice"`
	BlockSize        int    `plist:"DeviceBlockSize"`
	Virtual          string `plist:"VirtualOrPhysical"`
	MountPoint       string `plist:"MountPoint"`
	VolumeName       string `plist:"VolumeName"`
	FilesystemType   string `plist:"FilesystemType"`
	PartitionOffset  int64  `plist:"PartitionMapPartitionOffset"`
}

func listDrives() ([]Drive, error) {
	ctx := context.Background()
	var l duList
	if err := diskutilPlist(ctx, &l, "list", "-plist", "external", "physical"); err != nil {
		return nil, err
	}
	var drives []Drive
	for _, w := range l.AllDisksAndPartitions {
		d, err := driveInfo(ctx, w.DeviceIdentifier)
		if err != nil || d == nil {
			continue
		}
		for _, p := range w.Partitions {
			d.Volumes = append(d.Volumes, Volume{Label: p.VolumeName, FS: p.Content, Mount: p.MountPoint, Size: p.Size})
		}
		drives = append(drives, *d)
	}
	return drives, nil
}

func driveInfo(ctx context.Context, id string) (*Drive, error) {
	var in duInfo
	if err := diskutilPlist(ctx, &in, "info", "-plist", id); err != nil {
		return nil, err
	}
	if in.Internal || in.Virtual == "Virtual" {
		return nil, nil
	}
	size := in.TotalSize
	if size == 0 {
		size = in.Size
	}
	name := strings.TrimSpace(in.MediaName)
	if name == "" {
		name = in.IORegistryName
	}
	return &Drive{
		ID: in.DeviceIdentifier, Device: "/dev/" + in.DeviceIdentifier, Name: name, Size: size,
		Bus: in.BusProtocol, Removable: in.Removable, SectorSize: in.BlockSize,
	}, nil
}

func lookupDrive(id string) (Drive, error) {
	drives, err := listDrives()
	if err != nil {
		return Drive{}, err
	}
	for _, d := range drives {
		if d.ID == id {
			return d, nil
		}
	}
	return Drive{}, fmt.Errorf("the selected drive is no longer connected")
}

func partition(ctx context.Context, d Drive, logf func(string, ...any)) (*mounts, error) {
	out, err := diskutil(ctx, "partitionDisk", d.Device, "MBR",
		"MS-DOS FAT32", BootLabel, fmt.Sprintf("%dS", BootPartSize/sectorSize),
		"ExFAT", DataLabel, "R")
	if err != nil {
		return nil, err
	}
	logf("diskutil: %s", lastLine(string(out)))
	return locate(ctx, d, logf)
}

func locate(ctx context.Context, d Drive, logf func(string, ...any)) (*mounts, error) {
	var l duList
	if err := diskutilPlist(ctx, &l, "list", "-plist", d.ID); err != nil {
		return nil, err
	}
	var boot, data string
	for _, w := range l.AllDisksAndPartitions {
		for _, p := range w.Partitions {
			switch {
			case strings.EqualFold(p.VolumeName, BootLabel):
				boot = p.DeviceIdentifier
			case strings.EqualFold(p.VolumeName, DataLabel):
				data = p.DeviceIdentifier
			}
		}
	}
	if boot == "" || data == "" {
		return nil, fmt.Errorf("%s has no %s and %s partitions", d.ID, BootLabel, DataLabel)
	}
	m := &mounts{}
	for _, part := range []struct {
		id  string
		dst *string
	}{{boot, &m.Boot}, {data, &m.Data}} {
		var in duInfo
		if err := diskutilPlist(ctx, &in, "info", "-plist", part.id); err != nil {
			return nil, err
		}
		if in.MountPoint == "" {
			if _, err := diskutil(ctx, "mount", part.id); err != nil {
				return nil, err
			}
			if err := diskutilPlist(ctx, &in, "info", "-plist", part.id); err != nil {
				return nil, err
			}
		}
		if in.MountPoint == "" {
			return nil, fmt.Errorf("%s could not be mounted", part.id)
		}
		*part.dst = in.MountPoint
	}
	return m, nil
}

func flush(ctx context.Context, d Drive, m *mounts, logf func(string, ...any)) error {
	syscall.Sync()
	return nil
}

// openUncached asks macOS not to serve the reads from its cache (F_NOCACHE).
func openUncached(p string) (*os.File, error) {
	f, err := os.Open(p)
	if err != nil {
		return nil, err
	}
	const fNoCache = 48
	_, _, _ = syscall.Syscall(syscall.SYS_FCNTL, f.Fd(), fNoCache, 1)
	return f, nil
}

func writeBootCode(ctx context.Context, d Drive, blob []byte, logf func(string, ...any)) error {
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp("", "june-bios-*.img")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(blob); err != nil {
		tmp.Close()
		return err
	}
	tmp.Close()
	raw := "/dev/r" + d.ID
	shell := fmt.Sprintf("/usr/sbin/diskutil unmountDisk force %s && %s %s %s %s",
		shQuote(d.Device), shQuote(exe), BootCodeHelperFlag, shQuote(raw), shQuote(tmp.Name()))
	script := fmt.Sprintf("do shell script %s with administrator privileges with prompt %s",
		asQuote(shell), asQuote("June USB needs your password to make the stick start on older computers."))
	out, err := exec.CommandContext(ctx, "/usr/bin/osascript", "-e", script).CombinedOutput()
	if err != nil {
		msg := strings.TrimSpace(string(out))
		if strings.Contains(msg, "-128") {
			return fmt.Errorf("the password prompt was cancelled; the stick will still start on UEFI computers, run again to add legacy BIOS support")
		}
		return fmt.Errorf("writing the boot code: %s", msg)
	}
	return nil
}

func finish(ctx context.Context, d Drive, logf func(string, ...any)) error {
	syscall.Sync()
	_, err := diskutil(ctx, "eject", d.Device)
	return err
}

func shQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }

func asQuote(s string) string {
	r := strings.NewReplacer(`\`, `\\`, `"`, `\"`)
	return `"` + r.Replace(s) + `"`
}

func lastLine(s string) string {
	lines := bytes.Split(bytes.TrimSpace([]byte(s)), []byte("\n"))
	return string(lines[len(lines)-1])
}
