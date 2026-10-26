#!/usr/bin/env python3
"""Only owned loopback SSH, WHOIS, RDAP and iperf3 fixtures; Bonjour uses LocalOnly."""
import http.server,json,pathlib,socket,subprocess,sys,tempfile,threading,time
from TunnelIntegrationTests import fixture,free_port
class RDAP(http.server.BaseHTTPRequestHandler):
    def log_message(self,*args):pass
    def do_GET(self):
        data=json.dumps({'objectClassName':'domain','ldhName':'EXAMPLE.TEST','status':['active'],'events':[{'eventAction':'registration','eventDate':'2026-01-01T00:00:00Z'}]}).encode()
        self.send_response(200);self.send_header('Content-Type','application/rdap+json');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
with tempfile.TemporaryDirectory(prefix='ssh-hub-extra-integration-',dir='/private/tmp') as folder:
    root=pathlib.Path(folder); processes=[]; stopping=threading.Event(); received=[]
    http=http.server.ThreadingHTTPServer(('127.0.0.1',0),RDAP);threading.Thread(target=http.serve_forever,daemon=True).start()
    whois=socket.socket();whois.bind(('127.0.0.1',0));whois.listen();whois.settimeout(.2)
    def serve_whois():
        while not stopping.is_set():
            try: stream,_=whois.accept()
            except socket.timeout:continue
            except OSError:break
            with stream:
                stream.settimeout(2);query=b''
                while not query.endswith(b'\n'):
                    chunk=stream.recv(1024)
                    if not chunk:break
                    query+=chunk
                received.append(query)
                if query==b'big.test\r\n':stream.sendall(b'x'*1_100_000)
                elif query==b'slow.test\r\n':stopping.wait(2)
                else:stream.sendall(b'Domain Name: EXAMPLE.TEST\r\nRegistry: Fixture\r\n')
    threading.Thread(target=serve_whois,daemon=True).start()
    iperf=sys.argv[2] if len(sys.argv)>2 else '-';ports=[free_port() for _ in range(3)]
    try:
        if iperf!='-':
            for port in ports:
                process=subprocess.Popen([iperf,'-s','-1','-B','127.0.0.1','-p',str(port),'--idle-timeout','90'],stdout=subprocess.DEVNULL,stderr=subprocess.PIPE);processes.append(process)
                deadline=time.monotonic()+3
                while True:
                    probe=socket.socket()
                    try:probe.bind(('127.0.0.1',port));bound=False
                    except OSError:bound=True
                    finally:probe.close()
                    if bound:break
                    if process.poll() is not None or time.monotonic()>deadline:raise RuntimeError('iperf3 server not listening')
                    time.sleep(.03)
        with fixture(root/'ssh') as (config,_,__):
            ssh_port=next(line.split()[1] for line in config.read_text().splitlines() if line.strip().startswith('Port '))
            original=(root/'ssh'/'known_hosts').read_bytes()
            subprocess.run([sys.argv[1],str(config),ssh_port,str(http.server_port),str(whois.getsockname()[1]),iperf,','.join(map(str,ports))],check=True,timeout=100)
            assert (root/'ssh'/'known_hosts').read_bytes()==original,'SSH tooling changed known_hosts'
            assert not (root/'ssh'/'should-not-exist').exists(),'SSH probe inherited LocalCommand'
        assert received==[b'example.test\r\n',b'big.test\r\n',b'slow.test\r\n'],received
        subprocess.run([sys.argv[1],'--bonjour'],check=True,timeout=15)
    finally:
        stopping.set();whois.close();http.shutdown();http.server_close()
        for process in processes:
            if process.poll() is None:process.terminate()
            try:process.wait(timeout=3)
            except subprocess.TimeoutExpired:process.kill();process.wait()
