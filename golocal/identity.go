package main

// Local oven identity: the per-oven v2 bearer token, the
// /data/june/identity.json record and a read-only probe of the Android account
// database.
//
// Why this exists: a factory reset wipes the single com.junelife.user row in
// /data/system/users/0/accounts.db. The oven's JuneCloudMessaging app reads
// that row through AccountManager and attaches the token as
// "Authorization: Bearer v2:..." when it opens its messaging socket; with no
// row it sends no token and never connects (docs/identity-generation.md).
// june-local runs after Android has started, so it must NEVER write
// accounts.db -- a row written now is invisible until the next boot and
// racing AccountManagerService risks corruption. The installer pre-seeds the
// token and the account DB, and the pre-Android boot ensure installs the row;
// this file only mints/keeps the token record and observes the row so the
// support page can explain a correctly-installed oven that never connects.

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

const (
	// identityVersion is the schema version of /data/june/identity.json.
	identityVersion = 1
	// identityRoleOven marks an identity.json as an oven (not companion)
	// record. The companion identity loaded by --identity has no role/token
	// block like this and is deliberately kept separate.
	identityRoleOven = "oven"
	// juneAccountType is Accounts.ACCOUNT_TYPE_JUNE: the JCM selects its
	// account by type, so the visible name is free-form but this string is not.
	juneAccountType = "com.junelife.user"
	// juneAuthTokenAccess is Accounts.AUTHTOKEN_ACCESS: the token type the
	// messaging socket reads. It must be exactly this string.
	juneAuthTokenAccess = "Full access"
	// juneAuthTokenRefresh is Accounts.AUTHTOKEN_REFRESH. The real cloud seeded
	// it too; it is not needed to open the socket but is kept for fidelity.
	juneAuthTokenRefresh = "Refresh access"

	// The real cloud issued "v2:" plus 28 URL-safe base64 characters (21 random
	// bytes). The relay accepts any bearer token, so the shape is defensive
	// only -- it avoids surprises if an app or parser sanity-checks it.
	identityTokenPrefix  = "v2:"
	identityTokenBytes   = 21
	identityTokenBodyLen = 28

	// defaultIdentityFile is the regenerable bookkeeping record read at
	// runtime; it is NOT the gate (accounts.db is).
	defaultIdentityFile = "/data/june/identity.json"
	// defaultSeedTokenFile is the installer-seeded token that survives a
	// factory reset because it lives on /system (APP and SAP).
	defaultSeedTokenFile = "/system/etc/june/identity/token"
	// defaultAccountsDB is the Android account database the JCM reads.
	defaultAccountsDB = "/data/system/users/0/accounts.db"
)

// IdentityAccount is the account block of identity.json (docs/identity-generation.md 4.3).
type IdentityAccount struct {
	Name             string `json:"name"`
	Type             string `json:"type"`
	TokenType        string `json:"token_type"`
	RefreshTokenType string `json:"refresh_token_type,omitempty"`
	Token            string `json:"token"`
}

// IdentityFile is the local /data/june/identity.json document.
type IdentityFile struct {
	Version     int             `json:"version"`
	Role        string          `json:"role"`
	GeneratedAt string          `json:"generated_at,omitempty"`
	GeneratedBy string          `json:"generated_by,omitempty"`
	Endpoint    map[string]any  `json:"endpoint,omitempty"`
	Account     IdentityAccount `json:"account"`
	Oven        map[string]any  `json:"oven,omitempty"`
	Notes       string          `json:"notes,omitempty"`
}

// MintIdentityToken returns a fresh per-oven token: "v2:" plus 28 URL-safe
// base64 characters (21 random bytes), matching the observed cloud shape.
// The token is not a real credential -- the relay accepts any bearer token and
// the oven's Ed25519 signing key stays in the ATECC508A -- so it needs no
// server-side registration.
func MintIdentityToken() (string, error) {
	var raw [identityTokenBytes]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return "", fmt.Errorf("mint identity token: %w", err)
	}
	return identityTokenPrefix + base64.RawURLEncoding.EncodeToString(raw[:]), nil
}

// ValidateIdentityToken reports whether token has the expected shape. It is
// deliberately strict (prefix, exact length, URL-safe base64, 21 decoded
// bytes) so a truncated or corrupt token is never treated as usable.
func ValidateIdentityToken(token string) bool {
	if !strings.HasPrefix(token, identityTokenPrefix) {
		return false
	}
	if len(token) != len(identityTokenPrefix)+identityTokenBodyLen {
		return false
	}
	raw, err := base64.RawURLEncoding.DecodeString(token[len(identityTokenPrefix):])
	return err == nil && len(raw) == identityTokenBytes
}

// TokenPrefix returns a short display form of a token ("v2:AbCdEf...") so the
// status page and logs can identify which token is in use without exposing it.
// It returns "" for a malformed token -- never a token, whole or partial.
func TokenPrefix(token string) string {
	if !ValidateIdentityToken(token) {
		return ""
	}
	body := token[len(identityTokenPrefix):]
	return identityTokenPrefix + body[:6] + "..."
}

// NewIdentityFile builds the identity.json record for a minted or seeded token.
func NewIdentityFile(token, generatedBy string) *IdentityFile {
	return &IdentityFile{
		Version:     identityVersion,
		Role:        identityRoleOven,
		GeneratedAt: time.Now().UTC().Format(time.RFC3339),
		GeneratedBy: generatedBy,
		Account: IdentityAccount{
			Name:             "June Oven",
			Type:             juneAccountType,
			TokenType:        juneAuthTokenAccess,
			RefreshTokenType: juneAuthTokenRefresh,
			Token:            token,
		},
		Notes: "token minted locally; the relay accepts any bearer token; the oven Ed25519 signing key is in the ATECC508A",
	}
}

// LoadIdentityFile reads and parses identity.json. It does not validate the
// token shape; use ValidateIdentityFile for that.
func LoadIdentityFile(path string) (*IdentityFile, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var doc IdentityFile
	if err := json.Unmarshal(b, &doc); err != nil {
		return nil, fmt.Errorf("parse %s: %w", path, err)
	}
	return &doc, nil
}

// ValidateIdentityFile checks that doc is an oven identity carrying a usable
// token. An empty role/type is accepted for hand-written files; a mismatched
// role (for example a companion identity) is not.
func ValidateIdentityFile(doc *IdentityFile) error {
	if doc == nil {
		return errors.New("empty identity file")
	}
	if doc.Role != "" && doc.Role != identityRoleOven {
		return fmt.Errorf("identity role %q is not %q; this is not an oven identity", doc.Role, identityRoleOven)
	}
	if doc.Account.Type != "" && doc.Account.Type != juneAccountType {
		return fmt.Errorf("account type %q is not %q", doc.Account.Type, juneAccountType)
	}
	if !ValidateIdentityToken(doc.Account.Token) {
		return fmt.Errorf("identity token is not %q followed by %d base64url characters", identityTokenPrefix, identityTokenBodyLen)
	}
	return nil
}

// SaveIdentityFile writes doc atomically: a 0644 temp file in the target
// directory, fsynced and renamed over the destination. A half-written
// identity.json must never be observed by the next boot's ensure.
func SaveIdentityFile(path string, doc *IdentityFile) error {
	if path == "" {
		return errors.New("identity file path is empty")
	}
	b, err := json.MarshalIndent(doc, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal identity: %w", err)
	}
	b = append(b, '\n')
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".identity-*.json")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	remove := func() { _ = os.Remove(tmpName) }
	if _, err := tmp.Write(b); err != nil {
		_ = tmp.Close()
		remove()
		return err
	}
	if err := tmp.Chmod(0o644); err != nil {
		_ = tmp.Close()
		remove()
		return err
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		remove()
		return err
	}
	if err := tmp.Close(); err != nil {
		remove()
		return err
	}
	if err := os.Rename(tmpName, path); err != nil {
		remove()
		return err
	}
	return nil
}

// LocalIdentity is the outcome of loading (or creating) the local identity.
type LocalIdentity struct {
	Doc    *IdentityFile
	Token  string
	Source string // "identity.json", "system-token" or "generated"; "" when none
	Note   string // human-readable warning for the log; never contains the token
}

// EnsureOvenIdentity loads a valid identity.json, or writes one from the
// /system seed token, or -- when mint is set -- mints a fresh token. Call it
// once at startup: it writes identity.json (regenerable) and never accounts.db.
func EnsureOvenIdentity(identityPath, seedTokenPath, generatedBy string, mint bool) (LocalIdentity, error) {
	note := ""
	if doc, err := LoadIdentityFile(identityPath); err == nil {
		if vErr := ValidateIdentityFile(doc); vErr == nil {
			return LocalIdentity{Doc: doc, Token: doc.Account.Token, Source: "identity.json"}, nil
		} else {
			note = fmt.Sprintf("existing %s is unusable (%v); replacing it", identityPath, vErr)
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		note = fmt.Sprintf("cannot read %s (%v); replacing it", identityPath, err)
	}

	if token := readSeedToken(seedTokenPath); token != "" {
		doc := NewIdentityFile(token, generatedBy)
		if err := SaveIdentityFile(identityPath, doc); err != nil {
			return LocalIdentity{Doc: doc, Token: token, Source: "system-token", Note: note}, fmt.Errorf("copy seed identity to %s: %w", identityPath, err)
		}
		return LocalIdentity{Doc: doc, Token: token, Source: "system-token", Note: note}, nil
	}

	if !mint {
		return LocalIdentity{Source: "", Note: note}, fmt.Errorf("no usable identity at %s and no seed token at %s (pass --mint-identity to create one)", identityPath, seedTokenPath)
	}
	token, err := MintIdentityToken()
	if err != nil {
		return LocalIdentity{Note: note}, err
	}
	doc := NewIdentityFile(token, generatedBy)
	if err := SaveIdentityFile(identityPath, doc); err != nil {
		return LocalIdentity{Doc: doc, Token: token, Source: "generated", Note: note}, fmt.Errorf("write %s: %w", identityPath, err)
	}
	return LocalIdentity{Doc: doc, Token: token, Source: "generated", Note: note}, nil
}

// readSeedToken reads the installer-seeded token file, which contains only the
// token value. Returns "" when the file is absent or does not hold a valid
// token (never a partial value).
func readSeedToken(path string) string {
	if path == "" {
		return ""
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	token := strings.TrimSpace(string(b))
	if !ValidateIdentityToken(token) {
		return ""
	}
	return token
}

// ReadLocalToken returns the token currently backing the local identity and
// where it came from: identity.json first, then the /system seed token. It is
// read-only (the status refresher calls it periodically) and creates nothing.
func ReadLocalToken(identityPath, seedTokenPath string) (token, source string, doc *IdentityFile) {
	if d, err := LoadIdentityFile(identityPath); err == nil && ValidateIdentityFile(d) == nil {
		return d.Account.Token, "identity.json", d
	}
	if t := readSeedToken(seedTokenPath); t != "" {
		return t, "system-token", nil
	}
	return "", "none", nil
}

// AccountProbe is the read-only result of looking for the June account row in
// Android's accounts.db. june-local never writes that database.
type AccountProbe struct {
	Present bool
	Name    string
	Source  string // "sqlite3", "text" or "missing"
	Error   string // non-fatal explanation for the status page
}

// sqliteAccountQuery lists the June account names. Exactly one is expected; the
// JCM throws IllegalStateException("We got multiple Accounts!") for more.
const sqliteAccountQuery = `SELECT name FROM accounts WHERE type='com.junelife.user';`

// sqlite3LookPath is a variable so tests can force the byte probe.
var sqlite3LookPath = findSQLite3

// runSQLiteQuery is a variable so tests never need a sqlite3 binary.
var runSQLiteQuery = func(binary, dbPath, query string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	// -readonly keeps june-local from ever creating a journal or writing a
	// row; -batch keeps the output one value per line.
	cmd := exec.CommandContext(ctx, binary, "-batch", "-readonly", dbPath, query)
	var stdout bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = io.Discard
	if err := cmd.Run(); err != nil {
		return "", err
	}
	return stdout.String(), nil
}

// findSQLite3 returns a usable sqlite3 CLI path, preferring the on-oven
// binaries (it is not installed on every image).
func findSQLite3() string {
	for _, path := range []string{"/system/bin/sqlite3", "/system/xbin/sqlite3"} {
		if st, err := os.Stat(path); err == nil && !st.IsDir() {
			return path
		}
	}
	if path, err := exec.LookPath("sqlite3"); err == nil {
		return path
	}
	return ""
}

// ProbeJuneAccount checks accounts.db read-only for the single
// com.junelife.user row. The cheap byte probe is authoritative when it finds
// nothing (a live row stores the type string in a SQLite page); when the bytes
// match, a sqlite3 CLI (if available) confirms the live row and reads the
// account name. A false positive from a freed page therefore only means a
// conservative "present, name unknown" -- never a write.
func ProbeJuneAccount(dbPath string) AccountProbe {
	p := AccountProbe{Source: "missing"}
	if dbPath == "" {
		p.Error = "no accounts database path configured"
		return p
	}
	b, err := os.ReadFile(dbPath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			p.Error = "accounts.db not found"
		} else {
			p.Error = err.Error()
		}
		return p
	}
	p.Source = "text"
	if !bytes.Contains(b, []byte(juneAccountType)) {
		return p
	}
	if names, ok := queryJuneAccounts(dbPath); ok {
		p.Source = "sqlite3"
		p.Present = len(names) > 0
		if p.Present {
			p.Name = names[0]
		}
		if len(names) > 1 {
			p.Error = fmt.Sprintf("%d June accounts found; the oven apps require exactly one", len(names))
		}
		return p
	}
	p.Present = true
	return p
}

// queryJuneAccounts runs the name query through sqlite3. ok=false means "fall
// back to the byte probe" (no CLI, or it could not read this database).
func queryJuneAccounts(dbPath string) ([]string, bool) {
	binary := sqlite3LookPath()
	if binary == "" {
		return nil, false
	}
	out, err := runSQLiteQuery(binary, dbPath, sqliteAccountQuery)
	if err != nil {
		return nil, false
	}
	return parseAccountRows(out), true
}

// parseAccountRows turns sqlite3's line output into non-empty names. In -batch
// mode sqlite3 prints one value per line; an empty name prints a blank line.
func parseAccountRows(out string) []string {
	var names []string
	for _, line := range strings.Split(out, "\n") {
		if name := strings.TrimSpace(line); name != "" {
			names = append(names, name)
		}
	}
	return names
}

// IdentityStatusFor builds the identity fields the status page shows. It is
// read-only and never returns the token itself: only the source and a short
// display prefix (see TokenPrefix).
func IdentityStatusFor(cfg *Config) Identity {
	id := Identity{TokenSource: "none"}
	token, source, doc := ReadLocalToken(cfg.IdentityFile, cfg.SeedTokenFile)
	id.TokenSource = source
	if token != "" {
		id.TokenPrefix = TokenPrefix(token)
		id.TokenType = juneAuthTokenAccess
		if doc != nil && doc.Account.TokenType != "" {
			id.TokenType = doc.Account.TokenType
		}
	}
	probe := ProbeJuneAccount(cfg.AccountsDB)
	id.AccountPresent = probe.Present
	id.AccountName = probe.Name
	if id.AccountName == "" && probe.Present && doc != nil {
		id.AccountName = doc.Account.Name
	}
	return id
}

// initOvenIdentity runs once at startup. It makes sure identity.json exists
// (load, copy the /system seed token, or mint), then logs a redacted one-line
// summary of both halves of the identity: the token record and the Android
// account row it feeds. It never logs the token, only its display prefix.
func initOvenIdentity(cfg *Config) {
	if cfg.SeedAccounts {
		logLine("[identity] ignoring --seed-accounts: june-local must never write accounts.db at runtime; the pre-Android boot ensure is the only authority")
	}
	li, err := EnsureOvenIdentity(cfg.IdentityFile, cfg.SeedTokenFile, "june-local/"+appVersion, cfg.MintIdentity)
	if li.Note != "" {
		logLine("[identity] WARNING: %s", li.Note)
	}
	if err != nil {
		logLine("[identity] WARNING: %v", err)
	}
	if li.Token != "" {
		logLine("[identity] token source=%s prefix=%s", li.Source, TokenPrefix(li.Token))
	}

	probe := ProbeJuneAccount(cfg.AccountsDB)
	if probe.Present {
		logLine("[identity] account present name=%q probe=%s", probe.Name, probe.Source)
		return
	}
	logLine("[identity] WARNING: no June account row in %s; the oven app will not open its messaging socket (see /local: identity-missing)", cfg.AccountsDB)
}
