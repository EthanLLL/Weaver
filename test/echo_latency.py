# Keystroke → echo latency in a Loom-frontend terminal. python echo_latency.py <origin> <password-env-file> <password-var> [n]
# Opens a terminal through the API, measures in the page (keydown on xterm's textarea → its rows change), closes it.
import os, sys, time, json, statistics
from playwright.sync_api import sync_playwright
origin, envfile, var = sys.argv[1:4]
n = int(sys.argv[4]) if len(sys.argv) > 4 else 30
pw = next(l.split("=", 1)[1].strip().strip('"') for l in open(os.path.expanduser(envfile)) if l.startswith(var + "="))
with sync_playwright() as p:
    args = [os.environ["HOST_RULES"]] if os.environ.get("HOST_RULES") else []
    b = p.chromium.launch(args=args); pg = b.new_page(viewport={"width": 1200, "height": 700})
    pg.goto(origin + "/"); pg.wait_for_selector("input[type=password]"); pg.fill("input[type=password]", pw); pg.keyboard.press("Enter")
    pg.wait_for_function("!document.querySelector('input[type=password]')", timeout=15000); time.sleep(2)
    token = pg.evaluate("Object.entries(localStorage).find(([k]) => /token/i.test(k))?.[1]")
    term = pg.evaluate("""async (t) => (await (await fetch('/api/sessions', {method: 'POST', headers: {authorization: 'Bearer ' + t, 'content-type': 'application/json'}, body: JSON.stringify({title: 'latency test'})})).json())""", token)
    pg.reload(); time.sleep(3)
    pg.click(".session >> nth=0"); time.sleep(1); pg.click(".terminal-toggle")
    pg.wait_for_selector(".xterm-rows", timeout=15000); time.sleep(2); pg.click(".xterm"); time.sleep(0.5)
    pg.evaluate("""() => {
      const rows = document.querySelector('.xterm-screen .xterm-rows') || document.querySelector('.xterm-rows')
      const ta = document.querySelector('.xterm-helper-textarea')
      window.__lat = []; let t0 = null
      ta.addEventListener('keydown', () => { t0 = performance.now() }, true)
      new MutationObserver(() => { if (t0 !== null) { window.__lat.push(performance.now() - t0); t0 = null } })
        .observe(rows, {subtree: true, childList: true, characterData: true})
    }""")
    for i in range(n):
        pg.keyboard.press("a"); time.sleep(0.25)
    lat = pg.evaluate("window.__lat")
    pg.keyboard.press("Control+c")
    pg.evaluate("""async ([t, id]) => fetch('/api/sessions/' + id, {method: 'DELETE', headers: {authorization: 'Bearer ' + t}})""", [token, term["id"]])
    b.close()
lat = sorted(lat)
print(f"{origin}: n={len(lat)} median {statistics.median(lat):.1f} ms, p90 {lat[int(len(lat)*0.9)-1]:.1f} ms, min {lat[0]:.1f}, max {lat[-1]:.1f}")
