# Open Loom's terminal pane on <tenant>, run a command, reload, and see the same shell come back. python term_ui.py <tenant> <shot1> <shot2>
import os, sys, time
from playwright.sync_api import sync_playwright
tenant, shot1, shot2 = sys.argv[1:4]
pw = next(l.split("=", 1)[1].strip() for l in open(os.path.expanduser("~/weaver-ca/weaver.env")) if l.startswith("WEAVER_PASSWORD="))
with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width": 1280, "height": 760})
    logs = []
    pg.on("response", lambda r: r.status >= 400 and logs.append(f"HTTP {r.status} {r.url}"))
    pg.goto(f"https://{tenant}.luozhen.cloud/")
    pg.wait_for_selector("input[type=password]", timeout=15000)
    pg.fill("input[type=password]", pw); pg.keyboard.press("Enter")
    time.sleep(3)
    pg.click(".session >> nth=0"); time.sleep(2)
    pg.click(".terminal-toggle")
    pg.wait_for_selector(".xterm", timeout=15000); time.sleep(2)
    pg.click(".xterm")
    pg.keyboard.type("echo shell-$$ on $(hostname) as $(whoami); ls ~/.loom/sessions/*/output\n", delay=5)
    time.sleep(2)
    pg.screenshot(path=shot1)
    pg.reload()
    pg.wait_for_selector(".xterm", timeout=20000); time.sleep(3)
    pg.screenshot(path=shot2)
    print("\n".join(logs[-20:]))
    b.close()
