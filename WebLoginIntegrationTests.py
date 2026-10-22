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
state = {"posts": [], "basic": 0, "steps": [], "roles": [], "scripted": [], "anchor": [], "get_leaks": 0}
form = '<form action="/submit" method="post"><input name="username" autocomplete="username"><input name="password" type="password" autocomplete="current-password"><button type="submit">Войти</button></form>'
# A DSM-like layout: input in a default-GET form, JS role button outside it,
# a hidden password autofill field, nested arrow and delayed reactive enablement.
role_second = '<form id="password-stage"><input syno-id="password" name="password" type="password"></form><div role="button" syno-id="password-next" aria-label="Войти"><div class="arrow"></div></div>'
role_page = '<div id="root"><form id="username-stage"><input syno-id="username" name="username"><input name="password" type="password" hidden></form><div role="button" syno-id="account-panel-next-btn" aria-label="Войти"><div class="arrow"></div></div></div><style>.arrow{width:40px;height:40px}</style><script>' + """
let ready=false;
const initial=document.querySelector('[syno-id=username]');
initial.addEventListener('input',()=>setTimeout(()=>ready=true,0));
document.querySelector('[syno-id=account-panel-next-btn]').onclick=()=>{
 if(!ready){document.title='Premature click';return;}
 const username=initial.value;
 document.querySelector('#root').innerHTML=SECOND;
 let passwordReady=false;
 const field=document.querySelector('[syno-id=password]');
 field.addEventListener('input',()=>setTimeout(()=>passwordReady=true,0));
 document.querySelector('[syno-id=password-next]').onclick=()=>{
  if(!passwordReady){document.title='Premature password click';return;}
  fetch('/role-finish',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams({username,password:field.value})}).then(()=>document.title='Role success');
 };
};
""".replace('SECOND', json.dumps(role_second)) + '</script>'
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def send(self, body, code=200, headers=None):
        self.send_response(code)
        for key, value in (headers or {}).items(): self.send_header(key, value)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers(); self.wfile.write(body.encode())
    def do_GET(self):
        route = urllib.parse.urlsplit(self.path).path
        if urllib.parse.urlsplit(self.path).query: state["get_leaks"] += 1
        if route == "/anchor-form": return self.send('''<div role="dialog"><div class="x-form"><input id="account" name="username"><input id="credential" name="password" type="password"></div><a role="button" id="enter" href="javascript:;" aria-disabled="true" class="x-btn"><span id="enter-inner" class="x-btn-inner">Login</span></a></div><script>
const u=document.querySelector('#account'),p=document.querySelector('#credential'),b=document.querySelector('#enter');
for(const input of [u,p])input.addEventListener('input',()=>setTimeout(()=>b.setAttribute('aria-disabled',u.value&&p.value?'false':'true'),0));
b.onclick=e=>{e.preventDefault();if(b.getAttribute('aria-disabled')==='true')return;fetch('/anchor-submit',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams({username:u.value,password:p.value})}).then(()=>document.title='Anchor success');};
</script>''')
        if route == "/scripted-form": return self.send('''<form id="login"><input id="account" name="username" type="email" required><input id="credential" name="password" type="password" required><button id="enter" type="submit" disabled>Вход</button></form><script>
const form=document.querySelector('form'), button=document.querySelector('button');
form.addEventListener('input',()=>setTimeout(()=>button.disabled=!form.checkValidity(),0));
form.addEventListener('submit',event=>{event.preventDefault();fetch('/scripted-submit',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams(new FormData(form))}).then(()=>document.title='Scripted success');});
</script>''')
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
        if route == "/manual": return self.send('<form action="/submit" method="post"><input id="account" name="username"><input id="credential" name="password" type="password"><button id="enter" type="submit">Continue to dashboard</button></form><form><input type="password"></form>')
        if route in ["/two", "/two-redirect"]: return self.send('<form action="/step-next' + ('-redirect' if route.endswith('redirect') else '') + '" method="post"><input id="step-user" name="username"><button id="next" type="submit">Далее</button></form>')
        if route == "/two-spa": return self.send('<input id="step-user"><button id="next" type="button">Далее</button><script>document.getElementById("next").onclick=()=>setTimeout(()=>document.body.innerHTML=' + json.dumps('<input id="step-password" type="password"><button id="finish" type="button" onclick="document.title=\'Two success\'">Войти</button>') + ',200)</script>')
        if route == "/role-two": return self.send(role_page)
        if route == "/form": return self.send(form)
        if route == "/blank": return self.send("<h1>Blank</h1>")
        return self.send("unknown", 404)
    def do_POST(self):
        data = self.rfile.read(min(int(self.headers.get("Content-Length", "0")), 8192)).decode()
        if self.path == '/anchor-submit':
            state['anchor'].append(urllib.parse.parse_qs(data)); return self.send('<h1>Anchor success</h1>')
        if self.path == '/scripted-submit':
            state['scripted'].append(urllib.parse.parse_qs(data)); return self.send('<h1>Scripted success</h1>')
        if self.path == '/role-finish':
            state['roles'].append(urllib.parse.parse_qs(data)); return self.send('<h1>Role success</h1>')
        if self.path.startswith('/step-'):
            state["steps"].append({"path": self.path, "fields": urllib.parse.parse_qs(data)})
            if self.path == '/step-next-redirect': return self.send('', 302, {'Location': second_url + '/form'})
            if self.path == '/step-next': return self.send('<form action="/step-finish" method="post"><input id="step-password" name="password" type="password"><button id="finish" type="submit">Войти</button></form>')
            return self.send('<h1>Two success</h1>')
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
    subprocess.run([sys.argv[1], "http://127.0.0.1:" + str(servers[0].server_port), second_url], check=True, timeout=105)
    assert [x["fields"] for x in state["steps"]] == [{"username": ["fixture-setup"]}, {"username": [USER]}, {"password": [PASSWORD]}, {"username": [USER]}], "two-step payloads and cross-origin stop"
    assert state["roles"] == [{"username": [USER], "password": [PASSWORD]}], "role buttons, delayed DOM and exact synthetic credentials"
    assert state["scripted"] == [{"username": [USER], "password": [PASSWORD]}], "explicit JS form submits via handler once"
    assert state["anchor"] == [{"username": [USER], "password": [PASSWORD]}], "ExtJS anchor button submits synthetic credentials exactly once"
    assert state["get_leaks"] == 0, "credentials never reach GET query strings"
    assert state["basic"] == 1, "single Basic authentication"
    assert len(state["posts"]) == 5, "normal, delayed, SPA, manual selectors and one failed form attempt only"
    assert all(x["fields"] == {"username": [USER], "password": [PASSWORD]} for x in state["posts"]), "argument values preserved"
    assert sum(x["path"] == "/repeat-submit" for x in state["posts"]) == 1, "no retry loop"
    print("Web login loopback integration passed: Basic, POST, delayed form, one attempt, exact credentials")
finally:
    for server in servers: server.shutdown(); server.server_close()
