package stick

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestFetchReleases(t *testing.T) {
	const sum = "ac0a86673b7cc7c15d73f7109066baf1a43f7f1f1767555b20d2dacef59438c5"
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"releases": [
{"version": "v0.7", "url": "https://example.org/v0.7/june-local-live.iso", "sha256": "` + sum + `", "size": 1413529600, "date": "2026-10-11"},
{"version": "v0.6", "url": "http://example.org/v0.6/june-local-live.iso", "sha256": "` + sum + `", "size": 1413529600},
{"version": "v0.5", "url": "https://example.org/v0.5/june-local-live.iso", "sha256": "` + "AC0A86673B7CC7C15D73F7109066BAF1A43F7F1F1767555B20D2DACEF59438C5" + `", "size": 1406533632}
]}`))
	}))
	defer srv.Close()

	rels, err := FetchReleases(context.Background(), srv.URL)
	if err != nil {
		t.Fatal(err)
	}
	// v0.6 has no https URL and is left out; the order is kept.
	if len(rels) != 2 || rels[0].Version != "v0.7" || rels[1].Version != "v0.5" {
		t.Fatalf("got %+v", rels)
	}
	if rels[0].Date != "2026-10-11" || rels[1].SHA256 != sum {
		t.Fatalf("got %+v", rels)
	}
}

func TestFetchReleasesEmpty(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"releases": []}`))
	}))
	defer srv.Close()
	if _, err := FetchReleases(context.Background(), srv.URL); err == nil {
		t.Fatal("expected an error for an empty list")
	}
}

// isoServer serves body like R2 does (range requests honoured unless
// noRange) and records the Range header of each request.
func isoServer(t *testing.T, body []byte, noRange bool) (*httptest.Server, *[]string) {
	var ranges []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ranges = append(ranges, r.Header.Get("Range"))
		if noRange {
			r.Header.Del("Range")
		}
		http.ServeContent(w, r, "june-local-live.iso", time.Time{}, bytes.NewReader(body))
	}))
	t.Cleanup(srv.Close)
	return srv, &ranges
}

func testRelease(url string, body []byte) *Release {
	sum := sha256.Sum256(body)
	return &Release{Version: "v9", URL: url, SHA256: hex.EncodeToString(sum[:]), Size: int64(len(body))}
}

func TestDownloadResumes(t *testing.T) {
	body := bytes.Repeat([]byte("june"), 300000)
	srv, ranges := isoServer(t, body, false)
	dest := filepath.Join(t.TempDir(), ISOName)
	os.WriteFile(dest+".part", body[:500000], 0o644)

	var last int64
	if err := Download(context.Background(), testRelease(srv.URL, body), dest, func(d, _ int64) { last = d }); err != nil {
		t.Fatal(err)
	}
	if got, _ := os.ReadFile(dest); !bytes.Equal(got, body) {
		t.Fatal("wrong file content")
	}
	if len(*ranges) != 1 || (*ranges)[0] != "bytes=500000-" {
		t.Fatalf("requests: %q", *ranges)
	}
	if last != int64(len(body)) {
		t.Fatalf("progress ended at %d", last)
	}
	if _, err := os.Stat(dest + ".part"); !os.IsNotExist(err) {
		t.Fatal(".part left behind")
	}
}

func TestDownloadRestartsWithoutRanges(t *testing.T) {
	body := bytes.Repeat([]byte("oven"), 200000)
	srv, _ := isoServer(t, body, true)
	dest := filepath.Join(t.TempDir(), ISOName)
	os.WriteFile(dest+".part", body[:1000], 0o644)
	if err := Download(context.Background(), testRelease(srv.URL, body), dest, nil); err != nil {
		t.Fatal(err)
	}
	if got, _ := os.ReadFile(dest); !bytes.Equal(got, body) {
		t.Fatal("wrong file content")
	}
}

func TestDownloadDropsDamagedPart(t *testing.T) {
	body := bytes.Repeat([]byte("glow"), 200000)
	srv, ranges := isoServer(t, body, false)
	dest := filepath.Join(t.TempDir(), ISOName)
	os.WriteFile(dest+".part", bytes.Repeat([]byte("x"), 1000), 0o644)
	rel := testRelease(srv.URL, body)
	if err := Download(context.Background(), rel, dest, nil); err == nil {
		t.Fatal("expected a SHA256 error")
	}
	if _, err := os.Stat(dest + ".part"); !os.IsNotExist(err) {
		t.Fatal("damaged .part kept")
	}
	// The next try starts from scratch and succeeds.
	if err := Download(context.Background(), rel, dest, nil); err != nil {
		t.Fatal(err)
	}
	if (*ranges)[1] != "" {
		t.Fatalf("second try sent Range %q", (*ranges)[1])
	}
}

func TestDownloadKeepsPartWhenCancelled(t *testing.T) {
	body := bytes.Repeat([]byte("stik"), 2000000)
	// Send the first 2 MB, then stall like a dropped connection.
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Length", fmt.Sprint(len(body)))
		w.Write(body[:2<<20])
		w.(http.Flusher).Flush()
		<-r.Context().Done()
	}))
	t.Cleanup(srv.Close)
	dest := filepath.Join(t.TempDir(), ISOName)
	ctx, cancel := context.WithCancel(context.Background())
	time.AfterFunc(300*time.Millisecond, cancel)
	if err := Download(ctx, testRelease(srv.URL, body), dest, nil); err == nil {
		t.Fatal("expected cancellation")
	}
	st, err := os.Stat(dest + ".part")
	if err != nil || st.Size() != 2<<20 {
		t.Fatalf(".part not kept: %v %v", st, err)
	}
}

func TestPruneCache(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("JUNE_USB_CACHE", dir)
	for _, v := range []string{"v0.5", "v0.6", "v0.7"} {
		os.MkdirAll(filepath.Join(dir, v), 0o755)
		os.WriteFile(filepath.Join(dir, v, ISOName), []byte("iso"), 0o644)
	}
	os.WriteFile(filepath.Join(dir, "v0.5", ISOName+".part"), []byte("p"), 0o644)
	os.MkdirAll(filepath.Join(dir, "other"), 0o755)
	os.WriteFile(filepath.Join(dir, "other", "notes.txt"), []byte("keep me"), 0o644)

	if err := PruneCache([]Release{{Version: "v0.7"}, {Version: "v0.6"}}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(dir, "v0.5")); !os.IsNotExist(err) {
		t.Fatal("v0.5 not removed")
	}
	for _, p := range []string{"v0.6/" + ISOName, "v0.7/" + ISOName, "other/notes.txt"} {
		if _, err := os.Stat(filepath.Join(dir, p)); err != nil {
			t.Fatalf("%s removed", p)
		}
	}
}
