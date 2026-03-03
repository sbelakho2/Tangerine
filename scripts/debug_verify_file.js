const fs = require("fs");

const file = process.argv[2];
if (!file) {
  console.error("usage: node scripts/debug_verify_file.js <file>");
  process.exit(1);
}

const text = fs.readFileSync(file, "utf8");
const lines = text.split("\n");
const traceRange = process.argv[3] || "";
let traceStart = -1;
let traceEnd = -1;
if (/^\d+-\d+$/.test(traceRange)) {
  const [a, b] = traceRange.split("-").map((n) => Number(n));
  traceStart = a;
  traceEnd = b;
}
function inTrace(lineNumber) {
  return traceStart >= 0 && lineNumber >= traceStart && lineNumber <= traceEnd;
}
const startOnlyKeywords = ["struct","enum","trait","impl","for","while","until","loop","module","cap","try","extern"];
const blockStack = [];
let awaitingDo = false;
let inTripleQuote = false;
let fileErrors = [];

function nextContentLine(idx) {
  for (let j = idx + 1; j < lines.length; j++) {
    const t = lines[j].trim();
    if (t === "" || t.startsWith("#") || t.startsWith("///")) continue;
    return j;
  }
  return -1;
}

for (let i = 0; i < lines.length; i++) {
  const line = lines[i];
  const trimmed = line.trim();

  const tqm = (trimmed.match(/"""/g) || []).length;
  if (inTripleQuote) {
    if (tqm % 2 === 1) inTripleQuote = false;
    continue;
  } else if (tqm > 0) {
    if (tqm % 2 === 1) inTripleQuote = true;
    continue;
  }

  const sanitized = trimmed.replace(/"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'/g, '""');
  const noComment = sanitized.replace(/#.*$/, "").trim();
  if (trimmed.startsWith("#") || trimmed.startsWith("///") || noComment === "") continue;

  if (/^(?:pub\s+)?extern\b.*\bdef\b/.test(noComment)) continue;

  const branchMatch = noComment.match(/^(elsif|else|when|catch|finally)\b/);
  if (branchMatch) {
    const branch = branchMatch[1];
    const top = blockStack.length > 0 ? blockStack[blockStack.length-1].keyword : undefined;
    const isValid =
      ((branch==="elsif"||branch==="else")) ||
      (branch==="when") ||
      ((branch==="catch"||branch==="finally")&&top==="try");
    if (!isValid) {
      fileErrors.push(`L${i+1}: Unexpected ${branch} (top=${top})`);
    }
  }

  for (const kw of startOnlyKeywords) {
    const regex = new RegExp(`^(?:pub\\s+)?${kw}\\b`);
    if (regex.test(noComment) && !noComment.startsWith("end")) {
      if (kw === "extern" && /^(?:pub\s+)?extern\b.*\bdef\b/.test(noComment)) continue;
      const fieldPattern = new RegExp(`^(?:pub\\s+)?${kw}\\s*:`);
      if (fieldPattern.test(noComment)) continue;
      const assignPattern = new RegExp(`^(?:pub\\s+)?${kw}\\s*=`);
      if (assignPattern.test(noComment)) continue;
      const accessPattern = new RegExp(`^(?:pub\\s+)?${kw}\\s*\\.`);
      if (accessPattern.test(noComment)) continue;
      blockStack.push({ keyword: kw, line: i, indent: line.search(/\S/), isStartOfLine: true, closesWithBrace: false });
      if (inTrace(i + 1)) console.log(`L${i + 1} PUSH ${kw} stack=[${blockStack.map(s => s.keyword).join(",")}]`);
      const openBraces = (noComment.match(/\{/g) || []).length;
      const closeBraces = (noComment.match(/\}/g) || []).length;
      if (openBraces > 0 && openBraces === closeBraces) {
        blockStack.pop();
        if (inTrace(i + 1)) console.log(`L${i + 1} POP self-contained ${kw} stack=[${blockStack.map(s => s.keyword).join(",")}]`);
        continue;
      }
      if (["while","until","for","loop","extern"].includes(kw)) {
        if (!/\bdo\b/.test(noComment)) awaitingDo = true;
      }
    }
  }

  {
    const defMatch = noComment.match(/^(?:pub\s+)?(?:async\s+)?def\b/);
    if (defMatch) {
      const defIdx = noComment.indexOf('def');
      const afterDef = noComment.substring(defIdx + 3);
      const hasInlineEnd = /\bend\s*$/.test(afterDef);
      if (hasInlineEnd) {
        blockStack.push({ keyword: "def", line: i, indent: line.search(/\S/), isStartOfLine: true, closesWithBrace: false });
        if (inTrace(i + 1)) console.log(`L${i + 1} PUSH def-inline stack=[${blockStack.map(s => s.keyword).join(",")}]`);
      } else {
        const defIndent = line.search(/\S/);
        let sigEndIdx = i;
        if (!noComment.includes(')') || noComment.trimEnd().endsWith(',')) {
          for (let j = i + 1; j < lines.length; j++) {
            const t = lines[j].trim();
            if (t === "" || t.startsWith("#") || t.startsWith("///")) continue;
            sigEndIdx = j;
            if (t.includes(")")) break;
          }
        }
        const nextIdx = nextContentLine(sigEndIdx);
        let hasBody = true;
        if (nextIdx >= 0) {
          const nextIndent = lines[nextIdx].search(/\S/);
          hasBody = nextIndent > defIndent;
        }
        if (hasBody) {
          blockStack.push({ keyword: "def", line: i, indent: line.search(/\S/), isStartOfLine: true, closesWithBrace: false });
          if (inTrace(i + 1)) console.log(`L${i + 1} PUSH def stack=[${blockStack.map(s => s.keyword).join(",")}]`);
        }
      }
    }
  }

  {
    const re = /\b(match|if|unless|unsafe)\b/g;
    let m;
    while ((m = re.exec(noComment)) !== null) {
      if (m.index > 0 && noComment[m.index - 1] === ".") continue;
      const kw = m[1];
      if (kw === "if") {
        const beforeIf = noComment.substring(0, m.index).trimEnd();
        if (/\belse\s*$/.test(beforeIf)) continue;
      }
      if (kw === "unsafe") {
        const after = noComment.substring(m.index + 6);
        if (/\{/.test(after)) continue;
        if (/\bdo\b/.test(after)) {
          const doIdx = after.search(/\bdo\b/);
          const afterDo = after.substring(doIdx + 2).trim();
          if (afterDo === "") {
            blockStack.push({ keyword: kw, line: i, indent: line.search(/\S/), isStartOfLine: true, closesWithBrace: false });
            awaitingDo = true;
          } else if (/\bend\b/.test(afterDo)) {
            blockStack.push({ keyword: kw, line: i, indent: line.search(/\S/), isStartOfLine: true, closesWithBrace: false });
          }
        }
        continue;
      }
      const afterKw = noComment.substring(m.index + kw.length);
      const hasOpenBrace = /\{/.test(afterKw);
      const hasCloseBrace = /\}/.test(afterKw);
      if (hasOpenBrace && hasCloseBrace) continue;
      blockStack.push({ keyword: kw, line: i, indent: line.search(/\S/), isStartOfLine: m.index === 0, closesWithBrace: hasOpenBrace });
      if (inTrace(i + 1)) console.log(`L${i + 1} PUSH ${kw}-any stack=[${blockStack.map(s => s.keyword).join(",")}]`);
    }
  }

  {
    const re = /\bdo\b/g;
    let m;
    while ((m = re.exec(noComment)) !== null) {
      if (m.index > 0 && noComment[m.index - 1] === ".") continue;
      const before = noComment.substring(0, m.index);
      if (/\b(?:while|until|for|loop|unsafe|extern)\b/.test(before) || awaitingDo) {
        awaitingDo = false;
        continue;
      }
      blockStack.push({ keyword: "do", line: i, indent: line.search(/\S/), isStartOfLine: true, closesWithBrace: false });
      if (inTrace(i + 1)) console.log(`L${i + 1} PUSH do stack=[${blockStack.map(s => s.keyword).join(",")}]`);
    }
  }

  {
    const leadingCloseBraces = (noComment.match(/^\}+/) || [""])[0].length;
    for (let b = 0; b < leadingCloseBraces; b++) {
      if (blockStack.length === 0) break;
      const top = blockStack[blockStack.length - 1];
      if (top.closesWithBrace) {
        const popped = blockStack.pop();
        if (inTrace(i + 1)) console.log(`L${i + 1} POP brace ${popped.keyword} stack=[${blockStack.map(s => s.keyword).join(",")}]`);
      }
      else break;
    }
  }

  {
    const endLineIndent = line.search(/\S/);
    const re = /\bend\b/g;
    let m;
    while ((m = re.exec(noComment)) !== null) {
      if (m.index > 0 && noComment[m.index - 1] === ".") continue;
      if (m.index + 3 < noComment.length && noComment[m.index + 3] === ":") continue;
      const lookBack = noComment.substring(0, m.index).trimEnd();
      const nextCh = m.index + 3 < noComment.length ? noComment[m.index + 3] : "";
      if ((lookBack.endsWith(",") || lookBack.endsWith("(")) && (nextCh === ")" || nextCh === ",")) continue;
      if (blockStack.length > 0) {
        const top = blockStack[blockStack.length - 1];
        if (!top.isStartOfLine || top.indent >= endLineIndent) {
          const popped = blockStack.pop();
          if (inTrace(i + 1)) console.log(`L${i + 1} POP end ${popped.keyword} stack=[${blockStack.map(s => s.keyword).join(",")}]`);
        } else {
          if (inTrace(i + 1)) console.log(`L${i + 1} BREAK end top=${top.keyword} topIndent=${top.indent} endIndent=${endLineIndent}`);
          break;
        }
      } else {
        break;
      }
    }
  }
}

console.log("Errors:", fileErrors.length);
for (const e of fileErrors) console.log(e);
console.log("Unclosed:", blockStack.length);
for (const b of blockStack) {
  console.log(`L${b.line+1}: ${b.keyword} | ${lines[b.line].trim()}`);
}
