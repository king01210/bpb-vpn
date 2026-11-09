package main

import (
	"io"
	"net"
	"strconv"
	"sync/atomic"
	"time"
)

// SOCKS5 UDP ASSOCIATE over udpgw: one udpgw port forward per association, one conn ID per
// destination in it.
func handleUDPAssociate(ctrl net.Conn, t *tunnel) error {
	local, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		reply(ctrl, repFailure, nil)
		return err
	}
	defer local.Close()
	gw, err := dialUdpgw(t)
	if err != nil {
		reply(ctrl, repFailure, nil)
		return err
	}
	defer gw.Close()
	if err := reply(ctrl, repSucceeded, local.LocalAddr().(*net.UDPAddr)); err != nil {
		return err
	}
	ctrl.SetDeadline(time.Time{})

	var client atomic.Pointer[net.UDPAddr]

	// Replies go back to the client as SOCKS UDP datagrams (RSV RSV FRAG ATYP ADDR PORT DATA).
	go func() {
		defer local.Close()
		gw.receive(func(_ uint16, ip net.IP, port int, payload []byte) {
			if to := client.Load(); to != nil {
				local.WriteToUDP(append(appendAddr([]byte{0, 0, 0}, ip, port), payload...), to)
			}
		})
	}()

	// Datagrams from the client go on to their destinations.
	go func() {
		defer gw.Close()
		buf := make([]byte, 65535)
		for {
			n, from, err := local.ReadFromUDP(buf)
			if err != nil {
				return
			}
			if !from.IP.IsLoopback() || n < 4 || buf[2] != 0 { // fragments aren't supported
				continue
			}
			client.Store(from)
			r := &byteReader{b: buf[3:n]}
			host, port, err := readAddr(r)
			if err != nil {
				continue
			}
			ip := net.ParseIP(host)
			if ip == nil {
				if ip, err = t.resolve(host); err != nil {
					logger.Printf("udp: resolve %s: %v", host, err)
					continue
				}
			}
			key := net.JoinHostPort(ip.String(), strconv.Itoa(port))
			if err := gw.send(key, 0, ip, port, r.b); err != nil {
				return
			}
		}
	}()

	// The association lasts as long as the control connection.
	io.Copy(io.Discard, ctrl)
	return nil
}
