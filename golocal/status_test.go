package main

// Regression tests for the status page's problem rules, in particular the
// "cert-untrusted" warning: a basic/prepackaged install serves a chain issued
// by the project test CA (CN=*.junelife.com), which a clean oven does not
// trust. The warning must fire only in that case — never for a per-home CA
// (CN=June Local CA) or for the factory GoDaddy chain.
//
// The identity tests cover docs/identity-generation.md: minting/validating the
// per-oven v2 token, the read-only accounts.db probe, the
// load/copy-or-mint behaviour of /data/june/identity.json, and the redaction
// rules (the status page/problem list must never carry the full token).

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// hasProblem reports whether buildProblems emitted a problem with the given id.
func hasProblem(problems []Problem, id string) bool {
	for _, p := range problems {
		if p.ID == id {
			return true
		}
	}
	return false
}

// cleanStatus returns StatusData with the other buildProblems rules quiet so a
// cert-untrusted assertion cannot be masked by unrelated noise.
func cleanStatus(cert CertStatus) StatusData {
	return StatusData{
		Oven: OvenStatus{
			Connection: "connected", SystemSlot: "app", CollectorMounted: true,
			Identity: Identity{AccountPresent: true, TokenSource: "identity.json"},
		},
		Camera:  CameraStatus{CameradRunning: true, StockSocket: true},
		Install: InstallStatus{},
		Network: NetworkStatus{},
		Cert:    cert,
		Storage: StorageStatus{DataFreePct: 50},
		Presets: PresetsStatus{CatalogEntries: 1},
	}
}

func TestBuildProblemsCertUntrusted(t *testing.T) {
	cases := []struct {
		name string
		cert CertStatus
		want bool
	}{
		{
			name: "project test CA issuer, not in system store",
			cert: CertStatus{CAInSystemStore: false, Issuer: "CN=*.junelife.com", DaysRemaining: 365},
			want: true,
		},
		{
			name: "project test CA issuer, present in system store",
			cert: CertStatus{CAInSystemStore: true, Issuer: "CN=*.junelife.com", DaysRemaining: 365},
			want: false,
		},
		{
			name: "per-home CA issuer",
			cert: CertStatus{CAInSystemStore: false, Issuer: "CN=June Local CA", DaysRemaining: 365},
			want: false,
		},
		{
			name: "factory GoDaddy intermediate issuer",
			cert: CertStatus{CAInSystemStore: false, Issuer: "CN=Go Daddy Secure Certificate Authority - G2", DaysRemaining: 365},
			want: false,
		},
		{
			name: "no certificate parsed",
			cert: CertStatus{},
			want: false,
		},
	}
	for _, conn := range []string{"connected", "disconnected"} {
		for _, tc := range cases {
			t.Run(tc.name+"/"+conn, func(t *testing.T) {
				d := cleanStatus(tc.cert)
				d.Oven.Connection = conn
				got := hasProblem(buildProblems(d), "cert-untrusted")
				if got != tc.want {
					t.Fatalf("cert-untrusted = %v, want %v (issuer %q, CAInSystemStore %v)",
						got, tc.want, tc.cert.Issuer, tc.cert.CAInSystemStore)
				}
			})
		}
	}
}

func TestBuildProblemsCertUntrustedSeverity(t *testing.T) {
	d := cleanStatus(CertStatus{CAInSystemStore: false, Issuer: "CN=*.junelife.com", DaysRemaining: 365})
	for _, p := range buildProblems(d) {
		if p.ID != "cert-untrusted" {
			continue
		}
		if p.Severity != "red" {
			t.Fatalf("cert-untrusted severity = %q, want red", p.Severity)
		}
		if p.Title == "" || p.Detail == "" || p.Fix == "" {
			t.Fatalf("cert-untrusted problem is missing title/detail/fix: %+v", p)
		}
		return
	}
	t.Fatal("buildProblems did not emit cert-untrusted for the project test CA chain")
}

func TestReadTrimmedStripsTrailingNUL(t *testing.T) {
	// /proc/device-tree/model is NUL-terminated; the status page must not show
	// the NUL (it would end up escaped in JSON and copied diagnostics).
	path := filepath.Join(t.TempDir(), "model")
	if err := os.WriteFile(path, []byte("June Oven (meerkat)\x00"), 0o644); err != nil {
		t.Fatalf("write model: %v", err)
	}
	got := readTrimmed(path)
	if want := "June Oven (meerkat)"; got != want {
		t.Fatalf("readTrimmed = %q, want %q", got, want)
	}
	if strings.ContainsRune(got, '\x00') {
		t.Fatalf("readTrimmed left a trailing NUL: %q", got)
	}
	if got := readTrimmed(filepath.Join(t.TempDir(), "missing")); got != "" {
		t.Fatalf("readTrimmed(missing) = %q, want empty", got)
	}
}

// --- local oven identity -----------------------------------------------------

// withoutSQLite forces the accounts.db byte probe for the duration of a test so
// the result never depends on whether the host has a sqlite3 CLI installed.
func withoutSQLite(t *testing.T) {
	t.Helper()
	lookup, run := sqlite3LookPath, runSQLiteQuery
	sqlite3LookPath = func() string { return "" }
	runSQLiteQuery = func(string, string, string) (string, error) { return "", nil }
	t.Cleanup(func() { sqlite3LookPath, runSQLiteQuery = lookup, run })
}

func TestMintIdentityToken(t *testing.T) {
	seen := make(map[string]bool)
	for i := 0; i < 32; i++ {
		tok, err := MintIdentityToken()
		if err != nil {
			t.Fatalf("MintIdentityToken: %v", err)
		}
		if !ValidateIdentityToken(tok) {
			t.Fatalf("minted token %q does not validate", tok)
		}
		if seen[tok] {
			t.Fatalf("MintIdentityToken returned a duplicate: %q", tok)
		}
		seen[tok] = true
	}
}

func TestValidateIdentityToken(t *testing.T) {
	valid := identityTokenPrefix + strings.Repeat("A", identityTokenBodyLen)
	cases := []struct {
		name  string
		token string
		want  bool
	}{
		{"minted shape", valid, true},
		{"url-safe alphabet", identityTokenPrefix + strings.Repeat("-", identityTokenBodyLen), true},
		{"empty", "", false},
		{"prefix only", identityTokenPrefix, false},
		{"short body", identityTokenPrefix + strings.Repeat("A", identityTokenBodyLen-1), false},
		{"long body", identityTokenPrefix + strings.Repeat("A", identityTokenBodyLen+1), false},
		{"wrong prefix", "v1:" + strings.Repeat("A", identityTokenBodyLen), false},
		{"no prefix", strings.Repeat("A", identityTokenBodyLen+len(identityTokenPrefix)), false},
		{"padding", identityTokenPrefix + strings.Repeat("A", identityTokenBodyLen-2) + "==", false},
		{"std base64 alphabet", identityTokenPrefix + strings.Repeat("+", identityTokenBodyLen), false},
		{"trailing space", valid + " ", false},
	}
	for _, tc := range cases {
		if got := ValidateIdentityToken(tc.token); got != tc.want {
			t.Errorf("%s: ValidateIdentityToken(%q) = %v, want %v", tc.name, tc.token, got, tc.want)
		}
	}
}

func TestTokenPrefixNeverExposesToken(t *testing.T) {
	tok, err := MintIdentityToken()
	if err != nil {
		t.Fatalf("MintIdentityToken: %v", err)
	}
	p := TokenPrefix(tok)
	if p == "" || p == tok {
		t.Fatalf("TokenPrefix(%q) = %q, want a distinct non-empty prefix", tok, p)
	}
	if !strings.HasPrefix(p, identityTokenPrefix) {
		t.Fatalf("TokenPrefix(%q) = %q, want the %q prefix", tok, p, identityTokenPrefix)
	}
	body := tok[len(identityTokenPrefix):]
	if strings.Contains(p, body) {
		t.Fatalf("TokenPrefix(%q) = %q exposes the token body", tok, p)
	}
	if strings.Contains(p, body[6:]) {
		t.Fatalf("TokenPrefix(%q) = %q exposes more than the display prefix", tok, p)
	}
	for _, bad := range []string{"", "v2:", "not-a-token", "v2:short"} {
		if got := TokenPrefix(bad); got != "" {
			t.Errorf("TokenPrefix(%q) = %q, want empty for a malformed token", bad, got)
		}
	}
}

func TestParseAccountRows(t *testing.T) {
	cases := []struct {
		name string
		out  string
		want []string
	}{
		{"no rows", "", nil},
		{"one row", "June Oven\n", []string{"June Oven"}},
		{"two rows", "June Oven\nJune Oven (local)\n", []string{"June Oven", "June Oven (local)"}},
		{"crlf", "June Oven\r\n", []string{"June Oven"}},
		{"blank lines ignored", "\nJune Oven\n\n", []string{"June Oven"}},
		{"spaces trimmed", "  June Oven  \n", []string{"June Oven"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := parseAccountRows(tc.out)
			if strings.Join(got, "|") != strings.Join(tc.want, "|") {
				t.Fatalf("parseAccountRows(%q) = %q, want %q", tc.out, got, tc.want)
			}
		})
	}
}

func TestProbeJuneAccount(t *testing.T) {
	withoutSQLite(t)
	dir := t.TempDir()
	withRow := filepath.Join(dir, "with.db")
	if err := os.WriteFile(withRow, []byte("junk"+juneAccountType+"junk"), 0o644); err != nil {
		t.Fatalf("write account db: %v", err)
	}
	withoutRow := filepath.Join(dir, "without.db")
	if err := os.WriteFile(withoutRow, []byte("some other account data"), 0o644); err != nil {
		t.Fatalf("write account db: %v", err)
	}
	cases := []struct {
		name    string
		path    string
		present bool
		source  string
	}{
		{"june type present", withRow, true, "text"},
		{"june type absent", withoutRow, false, "text"},
		{"missing file", filepath.Join(dir, "absent.db"), false, "missing"},
		{"empty path", "", false, "missing"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := ProbeJuneAccount(tc.path)
			if got.Present != tc.present || got.Source != tc.source {
				t.Fatalf("ProbeJuneAccount(%q) = %+v, want present=%v source=%s", tc.path, got, tc.present, tc.source)
			}
		})
	}
}

func TestProbeJuneAccountUsesSQLite(t *testing.T) {
	dir := t.TempDir()
	dbPath := filepath.Join(dir, "accounts.db")
	if err := os.WriteFile(dbPath, []byte("junk"+juneAccountType+"junk"), 0o644); err != nil {
		t.Fatalf("write account db: %v", err)
	}
	lookup, run := sqlite3LookPath, runSQLiteQuery
	t.Cleanup(func() { sqlite3LookPath, runSQLiteQuery = lookup, run })
	sqlite3LookPath = func() string { return "/system/bin/sqlite3" }

	runSQLiteQuery = func(binary, path, query string) (string, error) {
		if binary != "/system/bin/sqlite3" || path != dbPath {
			t.Errorf("sqlite3 invoked as %q on %q, want the configured binary and db", binary, path)
		}
		if !strings.Contains(query, juneAccountType) {
			t.Errorf("sqlite3 query %q does not filter on %q", query, juneAccountType)
		}
		return "June Oven\n", nil
	}
	if got := ProbeJuneAccount(dbPath); !got.Present || got.Name != "June Oven" || got.Source != "sqlite3" {
		t.Fatalf("ProbeJuneAccount via sqlite3 = %+v, want present with name June Oven", got)
	}

	// A definitive sqlite3 answer beats a byte-probe false positive (for
	// example the type string in a freed page).
	runSQLiteQuery = func(string, string, string) (string, error) { return "", nil }
	if got := ProbeJuneAccount(dbPath); got.Present || got.Source != "sqlite3" {
		t.Fatalf("ProbeJuneAccount via empty sqlite3 = %+v, want absent with source sqlite3", got)
	}

	// A failing sqlite3 falls back to the byte probe instead of claiming absent.
	runSQLiteQuery = func(string, string, string) (string, error) { return "", os.ErrInvalid }
	if got := ProbeJuneAccount(dbPath); !got.Present || got.Source != "text" {
		t.Fatalf("ProbeJuneAccount after sqlite3 failure = %+v, want the byte-probe result", got)
	}
}

func TestSaveIdentityFileAtomic(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "identity.json")
	tok, err := MintIdentityToken()
	if err != nil {
		t.Fatalf("MintIdentityToken: %v", err)
	}
	if err := SaveIdentityFile(path, NewIdentityFile(tok, "test")); err != nil {
		t.Fatalf("SaveIdentityFile: %v", err)
	}
	doc, err := LoadIdentityFile(path)
	if err != nil {
		t.Fatalf("LoadIdentityFile: %v", err)
	}
	if err := ValidateIdentityFile(doc); err != nil {
		t.Fatalf("saved identity does not validate: %v", err)
	}
	if doc.Account.Token != tok {
		t.Fatalf("saved token = %q, want %q", doc.Account.Token, tok)
	}
	if doc.Role != identityRoleOven || doc.Account.Type != juneAccountType ||
		doc.Account.TokenType != juneAuthTokenAccess || doc.Account.RefreshTokenType != juneAuthTokenRefresh {
		t.Fatalf("saved identity has the wrong account block: %+v", doc.Account)
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("read identity dir: %v", err)
	}
	for _, e := range entries {
		if e.Name() != "identity.json" {
			t.Fatalf("atomic save left a stray file %q (tmp file not renamed?)", e.Name())
		}
	}
}

func TestEnsureOvenIdentity(t *testing.T) {
	const seededToken = identityTokenPrefix + "AAAAAAAAAAAAAAAAAAAAAAAAAAAA"
	validDoc := func() *IdentityFile { return NewIdentityFile(seededToken, "test") }
	cases := []struct {
		name       string
		identity   string // contents for identity.json; "" = leave absent
		seedToken  string // contents for the /system seed token; "" = leave absent
		mint       bool
		wantSource string
		wantErr    bool
	}{
		{name: "loads an existing identity", identity: mustJSON(t, validDoc()), wantSource: "identity.json"},
		{name: "copies the installer seed token", seedToken: seededToken, wantSource: "system-token"},
		{name: "mints when nothing exists", mint: true, wantSource: "generated"},
		{name: "refuses when nothing exists and minting is off", mint: false, wantErr: true},
		{name: "replaces an unusable identity", identity: "{not json", mint: true, wantSource: "generated"},
		{name: "replaces a companion identity", identity: `{"role":"companion","account":{"token":"` + seededToken + `"}}`, seedToken: seededToken, wantSource: "system-token"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			identityPath := filepath.Join(dir, "identity.json")
			seedPath := filepath.Join(dir, "token")
			if tc.identity != "" {
				if err := os.WriteFile(identityPath, []byte(tc.identity), 0o644); err != nil {
					t.Fatalf("write identity: %v", err)
				}
			}
			if tc.seedToken != "" {
				if err := os.WriteFile(seedPath, []byte(tc.seedToken+"\n"), 0o644); err != nil {
					t.Fatalf("write seed token: %v", err)
				}
			}
			got, err := EnsureOvenIdentity(identityPath, seedPath, "test", tc.mint)
			if tc.wantErr {
				if err == nil {
					t.Fatalf("EnsureOvenIdentity succeeded, want an error")
				}
				if _, statErr := os.Stat(identityPath); statErr == nil {
					t.Fatalf("EnsureOvenIdentity wrote identity.json despite the error")
				}
				return
			}
			if err != nil {
				t.Fatalf("EnsureOvenIdentity: %v", err)
			}
			if got.Source != tc.wantSource {
				t.Fatalf("source = %q, want %q", got.Source, tc.wantSource)
			}
			doc, err := LoadIdentityFile(identityPath)
			if err != nil {
				t.Fatalf("load written identity: %v", err)
			}
			if err := ValidateIdentityFile(doc); err != nil {
				t.Fatalf("written identity does not validate: %v", err)
			}
			if got.Token != doc.Account.Token {
				t.Fatalf("returned token does not match the written identity")
			}
			if tc.seedToken != "" && got.Source == "system-token" && doc.Account.Token != tc.seedToken {
				t.Fatalf("identity token = %q, want the seed token", doc.Account.Token)
			}
		})
	}
}

func TestIdentityStatusForRedaction(t *testing.T) {
	withoutSQLite(t)
	dir := t.TempDir()
	identityPath := filepath.Join(dir, "identity.json")
	dbPath := filepath.Join(dir, "accounts.db")
	tok := identityTokenPrefix + strings.Repeat("B", identityTokenBodyLen)
	if err := SaveIdentityFile(identityPath, NewIdentityFile(tok, "test")); err != nil {
		t.Fatalf("SaveIdentityFile: %v", err)
	}
	if err := os.WriteFile(dbPath, []byte("junk"+juneAccountType+"junk"), 0o644); err != nil {
		t.Fatalf("write account db: %v", err)
	}
	cfg := &Config{
		IdentityFile:  identityPath,
		SeedTokenFile: filepath.Join(dir, "seed-token"),
		AccountsDB:    dbPath,
	}
	id := IdentityStatusFor(cfg)
	if !id.AccountPresent {
		t.Fatalf("AccountPresent = false, want true (byte probe found %q)", juneAccountType)
	}
	if id.AccountName != "June Oven" {
		t.Fatalf("AccountName = %q, want the identity file's account name", id.AccountName)
	}
	if id.TokenSource != "identity.json" || id.TokenType != juneAuthTokenAccess {
		t.Fatalf("identity status = %+v, want source identity.json and token type %q", id, juneAuthTokenAccess)
	}
	if id.TokenPrefix == "" || id.TokenPrefix == tok {
		t.Fatalf("TokenPrefix = %q, want a short display prefix, not the token", id.TokenPrefix)
	}
	body := tok[len(identityTokenPrefix):]
	if strings.Contains(id.TokenPrefix, body) {
		t.Fatalf("TokenPrefix = %q exposes the token body", id.TokenPrefix)
	}

	// The token must not reach the status JSON by any field.
	b, err := json.Marshal(StatusData{Oven: OvenStatus{Identity: id}})
	if err != nil {
		t.Fatalf("marshal status: %v", err)
	}
	if strings.Contains(string(b), tok) {
		t.Fatalf("status JSON contains the full identity token: %s", b)
	}
	if strings.Contains(string(b), body) {
		t.Fatalf("status JSON contains the token body: %s", b)
	}
}

func TestIdentityStatusForNoIdentity(t *testing.T) {
	withoutSQLite(t)
	dir := t.TempDir()
	cfg := &Config{
		IdentityFile:  filepath.Join(dir, "absent.json"),
		SeedTokenFile: filepath.Join(dir, "absent-token"),
		AccountsDB:    filepath.Join(dir, "absent.db"),
	}
	id := IdentityStatusFor(cfg)
	if id.AccountPresent || id.TokenSource != "none" || id.TokenPrefix != "" || id.TokenType != "" {
		t.Fatalf("identity status = %+v, want an empty/none identity", id)
	}
}

func TestIdentityMissingProblem(t *testing.T) {
	cases := []struct {
		name    string
		present bool
		want    bool
	}{
		{"account row present", true, false},
		{"account row missing", false, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			d := cleanStatus(CertStatus{})
			d.Oven.Identity = Identity{AccountPresent: tc.present, TokenSource: "identity.json", TokenPrefix: "v2:AAAAAA..."}
			var got *Problem
			problems := buildProblems(d)
			for i := range problems {
				if problems[i].ID == "identity-missing" {
					got = &problems[i]
					break
				}
			}
			if (got != nil) != tc.want {
				t.Fatalf("identity-missing emitted = %v, want %v (problems: %+v)", got != nil, tc.want, problems)
			}
			if got == nil {
				return
			}
			if got.Severity != "red" {
				t.Fatalf("identity-missing severity = %q, want red", got.Severity)
			}
			if got.Title == "" || got.Detail == "" || got.Fix == "" {
				t.Fatalf("identity-missing is missing title/detail/fix: %+v", got)
			}
			for _, want := range []string{"accounts.db", "reset", "boot"} {
				if !strings.Contains(strings.ToLower(got.Detail+got.Fix), want) {
					t.Fatalf("identity-missing remedy does not mention %q: %+v", want, got)
				}
			}
		})
	}
}

func TestInitOvenIdentityNeverLogsToken(t *testing.T) {
	withoutSQLite(t)
	dir := t.TempDir()
	logFile := filepath.Join(dir, "identity.log")
	oldLogPath := logPath
	logPath = logFile
	t.Cleanup(func() { logPath = oldLogPath })

	cfg := &Config{
		IdentityFile:  filepath.Join(dir, "identity.json"),
		SeedTokenFile: filepath.Join(dir, "seed-token"),
		AccountsDB:    filepath.Join(dir, "accounts.db"),
		MintIdentity:  true,
	}
	initOvenIdentity(cfg)

	b, err := os.ReadFile(logFile)
	if err != nil {
		t.Fatalf("read identity log: %v", err)
	}
	logText := string(b)
	doc, err := LoadIdentityFile(cfg.IdentityFile)
	if err != nil {
		t.Fatalf("load minted identity: %v", err)
	}
	tok := doc.Account.Token
	if !ValidateIdentityToken(tok) {
		t.Fatalf("initOvenIdentity wrote a malformed token")
	}
	if strings.Contains(logText, tok) {
		t.Fatalf("startup log contains the full identity token:\n%s", logText)
	}
	if !strings.Contains(logText, TokenPrefix(tok)) {
		t.Fatalf("startup log does not identify the token by prefix:\n%s", logText)
	}
	if !strings.Contains(logText, "identity-missing") {
		t.Fatalf("startup log does not warn about the missing account row:\n%s", logText)
	}
}

// mustJSON marshals v for a table-test fixture.
func mustJSON(t *testing.T, v any) string {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("marshal fixture: %v", err)
	}
	return string(b)
}
