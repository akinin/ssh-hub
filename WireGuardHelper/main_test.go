package main

import (
	"bufio"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"golang.org/x/crypto/curve25519"
	"golang.org/x/crypto/ssh"
	"golang.org/x/crypto/ssh/knownhosts"
	"golang.org/x/net/dns/dnsmessage"
	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun/netstack"
)

func keys(t *testing.T) (string, string) {
	t.Helper()
	private := make([]byte, 32)
	rand.Read(private)
	public, e := curve25519.X25519(private, curve25519.Basepoint)
	if e != nil {
		t.Fatal(e)
	}
	return base64.StdEncoding.EncodeToString(private), base64.StdEncoding.EncodeToString(public)
}
func clientConfig(private, public string, port int) string {
	return fmt.Sprintf("[Interface]\nPrivateKey=%s\nAddress=10.77.0.2/32\nDNS=10.77.0.1\n[Peer]\nAllowedIPs=0.0.0.0/0\nEndpoint=127.0.0.1:%d\nPublicKey=%s\n", private, port, public)
}
func TestConfig(t *testing.T) {
	a, b := keys(t)
	good := clientConfig(a, b, 12345)
	c, e := parse(good)
	if e != nil || len(c.Addresses) != 1 || c.Peers != 1 || !strings.HasPrefix(c.IPC, "private_key=") {
		t.Fatal("valid profile")
	}
	for _, bad := range []string{good + "PostUp=touch /tmp/forbidden\n", strings.Replace(good, "Address=10.77.0.2/32", "Address=bad", 1), strings.Replace(good, "DNS=10.77.0.1", "DNS=system.example", 1), strings.Replace(good, "PublicKey="+b, "PublicKey=bad", 1), good + "[Peer]\nPublicKey=" + b + "\n", good + "[Interface]\n", good + "Endpoint=127.0.0.1:1\n"} {
		if _, e := parse(bad); e == nil {
			t.Fatal("accepted invalid config")
		}
	}
	if validHost("x';touch /tmp/a") || validHost("-oProxyCommand=x") || validHost("x\n") {
		t.Fatal("invalid host")
	}
}
func udpPort(t *testing.T) int {
	p, e := net.ListenPacket("udp4", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	n := p.LocalAddr().(*net.UDPAddr).Port
	p.Close()
	return n
}

type ownedServer struct {
	device  *device.Device
	network *netstack.Net
	port    int
	hostkey ssh.PublicKey
	public  string
}

func server(t *testing.T, clientPub, label string) *ownedServer {
	t.Helper()
	private, public := keys(t)
	tun, n, e := netstack.CreateNetTUN([]netip.Addr{netip.MustParseAddr("10.77.0.1")}, nil, 1420)
	if e != nil {
		t.Fatal(e)
	}
	d := device.NewDevice(tun, conn.NewDefaultBind(), device.NewLogger(device.LogLevelSilent, ""))
	p := udpPort(t)
	k, _ := key(private)
	pub, _ := key(clientPub)
	if e := d.IpcSet(fmt.Sprintf("private_key=%s\nlisten_port=%d\npublic_key=%s\nallowed_ip=10.77.0.2/32\n", k, p, pub)); e != nil {
		t.Fatal(e)
	}
	if e := d.Up(); e != nil {
		t.Fatal(e)
	}
	l, e := n.ListenTCPAddrPort(netip.MustParseAddrPort("10.77.0.1:8080"))
	if e != nil {
		t.Fatal(e)
	}
	go func() {
		for {
			c, e := l.Accept()
			if e != nil {
				return
			}
			go func() { defer c.Close(); io.WriteString(c, label) }()
		}
	}()
	dns, e := n.ListenUDPAddrPort(netip.MustParseAddrPort("10.77.0.1:53"))
	if e != nil {
		t.Fatal(e)
	}
	go func() {
		b := make([]byte, 1500)
		for {
			size, from, e := dns.ReadFrom(b)
			if e != nil {
				return
			}
			var q dnsmessage.Message
			if q.Unpack(b[:size]) != nil {
				continue
			}
			response := dnsmessage.Message{Header: dnsmessage.Header{ID: q.ID, Response: true, RecursionAvailable: true}, Questions: q.Questions}
			for _, question := range q.Questions {
				if question.Type == dnsmessage.TypeA && question.Name.String() == "owned.test." {
					response.Answers = append(response.Answers, dnsmessage.Resource{Header: dnsmessage.ResourceHeader{Name: question.Name, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET, TTL: 1}, Body: &dnsmessage.AResource{A: [4]byte{10, 77, 0, 1}}})
				}
			}
			packed, _ := response.Pack()
			dns.WriteTo(packed, from)
		}
	}()
	_, hostPrivate, _ := ed25519.GenerateKey(rand.Reader)
	signer, _ := ssh.NewSignerFromKey(hostPrivate)
	cfg := &ssh.ServerConfig{NoClientAuth: true}
	cfg.AddHostKey(signer)
	sl, e := n.ListenTCPAddrPort(netip.MustParseAddrPort("10.77.0.1:2222"))
	if e != nil {
		t.Fatal(e)
	}
	go func() {
		for {
			c, e := sl.Accept()
			if e != nil {
				return
			}
			go func() {
				defer c.Close()
				sc, channels, requests, e := ssh.NewServerConn(c, cfg)
				if e != nil {
					return
				}
				defer sc.Close()
				go ssh.DiscardRequests(requests)
				for ch := range channels {
					if ch.ChannelType() != "session" {
						ch.Reject(ssh.UnknownChannelType, "session only")
						continue
					}
					session, reqs, e := ch.Accept()
					if e != nil {
						return
					}
					go func() {
						defer session.Close()
						for r := range reqs {
							if r.Type == "exec" {
								r.Reply(true, nil)
								io.WriteString(session, label)
								session.SendRequest("exit-status", false, ssh.Marshal(struct{ Status uint32 }{0}))
								return
							}
							if r.WantReply {
								r.Reply(false, nil)
							}
						}
					}()
				}
			}()
		}
	}()
	t.Cleanup(func() { l.Close(); sl.Close(); dns.Close(); d.Close() })
	return &ownedServer{d, n, p, signer.PublicKey(), public}
}

type clientProcess struct {
	command *exec.Cmd
	input   io.WriteCloser
	output  *bufio.Reader
	port    int
	socket  string
}

func (c *clientProcess) request(t *testing.T, q map[string]any) map[string]any {
	t.Helper()
	if e := json.NewEncoder(c.input).Encode(q); e != nil {
		t.Fatal(e)
	}
	line, e := c.output.ReadBytes('\n')
	if e != nil {
		t.Fatal(e)
	}
	var r map[string]any
	if json.Unmarshal(line, &r) != nil || r["ok"] != true {
		t.Fatal("helper rejected request")
	}
	return r
}
func client(t *testing.T, binary, config string) *clientProcess {
	t.Helper()
	dir, e := os.MkdirTemp("/private/tmp", "wg-owned-")
	if e != nil {
		t.Fatal(e)
	}
	os.Chmod(dir, 0700)
	cmd := exec.Command(binary)
	input, _ := cmd.StdinPipe()
	output, _ := cmd.StdoutPipe()
	if e := cmd.Start(); e != nil {
		t.Fatal(e)
	}
	c := &clientProcess{command: cmd, input: input, output: bufio.NewReader(output), socket: filepath.Join(dir, "s")}
	r := c.request(t, map[string]any{"op": "start", "config": config, "socket": c.socket})
	c.port = int(r["port"].(float64))
	t.Cleanup(func() {
		input.Close()
		done := make(chan struct{})
		go func() { cmd.Wait(); close(done) }()
		select {
		case <-done:
		case <-time.After(2 * time.Second):
			cmd.Process.Kill()
			<-done
		}
		os.RemoveAll(dir)
	})
	return c
}
func viaSOCKS(t *testing.T, port int, host string) string {
	t.Helper()
	c, e := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", port), time.Second)
	if e != nil {
		t.Fatal(e)
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(5 * time.Second))
	c.Write([]byte{5, 1, 0})
	b := make([]byte, 2)
	io.ReadFull(c, b)
	if b[1] != 0 {
		t.Fatal("SOCKS greeting")
	}
	request := append([]byte{5, 1, 0, 3, byte(len(host))}, []byte(host)...)
	request = append(request, 0x1f, 0x90)
	c.Write(request)
	h := make([]byte, 10)
	if _, e := io.ReadFull(c, h); e != nil || h[1] != 0 {
		t.Fatal("SOCKS encrypted dial", e)
	}
	data, e := io.ReadAll(c)
	if e != nil {
		t.Fatal(e)
	}
	return string(data)
}
func TestOwnedEncryptedIsolation(t *testing.T) {
	binary := os.Getenv("SSH_HUB_WG_HELPER")
	if binary == "" {
		t.Skip("helper path required for owned subprocess integration")
	}
	onePrivate, onePublic := keys(t)
	twoPrivate, twoPublic := keys(t)
	one := server(t, onePublic, "vpn-one")
	two := server(t, twoPublic, "vpn-two")
	a := client(t, binary, clientConfig(onePrivate, one.public, one.port))
	b := client(t, binary, clientConfig(twoPrivate, two.public, two.port))
	if got := viaSOCKS(t, a.port, "owned.test"); got != "vpn-one" {
		t.Fatal("DNS/route one", got)
	}
	if got := viaSOCKS(t, b.port, "owned.test"); got != "vpn-two" {
		t.Fatal("DNS/route two", got)
	}
	for _, c := range []*clientProcess{a, b} {
		result := c.request(t, map[string]any{"op": "probe", "host": "10.77.0.1", "port": 8080, "dns_host": "owned.test"})
		if result["tcp"] != true || result["dns"] != "resolved" || result["handshake"].(float64) <= 0 {
			t.Fatal("explicit probe failed")
		}
		if len(result) != 5 {
			t.Fatal("probe returned unexpected fields")
		}
		stats := c.request(t, map[string]any{"op": "stats"})
		for _, field := range []string{"rx_bytes", "tx_bytes", "rx_packets", "tx_packets", "handshake"} {
			if value, ok := stats[field].(float64); !ok || value <= 0 {
				t.Fatalf("missing traffic/handshake: %s", field)
			}
		}
		if len(stats) != 6 {
			t.Fatal("stats returned unexpected fields")
		}
		r := c.request(t, map[string]any{"op": "forward", "host": "10.77.0.1", "port": 8080})
		s, e := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", int(r["port"].(float64))), time.Second)
		if e != nil {
			t.Fatal(e)
		}
		s.SetDeadline(time.Now().Add(5 * time.Second))
		v, e := io.ReadAll(s)
		s.Close()
		if e != nil || !strings.HasPrefix(string(v), "vpn-") {
			t.Fatal("forward", e)
		}
	}
	dir := t.TempDir()
	known := filepath.Join(dir, "known_hosts")
	os.WriteFile(known, []byte(knownhosts.Line([]string{"[10.77.0.1]:2222"}, one.hostkey)+"\n"), 0600)
	proxy := fmt.Sprintf("'%s' connect '%s' 10.77.0.1 2222", binary, a.socket)
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, "/usr/bin/ssh", "-F", "/dev/null", "-T", "-o", "ProxyCommand="+proxy, "-o", "ControlPath=none", "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile="+known, "-o", "GlobalKnownHostsFile=/dev/null", "-p", "2222", "demo@10.77.0.1", "owned-command")
	out, e := command.Output()
	if e != nil || string(out) != "vpn-one" {
		t.Fatal("OpenSSH private proxy/host identity", e)
	}
	a.input.Close()
	time.Sleep(100 * time.Millisecond)
	if got := viaSOCKS(t, b.port, "10.77.0.1"); got != "vpn-two" {
		t.Fatal("closing one affected two")
	}
	// A destination outside the peer is never dialled by the system stack.
	c, e := parse(clientConfig(twoPrivate, two.public, udpPort(t)))
	if e != nil {
		t.Fatal(e)
	}
	r, e := newRouter(c)
	if e != nil {
		t.Fatal(e)
	}
	defer r.close()
	failed := r.probe("127.0.0.1", 8080, "")
	if failed["tcp"] != false || failed["dns"] != "not_requested" {
		t.Fatal("probe bypassed unavailable VPN")
	}
	deadline, stop := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer stop()
	if s, e := r.dial(deadline, "127.0.0.1", 8080); e == nil {
		s.Close()
		t.Fatal("unreachable VPN bypassed")
	}
}
