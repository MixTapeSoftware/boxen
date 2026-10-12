"""Exercise a real ChromeDriver session against the installed Chrome binary."""
import json
import shutil
import subprocess
import time
import urllib.error
import urllib.request

driver = subprocess.Popen(
    ["chromedriver", "--port=19515"],
    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
)
# This test only talks to a loopback server; leave the sandbox's proxy env intact.
client = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def request(path, body=None, method=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(
        "http://127.0.0.1:19515" + path, data=data, method=method,
        headers={"Content-Type": "application/json"},
    )
    with client.open(req, timeout=30) as response:
        return json.load(response)["value"]


try:
    for attempt in range(50):
        if driver.poll() is not None:
            raise RuntimeError("ChromeDriver exited before becoming ready")
        try:
            request("/status")
            break
        except urllib.error.URLError:
            time.sleep(0.1)
    else:
        raise RuntimeError("ChromeDriver did not become ready")
    session = request("/session", {"capabilities": {"alwaysMatch": {
        "browserName": "chrome",
        "goog:chromeOptions": {
            "binary": shutil.which("google-chrome"),
            "args": ["--headless=new", "--no-sandbox", "--disable-dev-shm-usage"],
        },
    }}})
    sid = session["sessionId"]
    request("/session/" + sid + "/url", {"url": "data:text/html,<title>agent-sbx</title>"})
    assert request("/session/" + sid + "/title") == "agent-sbx"
    request("/session/" + sid, method="DELETE")
    print("ChromeDriver session passed")
finally:
    driver.terminate()
    try:
        driver.wait(timeout=5)
    except subprocess.TimeoutExpired:
        driver.kill()
        driver.wait()
