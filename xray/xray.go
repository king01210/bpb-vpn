// Package xray runs Xray-core for the BPB app, bound for Android with gomobile (see
// scripts/build_xray.sh): one Xray instance at a time, started from the app's JSON config,
// reading from the TUN device the app's VpnService opened. Only what the app uses: start and
// stop, a delay test through the running instance, the outbound traffic counters, the browser
// dialer address and the version.
//
// The app excludes itself from its VPN, so Xray's own sockets bypass the tunnel without
// VpnService.protect.
package xray

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	applog "github.com/xtls/xray-core/app/log"
	commlog "github.com/xtls/xray-core/common/log"
	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/features/stats"
	"github.com/xtls/xray-core/infra/conf/serial"
	_ "github.com/xtls/xray-core/main/distro/all"
	"github.com/xtls/xray-core/transport/internet/browser_dialer"
)

// Environment variables Xray-core reads.
const (
	envAsset         = "xray.location.asset"
	envCert          = "xray.location.cert"
	envTunFd         = "xray.tun.fd"
	envBrowserDialer = "xray.browser.dialer"
)

// InitEnv points Xray at dir for its geo files (geoip.dat, geosite.dat) and the
// certificates a config names without a path.
func InitEnv(dir string) {
	os.Setenv(envAsset, dir)
	os.Setenv(envCert, dir)
}

// Version is Xray-core's version, e.g. 26.10.21.
func Version() string {
	return core.Version()
}

// SetBrowserDialer sets the browser dialer's listen address, or turns it off ("").
func SetBrowserDialer(address string) {
	os.Setenv(envBrowserDialer, address)
	browser_dialer.Reload()
}

// Controller runs one Xray instance at a time.
type Controller struct {
	mu       sync.Mutex
	instance *core.Instance
	stats    stats.Manager
}

var registerConsole sync.Once

// NewController sends Xray's console log (when the config names no log file) to stdout.
func NewController() *Controller {
	registerConsole.Do(func() {
		err := applog.RegisterHandlerCreator(applog.LogType_Console,
			func(applog.LogType, applog.HandlerCreatorOptions) (commlog.Handler, error) {
				return commlog.NewLogger(func() commlog.Writer { return stdoutWriter{log.New(os.Stdout, "", 0)} }), nil
			})
		if err != nil {
			log.Printf("console log: %v", err)
		}
	})
	return &Controller{}
}

type stdoutWriter struct{ logger *log.Logger }

func (w stdoutWriter) Write(s string) error {
	w.logger.Print(s)
	return nil
}

func (stdoutWriter) Close() error { return nil }

// IsRunning: an instance is up.
func (c *Controller) IsRunning() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.instance != nil
}

// Start starts an instance from the JSON config, with the TUN device tunFd (0: none, for proxy
// mode). Does nothing while one is running.
func (c *Controller) Start(config string, tunFd int32) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.instance != nil {
		return nil
	}
	os.Setenv(envTunFd, strconv.Itoa(int(tunFd)))

	parsed, err := serial.LoadJSONConfig(strings.NewReader(config))
	if err != nil {
		return fmt.Errorf("config error: %w", err)
	}
	instance, err := core.New(parsed)
	if err != nil {
		return fmt.Errorf("core init failed: %w", err)
	}
	if err := instance.Start(); err != nil {
		instance.Close()
		return fmt.Errorf("startup failed: %w", err)
	}
	c.instance = instance
	c.stats, _ = instance.GetFeature(stats.ManagerType()).(stats.Manager)
	return nil
}

// Stop stops the running instance, if any.
func (c *Controller) Stop() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.instance == nil {
		return nil
	}
	err := c.instance.Close()
	c.instance, c.stats = nil, nil
	return err
}

// OutboundTraffic reads and resets the outbound traffic counters (the config's policy turns
// them on): "tag,uplink|downlink,bytes;" for each counter above 0.
func (c *Controller) OutboundTraffic() string {
	c.mu.Lock()
	manager := c.stats
	c.mu.Unlock()
	if manager == nil {
		return ""
	}
	var b strings.Builder
	manager.VisitCounters(func(name string, counter stats.Counter) bool {
		// outbound>>>tag>>>traffic>>>uplink
		parts := strings.Split(name, ">>>")
		if len(parts) != 4 || parts[0] != "outbound" || parts[2] != "traffic" {
			return true
		}
		if bytes := counter.Set(0); bytes > 0 {
			fmt.Fprintf(&b, "%s,%s,%d;", parts[1], parts[3], bytes)
		}
		return true
	})
	return b.String()
}

// MeasureDelay is the time in ms for a GET of url (a 204 / 200 page) through the running
// instance, the faster of two tries on one connection, so the second skips the handshakes.
func (c *Controller) MeasureDelay(url string) (int64, error) {
	c.mu.Lock()
	instance := c.instance
	c.mu.Unlock()
	if instance == nil {
		return -1, errors.New("not running")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()

	transport := &http.Transport{
		TLSHandshakeTimeout: 6 * time.Second,
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			dest, err := xnet.ParseDestination(network + ":" + addr)
			if err != nil {
				return nil, err
			}
			return core.Dial(ctx, instance, dest)
		},
	}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport}

	best := int64(-1)
	var lastErr error
	for range 2 {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
		if err != nil {
			return -1, err
		}
		start := time.Now()
		resp, err := client.Do(req)
		if err != nil {
			lastErr = err
			continue
		}
		_, err = io.Copy(io.Discard, resp.Body)
		resp.Body.Close()
		switch {
		case resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusNoContent:
			lastErr = fmt.Errorf("HTTP %s", resp.Status)
		case err != nil:
			lastErr = err
		default:
			if ms := time.Since(start).Milliseconds(); best < 0 || ms < best {
				best = ms
			}
		}
	}
	if best < 0 {
		return -1, lastErr
	}
	return best, nil
}
