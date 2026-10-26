#!/usr/bin/env python3
"""Disposable localhost SSH, DNS and TLS fixtures; no user server, keys or trust store."""
import http.server, os, pathlib, socket, ssl, struct, subprocess, sys, tempfile, threading
from TunnelIntegrationTests import fixture

class HTTPFixture(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_HEAD(self): self.reply(False)
    def do_GET(self): self.reply(True)
    def reply(self, body):
        redirects = {'/redirect':'/final', '/loop':'/loop', '/file':'file:///etc/passwd'}
        if self.path in redirects:
            self.send_response(302); self.send_header('Location',redirects[self.path]); self.end_headers(); return
        payload = b'<html><title>Fixture Nmap HTTP</title>BODY_NOT_SAVED</html>'
        self.send_response(200); self.send_header('Content-Type','text/html'); self.send_header('Content-Length',str(len(payload))); self.end_headers()
        if body: self.wfile.write(payload)

with tempfile.TemporaryDirectory(prefix='ssh-hub-toolkit-', dir='/private/tmp') as name:
    root = pathlib.Path(name)
    cfg = root/'certificate.cnf'
    cfg.write_text('[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=localhost\n[ext]\nsubjectAltName=DNS:localhost\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,digitalSignature,keyEncipherment,keyCertSign\nextendedKeyUsage=serverAuth\n')
    subprocess.run(['/usr/bin/openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','1','-config',str(cfg),'-keyout',str(root/'key.pem'),'-out',str(root/'cert.pem')],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    subprocess.run(['/usr/bin/openssl','x509','-in',str(root/'cert.pem'),'-outform','DER','-out',str(root/'cert.der')],check=True)
    tls = socket.socket(); tls.bind(('127.0.0.1',0)); tls.listen(); tls.settimeout(.2)
    dns = socket.socket(socket.AF_INET,socket.SOCK_DGRAM); dns.bind(('127.0.0.1',0)); dns.settimeout(.2)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); context.load_cert_chain(root/'cert.pem',root/'key.pem')
    stopping = threading.Event(); application_data = []
    def serve_tls():
        while not stopping.is_set():
            try: stream,_ = tls.accept()
            except socket.timeout: continue
            except OSError: break
            try:
                stream.settimeout(2)
                with context.wrap_socket(stream,server_side=True) as secure:
                    data = secure.recv(128)
                    if data: application_data.append(data)
            except (ssl.SSLError,OSError): stream.close()
    def serve_dns():
        while not stopping.is_set():
            try: query,address = dns.recvfrom(4096)
            except socket.timeout: continue
            except OSError: break
            end=12
            while query[end]: end += query[end]+1
            end += 5
            answer = query[:2]+struct.pack('!HHHHH',0x8180,1,1,0,0)+query[12:end]+b'\xc0\x0c'+struct.pack('!HHIH',1,1,60,4)+socket.inet_aton('192.0.2.10')
            dns.sendto(answer,address)
    http = http.server.ThreadingHTTPServer(('127.0.0.1',0),HTTPFixture)
    wol = socket.socket(socket.AF_INET,socket.SOCK_DGRAM); wol.bind(('127.0.0.1',0)); wol.settimeout(3)
    threads=[threading.Thread(target=serve_tls,daemon=True),threading.Thread(target=serve_dns,daemon=True),threading.Thread(target=http.serve_forever,daemon=True)]
    for thread in threads: thread.start()
    try:
        with fixture(root/'ssh') as (config,_,__):
            subprocess.run([sys.argv[1],str(config),str(tls.getsockname()[1]),str(dns.getsockname()[1]),str(root/'cert.der'),str(root/'ssh'),str(http.server_port),str(wol.getsockname()[1])],check=True,timeout=90)
            packet,_ = wol.recvfrom(2048)
            assert packet == bytes([255])*6 + bytes.fromhex('001122334455')*16
            transport = pathlib.Path(sys.argv[1]).with_name('transport-tests')
            subprocess.run([str(transport)],check=True,timeout=120,env=dict(os.environ, SSH_HUB_TEST_PORT=str(http.server_port)))
        assert not application_data,'TLS inspector sent application data'
    finally:
        stopping.set();tls.close();dns.close();wol.close();http.shutdown();http.server_close()
        for thread in threads: thread.join(timeout=3)
