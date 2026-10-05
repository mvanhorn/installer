package main

import "encoding/json"

// sendRaw writes a WebSocket text frame with the exact bytes given.
func (p *Peer) sendRaw(data []byte) error {
	return p.ws.writeFrame(0x1, data)
}

// sendJSON is used only for frames WE originate (pairing pushes in unsigned codes).
func (p *Peer) sendJSON(obj any) bool {
	b, err := json.Marshal(obj)
	if err != nil {
		logLine("[%s] marshal error: %v", p.addr, err)
		return false
	}
	if err := p.sendRaw(b); err != nil {
		logLine("[%s] send failed: %v", p.addr, err)
		return false
	}
	return true
}
