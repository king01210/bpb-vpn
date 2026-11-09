package main

import (
	"encoding/binary"
	"io"
	"net"
	"sync"
	"time"
)

// UDP over Psiphon's udpgw: a port forward to udpgwAddr, which Psiphon servers intercept,
// carrying badvpn udpgw messages:
//
//	| 2 byte size (LE) | flags | 2 byte conn ID (LE) | IPv4 or IPv6 | port (BE) | payload |
//
// With udpgwFlagDNS the server ignores the address and answers with its own DNS resolver
// (what Psiphon's packet-tunnel mode calls transparent DNS).
const (
	udpgwAddr          = "127.0.0.1:7300"
	udpgwFlagKeepalive = 1 << 0
	udpgwFlagRebind    = 1 << 1
	udpgwFlagDNS       = 1 << 2
	udpgwFlagIPv6      = 1 << 3
	udpgwMaxPayload    = 32768
	udpgwKeepalive     = 20 * time.Second
)

// udpgw is one udpgw port forward. Each key (a destination for SOCKS UDP, a client for DNS)
// gets a conn ID.
type udpgw struct {
	conn    net.Conn
	writeMu sync.Mutex

	mu      sync.Mutex
	ids     map[string]uint16
	keys    map[uint16]string
	nextID  uint16
	wrapped bool // conn IDs ran out once; new ones replace old ones on the server (rebind)
}

func dialUdpgw(t *tunnel) (*udpgw, error) {
	conn, err := t.dial(udpgwAddr, nil)
	if err != nil {
		return nil, err
	}
	g := &udpgw{conn: conn, ids: map[string]uint16{}, keys: map[uint16]string{}}
	go g.keepalive()
	return g, nil
}

func (g *udpgw) Close() error { return g.conn.Close() }

func (g *udpgw) connID(key string) (id uint16, rebind bool) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if id, ok := g.ids[key]; ok {
		return id, false
	}
	g.nextID++
	if g.nextID == 0 {
		g.wrapped = true
		clear(g.ids)
		clear(g.keys)
		g.nextID = 1
	}
	g.ids[key] = g.nextID
	g.keys[g.nextID] = key
	return g.nextID, g.wrapped
}

// key is the key that conn ID [id] was given to.
func (g *udpgw) key(id uint16) (string, bool) {
	g.mu.Lock()
	defer g.mu.Unlock()
	key, ok := g.keys[id]
	return key, ok
}

// send sends [payload] to ip:port under [key]'s conn ID, with [flags] (e.g. udpgwFlagDNS).
func (g *udpgw) send(key string, flags byte, ip net.IP, port int, payload []byte) error {
	if len(payload) > udpgwMaxPayload {
		return nil
	}
	id, rebind := g.connID(key)
	if rebind {
		flags |= udpgwFlagRebind
	}
	addr := ip.To4()
	if addr == nil {
		addr = ip.To16()
		flags |= udpgwFlagIPv6
	}
	msg := make([]byte, 0, 2+3+len(addr)+2+len(payload))
	msg = binary.LittleEndian.AppendUint16(msg, uint16(3+len(addr)+2+len(payload)))
	msg = append(msg, flags)
	msg = binary.LittleEndian.AppendUint16(msg, id)
	msg = append(msg, addr...)
	msg = binary.BigEndian.AppendUint16(msg, uint16(port))
	msg = append(msg, payload...)
	return g.write(msg)
}

func (g *udpgw) write(msg []byte) error {
	g.writeMu.Lock()
	defer g.writeMu.Unlock()
	_, err := g.conn.Write(msg)
	return err
}

func (g *udpgw) keepalive() {
	ticker := time.NewTicker(udpgwKeepalive)
	defer ticker.Stop()
	// Header only: size 3, keepalive flag, conn ID 0.
	msg := []byte{3, 0, udpgwFlagKeepalive, 0, 0}
	for range ticker.C {
		if g.write(msg) != nil {
			return
		}
	}
}

// receive calls [onPacket] for each reply until the port forward closes. [payload] is only
// valid during the call.
func (g *udpgw) receive(onPacket func(id uint16, ip net.IP, port int, payload []byte)) {
	head := make([]byte, 2)
	body := make([]byte, 0xffff)
	for {
		if _, err := io.ReadFull(g.conn, head); err != nil {
			return
		}
		size := int(binary.LittleEndian.Uint16(head))
		if size < 3 {
			return
		}
		msg := body[:size]
		if _, err := io.ReadFull(g.conn, msg); err != nil {
			return
		}
		flags := msg[0]
		if flags&udpgwFlagKeepalive != 0 {
			continue
		}
		addrLen := net.IPv4len
		if flags&udpgwFlagIPv6 != 0 {
			addrLen = net.IPv6len
		}
		if size < 3+addrLen+2 {
			return
		}
		id := binary.LittleEndian.Uint16(msg[1:3])
		ip := net.IP(msg[3 : 3+addrLen])
		port := int(binary.BigEndian.Uint16(msg[3+addrLen:]))
		onPacket(id, ip, port, msg[3+addrLen+2:])
	}
}

type byteReader struct{ b []byte }

func (r *byteReader) Read(p []byte) (int, error) {
	if len(r.b) == 0 {
		return 0, io.EOF
	}
	n := copy(p, r.b)
	r.b = r.b[n:]
	return n, nil
}
