# Drive the terminal page in Chromium: python terminal.py <port> <tenant> <screenshot>
import sys, time
from playwright.sync_api import sync_playwright
port, tenant, shot = sys.argv[1], sys.argv[2], sys.argv[3]
with sync_playwright() as p:
    b = p.chromium.launch(args=[f"--host-resolver-rules=MAP {tenant}.luozhen.cloud 127.0.0.1:{port}"])
    pg = b.new_page(viewport={"width": 1000, "height": 520})
    pg.goto(f"http://{tenant}.luozhen.cloud/")
    pg.wait_for_function("document.getElementById('status').textContent.startsWith('shell on')", timeout=15000)
    print("status:", pg.inner_text("#status"))
    pg.click("#term")
    for line in ["whoami; hostname; tput cols; tput lines", "ls ~/notes && cat ~/notes/hello.md", "aws_signing_helper version"]:
        pg.keyboard.type(line + "\n", delay=5)
        time.sleep(1.2)
    pg.set_viewport_size({"width": 1300, "height": 600})
    time.sleep(0.8)
    pg.keyboard.type("tput cols\n", delay=5)
    time.sleep(1.2)
    print(pg.evaluate("Array.from(document.querySelectorAll('.xterm-rows > div')).map(d => d.textContent).filter(Boolean).join('\\n')"))
    pg.screenshot(path=shot)
    b.close()
