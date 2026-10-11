package stick

import (
	"bytes"
	"encoding/binary"
	"strings"
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
