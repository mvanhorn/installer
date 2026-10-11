package stick

import (
	"bytes"
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	"github.com/diskfs/go-diskfs/backend/file"
	"github.com/diskfs/go-diskfs/filesystem/iso9660"
)

// BIOSBootFile is produced by installer/liveiso/make_bios_boot.sh.  ISOs
// without it still boot on UEFI; the stick then has no legacy BIOS boot.
const BIOSBootFile = "boot/grub/june-bios.img"

// fat32MaxFile is the largest file FAT32 can hold.
const fat32MaxFile = 1<<32 - 1

// ISO is an open june-local-live.iso.
type ISO struct {
	f     *os.File
	fs    *iso9660.FileSystem
	Files []ISOFile
	Total int64
}

// ISOFile is one regular file in the ISO, with a slash-separated path.
type ISOFile struct {
	Path string
	Size int64
}

// OpenISO opens path and lists its files.
func OpenISO(path string) (*ISO, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	st, err := f.Stat()
	if err != nil {
		f.Close()
		return nil, err
	}
	isofs, err := iso9660.Read(file.New(f, true), st.Size(), 0, 2048)
	if err != nil {
		f.Close()
		return nil, fmt.Errorf("%s is not a readable ISO image: %w", filepath.Base(path), err)
	}
	iso := &ISO{f: f, fs: isofs}
	err = fs.WalkDir(isofs, ".", func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			return nil
		}
		if !d.Type().IsRegular() {
			return fmt.Errorf("unsupported entry %s in the ISO", p)
		}
		info, err := d.Info()
		if err != nil {
			return err
		}
		if info.Size() > fat32MaxFile {
			return fmt.Errorf("%s is larger than 4 GB and cannot be stored on FAT32", p)
		}
		iso.Files = append(iso.Files, ISOFile{Path: p, Size: info.Size()})
		iso.Total += info.Size()
		return nil
	})
	if err == nil {
		err = iso.check()
	}
	if err != nil {
		f.Close()
		return nil, err
	}
	return iso, nil
}

// check makes sure this looks like a June Local live ISO.
func (i *ISO) check() error {
	need := []string{"live/filesystem.squashfs", "EFI/boot/bootx64.efi", "boot/grub/grub.cfg", ".disk/info"}
	have := map[string]bool{}
	for _, f := range i.Files {
		have[f.Path] = true
	}
	for _, p := range need {
		if !have[p] {
			return fmt.Errorf("this ISO is not a June Local installer (missing %s)", p)
		}
	}
	return nil
}

// Close releases the ISO file.
func (i *ISO) Close() error { return i.f.Close() }

// ReadFile returns one file from the ISO.
func (i *ISO) ReadFile(p string) ([]byte, error) { return i.fs.ReadFile(p) }

// HasBIOSBoot reports whether the ISO carries the legacy BIOS boot code.
func (i *ISO) HasBIOSBoot() bool {
	for _, f := range i.Files {
		if f.Path == BIOSBootFile {
			return true
		}
	}
	return false
}

// Version is the June release recorded in the ISO, or the Debian live build
// stamp for ISOs built before june-version.txt existed.
func (i *ISO) Version() string {
	if b, err := i.fs.ReadFile("june-version.txt"); err == nil {
		if v := strings.TrimSpace(string(b)); v != "" {
			return v
		}
	}
	if b, err := i.fs.ReadFile(".disk/info"); err == nil {
		s := strings.TrimSpace(string(b))
		if k := strings.LastIndex(s, " "); k >= 0 {
			return "build " + s[k+1:]
		}
		return s
	}
	return "unknown"
}

// Sums maps ISO paths to the SHA256 of their content.
type Sums map[string][32]byte

// CopyTo copies every ISO file below dir, hashing as it goes.
func (i *ISO) CopyTo(ctx context.Context, dir string, progress func(done, total int64, name string)) (Sums, error) {
	sums := Sums{}
	var done int64
	for _, f := range i.Files {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		dst := filepath.Join(dir, filepath.FromSlash(f.Path))
		if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
			return nil, err
		}
		src, err := i.fs.Open(f.Path)
		if err != nil {
			return nil, fmt.Errorf("reading %s from the ISO: %w", f.Path, err)
		}
		out, err := os.Create(dst)
		if err != nil {
			src.Close()
			return nil, fmt.Errorf("writing %s to the stick: %w", f.Path, err)
		}
		h := sha256.New()
		base := done
		n, err := copyWithProgress(ctx, io.MultiWriter(out, h), src, f.Size, func(d, _ int64) {
			if progress != nil {
				progress(base+d, i.Total, f.Path)
			}
		})
		src.Close()
		if cerr := out.Close(); err == nil {
			err = cerr
		}
		if err != nil {
			return nil, fmt.Errorf("writing %s to the stick: %w", f.Path, err)
		}
		if n != f.Size {
			return nil, fmt.Errorf("copying %s: wrote %d of %d bytes", f.Path, n, f.Size)
		}
		done += n
		var sum [32]byte
		copy(sum[:], h.Sum(nil))
		sums[f.Path] = sum
	}
	return sums, nil
}

// VerifyCopy reads every file back from dir and compares it with sums.
func VerifyCopy(ctx context.Context, dir string, files []ISOFile, sums Sums, total int64, progress func(done, total int64, name string)) error {
	var done int64
	for _, f := range files {
		p := filepath.Join(dir, filepath.FromSlash(f.Path))
		in, err := openUncached(p)
		if err != nil {
			return fmt.Errorf("verifying %s: %w", f.Path, err)
		}
		h := sha256.New()
		base := done
		n, err := copyWithProgress(ctx, h, in, f.Size, func(d, _ int64) {
			if progress != nil {
				progress(base+d, total, f.Path)
			}
		})
		in.Close()
		if err != nil {
			return fmt.Errorf("verifying %s: %w", f.Path, err)
		}
		want, ok := sums[f.Path]
		if !ok || n != f.Size || !bytes.Equal(h.Sum(nil), want[:]) {
			return fmt.Errorf("%s on the stick does not match the ISO; the stick may be faulty", f.Path)
		}
		done += n
	}
	return nil
}

// ClearDir removes everything inside dir but not dir itself.  Used when
// updating the boot partition of an existing June stick.
func ClearDir(dir string) error {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return err
	}
	var errs []error
	for _, e := range entries {
		name := e.Name()
		// Leave OS bookkeeping alone; it is recreated anyway.
		if strings.EqualFold(name, "System Volume Information") {
			continue
		}
		if err := os.RemoveAll(filepath.Join(dir, name)); err != nil {
			errs = append(errs, err)
		}
	}
	return errors.Join(errs...)
}
