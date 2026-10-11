package stick

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"
)

// The Linux backend is used by june-usb-cli on Linux and for testing the
// stick layout against loop devices.  Needs root, util-linux, dosfstools and
// exfatprogs.

type lsblkDev struct {
	Name       string     `json:"name"`
	Path       string     `json:"path"`
	Size       int64      `json:"size"`
	Model      string     `json:"model"`
	Serial     string     `json:"serial"`
	Tran       string     `json:"tran"`
	RM         bool       `json:"rm"`
	Type       string     `json:"type"`
	LogSec     int        `json:"log-sec"`
	Label      string     `json:"label"`
	FSType     string     `json:"fstype"`
	Mountpoint string     `json:"mountpoint"`
	Children   []lsblkDev `json:"children"`
}

func lsblk(args ...string) ([]lsblkDev, error) {
	cmd := append([]string{"-J", "-b", "-o", "NAME,PATH,SIZE,MODEL,SERIAL,TRAN,RM,TYPE,LOG-SEC,LABEL,FSTYPE,MOUNTPOINT"}, args...)
	out, err := exec.Command("lsblk", cmd...).Output()
	if err != nil {
		return nil, fmt.Errorf("lsblk: %w", err)
	}
	var v struct {
		Blockdevices []lsblkDev `json:"blockdevices"`
	}
	if err := json.Unmarshal(out, &v); err != nil {
		return nil, err
	}
	return v.Blockdevices, nil
}

// allowLoop lets tests use loop devices, which are never listed otherwise.
func allowLoop() bool { return os.Getenv("JUNE_USB_ALLOW_LOOP") == "1" }

func toDrive(b lsblkDev) (Drive, bool) {
	d := Drive{
		ID: b.Path, Device: b.Path, Name: strings.TrimSpace(b.Model), Size: b.Size,
		Bus: strings.ToUpper(b.Tran), Serial: b.Serial, Removable: b.RM, SectorSize: b.LogSec,
	}
	if b.Type == "loop" {
		d.Name, d.Bus = "Loop device "+b.Name, "USB"
	}
	if d.Name == "" {
		d.Name = b.Name
	}
	// A filesystem can sit on the whole disk (no partition table), so check
	// the disk's own mount point as well as its partitions'.
	system := isSystemMount(b.Mountpoint)
	for _, c := range b.Children {
		d.Volumes = append(d.Volumes, Volume{Label: c.Label, FS: c.FSType, Mount: c.Mountpoint, Size: c.Size})
		if isSystemMount(c.Mountpoint) {
			system = true
		}
	}
	return d, !system
}

func isSystemMount(mp string) bool {
	return mp == "/" || strings.HasPrefix(mp, "/boot") || mp == "[SWAP]" || strings.HasPrefix(mp, "/usr") ||
		strings.HasPrefix(mp, "/mnt/wsl") || strings.HasPrefix(mp, "/var")
}

func listDrives() ([]Drive, error) {
	devs, err := lsblk()
	if err != nil {
		return nil, err
	}
	var out []Drive
	for _, b := range devs {
		if b.Type != "disk" && !(b.Type == "loop" && allowLoop() && b.Size > 0) {
			continue
		}
		if d, ok := toDrive(b); ok {
			out = append(out, d)
		}
	}
	return out, nil
}

func lookupDrive(id string) (Drive, error) {
	devs, err := lsblk(id)
	if err != nil || len(devs) != 1 {
		return Drive{}, fmt.Errorf("the drive %s is no longer connected", id)
	}
	d, ok := toDrive(devs[0])
	if !ok {
		return Drive{}, fmt.Errorf("%s holds the running system", id)
	}
	return d, nil
}

func run(logf func(string, ...any), name string, args ...string) error {
	out, err := exec.Command(name, args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s %s: %v: %s", name, strings.Join(args, " "), err, bytes.TrimSpace(out))
	}
	return nil
}

func unmountChildren(d Drive, logf func(string, ...any)) error {
	devs, err := lsblk(d.Device)
	if err != nil || len(devs) != 1 {
		return err
	}
	for _, c := range devs[0].Children {
		if c.Mountpoint != "" {
			logf("Unmounting %s", c.Path)
			if err := run(logf, "umount", c.Path); err != nil {
				return err
			}
		}
	}
	return nil
}

func partitions(d Drive) (boot, data string, err error) {
	for i := 0; i < 50; i++ {
		devs, e := lsblk(d.Device)
		if e == nil && len(devs) == 1 && len(devs[0].Children) >= 2 {
			return devs[0].Children[0].Path, devs[0].Children[1].Path, nil
		}
		time.Sleep(200 * time.Millisecond)
	}
	return "", "", fmt.Errorf("the new partitions on %s did not appear", d.Device)
}

func partition(ctx context.Context, d Drive, logf func(string, ...any)) (*mounts, error) {
	if err := unmountChildren(d, logf); err != nil {
		return nil, err
	}
	if err := run(logf, "wipefs", "-a", "-q", d.Device); err != nil {
		return nil, err
	}
	script := fmt.Sprintf("label: dos\nstart=%d, size=%d, type=c, bootable\nstart=%d, type=7\n",
		BootPartStart, BootPartSize/sectorSize, BootPartStart+BootPartSize/sectorSize)
	cmd := exec.Command("sfdisk", "-q", "--wipe", "always", "--wipe-partitions", "always", d.Device)
	cmd.Stdin = strings.NewReader(script)
	if out, err := cmd.CombinedOutput(); err != nil {
		return nil, fmt.Errorf("sfdisk: %v: %s", err, bytes.TrimSpace(out))
	}
	_ = run(logf, "udevadm", "settle")
	boot, data, err := partitions(d)
	if err != nil {
		return nil, err
	}
	if err := run(logf, "mkfs.vfat", "-F", "32", "-n", BootLabel, boot); err != nil {
		return nil, err
	}
	if err := run(logf, "mkfs.exfat", "-L", DataLabel, data); err != nil {
		return nil, err
	}
	return mountBoth(boot, data, logf)
}

func locate(ctx context.Context, d Drive, logf func(string, ...any)) (*mounts, error) {
	if err := unmountChildren(d, logf); err != nil {
		return nil, err
	}
	devs, err := lsblk(d.Device)
	if err != nil || len(devs) != 1 {
		return nil, fmt.Errorf("reading %s: %v", d.Device, err)
	}
	var boot, data string
	for _, c := range devs[0].Children {
		switch {
		case strings.EqualFold(c.Label, BootLabel) && c.FSType == "vfat":
			boot = c.Path
		case strings.EqualFold(c.Label, DataLabel):
			data = c.Path
		}
	}
	if boot == "" || data == "" {
		return nil, fmt.Errorf("%s has no %s (FAT32) and %s partitions", d.Device, BootLabel, DataLabel)
	}
	return mountBoth(boot, data, logf)
}

func mountBoth(boot, data string, logf func(string, ...any)) (*mounts, error) {
	bdir, err := os.MkdirTemp("", "june-boot-")
	if err != nil {
		return nil, err
	}
	ddir, err := os.MkdirTemp("", "june-data-")
	if err != nil {
		return nil, err
	}
	if err := run(logf, "mount", boot, bdir); err != nil {
		return nil, err
	}
	if err := run(logf, "mount", data, ddir); err != nil {
		_ = run(logf, "umount", bdir)
		return nil, err
	}
	m := &mounts{Boot: bdir, Data: ddir}
	m.release = func() {
		_ = run(logf, "umount", bdir)
		_ = run(logf, "umount", ddir)
		os.Remove(bdir)
		os.Remove(ddir)
	}
	return m, nil
}

// flush writes everything out and drops the page cache, so verification
// reads what is really on the stick.
func flush(ctx context.Context, d Drive, m *mounts, logf func(string, ...any)) error {
	_ = run(logf, "sync")
	return os.WriteFile("/proc/sys/vm/drop_caches", []byte("1\n"), 0o200)
}

func openUncached(p string) (*os.File, error) { return os.Open(p) }

func writeBootCode(ctx context.Context, d Drive, blob []byte, logf func(string, ...any)) error {
	f, err := os.OpenFile(d.Device, os.O_RDWR, 0)
	if err != nil {
		return err
	}
	defer f.Close()
	if err := WriteBootCode(f, blob); err != nil {
		return err
	}
	return f.Sync()
}

func finish(ctx context.Context, d Drive, logf func(string, ...any)) error {
	return run(logf, "sync")
}
