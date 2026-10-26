"""Optional real-engine test: pass test binary, Nuclei CLI and an official signed template.
No downloads; all scan targets are servers owned by this fixture on loopback.
"""
import http.server
import json
import pathlib
import subprocess
import sys
import tempfile
import threading


class Handler(http.server.BaseHTTPRequestHandler):
    mode = "match"
    requests = []
    trap_port = 0

    def do_GET(self):
        self.requests.append((self.path, dict(self.headers)))
        if self.mode == "redirect":
            self.send_response(302)
            self.send_header("Location", f"http://127.0.0.1:{self.trap_port}/outside")
            body = b"redirect"
        else:
            self.send_response(200)
            body = b"<title>Apache HTTP Server Test Page powered by CentOS</title>"
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


class Trap(Handler):
    requests = []


def main():
    test, cli, template = sys.argv[1:]
    assert pathlib.Path(template).name == "default-apache-test-page.yaml"
    assert "# digest:" in pathlib.Path(template).read_text()
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    trap = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Trap)
    Handler.trap_port = trap.server_port
    for value in (server, trap):
        threading.Thread(target=value.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix="nuclei-loopback-") as folder:
            for mode, count in (("match", 1), ("redirect", 0)):
                Handler.mode = mode
                root = pathlib.Path(folder) / mode
                subprocess.run([test, "--integration", cli, template,
                                f"http://127.0.0.1:{server.server_port}", str(root)], check=True)
                report = json.loads((root / "report.json").read_text())
                assert report["status"] == "completed"
                assert len(report["findings"]) == count
                if count:
                    assert report["findings"][0]["template"] == "default-apache-test-page"
                    assert report["findings"][0]["severity"] == "info"
            assert Handler.requests
            assert not Trap.requests, "redirect target must never be contacted"
            assert all("Authorization" not in headers and "Cookie" not in headers
                       for _, headers in Handler.requests)
        print("PASS real Nuclei: signed template, JSONL finding, anonymous request, no redirects")
    finally:
        for value in (server, trap):
            value.shutdown()
            value.server_close()


if __name__ == "__main__":
    main()
