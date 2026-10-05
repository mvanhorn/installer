package main

import (
	"bufio"
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"sync"
)

const wsGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

func wsAccept(key string) string {
	h := sha1.Sum([]byte(key + wsGUID))
	return base64.StdEncoding.EncodeToString(h[:])
}

// wsConn reads and writes WebSocket frames over a buffered reader + net.Conn.
// Client frames are masked; server frames are unmasked. permessage-deflate is not
// negotiated in this port, so RSV1 is never set on incoming messages.
type wsConn struct {
	r      *bufio.Reader
	conn   net.Conn
	mu     sync.Mutex // guards writes
	closed bool
}

func newWSConn(conn net.Conn, r *bufio.Reader) *wsConn {
	return &wsConn{conn: conn, r: r}
}

// readMessage returns the next complete data message (opcode 1 text or 2 binary),
// transparently handling fragmentation and control frames (ping/pong/close).
// It returns io.EOF on a clean close frame.
func (w *wsConn) readMessage() (byte, []byte, error) {
	var fragOp byte
	var frag []byte
	haveFrag := false

	for {
		fin, opcode, payload, err := w.readFrame()
		if err != nil {
			return 0, nil, err
		}
		switch opcode {
		case 0x0: // continuation
			if !haveFrag {
				return 0, nil, errors.New("ws: continuation without initial frame")
			}
			frag = append(frag, payload...)
			if fin {
				op, buf := fragOp, frag
				fragOp, frag, haveFrag = 0, nil, false
				return op, buf, nil
			}
		case 0x8: // close
			return 0, nil, io.EOF
		case 0x9: // ping -> send pong, keep reading
			_ = w.writeFrame(0xA, payload)
		case 0xA: // pong -> ignore
		case 0x1, 0x2:
			if haveFrag {
				return 0, nil, errors.New("ws: new data frame during fragmentation")
			}
			if fin {
				return opcode, payload, nil
			}
			fragOp = opcode
			frag = append(frag[:0], payload...)
			haveFrag = true
		default:
			return 0, nil, errors.New("ws: unknown opcode")
		}
	}
}

// readFrame reads one raw frame: returns (fin, opcode, unmasked payload).
func (w *wsConn) readFrame() (bool, byte, []byte, error) {
	var hdr [2]byte
	if _, err := io.ReadFull(w.r, hdr[:]); err != nil {
		return false, 0, nil, err
	}
	fin := hdr[0]&0x80 != 0
	opcode := hdr[0] & 0x0F
	masked := hdr[1]&0x80 != 0
	length := uint64(hdr[1] & 0x7F)

	switch length {
	case 126:
		var ext [2]byte
		if _, err := io.ReadFull(w.r, ext[:]); err != nil {
			return false, 0, nil, err
		}
		length = uint64(binary.BigEndian.Uint16(ext[:]))
	case 127:
		var ext [8]byte
		if _, err := io.ReadFull(w.r, ext[:]); err != nil {
			return false, 0, nil, err
		}
		length = binary.BigEndian.Uint64(ext[:])
	}

	var maskKey [4]byte
	if masked {
		if _, err := io.ReadFull(w.r, maskKey[:]); err != nil {
			return false, 0, nil, err
		}
	}

	if length > 64<<20 {
		return false, 0, nil, errors.New("ws: frame too large")
	}
	payload := make([]byte, length)
	if _, err := io.ReadFull(w.r, payload); err != nil {
		return false, 0, nil, err
	}
	if masked {
		for i := range payload {
			payload[i] ^= maskKey[i%4]
		}
	}
	return fin, opcode, payload, nil
}

// writeFrame sends an unmasked server frame with the given opcode.
func (w *wsConn) writeFrame(opcode byte, payload []byte) error {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.closed {
		return io.ErrClosedPipe
	}
	hdr := []byte{0x80 | opcode}
	n := len(payload)
	switch {
	case n < 126:
		hdr = append(hdr, byte(n))
	case n < 65536:
		hdr = append(hdr, 126, byte(n>>8), byte(n))
	default:
		hdr = append(hdr, 127)
		var b [8]byte
		binary.BigEndian.PutUint64(b[:], uint64(n))
		hdr = append(hdr, b[:]...)
	}
	if _, err := w.conn.Write(hdr); err != nil {
		return err
	}
	_, err := w.conn.Write(payload)
	return err
}

func (w *wsConn) close() {
	w.mu.Lock()
	w.closed = true
	w.mu.Unlock()
	_ = w.conn.Close()
}

