# Log in through one node, use the token on the other, then drive the page.
# python login.py <port-node-1> <port-node-2> <screenshot>; password from ~/weaver-ca/weaver.env.
import os, sys, time, json, urllib.request
from playwright.sync_api import sync_playwright
p1, p2, shot = sys.argv[1:4]
pw = next(l.split("=", 1)[1].strip() for l in open(os.path.expanduser("~/weaver-ca/weaver.env")) if l.startswith("WEAVER_PASSWORD="))
def req(port, path, body=None, token=None):
    r = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=body and json.dumps(body).encode(), headers={"Host": "tenant-b.luozhen.cloud", "content-type": "application/json", **({"authorization": f"Bearer {token}"} if token else {})})
    try:
        with urllib.request.urlopen(r) as res: return res.status, res.read()
    except urllib.error.HTTPError as e: return e.code, b""
st, body = req(p1, "/login", {"password": pw}); token = json.loads(body)["token"]
print("login on node 1:", st, "| token on node 2 /me:", req(p2, "/me", token=token)[0], "| bad token:", req(p2, "/me", token="x")[0])
with sync_playwright() as p:
    b = p.chromium.launch(args=[f"--host-resolver-rules=MAP tenant-b.luozhen.cloud 127.0.0.1:{p2}"])
    pg = b.new_page(viewport={"width": 1000, "height": 400})
    pg.goto("http://tenant-b.luozhen.cloud/")
    pg.wait_for_selector("#login:not([hidden])")
    pg.fill("#password", "wrong"); pg.click("#login button"); pg.wait_for_function("document.getElementById('status').textContent === 'wrong password'")
    print("wrong password ->", pg.inner_text("#status"))
    pg.fill("#password", pw); pg.click("#login button")
    pg.wait_for_function("document.getElementById('status').textContent.startsWith('shell on')", timeout=15000)
    print("logged in ->", pg.inner_text("#status"))
    pg.click("#term"); pg.keyboard.type("hostname; whoami\n", delay=5); time.sleep(1.5)
    pg.reload(); pg.wait_for_function("document.getElementById('status').textContent.startsWith('shell on')", timeout=15000)
    print("after reload (token kept) ->", pg.inner_text("#status"))
    pg.click("#term"); pg.keyboard.type("hostname; whoami\n", delay=5); time.sleep(1.5)
    print(pg.evaluate("Array.from(document.querySelectorAll('.xterm-rows > div')).map(d => d.textContent).filter(Boolean).join('\\n')"))
    pg.screenshot(path=shot); b.close()
