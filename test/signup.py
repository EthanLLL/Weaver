import sys, time
from playwright.sync_api import sync_playwright
# signup.py <new name> <invite>: sign up on the platform's host, land in the new tenant,
# then check invites are single-use and tokens are bound to their tenant.
name, invite = sys.argv[1], sys.argv[2]
with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page()
    pg.goto("https://weaver.luozhen.cloud/")
    pg.fill("input[placeholder=name]", name)
    pg.fill("input[type=password]", "correct-horse-1")
    pg.fill("input[placeholder='invite code']", "bogus")
    pg.click("button[type=submit]"); pg.wait_for_selector(".login-error"); print("bogus invite:", pg.inner_text(".login-error"))
    pg.fill("input[placeholder='invite code']", invite)
    t0 = time.time()
    pg.click("button[type=submit]")
    pg.wait_for_url(f"https://{name}.luozhen.cloud/**", timeout=120000)
    print("signed up, redirected in %.1fs to %s" % (time.time()-t0, pg.url))
    pg.wait_for_selector("text=New", timeout=120000)
    print("app loaded %.1fs after submit" % (time.time()-t0))
    pg.screenshot(path="/tmp/signup.png")
    # Same invite again: refused.
    pg2 = b.new_page(); pg2.goto("https://weaver.luozhen.cloud/")
    pg2.fill("input[placeholder=name]", name + "x"); pg2.fill("input[type=password]", "correct-horse-1"); pg2.fill("input[placeholder='invite code']", invite)
    pg2.click("button[type=submit]"); pg2.wait_for_selector(".login-error"); print("reused invite:", pg2.inner_text(".login-error"))
    # Fresh browser: login with password; wrong one refused; token from another tenant refused.
    c = b.new_context(); pg3 = c.new_page(); pg3.goto(f"https://{name}.luozhen.cloud/")
    pg3.fill("input[type=password]", "wrong-pass"); pg3.click("button[type=submit]"); pg3.wait_for_selector(".login-error"); print("wrong pw:", pg3.inner_text(".login-error"))
    pg3.fill("input[type=password]", "correct-horse-1"); pg3.click("button[type=submit]"); pg3.wait_for_selector("text=New", timeout=60000); print("login ok")
    tok = pg3.evaluate("localStorage.getItem('loom_token')")
    r = c.request.get("https://tenant-a.luozhen.cloud/api/layout", headers={"Authorization": "Bearer " + tok}); print("token on tenant-a:", r.status)
    r = c.request.get(f"https://{name}.luozhen.cloud/api/layout", headers={"Authorization": "Bearer " + tok}); print("token on own:", r.status)
    r = c.request.get("https://weaver.luozhen.cloud/api/layout"); print("platform host /api/layout:", r.status)
    b.close()
