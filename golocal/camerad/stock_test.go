package main

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"io"
	"net"
	"testing"
)

func stockMetadata(t *testing.T, name string) []byte {
	t.Helper()
	var b bytes.Buffer
	writeU32 := func(v uint32) {
		var buf [4]byte
		binary.BigEndian.PutUint32(buf[:], v)
		b.Write(buf[:])
	}
	writeU16 := func(v uint16) {
		var buf [2]byte
		binary.BigEndian.PutUint16(buf[:], v)
		b.Write(buf[:])
	}
	writeU32(1) // version
	writeU16(uint16(len(name)))
	b.WriteString(name)
	writeU16(0x05a3) // vendor
	writeU16(0x9230) // product
	writeU32(42)     // frame
	var captureTime [8]byte
	binary.BigEndian.PutUint64(captureTime[:], 123456789)
	b.Write(captureTime[:])
	writeU32(6) // rectified JPEG
	writeU32(640)
	writeU32(480)
	writeU32(0)
	writeU32(0)
	var zoom [8]byte
	binary.BigEndian.PutUint64(zoom[:], 1.0)
	b.Write(zoom[:])
	return b.Bytes()
}

func TestReadStockFrame(t *testing.T) {
	jpeg := []byte{0xff, 0xd8, 0xff, 0xe0, 'j', 'u', 'n', 'e', 0xff, 0xd9}
	var wire bytes.Buffer
	wire.Write(stockMetadata(t, "june-camera"))
	var size [4]byte
	binary.BigEndian.PutUint32(size[:], uint32(len(jpeg)))
	wire.Write(size[:])
	wire.Write(jpeg)

	got, err := readStockFrame(bytes.NewReader(wire.Bytes()))
	if err != nil {
		t.Fatalf("readStockFrame: %v", err)
	}
	if !bytes.Equal(got, jpeg) {
		t.Fatalf("frame = %x, want %x", got, jpeg)
	}
}

func TestReadStockFrameRejectsBadLength(t *testing.T) {
	var wire bytes.Buffer
	wire.Write(stockMetadata(t, ""))
	var size [4]byte
	binary.BigEndian.PutUint32(size[:], 0)
	wire.Write(size[:])
	if _, err := readStockFrame(bytes.NewReader(wire.Bytes())); err == nil {
		t.Fatal("zero-length frame accepted")
	}
}

func TestCaptureStockFrameRequestsRectifiedJPEG(t *testing.T) {
	jpeg := []byte{0xff, 0xd8, 0xff, 0xe0, 'c', 'a', 'm', 0xff, 0xd9}
	var response bytes.Buffer
	response.Write(stockMetadata(t, "june-camera"))
	var size [4]byte
	binary.BigEndian.PutUint32(size[:], uint32(len(jpeg)))
	response.Write(size[:])
	response.Write(jpeg)

	server, client := net.Pipe()
	defer server.Close()
	defer client.Close()

	type requestInfo struct {
		opcode uint32
		format uint32
	}
	requests := make(chan requestInfo, 1)
	go func() {
		var req [8]byte
		if _, err := io.ReadFull(server, req[:]); err != nil {
			return
		}
		requests <- requestInfo{
			opcode: binary.BigEndian.Uint32(req[0:4]),
			format: binary.BigEndian.Uint32(req[4:8]),
		}
		_, _ = server.Write(response.Bytes())
	}()

	got, err := captureStockFrame(client, bufio.NewReader(client), 6)
	if err != nil {
		t.Fatalf("captureStockFrame: %v", err)
	}
	if !bytes.Equal(got, jpeg) {
		t.Fatalf("frame = %x, want %x", got, jpeg)
	}
	req := <-requests
	if req.opcode != 1 {
		t.Errorf("request opcode = %d, want 1 (CAPTURE)", req.opcode)
	}
	if req.format != 6 {
		t.Errorf("request format = %d, want 6 (rectified JPEG)", req.format)
	}
}
