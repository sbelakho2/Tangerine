import json
import signal
import subprocess
import sys

TIMEOUT_SECS = 15


def _timeout_handler(signum, frame):
    print("ERROR: LSP handshake timed out", file=sys.stderr)
    sys.exit(2)


signal.signal(signal.SIGALRM, _timeout_handler)
signal.alarm(TIMEOUT_SECS)

p = subprocess.Popen(
    ["./build/tg", "lsp"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
)


def send(msg):
    raw = json.dumps(msg).encode("utf-8")
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
    if content_length <= 0:
        return None
    body = p.stdout.read(content_length)
    return body.decode("utf-8", errors="ignore")


send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"capabilities": {}}})
init_resp = recv()
send({"jsonrpc": "2.0", "id": 2, "method": "shutdown", "params": None})
shutdown_resp = recv()
send({"jsonrpc": "2.0", "method": "exit", "params": None})
_, stderr = p.communicate(timeout=2)

init_ok = bool(init_resp and '"capabilities"' in init_resp)
shutdown_ok = bool(shutdown_resp and '"id":2' in shutdown_resp and '"result":null' in shutdown_resp)
exit_ok = p.returncode == 0

print(f"INIT_OK={init_ok}")
print(f"SHUTDOWN_OK={shutdown_ok}")
print(f"EXIT_OK={exit_ok}")
if stderr:
    print(stderr.decode("utf-8", errors="ignore"))

if init_ok and shutdown_ok and exit_ok:
    sys.exit(0)

sys.exit(1)
