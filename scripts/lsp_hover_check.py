import json
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parents[1]
uri = (root / "golden" / "budget_01.tg").as_uri()

p = subprocess.Popen(
    [str(root / "build" / "tg"), "lsp"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
)


def send(msg):
    raw = json.dumps(msg, separators=(",", ":")).encode("utf-8")
    p.stdin.write(f"Content-Length: {len(raw)}\r\n\r\n".encode("ascii") + raw)
    p.stdin.flush()


def recv():
    headers = b""
    while True:
        line = p.stdout.readline()
        if not line:
            return None
        headers += line
        if line in (b"\r\n", b"\n"):
            break
    content_length = 0
    for h in headers.decode("utf-8", errors="ignore").splitlines():
        if h.lower().startswith("content-length:"):
            content_length = int(h.split(":", 1)[1].strip())
            break
    if content_length <= 0:
        return None
    body = p.stdout.read(content_length)
    return json.loads(body.decode("utf-8", errors="ignore"))


send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"capabilities": {}}})
_ = recv()
send({
    "jsonrpc": "2.0",
    "id": 2,
    "method": "textDocument/hover",
    "params": {"textDocument": {"uri": uri}, "position": {"line": 14, "character": 10}},
})
hover = recv()
print(json.dumps(hover, indent=2))
send({"jsonrpc": "2.0", "id": 3, "method": "shutdown", "params": None})
_ = recv()
send({"jsonrpc": "2.0", "method": "exit", "params": None})
p.wait(timeout=2)
