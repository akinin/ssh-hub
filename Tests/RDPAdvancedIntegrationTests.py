"""Real RDP channels against temporary localhost fixtures; no user servers or clipboard."""
import contextlib, pathlib, queue, struct, subprocess, sys, tempfile, threading, time
from RemoteIntegrationTests import line, exact
from TunnelIntegrationTests import fixture as ssh_fixture, session as ssh_session, free_port

helper, fixture = sys.argv[1:3]
with tempfile.TemporaryDirectory(prefix="ssh-hub-rdp-channels-", dir="/private/tmp") as directory, contextlib.ExitStack() as stack:
    root = pathlib.Path(directory)
    cert, key = root / "cert.pem", root / "key.pem"
    subprocess.run(["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", str(key), "-out", str(cert), "-days", "1", "-subj", "/CN=127.0.0.1", "-addext", "subjectAltName=IP:127.0.0.1"], check=True, capture_output=True)
    share = root / "share"; share.mkdir(); (share / "from-mac.txt").write_text("MAC_FILE_OK")
    errors = (root / "errors.log").open("wb")
    server = subprocess.Popen([fixture, str(cert), str(key), "none", "channels"], stdout=subprocess.PIPE, stderr=errors)
    port = int(line(server.stdout).split()[1])
    proxy_port = 0
    if len(sys.argv) > 3:
        config, _, _ = stack.enter_context(ssh_fixture(root / "ssh"))
        proxy_port = free_port()
        stack.enter_context(ssh_session(pathlib.Path(sys.argv[3]),config,proxy_port,"socks",0,root / "stop-ssh"))
    client = subprocess.Popen([helper, "127.0.0.1", str(port), "fixture", "", "640", "480", str(root / "config"), "2", "1", str(share), str(proxy_port)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errors)
    events = queue.Queue(); write_lock = threading.Lock()
    def write(data):
        with write_lock:
            client.stdin.write(data); client.stdin.flush()
    def read_client():
        try:
            while True:
                kind, length = struct.unpack("!II", exact(client.stdout, 8))
                assert length <= 132000008
                value = exact(client.stdout, length)
                if kind == 2: write(struct.pack("!I", 1))  # Known self-signed fixture, in this process only.
                elif kind == 1: events.put(("frame", struct.unpack("!II", value[:8])))
                else: events.put(("message", (kind, value.decode("utf-8"))))
        except BaseException as error: events.put(("client_end", str(error)))
    def read_server():
        try:
            while True: events.put(("server", line(server.stdout)))
        except BaseException: events.put(("server_end", "EOF"))
    threading.Thread(target=read_client, daemon=True).start(); threading.Thread(target=read_server, daemon=True).start()
    secret = b"fixture-secret"; write(struct.pack("!I",len(secret)) + secret)
    seen = []; deadline = time.monotonic() + 25; sent = False; resized = False
    try:
        while time.monotonic() < deadline:
            try: event = events.get(timeout=10)
            except queue.Empty: raise AssertionError((seen, (root / "errors.log").read_text(errors="replace")[-7000:]))
            seen.append(event)
            if event == ("message", (4, "Изменение разрешения доступно")) and not sent:
                text = "LOCAL_CLIP_Привет".encode(); write(struct.pack("!IIII",5,len(text),0,0) + text)
                sent = True
            if not resized and all(item in seen for item in [("server", "CLIP_LOCAL LOCAL_CLIP_Привет"),("server", "DRIVE_READ 0 MAC_FILE_OK"),("server", "DRIVE_WRITE 0 15"),("server", "DRIVE_CLOSED 2")]):
                write(struct.pack("!IIII",7,800,600,2)); resized = True
            requirements = [
                any(k == "server" and v.startswith("MONITORS 2 1280 480") for k,v in seen),
                ("message", (3,"REMOTE_CLIP_Привет")) in seen,
                ("server", "CLIP_LOCAL LOCAL_CLIP_Привет") in seen,
                ("server", "LAYOUT 2 1600 600") in seen,
                ("frame", (1600,600)) in seen,
                ("server", "DRIVE_READ 0 MAC_FILE_OK") in seen,
                ("server", "DRIVE_WRITE 0 15") in seen,
            ]
            if all(requirements): break
        assert all(requirements), (requirements,seen, (root / "errors.log").read_text(errors="replace")[-5000:])
        assert (share / "from-windows.txt").read_bytes() == b"WINDOWS_FILE_OK"
        write(struct.pack("!IIII",4,0,0,0)); client.wait(timeout=4)
        print("PASS RDP channels: bidirectional Unicode clipboard, selected drive read/write, two monitors, dynamic layout and resized framebuffer; localhost only" + ("; through owned SSH SOCKS tunnel" if proxy_port else ""))
    finally:
        for process in (client,server):
            if process.poll() is None: process.terminate()
            try: process.wait(timeout=3)
            except subprocess.TimeoutExpired: process.kill(); process.wait()
        errors.close()
