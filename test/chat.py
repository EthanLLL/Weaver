# New Claude Code session on <tenant>, send <message>, wait for the turn to end. python chat.py <tenant> <shot> <message>
import os, sys, time
from playwright.sync_api import sync_playwright
tenant, shot, msg = sys.argv[1], sys.argv[2], sys.argv[3]
backend = sys.argv[4] if len(sys.argv) > 4 else "Claude Code"
pw = next(l.split("=", 1)[1].strip() for l in open(os.path.expanduser("~/weaver-ca/weaver.env")) if l.startswith("WEAVER_PASSWORD="))
with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width": 1280, "height": 860})
    logs = []
    pg.on("console", lambda m: m.type in ("error", "warning") and logs.append(f"{m.type}: {m.text}"))
    pg.on("response", lambda r: r.status >= 400 and logs.append(f"HTTP {r.status} {r.url}"))
    pg.goto(f"https://{tenant}.luozhen.cloud/")
    pg.wait_for_selector("input[type=password]", timeout=15000)
    pg.fill("input[type=password]", pw); pg.keyboard.press("Enter")
    pg.wait_for_selector(".new-chat", timeout=15000)
    pg.click(".new-chat"); pg.click(f".backend-menu >> text={backend}")
    # A new session shows "Send a message to start." once it exists.
    pg.wait_for_selector("text=Send a message to start.", timeout=120000)
    pg.wait_for_selector("textarea", timeout=15000)
    t0 = time.time()
    pg.fill("textarea", msg); pg.keyboard.press("Enter")
    # Busy while the turn runs; done when the stop button is gone and a reply is there.
    # Done when the header's status chip says idle again after the turn.
    pg.wait_for_function("!document.body.innerText.includes('Send a message to start.')", timeout=30000)
    time.sleep(3)
    for _ in range(150):
        if pg.evaluate("[...document.querySelectorAll('.chip')].some(c => c.textContent.trim() === 'idle')"): break
        time.sleep(2)
    print(f"turn took ~{time.time()-t0:.0f}s")
    time.sleep(2)
    pg.screenshot(path=shot)
    print("\n".join(logs[-20:]))
    b.close()
