# Through Cloudflare: log in on <tenant>.luozhen.cloud, run a command, a few times, and see which nodes served.
import os, sys, time
from playwright.sync_api import sync_playwright
tenant, shot, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
pw = next(l.split("=", 1)[1].strip() for l in open(os.path.expanduser("~/weaver-ca/weaver.env")) if l.startswith("WEAVER_PASSWORD="))
with sync_playwright() as p:
    b = p.chromium.launch()
    for i in range(n):
        ctx = b.new_context(viewport={"width": 1000, "height": 380}); pg = ctx.new_page()
        pg.goto(f"https://{tenant}.luozhen.cloud/")
        pg.wait_for_selector("#login:not([hidden])"); pg.fill("#password", pw); pg.click("#login button")
        pg.wait_for_function("document.getElementById('status').textContent.startsWith('shell on')", timeout=20000)
        print(i, pg.inner_text("#status"))
        if i == n - 1:
            pg.click("#term"); pg.keyboard.type("echo $USER@$(hostname) via the internet; claude --version 2>/dev/null || true\n", delay=5); time.sleep(2.5)
            pg.screenshot(path=shot)
        ctx.close()
    b.close()
