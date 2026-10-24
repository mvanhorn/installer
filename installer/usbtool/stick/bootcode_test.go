package stick

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

type memDisk []byte

func (m memDisk) ReadAt(p []byte, off int64) (int, error)  { return copy(p, m[off:]), nil }
func (m memDisk) WriteAt(p []byte, off int64) (int, error) { return copy(m[off:], p), nil }

// newDisk returns a disk with an MBR whose partition 1 (type typ) starts at
// sector start, and a fake disk signature.
func newDisk(typ byte, start uint32) memDisk {
	d := make(memDisk, 4<<20)
	copy(d[440:444], []byte{0xde, 0xad, 0xbe, 0xef})
	e := d[446:462]
	e[4] = typ
	binary.LittleEndian.PutUint32(e[8:], start)
	binary.LittleEndian.PutUint32(e[12:], 1000)
	e2 := d[462:478]
	e2[0] = 0x80 // a stray active flag that must be cleared
	e2[4] = 0x07
	binary.LittleEndian.PutUint32(e2[8:], start+1000)
	d[510], d[511] = 0x55, 0xaa
	return d
}

func newBlob(coreSectors int) []byte {
	b := make([]byte, 1<<20)
	for i := 0; i < 440; i++ {
		b[i] = 0xb0
	}
	b[510], b[511] = 0x55, 0xaa
	for i := 512; i < (1+coreSectors)*512; i++ {
		b[i] = 0xc0
	}
	return b
}

func TestWriteBootCode(t *testing.T) {
	d := newDisk(0x0b, BootPartStart)
	if err := WriteBootCode(d, newBlob(224)); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(d[:440], bytes.Repeat([]byte{0xb0}, 440)) {
		t.Error("boot code not written")
	}
	if !bytes.Equal(d[440:444], []byte{0xde, 0xad, 0xbe, 0xef}) {
		t.Error("disk signature not kept")
	}
	if d[446] != 0x80 || d[446+4] != 0x0c || d[462] != 0 || d[462+4] != 0x07 {
		t.Errorf("partition entries wrong: p1 %x/%x p2 %x/%x", d[446], d[450], d[462], d[466])
	}
	if d[512] != 0xc0 || d[225*512-1] != 0xc0 || d[225*512] != 0 {
		t.Error("core.img not written exactly")
	}
}

func TestWriteBootCodeRefuses(t *testing.T) {
	for name, tc := range map[string]struct {
		disk memDisk
		want string
	}{
		"overlap":  {newDisk(0x0c, 63), "inside the boot code area"},
		"not fat":  {newDisk(0x83, BootPartStart), "expected FAT32"},
		"gpt":      {newDisk(0xee, 1), "GPT"},
		"no table": {make(memDisk, 4<<20), "no MBR"},
	} {
		err := WriteBootCode(tc.disk, newBlob(224))
		if err == nil || !strings.Contains(err.Error(), tc.want) {
			t.Errorf("%s: got %v, want %q", name, err, tc.want)
		}
	}
}

func TestSyncUnsupported(t *testing.T) {
	enotty := &os.PathError{Op: "sync", Path: "/dev/rdisk4", Err: syscall.Errno(25)}
	for name, tc := range map[string]struct {
		err  error
		want bool
	}{
		"nil":            {nil, false},
		"enotty":         {enotty, true},
		"enotty wrapped": {fmt.Errorf("flush: %w", enotty), true},
		"einval":         {syscall.Errno(22), true},
		"eio":            {&os.PathError{Op: "sync", Path: "/dev/rdisk4", Err: syscall.Errno(5)}, false},
		"not an errno":   {errors.New("boom"), false},
	} {
		if got := syncUnsupported(tc.err); got != tc.want {
			t.Errorf("%s: syncUnsupported = %v, want %v", name, got, tc.want)
		}
	}
}

func TestSyncBootDevice(t *testing.T) {
	f, err := os.CreateTemp(t.TempDir(), "boot-device")
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()

	origFile, origAll := syncFile, syncAll
	defer func() { syncFile, syncAll = origFile, origAll }()

	enotty := &os.PathError{Op: "sync", Path: "/dev/rdisk4", Err: syscall.Errno(25)}

	// Platform without sync(2): the device is fsynced directly, and an
	// unsupported fsync is tolerated because the read-back already verified it.
	syncAll = nil
	for name, tc := range map[string]struct {
		syncErr error
		wantErr bool
	}{
		"clean sync":       {nil, false},
		"real error":       {&os.PathError{Op: "sync", Path: "/dev/rdisk4", Err: syscall.Errno(5)}, true},
		"enotty tolerated": {enotty, false},
		"einval tolerated": {syscall.Errno(22), false},
	} {
		syncFile = func(*os.File) error { return tc.syncErr }
		if err := syncBootDevice(f); (err != nil) != tc.wantErr {
			t.Errorf("%s: err = %v, wantErr %v", name, err, tc.wantErr)
		}
	}

	// darwin: sync(2) is used and the raw device is not fsynced.
	syncAllCalled := false
	syncAll = func() { syncAllCalled = true }
	syncFile = func(*os.File) error { return enotty }
	if err := syncBootDevice(f); err != nil {
		t.Errorf("syncBootDevice with syncAll set: err = %v, want nil", err)
	}
	if !syncAllCalled {
		t.Error("syncBootDevice did not call sync(2) when it is available")
	}
}

// writeHelperInputs writes a bootable disk image and the BIOS boot code blob
// into a temporary directory, as the app does for the root helper.
func writeHelperInputs(t *testing.T) (diskPath, blobPath string) {
	t.Helper()
	dir := t.TempDir()
	diskPath = filepath.Join(dir, "stick.img")
	if err := os.WriteFile(diskPath, newDisk(0x0b, BootPartStart), 0o644); err != nil {
		t.Fatal(err)
	}
	blobPath = filepath.Join(dir, "june-bios.img")
	if err := os.WriteFile(blobPath, newBlob(224), 0o644); err != nil {
		t.Fatal(err)
	}
	return diskPath, blobPath
}

// assertBootCode checks that WriteBootCode's output reached the disk image.
func assertBootCode(t *testing.T, disk []byte) {
	t.Helper()
	if !bytes.Equal(disk[:440], bytes.Repeat([]byte{0xb0}, 440)) {
		t.Error("boot code not written")
	}
	if !bytes.Equal(disk[440:444], []byte{0xde, 0xad, 0xbe, 0xef}) {
		t.Error("disk signature not kept")
	}
	if disk[446] != 0x80 || disk[446+4] != 0x0c {
		t.Errorf("partition 1 not made active FAT32: %x/%x", disk[446], disk[446+4])
	}
	if disk[512] != 0xc0 || disk[225*512-1] != 0xc0 || disk[225*512] != 0 {
		t.Error("core.img not written exactly")
	}
}

// TestRunBootCodeHelper exercises the root helper end to end on a regular file
// standing in for the raw device: it must write the boot code, keep the
// partition table, and not fail in the flush after the read-back.
func TestRunBootCodeHelper(t *testing.T) {
	diskPath, blobPath := writeHelperInputs(t)
	if err := RunBootCodeHelper([]string{diskPath, blobPath}); err != nil {
		t.Fatalf("RunBootCodeHelper: %v", err)
	}
	disk, err := os.ReadFile(diskPath)
	if err != nil {
		t.Fatal(err)
	}
	assertBootCode(t, disk)
}

// TestRunBootCodeHelperToleratesENOTTY reproduces the macOS failure: fsync(2)
// on the raw boot-code device returns ENOTTY after every byte was written and
// read back.  That must not fail the helper (the user saw "Writing the boot
// code: ... inappropriate ioctl for device (1)").
func TestRunBootCodeHelperToleratesENOTTY(t *testing.T) {
	origFile, origAll := syncFile, syncAll
	defer func() { syncFile, syncAll = origFile, origAll }()
	syncFile = func(*os.File) error {
		return &os.PathError{Op: "sync", Path: "/dev/rdisk4", Err: syscall.Errno(25)}
	}
	// The plain helper runs before macOS sets up sync(2); exercise the exact
	// fallback used there.
	syncAll = nil

	diskPath, blobPath := writeHelperInputs(t)
	if err := RunBootCodeHelper([]string{diskPath, blobPath}); err != nil {
		t.Fatalf("helper failed on an unsupported fsync after a verified read-back: %v", err)
	}
	disk, err := os.ReadFile(diskPath)
	if err != nil {
		t.Fatal(err)
	}
	assertBootCode(t, disk)
}

func TestRunBootCodeHelperErrors(t *testing.T) {
	if err := RunBootCodeHelper(nil); err == nil || !strings.Contains(err.Error(), "usage") {
		t.Errorf("no args: err = %v, want a usage error", err)
	}

	diskPath, blobPath := writeHelperInputs(t)
	badBlob := filepath.Join(filepath.Dir(blobPath), "bad.img")
	if err := os.WriteFile(badBlob, []byte("too short"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := RunBootCodeHelper([]string{diskPath, badBlob}); err == nil || !strings.Contains(err.Error(), "invalid size") {
		t.Errorf("bad blob: err = %v, want an invalid-size error", err)
	}
	if err := RunBootCodeHelper([]string{filepath.Join(filepath.Dir(diskPath), "missing.img"), badBlob}); err == nil {
		t.Error("missing device: want an error")
	}
}
