import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TEST_FILE = ROOT / "golden" / "budget_01.tg"
URI = TEST_FILE.as_uri()
TEXT = TEST_FILE.read_text(encoding="utf-8")

p = subprocess.Popen(
    [str(ROOT / "build" / "tg"), "lsp"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
)


def send(msg):
    payload = json.dumps(msg, separators=(",", ":")).encode("utf-8")
    header = f"Content-Length: {len(payload)}\r\n\r\n".encode("ascii")
    assert p.stdin is not None
    p.stdin.write(header + payload)
    p.stdin.flush()


def recv():
    assert p.stdout is not None
    headers = b""
    while True:
        line = p.stdout.readline()
        if not line:
            return None
        headers += line
        if line in (b"\r\n", b"\n"):
            break
    content_length = 0
    for line in headers.decode("utf-8", errors="ignore").splitlines():
        if line.lower().startswith("content-length:"):
            content_length = int(line.split(":", 1)[1].strip())
            break
    if content_length <= 0:
        return None
    body = p.stdout.read(content_length)
    return json.loads(body.decode("utf-8", errors="ignore"))


def req(req_id, method, params):
    send({"jsonrpc": "2.0", "id": req_id, "method": method, "params": params})
    return recv()


def notif(method, params):
    send({"jsonrpc": "2.0", "method": method, "params": params})


results = []

try:
    r = req(1, "initialize", {"capabilities": {}})
    results.append(("initialize", bool(r and "result" in r and "capabilities" in r["result"])))

    notif("initialized", {})
    notif(
        "textDocument/didOpen",
        {
            "textDocument": {
                "uri": URI,
                "languageId": "tangerine",
                "version": 1,
                "text": TEXT,
            }
        },
    )

    hover = req(
        2,
        "textDocument/hover",
        {"textDocument": {"uri": URI}, "position": {"line": 14, "character": 10}},
    )
    results.append(("hover-response", bool(hover and hover.get("id") == 2 and "result" in hover)))

    definition = req(
        3,
        "textDocument/definition",
        {"textDocument": {"uri": URI}, "position": {"line": 15, "character": 11}},
    )
    results.append(("definition-response", bool(definition and definition.get("id") == 3 and "result" in definition)))

    completion = req(
        4,
        "textDocument/completion",
        {
            "textDocument": {"uri": URI},
            "position": {"line": 15, "character": 5},
            "context": {"triggerKind": 1},
        },
    )
    results.append(("completion-response", bool(completion and completion.get("id") == 4 and "result" in completion)))

    references = req(
        5,
        "textDocument/references",
        {
            "textDocument": {"uri": URI},
            "position": {"line": 14, "character": 10},
            "context": {"includeDeclaration": True},
        },
    )
    results.append(("references-response", bool(references and references.get("id") == 5 and "result" in references)))

    rename = req(
        6,
        "textDocument/rename",
        {
            "textDocument": {"uri": URI},
            "position": {"line": 14, "character": 10},
            "newName": "a2",
        },
    )
    results.append(("rename-response", bool(rename and rename.get("id") == 6 and "result" in rename)))

    formatting = req(
        7,
        "textDocument/formatting",
        {
            "textDocument": {"uri": URI},
            "options": {"tabSize": 2, "insertSpaces": True},
        },
    )
    results.append(("formatting-response", bool(formatting and formatting.get("id") == 7 and "result" in formatting)))

    shutdown = req(8, "shutdown", None)
    results.append(("shutdown", bool(shutdown and shutdown.get("id") == 8 and shutdown.get("result") is None)))

    notif("exit", None)
    p.wait(timeout=2)
    results.append(("exit", p.returncode == 0))
except Exception:
    results.append(("exception", False))
finally:
    if p.poll() is None:
        p.kill()

failed = [name for name, ok in results if not ok]
for name, ok in results:
    print(f"{name}={'OK' if ok else 'FAIL'}")

if failed:
    print("FAILED:", ", ".join(failed))
    sys.exit(1)

print("ALL_LSP_EDITOR_SMOKE_CHECKS_OK")
