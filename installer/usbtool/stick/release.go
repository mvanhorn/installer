// Package stick prepares a June Local USB stick: an MBR disk with a FAT32
// "JUNEBOOT" partition holding the files of june-local-live.iso (UEFI and
// legacy BIOS boot) and an exFAT "JUNE" partition for oven backups, logs and
// certificates.
package stick

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// DefaultManifestURL describes the current release; see
// installer/liveiso/PUBLISHING.md for how it is published.
const DefaultManifestURL = "https://downloads.project-july.org/installer/latest.json"

// DefaultReleasesURL lists every published version, newest first.
const DefaultReleasesURL = "https://downloads.project-july.org/installer/releases.json"

// ISOName is the release file name; it never changes between versions.
const ISOName = "june-local-live.iso"

// Release is the content of latest.json, or one entry of releases.json.
type Release struct {
	Version string `json:"version"`
	URL     string `json:"url"`
	SHA256  string `json:"sha256"`
	Size    int64  `json:"size"`
	Date    string `json:"date,omitempty"` // releases.json only
}

var hexSHA256 = regexp.MustCompile(`^[0-9a-f]{64}$`)

func (rel *Release) check() error {
	rel.SHA256 = strings.ToLower(strings.TrimSpace(rel.SHA256))
	switch {
	case rel.Version == "":
		return errors.New("the release manifest has no version")
	case !strings.HasPrefix(rel.URL, "https://"):
		return errors.New("the release manifest has no https download URL")
	case !hexSHA256.MatchString(rel.SHA256):
		return errors.New("the release manifest has no valid SHA256")
	case rel.Size <= 0:
		return errors.New("the release manifest has no size")
	}
	return nil
}

// FetchRelease downloads and validates the release manifest.
func FetchRelease(ctx context.Context, manifestURL string) (*Release, error) {
	var rel Release
	if err := fetchJSON(ctx, manifestURL, &rel); err != nil {
		return nil, err
	}
	if err := rel.check(); err != nil {
		return nil, err
	}
	return &rel, nil
}

// FetchReleases downloads releases.json and returns its valid entries,
// newest first.
func FetchReleases(ctx context.Context, listURL string) ([]Release, error) {
	var list struct {
		Releases []Release `json:"releases"`
	}
	if err := fetchJSON(ctx, listURL, &list); err != nil {
		return nil, err
	}
	var out []Release
	for _, rel := range list.Releases {
		if rel.check() == nil {
			out = append(out, rel)
		}
	}
	if len(out) == 0 {
		return nil, errors.New("the release list has no valid releases")
	}
	return out, nil
}

func fetchJSON(ctx context.Context, url string, v any) error {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("could not reach the download server: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("the download server answered %s for %s", resp.Status, url)
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(v); err != nil {
		return fmt.Errorf("the release manifest is not valid JSON: %w", err)
	}
	return nil
}

// CachePath is where a release's ISO is kept between runs.
func CachePath(rel *Release) (string, error) {
	dir, err := cacheDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, safeVersion(rel.Version), ISOName), nil
}

// cacheDir holds one folder per version; JUNE_USB_CACHE overrides it (tests).
func cacheDir() (string, error) {
	if d := os.Getenv("JUNE_USB_CACHE"); d != "" {
		return d, nil
	}
	base, err := os.UserCacheDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(base, "June USB"), nil
}

func safeVersion(v string) string {
	safe := strings.Map(func(r rune) rune {
		if r == '/' || r == '\\' || r == ':' {
			return '_'
		}
		return r
	}, v)
	if safe == "" || safe == "." || safe == ".." {
		safe = "_"
	}
	return safe
}

// ByteProgress reports done of total bytes.
type ByteProgress func(done, total int64)

// Download fetches rel into dest, verifying size and SHA256.  An existing
// dest with the right hash is reused.  The file only appears at dest once it
// is complete and verified.
//
// The download goes to dest+".part", which is kept when the download stops
// (cancelled, connection lost), so the next call continues where it left off
// with an HTTP range request.  The SHA256 always covers the whole file: the
// bytes already there are hashed again first.  A part that does not add up to
// the right hash is deleted, so the next try starts from scratch.
func Download(ctx context.Context, rel *Release, dest string, progress ByteProgress) error {
	if st, err := os.Stat(dest); err == nil && st.Size() == rel.Size {
		sum, err := HashFile(ctx, dest, progress)
		if err == nil && sum == rel.SHA256 {
			return nil
		}
		if ctx.Err() != nil {
			return ctx.Err()
		}
	}
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		return err
	}
	part := dest + ".part"
	out, err := os.OpenFile(part, os.O_RDWR|os.O_CREATE, 0o644)
	if err != nil {
		return err
	}
	defer out.Close()

	// Hash what an earlier attempt left behind.
	h := sha256.New()
	have, err := out.Seek(0, io.SeekEnd)
	if err != nil {
		return err
	}
	if have > rel.Size {
		have = 0
	}
	if have > 0 {
		if _, err := out.Seek(0, io.SeekStart); err != nil {
			return err
		}
		n, err := copyWithProgress(ctx, h, io.LimitReader(out, have), rel.Size, progress)
		if err != nil {
			return err
		}
		have = n
	}
	if err := out.Truncate(have); err != nil {
		return err
	}
	if _, err := out.Seek(have, io.SeekStart); err != nil {
		return err
	}

	if have < rel.Size {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, rel.URL, nil)
		if err != nil {
			return err
		}
		if have > 0 {
			req.Header.Set("Range", fmt.Sprintf("bytes=%d-", have))
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			return fmt.Errorf("download failed: %w", err)
		}
		defer resp.Body.Close()
		switch {
		case have > 0 && resp.StatusCode == http.StatusPartialContent &&
			strings.HasPrefix(resp.Header.Get("Content-Range"), fmt.Sprintf("bytes %d-", have)):
			// Continue after the bytes we have.
		case resp.StatusCode == http.StatusOK:
			// A fresh download, or a server that ignored the range: start over.
			if have > 0 {
				h.Reset()
				have = 0
				if err := out.Truncate(0); err != nil {
					return err
				}
				if _, err := out.Seek(0, io.SeekStart); err != nil {
					return err
				}
			}
		default:
			if have > 0 {
				out.Close()
				os.Remove(part)
			}
			return fmt.Errorf("download failed: server answered %s", resp.Status)
		}
		n, err := copyWithProgress(ctx, io.MultiWriter(out, h), resp.Body, rel.Size, offsetProgress(progress, have))
		have += n
		if err != nil {
			return fmt.Errorf("download failed: %w", err)
		}
	}
	if have != rel.Size {
		return fmt.Errorf("download incomplete: got %d of %d bytes", have, rel.Size)
	}
	if got := hex.EncodeToString(h.Sum(nil)); got != rel.SHA256 {
		out.Close()
		os.Remove(part)
		return fmt.Errorf("the downloaded file is damaged (SHA256 %s, expected %s); please try again", got, rel.SHA256)
	}
	if err := out.Close(); err != nil {
		return err
	}
	return os.Rename(part, dest)
}

// offsetProgress reports progress of a download that continues after skip
// bytes.
func offsetProgress(progress ByteProgress, skip int64) ByteProgress {
	if progress == nil {
		return nil
	}
	return func(done, total int64) { progress(skip+done, total) }
}

// PruneCache removes cached ISOs (and unfinished downloads) of versions not
// in keep.  It only touches the version folders CachePath makes.
func PruneCache(keep []Release) error {
	dir, err := cacheDir()
	if err != nil {
		return err
	}
	ents, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	kept := map[string]bool{}
	for i := range keep {
		kept[safeVersion(keep[i].Version)] = true
	}
	for _, e := range ents {
		if !e.IsDir() || kept[e.Name()] {
			continue
		}
		vd := filepath.Join(dir, e.Name())
		os.Remove(filepath.Join(vd, ISOName))
		os.Remove(filepath.Join(vd, ISOName+".part"))
		os.Remove(vd) // only if nothing else is in it
	}
	return nil
}

// HashFile returns the hex SHA256 of path.
func HashFile(ctx context.Context, path string, progress ByteProgress) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return "", err
	}
	h := sha256.New()
	if _, err := copyWithProgress(ctx, h, f, st.Size(), progress); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// copyWithProgress copies in 1 MiB chunks, honouring ctx and reporting at
// most every 100 ms.
func copyWithProgress(ctx context.Context, dst io.Writer, src io.Reader, total int64, progress ByteProgress) (int64, error) {
	buf := make([]byte, 1<<20)
	var done int64
	last := time.Time{}
	for {
		if err := ctx.Err(); err != nil {
			return done, err
		}
		n, rerr := src.Read(buf)
		if n > 0 {
			if _, err := dst.Write(buf[:n]); err != nil {
				return done, err
			}
			done += int64(n)
			if progress != nil && time.Since(last) > 100*time.Millisecond {
				progress(done, total)
				last = time.Now()
			}
		}
		if rerr == io.EOF {
			if progress != nil {
				progress(done, total)
			}
			return done, nil
		}
		if rerr != nil {
			return done, rerr
		}
	}
}
