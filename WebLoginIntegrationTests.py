#!/usr/bin/env python3
"""Owned loopback fixtures only; synthetic credentials never touch Keychain."""
import base64
import http.server
import json
import subprocess
import sys
import threading
import urllib.parse

USER = "fixture@example.test"
PASSWORD = "fixture-'\"\\</script>"
state = {"posts": [], "basic": 0}
form = '<form action="/submit" method="post"><input name="username" autocomplete="username"><input name="password" type="password" autocomplete="current-password"><button type="submit">Войти</button></form>'
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def send(self, body, code=200, headers=None):
        self.send_response(code)
        for key, value in (headers or {}).items(): self.send_header(key, value)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers(); self.wfile.write(body.encode())
    def do_GET(self):
        route = urllib.parse.urlsplit(self.path).path
        if route == "/state": return self.send(json.dumps(state))
        if route == "/basic":
            expected = "Basic " + base64.b64encode((USER + ":" + PASSWORD).encode()).decode()
            if self.headers.get("Authorization") != expected:
                return self.send("login", 401, {"WWW-Authenticate": 'Basic realm="fixture"'})
            state["basic"] += 1; return self.send("<h1>Basic success</h1>")
        if route == "/redirect": return self.send("", 302, {"Location": second_url + "/form"})
        if route == "/delayed": return self.send('<div id="root"></div><script>setTimeout(()=>document.getElementById("root").innerHTML=' + json.dumps(form) + ',300)</script>')
        if route == "/spa": return self.send('<input name="username"><input name="password" type="password"><button type="button" onclick="fetch(\'/submit\',{method:\'POST\',headers:{\'Content-Type\':\'application/x-www-form-urlencoded\'},body:new URLSearchParams({username:document.querySelector(\'[name=username]\').value,password:document.querySelector(\'[name=password]\').value})}).then(()=>document.title=\'SPA success\')">Login</button>')
        if route == "/repeat": return self.send(form.replace('/submit', '/repeat-submit'))
        if route == "/form": return self.send(form)
        if route == "/blank": return self.send("<h1>Blank</h1>")
        return self.send("unknown", 404)
    def do_POST(self):
        data = self.rfile.read(min(int(self.headers.get("Content-Length", "0")), 8192)).decode()
        state["posts"].append({"path": self.path, "fields": urllib.parse.parse_qs(data)})
        self.send(form.replace('/submit', '/repeat-submit') if self.path == '/repeat-submit' else '<h1>Form success</h1>')
class Server(http.server.ThreadingHTTPServer):
    def handle_error(self, request, client_address):
        if not isinstance(sys.exc_info()[1], (ConnectionResetError, BrokenPipeError)):
            super().handle_error(request, client_address)
servers = [Server(("127.0.0.1", 0), Handler) for _ in range(2)]
second_url = "http://127.0.0.1:" + str(servers[1].server_port)
for server in servers: threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    subprocess.run([sys.argv[1], "http://127.0.0.1:" + str(servers[0].server_port), second_url], check=True, timeout=90)
    assert state["basic"] == 1, "single Basic authentication"
    assert len(state["posts"]) == 4, "normal, delayed, SPA and one failed form attempt only"
    assert all(x["fields"] == {"username": [USER], "password": [PASSWORD]} for x in state["posts"]), "argument values preserved"
    assert sum(x["path"] == "/repeat-submit" for x in state["posts"]) == 1, "no retry loop"
    print("Web login loopback integration passed: Basic, POST, delayed form, one attempt, exact credentials")
finally:
    for server in servers: server.shutdown(); server.server_close()
