package main

import (
	"context"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"strconv"
	"sync"
	"time"

	"github.com/Psiphon-Labs/psiphon-tunnel-core/psiphon"
)

// SOCKS5 (RFC 1928), no authentication: CONNECT and UDP ASSOCIATE.
const (
	socksVersion   = 0x05
	cmdConnect     = 0x01
	cmdUDP         = 0x03
	atypIPv4       = 0x01
	atypDomain     = 0x03
	atypIPv6       = 0x04
	repSucceeded   = 0x00
	repFailure     = 0x01
	repHostUnreach = 0x04
	repCmdNotSupp  = 0x07
)

// tunnel dials through the Psiphon tunnel, as Psiphon's own SOCKS proxy does.
type tunnel struct {
	controller *psiphon.Controller
	resolver   *net.Resolver

	mu    sync.Mutex
	cache map[string]cachedIP
}

type cachedIP struct {
	ip      net.IP
	expires time.Time
}

func newTunnel(c *psiphon.Controller) *tunnel {
	t := &tunnel{controller: c, cache: map[string]cachedIP{}}
	// Domains in UDP requests are resolved over TCP DNS through the tunnel (udpgw needs an IP).
	t.resolver = &net.Resolver{
		PreferGo: true,
		Dial: func(ctx context.Context, network, address string) (net.Conn, error) {
			return t.dial("1.1.1.1:53", nil)
		},
	}
	return t
}

func (t *tunnel) dial(addr string, downstream net.Conn) (net.Conn, error) {
	return t.controller.Dial(addr, downstream)
}

// resolve returns an IPv4 address for host if it has one, otherwise IPv6.
func (t *tunnel) resolve(host string) (net.IP, error) {
	t.mu.Lock()
	c, ok := t.cache[host]
	t.mu.Unlock()
	if ok && time.Now().Before(c.expires) {
		return c.ip, nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	ips, err := t.resolver.LookupIP(ctx, "ip", host)
	if err != nil {
		return nil, err
	}
	ip := ips[0]
	for _, candidate := range ips {
		if candidate.To4() != nil {
			ip = candidate
			break
		}
	}
	t.mu.Lock()
	t.cache[host] = cachedIP{ip, time.Now().Add(5 * time.Minute)}
	t.mu.Unlock()
	return ip, nil
}

func serveSocks(ln net.Listener, t *tunnel) {
	for {
		conn, err := ln.Accept()
		if err != nil {
			var ne net.Error
			if errors.As(err, &ne) && ne.Timeout() {
				continue
			}
			fatal("accept: %v", err)
		}
		go func() {
			defer conn.Close()
			if err := handleSocks(conn, t); err != nil {
				logger.Printf("socks: %v", err)
			}
		}()
	}
}

func handleSocks(conn net.Conn, t *tunnel) error {
	conn.SetDeadline(time.Now().Add(30 * time.Second))

	// Greeting: VER NMETHODS METHODS; we only offer "no authentication".
	head := make([]byte, 2)
	if _, err := io.ReadFull(conn, head); err != nil {
		return err
	}
	if head[0] != socksVersion {
		return errors.New("not SOCKS5")
	}
	if _, err := io.ReadFull(conn, make([]byte, head[1])); err != nil {
		return err
	}
	if _, err := conn.Write([]byte{socksVersion, 0x00}); err != nil {
		return err
	}

	// Request: VER CMD RSV ATYP DST.ADDR DST.PORT
	req := make([]byte, 3)
	if _, err := io.ReadFull(conn, req); err != nil {
		return err
	}
	host, port, err := readAddr(conn)
	if err != nil {
		return err
	}

	switch req[1] {
	case cmdConnect:
		target := net.JoinHostPort(host, strconv.Itoa(port))
		remote, err := t.dial(target, conn)
		if err != nil {
			reply(conn, repHostUnreach, nil)
			return err
		}
		defer remote.Close()
		if err := reply(conn, repSucceeded, nil); err != nil {
			return err
		}
		conn.SetDeadline(time.Time{})
		relay(conn, remote)
		return nil
	case cmdUDP:
		return handleUDPAssociate(conn, t)
	default:
		reply(conn, repCmdNotSupp, nil)
		return nil
	}
}

// readAddr reads ATYP DST.ADDR DST.PORT.
func readAddr(r io.Reader) (string, int, error) {
	atyp := make([]byte, 1)
	if _, err := io.ReadFull(r, atyp); err != nil {
		return "", 0, err
	}
	var host string
	switch atyp[0] {
	case atypIPv4, atypIPv6:
		size := net.IPv4len
		if atyp[0] == atypIPv6 {
			size = net.IPv6len
		}
		ip := make([]byte, size)
		if _, err := io.ReadFull(r, ip); err != nil {
			return "", 0, err
		}
		host = net.IP(ip).String()
	case atypDomain:
		n := make([]byte, 1)
		if _, err := io.ReadFull(r, n); err != nil {
			return "", 0, err
		}
		name := make([]byte, n[0])
		if _, err := io.ReadFull(r, name); err != nil {
			return "", 0, err
		}
		host = string(name)
	default:
		return "", 0, errors.New("bad address type")
	}
	p := make([]byte, 2)
	if _, err := io.ReadFull(r, p); err != nil {
		return "", 0, err
	}
	return host, int(binary.BigEndian.Uint16(p)), nil
}

// appendAddr appends ATYP ADDR PORT for an IP address.
func appendAddr(b []byte, ip net.IP, port int) []byte {
	if ip4 := ip.To4(); ip4 != nil {
		b = append(append(b, atypIPv4), ip4...)
	} else {
		b = append(append(b, atypIPv6), ip.To16()...)
	}
	return binary.BigEndian.AppendUint16(b, uint16(port))
}

// reply sends VER REP RSV BND.ADDR BND.PORT; bind is 0.0.0.0:0 when nil.
func reply(conn net.Conn, rep byte, bind *net.UDPAddr) error {
	ip, port := net.IPv4zero, 0
	if bind != nil {
		ip, port = bind.IP, bind.Port
	}
	_, err := conn.Write(appendAddr([]byte{socksVersion, rep, 0x00}, ip, port))
	return err
}

func relay(a, b net.Conn) {
	done := make(chan struct{}, 2)
	pipe := func(dst, src net.Conn) {
		io.Copy(dst, src)
		if c, ok := dst.(interface{ CloseWrite() error }); ok {
			c.CloseWrite()
		} else {
			dst.Close()
		}
		done <- struct{}{}
	}
	go pipe(a, b)
	go pipe(b, a)
	<-done
	<-done
}
