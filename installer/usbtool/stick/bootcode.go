package stick

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
)

const (
	sectorSize = 512
	// BootPartStart is where partition 1 starts (1 MiB).  The BIOS boot code
	// lives in the sectors before it.
	BootPartStart = 2048
	// BootPartSize is the size of the FAT32 boot partition.
	BootPartSize int64 = 4 << 30

	BootLabel = "JUNEBOOT"
	DataLabel = "JUNE"
)

// Disk is the raw whole-disk device.
type Disk interface {
	io.ReaderAt
	io.WriterAt
}

// WriteBootCode installs the legacy BIOS boot code from blob (the first MiB
// produced by make_bios_boot.sh) into a disk that already has the June MBR
// layout.  It keeps the disk's own partition table and disk signature, marks
// partition 1 active and FAT32 (LBA), and refuses if the boot code would
// overlap a partition.
func WriteBootCode(d Disk, blob []byte) error {
	if len(blob) < 2*sectorSize || len(blob)%sectorSize != 0 {
		return errors.New("BIOS boot code has an invalid size")
	}
	if blob[510] != 0x55 || blob[511] != 0xaa {
		return errors.New("BIOS boot code has no boot signature")
	}
	// Only the sectors up to the end of core.img matter; the rest of the
	// blob is zero padding.
	used := len(blob) / sectorSize
	for used > 1 && isZero(blob[(used-1)*sectorSize:used*sectorSize]) {
		used--
	}

	mbr := make([]byte, sectorSize)
	if _, err := d.ReadAt(mbr, 0); err != nil {
		return fmt.Errorf("reading the partition table: %w", err)
	}
	if mbr[510] != 0x55 || mbr[511] != 0xaa {
		return errors.New("the stick has no MBR partition table")
	}
	for n := 0; n < 4; n++ {
		e := mbr[446+16*n : 446+16*(n+1)]
		typ := e[4]
		start := binary.LittleEndian.Uint32(e[8:12])
		if typ == 0 {
			continue
		}
		if typ == 0xee {
			return errors.New("the stick uses GPT, not MBR")
		}
		if int(start) < used {
			return fmt.Errorf("partition %d starts at sector %d, inside the boot code area (%d sectors)", n+1, start, used)
		}
		if n == 0 && typ != 0x0b && typ != 0x0c {
			return fmt.Errorf("partition 1 has type 0x%02x, expected FAT32", typ)
		}
	}

	// Write core.img first and the MBR boot code last, so an interrupted
	// write never leaves an MBR that jumps into garbage.
	if _, err := d.WriteAt(blob[sectorSize:used*sectorSize], sectorSize); err != nil {
		return fmt.Errorf("writing the BIOS boot code: %w", err)
	}
	next := make([]byte, sectorSize)
	copy(next, mbr)
	copy(next[:440], blob[:440]) // bytes 440..445: disk signature, kept
	for n := 0; n < 4; n++ {
		next[446+16*n] = 0
	}
	next[446] = 0x80   // partition 1 active: some BIOSes only boot active partitions
	next[446+4] = 0x0c // FAT32 with LBA
	if _, err := d.WriteAt(next, 0); err != nil {
		return fmt.Errorf("writing the boot sector: %w", err)
	}

	back := make([]byte, used*sectorSize)
	if _, err := d.ReadAt(back, 0); err != nil {
		return fmt.Errorf("reading back the boot code: %w", err)
	}
	if !bytes.Equal(back[:sectorSize], next) || !bytes.Equal(back[sectorSize:], blob[sectorSize:used*sectorSize]) {
		return errors.New("the boot code did not read back correctly; the stick may be faulty")
	}
	return nil
}

func isZero(b []byte) bool {
	for _, c := range b {
		if c != 0 {
			return false
		}
	}
	return true
}
