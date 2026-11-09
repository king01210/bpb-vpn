package main

import (
	"net"
	"sync"
)

// serveDNS answers plain DNS on [pc] with Psiphon's own resolver: queries go over udpgw with
// udpgwFlagDNS, which Psiphon servers answer themselves (like Tor's DNSPort). One udpgw port
// forward, opened on the first query and reopened if it closes; one conn ID per client.
func serveDNS(pc *net.UDPConn, t *tunnel) {
	var mu sync.Mutex
	var current *udpgw

	gateway := func() (*udpgw, error) {
		mu.Lock()
		defer mu.Unlock()
		if current != nil {
			return current, nil
		}
		g, err := dialUdpgw(t)
		if err != nil {
			return nil, err
		}
		current = g
		go func() {
			g.receive(func(id uint16, _ net.IP, _ int, answer []byte) {
				key, ok := g.key(id)
				if !ok {
					return
				}
				if to, err := net.ResolveUDPAddr("udp", key); err == nil {
					pc.WriteToUDP(answer, to)
				}
			})
			g.Close()
			mu.Lock()
			if current == g {
				current = nil
			}
			mu.Unlock()
		}()
		return g, nil
	}

	buf := make([]byte, 65535)
	for {
		n, from, err := pc.ReadFromUDP(buf)
		if err != nil {
			fatal("dns: %v", err)
		}
		g, err := gateway()
		if err != nil {
			logger.Printf("dns: %v", err)
			continue
		}
		// The address is ignored with udpgwFlagDNS.
		if err := g.send(from.String(), udpgwFlagDNS, net.IPv4zero, 53, buf[:n]); err != nil {
			g.Close()
		}
	}
}
