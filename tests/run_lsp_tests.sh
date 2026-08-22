#!/usr/bin/env bash
#
# tests/run_lsp_tests.sh — the LSP 3.17 protocol tests: a JSON-RPC
# client drives `tg lsp` over its stdio transport and asserts every
# endpoint: initialize (the capability matrix + serverInfo),
# didOpen + the 3.17 pull-diagnostics request, hover, completion,
# definition, references, rename, formatting, the didChange refresh,
# shutdown, and exit.
#
# The position units: every request uses the UTF-16 character units of
# the LSP 3.17 position model (the client-side conversion + the astral
# positions are pinned by tests/lsp_delegation_test.tg).
#
# Usage: tests/run_lsp_tests.sh [compiler]
#   compiler defaults to ./build/tg_stage1
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
COMPILER="${1:-./build/tg_stage1}"
FAILURES=0

if [ ! -x "$COMPILER" ]; then
  echo "lsp-gate: compiler not executable: $COMPILER" >&2
  exit 1
fi

pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; FAILURES=$((FAILURES + 1)); }

echo "========================================"
echo "lsp gate: compiler = $COMPILER"
echo "========================================"

python3 - "$COMPILER" <<'PY' > "$ROOT/build/.lsp_gate_result" 2>&1
import json
import subprocess
import sys
import time

compiler = sys.argv[1]

DOC = """def add(a: Int, b: Int) -> Int
  a + b
end

def main() -> Int
  add(1, 2)
end
"""

BROKEN = """def main() -> Int
  let =
end
"""


class Client:
    def __init__(self, compiler):
        self.proc = subprocess.Popen(
            [compiler, "lsp"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        self.next_id = 1

    def _read_message(self):
        # Read the framed stream: Content-Length: N\r\n\r\n<body>
        headers = {}
        while True:
            line = self.proc.stdout.readline()
            if not line:
                raise EOFError("server closed the stream")
            line = line.decode("utf-8", "replace").rstrip("\r\n")
            if line == "":
                break
            if line.startswith("Content-Length:"):
                headers["length"] = int(line.split(":", 1)[1].strip())
        length = headers.get("length")
        if length is None:
            raise EOFError("no Content-Length header")
        body = self.proc.stdout.read(length)
        if len(body) != length:
            raise EOFError("short body: %d != %d" % (len(body), length))
        return json.loads(body.decode("utf-8"))

    def request(self, method, params):
        msg = {"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params}
        self.next_id += 1
        self._send(msg)
        return self._read_message()

    def notify(self, method, params):
        msg = {"jsonrpc": "2.0", "method": method, "params": params}
        self._send(msg)

    def _send(self, msg):
        body = json.dumps(msg).encode("utf-8")
        header = ("Content-Length: %d\r\n\r\n" % len(body)).encode("ascii")
        self.proc.stdin.write(header + body)
        self.proc.stdin.flush()

    def close(self):
        try:
            self.proc.stdin.close()
        except Exception:
            pass
        self.proc.wait(timeout=30)


c = Client(compiler)
ok = True


def check(desc, cond):
    global ok
    if cond:
        print("  ok: " + desc)
    else:
        print("  FAIL: " + desc)
        ok = False


# ── initialize: the capability matrix + serverInfo ──────────────────
resp = c.request("initialize", {
    "processId": None,
    "rootUri": None,
    "capabilities": {},
    "positionEncodings": ["utf-16"],
})
result = resp.get("result")
check("initialize returns a result", result is not None)
caps = (result or {}).get("capabilities", {})
check("capabilities: hoverProvider", caps.get("hoverProvider") is True)
check("capabilities: definitionProvider", caps.get("definitionProvider") is True)
check("capabilities: referencesProvider", caps.get("referencesProvider") is True)
check("capabilities: renameProvider", caps.get("renameProvider") is True)
check("capabilities: documentFormattingProvider", caps.get("documentFormattingProvider") is True)
check("capabilities: codeActionProvider", caps.get("codeActionProvider") is True)
check("capabilities: completionProvider", caps.get("completionProvider") is not None)
check("capabilities: signatureHelpProvider", caps.get("signatureHelpProvider") is not None)
check("capabilities: textDocumentSync", caps.get("textDocumentSync") == 1)
check("serverInfo: tangerine-ls", (result or {}).get("serverInfo", {}).get("name") == "tangerine-ls")
check("initialize carries the request id", resp.get("id") == 1)

c.notify("initialized", {})

# ── didOpen + the 3.17 pull-diagnostics ─────────────────────────────
URI = "file:///gate_doc.tg"
c.notify("textDocument/didOpen", {
    "textDocument": {"uri": URI, "languageId": "tangerine", "version": 1, "text": DOC},
})

resp = c.request("textDocument/diagnostic", {"textDocument": {"uri": URI}})
items = resp.get("result", {}).get("items", [])
check("diagnostic: the clean document carries no diagnostics", items == [])
check("diagnostic: kind is full", resp.get("result", {}).get("kind") == "full")

# ── hover ────────────────────────────────────────────────────────────
resp = c.request("textDocument/hover", {
    "textDocument": {"uri": URI},
    "position": {"line": 0, "character": 5},
})
contents = resp.get("result", {}).get("contents", {})
value = contents.get("value", "") if isinstance(contents, dict) else ""
check("hover: markdown contents name the symbol", "add" in value)

# ── completion ───────────────────────────────────────────────────────
resp = c.request("textDocument/completion", {
    "textDocument": {"uri": URI},
    "position": {"line": 5, "character": 3},
})
comp_items = resp.get("result", {}).get("items", [])
check("completion: returns items", len(comp_items) > 0)
labels = [it.get("label", "") for it in comp_items]
check("completion: offers the add symbol", "add" in labels)

# ── definition ───────────────────────────────────────────────────────
resp = c.request("textDocument/definition", {
    "textDocument": {"uri": URI},
    "position": {"line": 5, "character": 2},
})
loc = resp.get("result")
check("definition: returns a location", isinstance(loc, dict))
check("definition: same document", loc.get("uri") == URI if isinstance(loc, dict) else False)

# ── references ───────────────────────────────────────────────────────
resp = c.request("textDocument/references", {
    "textDocument": {"uri": URI},
    "position": {"line": 5, "character": 2},
    "context": {"includeDeclaration": True},
})
refs = resp.get("result", [])
check("references: returns at least one location", len(refs) >= 1)

# ── rename ───────────────────────────────────────────────────────────
resp = c.request("textDocument/rename", {
    "textDocument": {"uri": URI},
    "position": {"line": 5, "character": 2},
    "newName": "renamed_main",
})
changes = resp.get("result", {}).get("changes", {})
edits = changes.get(URI, []) if isinstance(changes, dict) else []
check("rename: returns edits for the document", len(edits) >= 1)
if edits:
    check("rename: newText carries the new name", edits[0].get("newText") == "renamed_main")

# ── formatting ───────────────────────────────────────────────────────
resp = c.request("textDocument/formatting", {
    "textDocument": {"uri": URI},
    "options": {"tabSize": 2, "insertSpaces": True},
})
fmt_edits = resp.get("result", [])
check("formatting: returns edits", len(fmt_edits) >= 1)
if fmt_edits:
    check("formatting: newText non-empty", len(fmt_edits[0].get("newText", "")) > 0)

# ── didChange (incremental document refresh) ─────────────────────────
c.notify("textDocument/didChange", {
    "textDocument": {"uri": URI, "version": 2},
    "contentChanges": [{"text": BROKEN}],
})
resp = c.request("textDocument/diagnostic", {"textDocument": {"uri": URI}})
items = resp.get("result", {}).get("items", [])
check("didChange: the broken document refreshes to diagnostics", len(items) > 0)
if items:
    check("didChange: the diagnostic is severity 1 (error)", items[0].get("severity") == 1)
    check("didChange: the diagnostic has a range", "range" in items[0])

# ── shutdown + exit ─────────────────────────────────────────────────
resp = c.request("shutdown", None)
check("shutdown: returns null", resp.get("result") is None)
c.notify("exit", None)
c.proc.wait(timeout=30)
check("exit: the server process terminates", c.proc.returncode == 0)

c.close()
sys.exit(0 if ok else 1)
PY

RESULT=$?
if [ $RESULT -eq 0 ]; then
  echo "lsp gate OK: initialize/didOpen/diagnostics/hover/completion/definition/references/rename/format/didChange/shutdown/exit all green"
else
  cat "$ROOT/build/.lsp_gate_result"
  echo "lsp gate FAILED" >&2
  FAILURES=$((FAILURES + 1))
fi

echo ""
if [ "$FAILURES" -ne 0 ]; then
  exit 1
fi
echo "lsp gate OK"
