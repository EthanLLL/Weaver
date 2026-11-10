# Drive Loom's frontend on <tenant>.luozhen.cloud: log in, screenshot. python ui.py <tenant> <shot>
import os, sys, time
from playwright.sync_api import sync_playwright
tenant, shot = sys.argv[1], sys.argv[2]
pw = next(l.split("=", 1)[1].strip() for l in open(os.path.expanduser("~/weaver-ca/weaver.env")) if l.startswith("WEAVER_PASSWORD="))
with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width": 1280, "height": 800})
    logs = []
    pg.on("console", lambda m: logs.append(f"{m.type}: {m.text}"))
    pg.on("response", lambda r: r.status >= 400 and logs.append(f"HTTP {r.status} {r.url}"))
    pg.goto(f"https://{tenant}.luozhen.cloud/")
    pg.wait_for_selector("input[type=password]", timeout=15000)
    pg.fill("input[type=password]", pw)
    pg.keyboard.press("Enter")
    time.sleep(4)
    pg.screenshot(path=shot)
    print("\n".join(logs[-20:]))
    b.close()
