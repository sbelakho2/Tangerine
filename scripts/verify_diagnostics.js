// Verification script: simulate the VSCode extension's block-balance checker
const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");

// Get all .tg files
const dirs = ["tg_compiler", "std", "golden", "examples", "tests"];
const files = [];
for (const dir of dirs) {
  const dirPath = path.join(root, dir);
  if (!fs.existsSync(dirPath)) continue;
  const walk = (d) => {
    for (const entry of fs.readdirSync(d, { withFileTypes: true })) {
      if (entry.isDirectory()) walk(path.join(d, entry.name));
      else if (entry.name.endsWith(".tg")) files.push(path.join(d, entry.name));
    }
  };
  walk(dirPath);
}

let totalErrors = 0;
let errorFiles = 0;

for (const file of files) {
  const normalized = file.replace(/\\/g, "/");
  if (normalized.endsWith("/golden/diagnostics_quality.tg")) {
    // Skip: diagnostics_quality.tg contains intentional errors used to
    // test diagnostic output quality. It is validated separately by the
    // CQS quality gate, not by structural verification.
    continue;
  }

  const text = fs.readFileSync(file, "utf8");
  const lines = text.split("\n");
  const startOnlyKeywords = ["struct","enum","trait","impl","for","while","until","loop","module","cap","try","extern"];
  const blockStack = [];
  let awaitingDo = false;
  let inTripleQuote = false;
  let fileErrors = [];

  function nextContentLine(idx) {
    for (let j = idx + 1; j < lines.length; j++) {
      const t = lines[j].trim();
      if (t === "" || t.startsWith("#")) continue;
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

    // Self-contained: extern def declarations
    if (/^(?:pub\s+)?extern\b.*\bdef\b/.test(noComment)) continue;

    // Branch keywords
    const branchMatch = noComment.match(/^(elsif|else|when|catch|finally)\b/);
    if (branchMatch) {
      const branch = branchMatch[1];
      const top = blockStack.length > 0 ? blockStack[blockStack.length-1].keyword : undefined;
      const hasOpenConditional = blockStack.some((b) => b.keyword === "if" || b.keyword === "unless" || b.keyword === "match");
      const isValid =
        ((branch==="elsif"||branch==="else")) ||
        (branch==="when") ||
        ((branch==="catch"||branch==="finally")&&top==="try");
      if (!isValid) {
        fileErrors.push(`  L${i+1}: Unexpected \`${branch}\` (top=${top})`);
      }
      // Fall through — don't `continue`; end on same line must be counted
    }

    // Start-of-line keywords
    for (const kw of startOnlyKeywords) {
      const regex = new RegExp(`^(?:pub\\s+)?${kw}\\b`);
      if (regex.test(noComment) && !noComment.startsWith("end")) {
        if (kw === "extern" && /^(?:pub\s+)?extern\b.*\bdef\b/.test(noComment)) continue;
        const fieldPattern = new RegExp(`^(?:pub\\s+)?${kw}\\s*:`);
        if (fieldPattern.test(noComment)) continue;
        if (kw === "module" && /^(?:pub\s+)?module\s*$/.test(noComment)) continue;
        const assignPattern = new RegExp(`^(?:pub\\s+)?${kw}\\s*=`);
        if (assignPattern.test(noComment)) continue;
        // NEW: skip field/method access like module.xxx or module(xxx)
        const accessPattern = new RegExp(`^(?:pub\\s+)?${kw}\\s*\\.`);
        if (accessPattern.test(noComment)) continue;
        blockStack.push({ keyword: kw, line: i, indent: line.search(/\S/), isStartOfLine: true, closesWithBrace: false });
        // If braces are balanced on this line, block is self-contained
        const openBraces = (noComment.match(/\{/g) || []).length;
        const closeBraces = (noComment.match(/\}/g) || []).length;
        if (openBraces > 0 && openBraces === closeBraces) {
          blockStack.pop();
          continue;
        }
        if (["while","until","for","loop","extern"].includes(kw)) {
          if (!/\bdo\b/.test(noComment)) awaitingDo = true;
        }
      }
    }

    // def with body check
    {
      const defMatch = noComment.match(/^(?:pub\s+)?(?:async\s+)?def\b/);
      if (defMatch) {
        const isExpressionBodyDef = /\)\s*(?:->\s*[^=]+)?\s*=\s*.+$/.test(noComment);
        if (isExpressionBodyDef) continue;
        const defIdx = noComment.indexOf('def');
        const afterDef = noComment.substring(defIdx + 3);
        const hasInlineEnd = /\bend\s*$/.test(afterDef);
        if (hasInlineEnd) {
          blockStack.push({ keyword: "def", line: i, indent: line.search(/\S/), isStartOfLine: true, closesWithBrace: false });
        } else {
          const defIndent = line.search(/\S/);
          let sigEndIdx = i;
          if (!noComment.includes(')') || noComment.trimEnd().endsWith(',')) {
            for (let j = i + 1; j < lines.length; j++) {
              const t = lines[j].trim();
              if (t === "" || t.startsWith("#")) continue;
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
          if (hasBody) blockStack.push({ keyword: "def", line: i, indent: line.search(/\S/), isStartOfLine: true, closesWithBrace: false });
        }
      }
    }

    // match / if / unless / unsafe detected anywhere
    {
      const re = /\b(match|if|unless|unsafe)\b/g;
      let m;
      while ((m = re.exec(noComment)) !== null) {
        if (m.index > 0 && noComment[m.index - 1] === ".") continue;
        const kw = m[1];
        if (kw === "if") {
          const beforeIf = noComment.substring(0, m.index).trimEnd();
          if (/\belse\s*$/.test(beforeIf)) continue;
          const afterIf = noComment.substring(m.index + 2);
          if (afterIf.includes("=>") && !/\bthen\b/.test(afterIf)) continue;
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
        blockStack.push({
          keyword: kw,
          line: i,
          indent: line.search(/\S/),
          isStartOfLine: m.index === 0,
          closesWithBrace: hasOpenBrace
        });
      }
    }

    // Closures: intentionally not tracked in fallback verification.

    // do
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
      }
    }

    // } at start of line — close brace-delimited expression blocks only
    {
      const leadingCloseBraces = (noComment.match(/^\}+/) || [""])[0].length;
      for (let b = 0; b < leadingCloseBraces; b++) {
        if (blockStack.length === 0) break;
        const top = blockStack[blockStack.length - 1];
        if (top.closesWithBrace) blockStack.pop();
        else break;
      }
    }

    // end — indent-aware popping
    {
      const endLineIndent = line.search(/\S/);
      const re = /\bend\b/g;
      let m;
      while ((m = re.exec(noComment)) !== null) {
        if (m.index > 0 && noComment[m.index - 1] === ".") continue;
        if (m.index + 3 < noComment.length && noComment[m.index + 3] === ":") continue;
        {
          const lookBack = noComment.substring(0, m.index).trimEnd();
          const nextCh = m.index + 3 < noComment.length ? noComment[m.index + 3] : "";
          if ((lookBack.endsWith(",") || lookBack.endsWith("(")) &&
              (nextCh === ")" || nextCh === ",")) continue;
        }
        if (blockStack.length > 0) {
          const top = blockStack[blockStack.length - 1];
          if (!top.isStartOfLine || top.indent >= endLineIndent) {
            blockStack.pop();
          } else {
            break;
          }
        } else {
          break;
        }
      }
    }
  }

  // Unclosed blocks
  for (const block of blockStack) {
    fileErrors.push(`  L${block.line+1}: Unclosed \`${block.keyword}\``);
  }

  const relPath = path.relative(root, file);
  if (fileErrors.length > 0) {
    console.log(`${relPath}: ${fileErrors.length} error(s)`);
    for (const e of fileErrors) console.log(e);
    totalErrors += fileErrors.length;
    errorFiles++;
  }
}

console.log(`\n=== TOTAL: ${totalErrors} errors in ${errorFiles} files (${files.length} files scanned) ===`);
