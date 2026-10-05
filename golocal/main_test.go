package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/binary"
	"encoding/pem"
	"fmt"
	"io"
	"math/big"
	"mime/multipart"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestWSAcceptRFC6455(t *testing.T) {
	got := wsAccept("dGhlIHNhbXBsZSBub25jZQ==")
	want := "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
	if got != want {
		t.Fatalf("wsAccept = %q, want %q", got, want)
	}
}

func TestFrameRoundTrip(t *testing.T) {
	server, client := net.Pipe()
	defer server.Close()
	defer client.Close()

	s := newWSConn(server, bufio.NewReader(server))
	payload := []byte("hello relay \x00\xff world")
	go func() {
		if err := s.writeFrame(0x1, payload); err != nil {
			t.Errorf("writeFrame: %v", err)
		}
		server.Close()
	}()

	c := newWSConn(client, bufio.NewReader(client))
	op, got, err := c.readMessage()
	if err != nil {
		t.Fatalf("readMessage: %v", err)
	}
	if op != 0x1 {
		t.Fatalf("opcode = %#x, want 0x1", op)
	}
	if !bytes.Equal(got, payload) {
		t.Fatalf("payload mismatch: got %q want %q", got, payload)
	}
}

// TestRelayByteExact spins up the full server with a self-signed cert, connects an
// oven and a companion, and asserts the relay forwards a frame byte-identically.
func TestRelayByteExact(t *testing.T) {
	certPEM, keyPEM := selfSignedCert(t)
	cert, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		t.Fatalf("X509KeyPair: %v", err)
	}

	ln, err := tls.Listen("tcp", "127.0.0.1:0", &tls.Config{Certificates: []tls.Certificate{cert}})
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer ln.Close()

	hub := newHub(false, "")
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		handleRoot(hub, &Config{Timeout: 30}, w, r)
	})
	srv := &http.Server{Handler: mux}
	go srv.Serve(ln)
	defer srv.Close()

	// Companion first (so the oven has a counterpart).
	companion := wsClientDial(t, ln.Addr().String(), "/1/messaging/websocket/companion")
	defer companion.Close()
	oven := wsClientDial(t, ln.Addr().String(), "/1/messaging/websocket/oven")
	defer oven.Close()

	// Oven -> companion: byte-exact forward.
	msg := []byte(`{"message_code":10018,"data":{"state":"idle"},"signature":""}`)
	if err := oven.writeText(msg); err != nil {
		t.Fatalf("oven write: %v", err)
	}
	_, got, err := companion.readMessage()
	if err != nil {
		t.Fatalf("companion read: %v", err)
	}
	if !bytes.Equal(got, msg) {
		t.Fatalf("relay changed bytes:\n got  %s\n want %s", got, msg)
	}

	// The relay echoes an oven's own message back to it (real-cloud behavior);
	// drain that echo before the next exchange.
	if _, echo, err := oven.readMessage(); err != nil {
		t.Fatalf("oven echo read: %v", err)
	} else if !bytes.Equal(echo, msg) {
		t.Fatalf("oven echo mismatch: got %s want %s", echo, msg)
	}

	// Companion -> oven: byte-exact forward.
	msg2 := []byte(`{"message_code":11011,"target":{"id":"oven"}}`)
	if err := companion.writeText(msg2); err != nil {
		t.Fatalf("companion write: %v", err)
	}
	_, got2, err := oven.readMessage()
	if err != nil {
		t.Fatalf("oven read: %v", err)
	}
	if !bytes.Equal(got2, msg2) {
		t.Fatalf("relay changed bytes (companion->oven): got %s want %s", got2, msg2)
	}
}

func selfSignedCert(t *testing.T) ([]byte, []byte) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("gen key: %v", err)
	}
	tmpl := x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "test"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
		DNSNames:     []string{"localhost", "api.junelife.com", "messaging.junelife.com"},
	}
	der, err := x509.CreateCertificate(rand.Reader, &tmpl, &tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatalf("create cert: %v", err)
	}
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyDER, _ := x509.MarshalECPrivateKey(key)
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER})
	return certPEM, keyPEM
}

// wsTestConn is a minimal WebSocket client used by the tests.
type wsTestConn struct {
	conn net.Conn
	r    *bufio.Reader
}

func wsClientDial(t *testing.T, addr, path string) *wsTestConn {
	d := &net.Dialer{Timeout: 5 * time.Second}
	conn, err := tls.DialWithDialer(d, "tcp", addr, &tls.Config{InsecureSkipVerify: true})
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	key := "dGhlIHNhbXBsZSBub25jZQ=="
	req := fmt.Sprintf("GET %s HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n", path, key)
	if _, err := conn.Write([]byte(req)); err != nil {
		t.Fatalf("write handshake: %v", err)
	}
	r := bufio.NewReader(conn)
	// Read the 101 response headers.
	var statusLine string
	for {
		line, err := r.ReadString('\n')
		if err != nil {
			t.Fatalf("read handshake line: %v", err)
		}
		if statusLine == "" {
			statusLine = line
		}
		if line == "\r\n" {
			break
		}
	}
	if !bytes.HasPrefix([]byte(statusLine), []byte("HTTP/1.1 101")) {
		t.Fatalf("handshake status = %q", statusLine)
	}
	return &wsTestConn{conn: conn, r: r}
}

func (w *wsTestConn) writeText(payload []byte) error {
	mask := [4]byte{0x11, 0x22, 0x33, 0x44}
	hdr := []byte{0x81}
	n := len(payload)
	switch {
	case n < 126:
		hdr = append(hdr, 0x80|byte(n))
	case n < 65536:
		hdr = append(hdr, 0x80|126, byte(n>>8), byte(n))
	default:
		hdr = append(hdr, 0x80|127)
		var b [8]byte
		binary.BigEndian.PutUint64(b[:], uint64(n))
		hdr = append(hdr, b[:]...)
	}
	hdr = append(hdr, mask[:]...)
	masked := make([]byte, n)
	for i := range payload {
		masked[i] = payload[i] ^ mask[i%4]
	}
	if _, err := w.conn.Write(hdr); err != nil {
		return err
	}
	_, err := w.conn.Write(masked)
	return err
}

func (w *wsTestConn) readMessage() (byte, []byte, error) {
	var hdr [2]byte
	if _, err := io.ReadFull(w.r, hdr[:]); err != nil {
		return 0, nil, err
	}
	opcode := hdr[0] & 0x0F
	length := uint64(hdr[1] & 0x7F)
	switch length {
	case 126:
		var ext [2]byte
		if _, err := io.ReadFull(w.r, ext[:]); err != nil {
			return 0, nil, err
		}
		length = uint64(binary.BigEndian.Uint16(ext[:]))
	case 127:
		var ext [8]byte
		if _, err := io.ReadFull(w.r, ext[:]); err != nil {
			return 0, nil, err
		}
		length = binary.BigEndian.Uint64(ext[:])
	}
	payload := make([]byte, length)
	if _, err := io.ReadFull(w.r, payload); err != nil {
		return 0, nil, err
	}
	return opcode, payload, nil
}

func (w *wsTestConn) Close() {
	_ = w.conn.Close()
}

func TestMultipartJPEG(t *testing.T) {
	var body bytes.Buffer
	mw := multipart.NewWriter(&body)
	part, err := mw.CreateFormFile("photo", "image.jpg")
	if err != nil {
		t.Fatalf("CreateFormFile: %v", err)
	}
	want := []byte{0xff, 0xd8, 0xff, 0xe0, 'j', 'p', 'e', 'g', 0xff, 0xd9}
	if _, err := part.Write(want); err != nil {
		t.Fatalf("write part: %v", err)
	}
	if err := mw.Close(); err != nil {
		t.Fatalf("multipart close: %v", err)
	}

	got, err := multipartJPEG(mw.FormDataContentType(), body.Bytes())
	if err != nil {
		t.Fatalf("multipartJPEG: %v", err)
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("multipart payload = %x, want %x", got, want)
	}

	raw, err := multipartJPEG("image/jpeg", want)
	if err != nil || !bytes.Equal(raw, want) {
		t.Fatalf("raw JPEG fallback: got %x err %v", raw, err)
	}
}

func TestPublishVideoJPEG(t *testing.T) {
	dir := t.TempDir()
	hub := newHub(true, "")
	jpeg := []byte{0xff, 0xd8, 0xff, 0xe0, 'x', 0xff, 0xd9}
	url, err := publishVideoJPEG(hub, &Config{MediaDir: dir}, jpeg)
	if err != nil {
		t.Fatalf("publishVideoJPEG: %v", err)
	}
	if url == "" {
		t.Fatal("publishVideoJPEG returned an empty URL")
	}
	got, err := os.ReadFile(filepath.Join(dir, "prod", "images", "latest.jpg"))
	if err != nil {
		t.Fatalf("read published frame: %v", err)
	}
	if !bytes.Equal(got, jpeg) {
		t.Fatalf("published frame = %x, want %x", got, jpeg)
	}
}

func TestStartImageRESTRoute(t *testing.T) {
	defer lastCookFrameNano.Store(0)
	dir := t.TempDir()
	hub := newHub(true, "")
	jpeg := []byte{0xff, 0xd8, 0xff, 0xe0, 'c', 'o', 'o', 'k', 0xff, 0xd9}

	var body bytes.Buffer
	mw := multipart.NewWriter(&body)
	part, err := mw.CreateFormFile("photo", "image.jpg")
	if err != nil {
		t.Fatalf("CreateFormFile: %v", err)
	}
	if _, err := part.Write(jpeg); err != nil {
		t.Fatalf("write part: %v", err)
	}
	if err := mw.Close(); err != nil {
		t.Fatalf("multipart close: %v", err)
	}

	req := httptest.NewRequest(http.MethodPost, "/1/videos/session-1/start_image", &body)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	rec := httptest.NewRecorder()
	handleREST(hub, &Config{MediaDir: dir}, rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("start_image status = %d, body %s", rec.Code, rec.Body.String())
	}
	got, err := os.ReadFile(filepath.Join(dir, "prod", "images", "latest.jpg"))
	if err != nil {
		t.Fatalf("read published frame: %v", err)
	}
	if !bytes.Equal(got, jpeg) {
		t.Fatalf("published frame = %x, want %x", got, jpeg)
	}
	if lastCookFrameNano.Load() == 0 {
		t.Fatal("start_image did not record the cook frame timestamp")
	}
}

func TestCameraBridgeGate(t *testing.T) {
	cameraEnabledFlag.Store(false)
	cameraOverrideUntil.Store(0)
	lastCookFrameNano.Store(0)
	defer func() {
		cameraEnabledFlag.Store(false)
		cameraOverrideUntil.Store(0)
		lastCookFrameNano.Store(0)
	}()

	if cameraBridgeEnabled() {
		t.Fatal("bridge enabled without a viewer")
	}
	cameraOverrideUntil.Store(time.Now().Add(time.Minute).UnixNano())
	if !cameraBridgeEnabled() {
		t.Fatal("bridge disabled while a viewer is active")
	}
	cameraEnabledFlag.Store(true)
	if !cameraBridgeEnabled() {
		t.Fatal("bridge fallback disabled when a cook has no MediaCapturer frames")
	}
	lastCookFrameNano.Store(time.Now().UnixNano())
	if cameraBridgeEnabled() {
		t.Fatal("bridge enabled while MediaCapturer is supplying cook frames")
	}
}

func TestCameraViewPage(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/media/view", nil)
	rec := httptest.NewRecorder()
	handleREST(newHub(true, ""), &Config{}, rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("camera view status = %d", rec.Code)
	}
	if !bytes.Contains(rec.Body.Bytes(), []byte("/media/stream.mjpg")) {
		t.Fatal("camera view page does not embed the MJPEG stream")
	}
}

func TestCatalogGETRoute(t *testing.T) {
	dir := t.TempDir()
	catalog := `{"hierarchies":[],"presets":[{"content_id":"bake","url":"https://api.junelife.com/1/presets/bundle/cook_preset/bake/x.jcpb"}],"version":2}`
	if err := os.WriteFile(filepath.Join(dir, "catalog.json"), []byte(catalog), 0o644); err != nil {
		t.Fatalf("write catalog: %v", err)
	}
	req := httptest.NewRequest(http.MethodGet, "/1/presets/catalog", nil)
	rec := httptest.NewRecorder()
	handleREST(newHub(true, ""), &Config{ContentRoot: dir}, rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET catalog status = %d", rec.Code)
	}
	if !bytes.Contains(rec.Body.Bytes(), []byte(`http://example.com/1/presets/bundle/`)) {
		t.Fatalf("GET catalog did not return the rewritten catalog: %s", rec.Body.String())
	}
}

func TestMJPEGViewerOpensCameraGate(t *testing.T) {
	cameraOverrideUntil.Store(0)
	defer cameraOverrideUntil.Store(0)

	ctx, cancel := context.WithCancel(context.Background())
	req := httptest.NewRequest(http.MethodGet, "/media/stream.mjpg", nil).WithContext(ctx)
	rec := httptest.NewRecorder()
	done := make(chan struct{})
	go func() {
		handleREST(newHub(true, ""), &Config{MJPEGViewerGate: true, MJPEGFps: 20}, rec, req)
		close(done)
	}()

	deadline := time.Now().Add(2 * time.Second)
	for cameraOverrideUntil.Load() == 0 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	cancel()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("MJPEG handler did not stop after its client disconnected")
	}
	if cameraOverrideUntil.Load() == 0 {
		t.Fatal("watching the MJPEG stream did not open the camera gate")
	}
}
