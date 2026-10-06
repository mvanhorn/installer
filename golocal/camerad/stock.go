package main

import (
	"bufio"
	"encoding/binary"
	"fmt"
	"io"
	"log"
	"net"
	"strings"
	"time"
)

const stockMaxJPEGBytes = 10 << 20

// dialStock opens cameracapturerd's capture socket.  The daemon binds it in
// the Linux abstract namespace, which /proc/net/unix shows as
// "@/juneOS2/cameracapturerd-capture.sock" and which Go addresses with a
// leading '@'.  Some builds bind a filesystem socket instead, so try the
// literal path first and fall back to the abstract name.
func dialStock(socket string) (net.Conn, error) {
	conn, err := net.DialTimeout("unix", socket, 2*time.Second)
	if err == nil {
		return conn, nil
	}
	if !strings.HasPrefix(socket, "@") && !strings.HasPrefix(socket, "\x00") {
		if abstract, err2 := net.DialTimeout("unix", "@"+socket, 2*time.Second); err2 == nil {
			return abstract, nil
		}
	}
	return nil, err
}

// runStockBridge serves idle live-view frames by asking the stock
// cameracapturerd daemon for rectified JPEGs over its Unix socket. It never
// opens /dev/video0, so the stock pipeline keeps the camera for food
// recognition (door open) and cook-time stills (MediaCapturer / toast
// doneness). The bridge connects only while the golocal gate says a viewer is
// active and no cook is running, and it disconnects as soon as either changes.
func runStockBridge(socket, relay, trigger string, fps, format int) {
	if fps <= 0 {
		fps = 1
	}
	frameDur := time.Second / time.Duration(fps)
	gate := func() bool {
		return trigger == "" || cameraEnabled(trigger)
	}

	for {
		if !gate() {
			time.Sleep(250 * time.Millisecond)
			continue
		}
		conn, err := dialStock(socket)
		if err != nil {
			log.Printf("camerad: stock socket unavailable (%s): %v", socket, err)
			time.Sleep(time.Second)
			continue
		}
		reader := bufio.NewReader(conn)
		log.Printf("camerad: stock bridge connected to %s", socket)
		for gate() {
			start := time.Now()
			frame, err := captureStockFrame(conn, reader, format)
			if err != nil {
				log.Printf("camerad: stock capture stopped: %v", err)
				break
			}
			if err := postJPEG(relay, frame); err != nil {
				log.Printf("camerad: relay post failed: %v", err)
			}
			if elapsed := time.Since(start); elapsed < frameDur {
				time.Sleep(frameDur - elapsed)
			}
		}
		_ = conn.Close()
		log.Printf("camerad: stock bridge released %s", socket)
	}
}

func captureStockFrame(conn net.Conn, reader *bufio.Reader, format int) ([]byte, error) {
	if err := conn.SetDeadline(time.Now().Add(5 * time.Second)); err != nil {
		return nil, err
	}
	var req [8]byte
	binary.BigEndian.PutUint32(req[0:4], 1) // CAPTURE
	binary.BigEndian.PutUint32(req[4:8], uint32(format))
	if _, err := conn.Write(req[:]); err != nil {
		return nil, err
	}
	return readStockFrame(reader)
}

// readStockFrame parses one cameracapturerd response:
// CameraCaptureMetaData (version 1), then int32 length, then JPEG bytes.
func readStockFrame(r io.Reader) ([]byte, error) {
	if err := readStockMetadata(r); err != nil {
		return nil, err
	}
	var lenBuf [4]byte
	if _, err := io.ReadFull(r, lenBuf[:]); err != nil {
		return nil, err
	}
	n := binary.BigEndian.Uint32(lenBuf[:])
	if n == 0 || n > stockMaxJPEGBytes {
		return nil, fmt.Errorf("invalid stock frame length %d", n)
	}
	frame := make([]byte, n)
	if _, err := io.ReadFull(r, frame); err != nil {
		return nil, err
	}
	if len(frame) < 2 || frame[0] != 0xff || frame[1] != 0xd8 {
		return nil, fmt.Errorf("stock frame is not a JPEG")
	}
	return frame, nil
}

// readStockMetadata mirrors CameraCaptureMetaData(DataInputStream):
// int version, UTF name, short vendor, short product, int frame, long
// captureTime, int format, int width, int height, int shiftX, int shiftY,
// double zoom. The bridge only needs to consume it; the JPEG follows.
func readStockMetadata(r io.Reader) error {
	var i32 [4]byte
	readInt32 := func() (uint32, error) {
		if _, err := io.ReadFull(r, i32[:]); err != nil {
			return 0, err
		}
		return binary.BigEndian.Uint32(i32[:]), nil
	}
	version, err := readInt32()
	if err != nil {
		return err
	}
	if version != 1 {
		return fmt.Errorf("unexpected camera metadata version %d", version)
	}
	var l16 [2]byte
	if _, err := io.ReadFull(r, l16[:]); err != nil {
		return err
	}
	nameLen := int(binary.BigEndian.Uint16(l16[:]))
	if nameLen > 4096 {
		return fmt.Errorf("camera metadata name too long (%d)", nameLen)
	}
	if nameLen > 0 {
		if _, err := io.CopyN(io.Discard, r, int64(nameLen)); err != nil {
			return err
		}
	}
	// vendor+product shorts (4), frame int (4), captureTime long (8),
	// format/width/height/shiftX/shiftY ints (20), zoom double (8).
	if _, err := io.CopyN(io.Discard, r, 44); err != nil {
		return err
	}
	return nil
}
