package stick

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
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
