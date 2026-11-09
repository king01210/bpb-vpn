// Command psiphon runs a Psiphon tunnel for the BPB app and serves it as a local SOCKS5
// proxy, TCP and UDP, for Xray's "exit" outbound, and optionally as a local DNS server
// answered by Psiphon's own resolver (see dns.go). TCP from the SOCKS proxy is port forwarded
// through the tunnel; UDP goes over Psiphon's udpgw (see udpgw.go), which the stock local SOCKS
// proxy doesn't offer.
//
// -version prints the Psiphon core's module version and exits. Everything else is set by
// -config, a standard Psiphon config file (psiphon.LoadConfig: network IDs, server list,
// UpstreamProxyURL, EgressRegion, DataRootDirectory, LimitTunnelProtocols…) plus this
// program's own fields:
//
//	BpbSocksListen  the SOCKS5 address to serve (required)
//	BpbDnsListen    the DNS address to serve; empty for none
//
// Stdout carries JSON lines for the app: every Psiphon notice as is ({"noticeType":…}), plus
// this program's own {"event":"ready"} and {"event":"error",…}. The process exits when
// stdin closes, so it never outlives the app.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"runtime/debug"
	"sync"

	"github.com/Psiphon-Labs/psiphon-tunnel-core/psiphon"
)

var (
	stdoutMu sync.Mutex
	logger   = log.New(os.Stderr, "", log.LstdFlags)
)

// emit writes one status line for the app.
func emit(event string, fields map[string]any) {
	m := map[string]any{"event": event}
	for k, v := range fields {
		m[k] = v
	}
	b, _ := json.Marshal(m)
	writeLine(b)
}

// writeLine writes one line to stdout for the app.
func writeLine(b []byte) {
	stdoutMu.Lock()
	defer stdoutMu.Unlock()
	os.Stdout.Write(append(append([]byte{}, b...), '\n'))
}

func fatal(format string, args ...any) {
	emit("error", map[string]any{"message": fmt.Sprintf(format, args...)})
	os.Exit(1)
}

// options are this program's own fields in the config file, next to Psiphon's.
type options struct {
	BpbSocksListen string
	BpbDnsListen   string
}

// coreModule is the Psiphon core this program is built with.
const coreModule = "github.com/Psiphon-Labs/psiphon-tunnel-core"

func main() {
	configFile := flag.String("config", "", "Psiphon config file, with this program's Bpb* fields")
	version := flag.Bool("version", false, "print the Psiphon core's module version and exit")
	flag.Parse()

	if *version {
		if info, ok := debug.ReadBuildInfo(); ok {
			for _, dep := range info.Deps {
				if dep.Path == coreModule {
					fmt.Println(dep.Version)
				}
			}
		}
		return
	}

	raw, err := os.ReadFile(*configFile)
	if err != nil {
		fatal("config file: %v", err)
	}
	var opts options
	if err := json.Unmarshal(raw, &opts); err != nil {
		fatal("config file: %v", err)
	}
	if opts.BpbSocksListen == "" {
		fatal("config file: BpbSocksListen is required")
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Exit with the app: it holds our stdin open.
	go func() {
		io.Copy(io.Discard, os.Stdin)
		logger.Print("stdin closed, exiting")
		os.Exit(0)
	}()

	// Listen first so a busy port fails at once, not after the tunnel is up.
	ln, err := net.Listen("tcp", opts.BpbSocksListen)
	if err != nil {
		fatal("listen %s: %v", opts.BpbSocksListen, err)
	}
	var dnsConn *net.UDPConn
	if opts.BpbDnsListen != "" {
		addr, err := net.ResolveUDPAddr("udp", opts.BpbDnsListen)
		if err == nil {
			dnsConn, err = net.ListenUDP("udp", addr)
		}
		if err != nil {
			fatal("listen %s: %v", opts.BpbDnsListen, err)
		}
	}
	controller := startPsiphon(ctx, raw)
	t := newTunnel(controller)
	if dnsConn != nil {
		go serveDNS(dnsConn, t)
	}
	serveSocks(ln, t)
}

// startPsiphon starts the controller from the config file's content and returns once the
// first tunnel is up; the app stops it to give up.
func startPsiphon(ctx context.Context, raw []byte) *psiphon.Controller {
	config, err := psiphon.LoadConfig(raw)
	if err != nil {
		fatal("config: %v", err)
	}
	if config.DataRootDirectory != "" {
		if err := os.MkdirAll(config.DataRootDirectory, 0o700); err != nil {
			fatal("data directory: %v", err)
		}
	}

	connected := make(chan struct{})
	var once sync.Once
	// Every Psiphon notice goes to the app as is ({"noticeType":…,"data":…} per line), so the
	// app picks what to show without changes here. The first tunnel also unblocks startup.
	psiphon.SetNoticeWriter(psiphon.NewNoticeReceiver(func(notice []byte) {
		writeLine(notice)
		var n struct {
			Type string         `json:"noticeType"`
			Data map[string]any `json:"data"`
		}
		if json.Unmarshal(notice, &n) == nil && n.Type == "Tunnels" {
			if count, _ := n.Data["count"].(float64); count > 0 {
				once.Do(func() { close(connected) })
			}
		}
	}))
	// Diagnostic notices include each failed attempt ("failed to connect to …"), for the app's progress
	// line. false: no circumvention network parameters in them.
	psiphon.SetEmitDiagnosticNotices(true, false)

	if err := config.Commit(true); err != nil {
		fatal("config: %v", err)
	}
	if err := psiphon.OpenDataStore(config); err != nil {
		fatal("data store: %v", err)
	}
	controller, err := psiphon.NewController(config)
	if err != nil {
		fatal("controller: %v", err)
	}
	go func() {
		controller.Run(ctx)
		fatal("Psiphon stopped")
	}()

	select {
	case <-connected:
	case <-ctx.Done():
	}
	emit("ready", nil)
	return controller
}
