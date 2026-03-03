// Trace script: detailed block stack trace for a specific file
const fs = require("fs");
const path = require("path");

const file = process.argv[2] || "tg_compiler/borrow_check.tg";
const root = path.resolve(__dirname, "..");
const text = fs.readFileSync(path.join(root, file), "utf8");
const lines = text.split("\n");

const startOnlyKeywords = ["struct","enum","trait","impl","for","while","until","loop","module","cap","try","extern"];
const blockStack = [];
let awaitingDo = false;
let inTripleQuote = false;

function nextContentLine(idx) {
  for (let j = idx + 1; j < lines.length; j++) {
    const t = lines[j].trim();
    if (t === "" || t.startsWith("#")) continue;
    return j;
  }
  return -1;
}

const startLine = parseInt(process.argv[3] || "300") - 1;
const endLine = parseInt(process.argv[4] || "400") - 1;

for (let i = 0; i < lines.length; i++) {
  const line = lines[i];
  const trimmed = line.trim();
  const tqm = (trimmed.match(/"""/g) || []).length;
  if (inTripleQuote) { if (tqm % 2 === 1) inTripleQuote = false; continue; }
  else if (tqm > 0) { if (tqm % 2 === 1) inTripleQuote = true; continue; }

  const sanitized = trimmed.replace(/"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'/g, '""');
  const noComment = sanitized.replace(/#.*$/, "").trim();
  if (trimmed.startsWith("#") || noComment === "") continue;

  const prevStack = blockStack.map(b => b.keyword + "@" + (b.line+1)).join(",");

  // Branch keywords
  const branchMatch = noComment.match(/^(elsif|else|when|catch|finally)\b/);
  if (branchMatch) {
    const branch = branchMatch[1];
    const top = blockStack.length > 0 ? blockStack[blockStack.length-1].keyword : undefined;
    const isValid =
      ((branch==="elsif"||branch==="else")&&(top==="if"||top==="unless"||top==="match")) ||
      (branch==="when"&&top==="match") ||
      ((branch==="catch"||branch==="finally")&&top==="try");
    if (i >= startLine && i <= endLine) {
      console.log(`L${i+1}: BRANCH ${branch} top=${top} valid=${isValid} | stack=[${prevStack}]`);
      if (!isValid) console.log(`  *** ERROR: ${branch} without matching opener`);
    }
    continue;
  }

  let actions = [];

  // Start-of-line keywords
  for (const kw of startOnlyKeywords) {
    const regex = new RegExp(`^(?:pub\\s+)?${kw}\\b`);
    if (regex.test(noComment) && !noComment.startsWith("end")) {
      if (kw === "extern" && /^(?:pub\s+)?extern\s+def\b/.test(noComment)) { actions.push(`skip extern-def`); continue; }
      const fieldPattern = new RegExp(`^(?:pub\\s+)?${kw}\\s*:`);
      if (fieldPattern.test(noComment)) { actions.push(`skip ${kw}:`); continue; }
      const accessPattern = new RegExp(`^(?:pub\\s+)?${kw}\\s*\\.`);
      if (accessPattern.test(noComment)) { actions.push(`skip ${kw}.xxx`); continue; }
      blockStack.push({ keyword: kw, line: i });
      actions.push(`push ${kw}`);
      if (["while","until","for","loop"].includes(kw)) {
        if (!/\bdo\b/.test(noComment)) { awaitingDo = true; actions.push("awaitingDo=true"); }
      }
    }
  }

  // def
  {
    const defMatch = noComment.match(/^(?:pub\s+)?(?:async\s+)?def\b/);
    if (defMatch) {
      const defIndent = line.search(/\S/);
      const nextIdx = nextContentLine(i);
      let hasBody = true;
      if (nextIdx >= 0) {
        const nextIndent = lines[nextIdx].search(/\S/);
        hasBody = nextIndent > defIndent;
      }
      if (hasBody) { blockStack.push({ keyword: "def", line: i }); actions.push("push def"); }
      else actions.push("skip def (no body)");
    }
  }

  // match / if / unless / unsafe
  {
    const re = /\b(match|if|unless|unsafe)\b/g;
    let m;
    while ((m = re.exec(noComment)) !== null) {
      if (m.index > 0 && noComment[m.index - 1] === ".") { actions.push(`skip .${m[1]}`); continue; }
      const kw = m[1];
      if (kw === "unsafe") {
        const after = noComment.substring(m.index + 6);
        if (/\bdo\b/.test(after)) { awaitingDo = true; actions.push("awaitingDo=true (unsafe)"); }
      }
      blockStack.push({ keyword: kw, line: i });
      actions.push(`push ${kw}`);
    }
  }

  // Closures
  {
    const closureRe = /(?:^|[\(,=]|->)\s*\|[^|]*\|(?:\s*async)?\s*$/;
    if (closureRe.test(noComment)) {
      if (!/\bend\b/.test(noComment)) {
        blockStack.push({ keyword: "closure", line: i });
        actions.push("push closure");
      }
    }
  }

  // do
  {
    const re = /\bdo\b/g;
    let m;
    while ((m = re.exec(noComment)) !== null) {
      if (m.index > 0 && noComment[m.index - 1] === ".") continue;
      const before = noComment.substring(0, m.index);
      if (/\b(?:while|until|for|loop|unsafe)\b/.test(before) || awaitingDo) {
        awaitingDo = false;
        actions.push("skip do (loop/await)");
        continue;
      }
      blockStack.push({ keyword: "do", line: i });
      actions.push("push do");
    }
  }

  // end
  {
    const re = /\bend\b/g;
    let m;
    while ((m = re.exec(noComment)) !== null) {
      if (m.index > 0 && noComment[m.index - 1] === ".") continue;
      if (blockStack.length > 0) {
        const popped = blockStack.pop();
        actions.push(`pop ${popped.keyword}@${popped.line+1}`);
      } else {
        actions.push("ERROR: end without opener");
      }
    }
  }

  if (i >= startLine && i <= endLine && actions.length > 0) {
    const newStack = blockStack.map(b => b.keyword + "@" + (b.line+1)).join(",");
    console.log(`L${i+1}: ${actions.join(", ")} | stack=[${newStack}]`);
    console.log(`  code: ${noComment.substring(0, 80)}`);
  }
}

console.log(`\nFinal stack (${blockStack.length}): ${blockStack.map(b=>b.keyword+"@"+(b.line+1)).join(", ")}`);
