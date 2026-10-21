// SSH Hub isolated WireGuard transport. No system TUN, routes or executable hooks.
package main

import (
	"bufio"
	"context"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun/netstack"
)

type configuration struct {
	Addresses, DNS []netip.Addr
	MTU            int
	IPC            string
	Peers          int
}

func key(s string) (string, error) {
	b, e := base64.StdEncoding.DecodeString(s)
	if e != nil || len(b) != 32 {
		return "", errors.New("invalid_key")
	}
	return hex.EncodeToString(b), nil
}
func parse(text string) (configuration, error) {
	c := configuration{MTU: 1420}
	section := ""
	seen := map[string]bool{}
	var ipc strings.Builder
	if len(text) > 65536 {
		return c, errors.New("config_limit")
	}
	scanner := bufio.NewScanner(strings.NewReader(text))
	for scanner.Scan() {
		line := strings.TrimSpace(strings.SplitN(scanner.Text(), "#", 2)[0])
		if line == "" {
			continue
		}
		if line == "[Interface]" {
			if section != "" {
				return c, errors.New("invalid_section")
			}
			section = "interface"
			continue
		}
		if line == "[Peer]" {
			if section == "" || c.Peers >= 16 {
				return c, errors.New("invalid_section")
			}
			section = "peer"
			c.Peers++
			ipc.WriteString("\x00peer\n")
			seen = map[string]bool{}
			continue
		}
		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 || section == "" {
			return c, errors.New("invalid_config")
		}
		field, value := strings.TrimSpace(parts[0]), strings.TrimSpace(parts[1])
		if seen[field] {
			return c, errors.New("duplicate_field")
		}
		seen[field] = true
		if section == "interface" {
			switch field {
			case "PrivateKey":
				k, e := key(value)
				if e != nil {
					return c, e
				}
				fmt.Fprintf(&ipc, "private_key=%s\n", k)
			case "Address":
				for _, v := range strings.Split(value, ",") {
					p, e := netip.ParsePrefix(strings.TrimSpace(v))
					if e != nil || p.Addr().IsUnspecified() || p.Addr().IsMulticast() {
						return c, errors.New("invalid_address")
					}
					c.Addresses = append(c.Addresses, p.Addr())
				}
			case "DNS":
				for _, v := range strings.Split(value, ",") {
					p, e := netip.ParseAddr(strings.TrimSpace(v))
					if e != nil || p.IsUnspecified() || p.IsMulticast() {
						return c, errors.New("invalid_dns")
					}
					c.DNS = append(c.DNS, p)
				}
			case "MTU":
				n, e := strconv.Atoi(value)
				if e != nil || n < 1280 || n > 9000 {
					return c, errors.New("invalid_mtu")
				}
				c.MTU = n
			case "ListenPort":
				n, e := strconv.Atoi(value)
				if e != nil || n < 0 || n > 65535 {
					return c, errors.New("invalid_port")
				}
				fmt.Fprintf(&ipc, "listen_port=%d\n", n)
			default:
				return c, errors.New("unsupported_field")
			}
		} else {
			switch field {
			case "PublicKey":
				k, e := key(value)
				if e != nil {
					return c, e
				}
				fmt.Fprintf(&ipc, "public_key=%s\n", k)
			case "PresharedKey":
				k, e := key(value)
				if e != nil {
					return c, e
				}
				fmt.Fprintf(&ipc, "preshared_key=%s\n", k)
			case "Endpoint":
				h, p, e := net.SplitHostPort(value)
				if e != nil || !validHost(h) {
					return c, errors.New("invalid_endpoint")
				}
				n, e := strconv.Atoi(p)
				if e != nil || n < 1 || n > 65535 {
					return c, errors.New("invalid_endpoint")
				}
				fmt.Fprintf(&ipc, "endpoint=%s\n", value)
			case "AllowedIPs":
				for _, v := range strings.Split(value, ",") {
					p, e := netip.ParsePrefix(strings.TrimSpace(v))
					if e != nil {
						return c, errors.New("invalid_allowed_ips")
					}
					fmt.Fprintf(&ipc, "allowed_ip=%s\n", p.Masked())
				}
			case "PersistentKeepalive":
				n, e := strconv.Atoi(value)
				if e != nil || n < 0 || n > 65535 {
					return c, errors.New("invalid_keepalive")
				}
				fmt.Fprintf(&ipc, "persistent_keepalive_interval=%d\n", n)
			default:
				return c, errors.New("unsupported_field")
			}
		}
	}
	segments := strings.Split(ipc.String(), "\x00peer\n")
	c.IPC = segments[0]
	for _, segment := range segments[1:] {
		public := ""
		rest := ""
		endpoint, allowed := false, false
		for _, line := range strings.Split(segment, "\n") {
			if strings.HasPrefix(line, "public_key=") {
				public = line
			} else if line != "" {
				rest += line + "\n"
				endpoint = endpoint || strings.HasPrefix(line, "endpoint=")
				allowed = allowed || strings.HasPrefix(line, "allowed_ip=")
			}
		}
		if public == "" || !endpoint || !allowed {
			return c, errors.New("incomplete_peer")
		}
		c.IPC += public + "\n" + rest
	}

	if scanner.Err() != nil || len(c.Addresses) == 0 || len(c.Addresses) > 16 || len(c.DNS) > 8 || c.Peers == 0 || !strings.Contains(c.IPC, "private_key=") || strings.Count(c.IPC, "public_key=") != c.Peers || strings.Count(c.IPC, "endpoint=") != c.Peers || strings.Count(c.IPC, "allowed_ip=") < c.Peers {
		return c, errors.New("incomplete_config")
	}
	return c, nil
}
func validHost(h string) bool {
	if len(h) == 0 || len(h) > 253 || strings.HasPrefix(h, "-") {
		return false
	}
	if _, e := netip.ParseAddr(h); e == nil {
		return true
	}
	for _, c := range h {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '.' || c == '-' || c == '_') {
			return false
		}
	}
	return true
}

// Counts encrypted UDP datagrams, including handshake and keepalive traffic.
type trafficBind struct {
	conn.Bind
	rxPackets, txPackets, rxBytes, txBytes atomic.Uint64
}

func (b *trafficBind) Open(port uint16) ([]conn.ReceiveFunc, uint16, error) {
	fns, actual, err := b.Bind.Open(port)
	for i, fn := range fns {
		receive := fn
		fns[i] = func(packets [][]byte, sizes []int, eps []conn.Endpoint) (int, error) {
			n, err := receive(packets, sizes, eps)
			for _, size := range sizes[:n] {
				if size > 0 {
					b.rxPackets.Add(1)
					b.rxBytes.Add(uint64(size))
				}
			}
			return n, err
		}
	}
	return fns, actual, err
}
func (b *trafficBind) Send(bufs [][]byte, ep conn.Endpoint) error {
	if err := b.Bind.Send(bufs, ep); err != nil {
		return err
	}
	for _, buf := range bufs {
		b.txPackets.Add(1)
		b.txBytes.Add(uint64(len(buf)))
	}
	return nil
}
func (r *router) stats() (map[string]any, error) {
	text, err := r.dev.IpcGet()
	if err != nil {
		return nil, err
	}
	var handshake int64
	for _, line := range strings.Split(text, "\n") {
		if value, ok := strings.CutPrefix(line, "last_handshake_time_sec="); ok {
			sec, _ := strconv.ParseInt(value, 10, 64)
			if sec > handshake {
				handshake = sec
			}
		}
	}
	return map[string]any{"ok": true, "rx_bytes": r.traffic.rxBytes.Load(), "tx_bytes": r.traffic.txBytes.Load(), "rx_packets": r.traffic.rxPackets.Load(), "tx_packets": r.traffic.txPackets.Load(), "handshake": handshake}, nil
}

type router struct {
	dev       *device.Device
	traffic   *trafficBind
	network   *netstack.Net
	mu        sync.Mutex
	listeners []net.Listener
	streams   map[net.Conn]bool
	closed    bool
	limit     chan struct{}
}

func newRouter(c configuration) (*router, error) {
	tun, network, e := netstack.CreateNetTUN(c.Addresses, c.DNS, c.MTU)
	if e != nil {
		return nil, errors.New("network_failed")
	}
	traffic := &trafficBind{Bind: conn.NewDefaultBind()}
	d := device.NewDevice(tun, traffic, device.NewLogger(device.LogLevelSilent, ""))
	if e = d.IpcSet(c.IPC); e != nil {
		d.Close()
		return nil, errors.New("wireguard_config_failed")
	}
	if e = d.Up(); e != nil {
		d.Close()
		return nil, errors.New("wireguard_start_failed")
	}
	return &router{dev: d, traffic: traffic, network: network, streams: map[net.Conn]bool{}, limit: make(chan struct{}, 128)}, nil
}
func (r *router) close() {
	r.mu.Lock()
	if r.closed {
		r.mu.Unlock()
		return
	}
	r.closed = true
	for _, l := range r.listeners {
		l.Close()
	}
	for c := range r.streams {
		c.Close()
	}
	r.mu.Unlock()
	r.dev.Close()
}
func (r *router) track(c net.Conn) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed {
		c.Close()
		return false
	}
	r.streams[c] = true
	return true
}
func (r *router) forget(c net.Conn) { c.Close(); r.mu.Lock(); delete(r.streams, c); r.mu.Unlock() }
func (r *router) serve(l net.Listener, handle func(net.Conn)) {
	r.mu.Lock()
	if r.closed {
		r.mu.Unlock()
		l.Close()
		return
	}
	r.listeners = append(r.listeners, l)
	r.mu.Unlock()
	go func() {
		for {
			c, e := l.Accept()
			if e != nil {
				return
			}
			select {
			case r.limit <- struct{}{}:
				if !r.track(c) {
					<-r.limit
					return
				}
				go func() { defer func() { r.forget(c); <-r.limit }(); handle(c) }()
			default:
				c.Close()
			}
		}
	}()
}
func (r *router) dial(ctx context.Context, host string, port int) (net.Conn, error) {
	if !validHost(host) || port < 1 || port > 65535 {
		return nil, errors.New("invalid_target")
	}
	c, e := r.network.DialContext(ctx, "tcp", net.JoinHostPort(host, strconv.Itoa(port)))
	if e == nil && !r.track(c) {
		return nil, errors.New("closed")
	}
	return c, e
}
func (r *router) relay(local net.Conn, remote net.Conn, source io.Reader) {
	defer r.forget(remote)
	local.SetDeadline(time.Time{})
	done := make(chan struct{})
	go func() { io.Copy(remote, source); remote.Close(); close(done) }()
	io.Copy(local, remote)
	local.Close()
	<-done
}

// Explicit diagnostic: both DNS and TCP stay inside this router's netstack.
func (r *router) probe(host string, port int, dnsHost string) map[string]any {
	if !validHost(host) || port < 1 || port > 65535 || (dnsHost != "" && !validHost(dnsHost)) {
		return map[string]any{"ok": false, "error": "invalid_target"}
	}
	begin := time.Now()
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	defer cancel()
	dns := "not_requested"
	query := dnsHost
	if query == "" {
		if _, err := netip.ParseAddr(host); err != nil {
			query = host
		}
	}
	if query != "" {
		dnsCtx, stop := context.WithTimeout(ctx, 2*time.Second)
		ips, err := r.network.LookupContextHost(dnsCtx, query)
		stop()
		dns = "failed"
		if err == nil && len(ips) > 0 {
			dns = "resolved"
		}
	}
	remote, err := r.dial(ctx, host, port)
	if err == nil {
		r.forget(remote)
	}
	stats, _ := r.stats()
	return map[string]any{"ok": true, "dns": dns, "tcp": err == nil, "handshake": stats["handshake"], "duration_ms": time.Since(begin).Milliseconds()}
}

func (r *router) forward(host string, port int) (int, error) {
	if !validHost(host) || port < 1 || port > 65535 {
		return 0, errors.New("invalid_target")
	}
	l, e := net.Listen("tcp4", "127.0.0.1:0")
	if e != nil {
		return 0, e
	}
	r.serve(l, func(c net.Conn) {
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		remote, e := r.dial(ctx, host, port)
		if e == nil {
			r.relay(c, remote, c)
		}
	})
	return l.Addr().(*net.TCPAddr).Port, nil
}
func (r *router) socks(c net.Conn) {
	c.SetDeadline(time.Now().Add(10 * time.Second))
	b := make([]byte, 2)
	if _, e := io.ReadFull(c, b); e != nil || b[0] != 5 || b[1] == 0 {
		return
	}
	methods := make([]byte, int(b[1]))
	if _, e := io.ReadFull(c, methods); e != nil {
		return
	}
	ok := false
	for _, m := range methods {
		if m == 0 {
			ok = true
		}
	}
	if !ok {
		c.Write([]byte{5, 255})
		return
	}
	c.Write([]byte{5, 0})
	h := make([]byte, 4)
	if _, e := io.ReadFull(c, h); e != nil || h[0] != 5 || h[1] != 1 || h[2] != 0 {
		return
	}
	host := ""
	switch h[3] {
	case 1:
		b := make([]byte, 4)
		if _, e := io.ReadFull(c, b); e != nil {
			return
		}
		host = net.IP(b).String()
	case 4:
		b := make([]byte, 16)
		if _, e := io.ReadFull(c, b); e != nil {
			return
		}
		host = net.IP(b).String()
	case 3:
		b := make([]byte, 1)
		if _, e := io.ReadFull(c, b); e != nil || b[0] == 0 {
			return
		}
		name := make([]byte, int(b[0]))
		if _, e := io.ReadFull(c, name); e != nil {
			return
		}
		host = string(name)
	default:
		return
	}
	p := make([]byte, 2)
	if _, e := io.ReadFull(c, p); e != nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	remote, e := r.dial(ctx, host, int(binary.BigEndian.Uint16(p)))
	if e != nil {
		c.Write([]byte{5, 4, 0, 1, 0, 0, 0, 0, 0, 0})
		return
	}
	c.Write([]byte{5, 0, 0, 1, 0, 0, 0, 0, 0, 0})
	r.relay(c, remote, c)
}

type request struct {
	DNSHost string `json:"dns_host"`
	Op      string `json:"op"`
	Config  string `json:"config"`
	Socket  string `json:"socket"`
	Host    string `json:"host"`
	Port    int    `json:"port"`
}

func reply(v any) { json.NewEncoder(os.Stdout).Encode(v) }
func run() error {
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 4096), 131072)
	if !scanner.Scan() {
		return errors.New("invalid_request")
	}
	var q request
	if json.Unmarshal(scanner.Bytes(), &q) != nil {
		return errors.New("invalid_request")
	}
	c, e := parse(q.Config)
	q.Config = ""
	if e != nil {
		return e
	}
	if q.Op == "validate" {
		reply(map[string]any{"ok": true, "addresses": c.Addresses, "peers": c.Peers, "dns": c.DNS})
		return nil
	}
	if q.Op != "start" || len(q.Socket) > 100 || len(q.Socket) < 1 {
		return errors.New("invalid_request")
	}
	r, e := newRouter(c)
	c.IPC = ""
	if e != nil {
		return e
	}
	defer r.close()
	l, e := net.Listen("unix", q.Socket)
	if e != nil {
		return errors.New("socket_failed")
	}
	os.Chmod(q.Socket, 0600)
	defer os.Remove(q.Socket)
	r.serve(l, func(s net.Conn) {
		s.SetDeadline(time.Now().Add(10 * time.Second))
		reader := bufio.NewReaderSize(s, 4096)
		line, e := reader.ReadSlice('\n')
		var target request
		if e != nil || json.Unmarshal(line, &target) != nil {
			return
		}
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		remote, e := r.dial(ctx, target.Host, target.Port)
		if e != nil {
			s.Write([]byte{1})
			return
		}
		s.Write([]byte{0})
		r.relay(s, remote, reader)
	})
	socks, e := net.Listen("tcp4", "127.0.0.1:0")
	if e != nil {
		return errors.New("socket_failed")
	}
	r.serve(socks, r.socks)
	reply(map[string]any{"ok": true, "port": socks.Addr().(*net.TCPAddr).Port})
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	go func() { <-sig; r.close(); os.Exit(0) }()
	for scanner.Scan() {
		var q request
		if json.Unmarshal(scanner.Bytes(), &q) != nil {
			return errors.New("invalid_request")
		}
		if q.Op == "probe" {
			reply(r.probe(q.Host, q.Port, q.DNSHost))
			continue
		}
		if q.Op == "stats" {
			stats, err := r.stats()
			if err != nil {
				reply(map[string]any{"ok": false, "error": "stats_failed"})
			} else {
				reply(stats)
			}
			continue
		}
		if q.Op != "forward" {
			return errors.New("invalid_request")
		}
		port, e := r.forward(q.Host, q.Port)
		if e != nil {
			reply(map[string]any{"ok": false, "error": "forward_failed"})
		} else {
			reply(map[string]any{"ok": true, "port": port})
		}
	}
	return nil
}
func connect(args []string) error {
	if len(args) != 3 {
		return errors.New("invalid_target")
	}
	port, e := strconv.Atoi(args[2])
	if e != nil || !validHost(args[1]) || port < 1 || port > 65535 {
		return errors.New("invalid_target")
	}
	st, e := os.Lstat(args[0])
	if e != nil || st.Mode()&os.ModeSocket == 0 || st.Mode().Perm() != 0600 {
		return errors.New("closed")
	}
	s, e := net.DialTimeout("unix", args[0], 3*time.Second)
	if e != nil {
		return errors.New("closed")
	}
	defer s.Close()
	s.SetDeadline(time.Now().Add(25 * time.Second))
	json.NewEncoder(s).Encode(request{Host: args[1], Port: port})
	b := make([]byte, 1)
	if _, e = io.ReadFull(s, b); e != nil || b[0] != 0 {
		return errors.New("vpn_unreachable")
	}
	s.SetDeadline(time.Time{})
	done := make(chan struct{})
	go func() {
		io.Copy(s, os.Stdin)
		if u, ok := s.(*net.UnixConn); ok {
			u.CloseWrite()
		}
		close(done)
	}()
	io.Copy(os.Stdout, s)
	return nil
}
func main() {
	var e error
	if len(os.Args) > 1 && os.Args[1] == "connect" {
		e = connect(os.Args[2:])
	} else if len(os.Args) == 1 {
		e = run()
	} else {
		e = errors.New("invalid_request")
	}
	if e != nil {
		reply(map[string]any{"ok": false, "error": e.Error()})
		os.Exit(1)
	}
}
