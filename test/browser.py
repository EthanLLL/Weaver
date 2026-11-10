# Open the Browser pane on <tenant>.luozhen.cloud, wait for VNC, screenshot; then a content search.
# python browser.py <tenant> <shot> [query]
import os, sys, time
from playwright.sync_api import sync_playwright
tenant, shot = sys.argv[1], sys.argv[2]
query = sys.argv[3] if len(sys.argv) > 3 else None
pw = next(l.split("=", 1)[1].strip() for l in open(os.path.expanduser("~/weaver-ca/weaver.env")) if l.startswith("WEAVER_PASSWORD="))
with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width": 1400, "height": 900})
    logs = []
    pg.on("console", lambda m: logs.append(f"{m.type}: {m.text}"))
    pg.on("websocket", lambda ws: logs.append(f"ws {ws.url.split('?')[0]}"))
    pg.goto(f"https://{tenant}.luozhen.cloud/")
    pg.wait_for_selector("input[type=password]", timeout=15000)
    pg.fill("input[type=password]", pw)
    pg.keyboard.press("Enter")
    pg.wait_for_selector("button[title^='Your browser']", timeout=15000)
    pg.click("button[title^='Your browser']")
    t0 = time.time()
    pg.wait_for_selector(".browser canvas, canvas", timeout=120000)
    time.sleep(3)
    print(f"canvas after {time.time() - t0:.1f}s")
    pg.screenshot(path=shot)
    if query:
        pg.click("button[title^='Search']")
        pg.keyboard.type(query)
        time.sleep(3)
        pg.screenshot(path=shot.replace(".png", "-search.png"))
    print("\n".join(logs[-15:]))
    b.close()
