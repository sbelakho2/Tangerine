#!/usr/bin/env node
// Trace block stack for a single file — shows pushes/pops and final stack
const fs = require('fs');
const file = process.argv[2] || 'std/crypto.tg';
const text = fs.readFileSync(file, 'utf8');
const lines = text.split('\n');
const startOnly = ['struct','enum','trait','impl','for','while','until','loop','module','cap','try','extern'];
const stack = [];
let awaitingDo = false;
let inTripleQuote = false;
let errors = 0;

function nextContent(idx) {
  for (let j = idx+1; j < lines.length; j++) {
    const t = lines[j].trim();
    if (t === '' || t.startsWith('#')) continue;
    return j;
  }
  return -1;
}

for (let i = 0; i < lines.length; i++) {
  const line = lines[i];
  const trimmed = line.trim();
  const tqm = (trimmed.match(/"""/g)||[]).length;
  if (inTripleQuote) { if (tqm%2===1) inTripleQuote=false; continue; }
  if (tqm>0) { if (tqm%2===1) inTripleQuote=true; continue; }
  const sanitized = trimmed.replace(/"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'/g, '""');
  const noComment = sanitized.replace(/#.*$/, '').trim();
  if (trimmed.startsWith('#') || noComment === '') continue;
  if (/^(?:pub\s+)?extern\s+def\b/.test(noComment)) continue;

  // Branch
  const bm = noComment.match(/^(elsif|else|when|catch|finally)\b/);
  if (bm) {
    const top = stack.length > 0 ? stack[stack.length-1].keyword : 'EMPTY';
    // don't print valid branches
    continue;
  }

  // Start-of-line keywords
  for (const kw of startOnly) {
    const rx = new RegExp('^(?:pub\\s+)?' + kw + '\\b');
    if (rx.test(noComment) && !noComment.startsWith('end')) {
      if (kw==='extern' && /^(?:pub\s+)?extern\s+def\b/.test(noComment)) continue;
      const fp = new RegExp('^(?:pub\\s+)?' + kw + '\\s*:');
      if (fp.test(noComment)) continue;
      const ap = new RegExp('^(?:pub\\s+)?' + kw + '\\s*\\.');
      if (ap.test(noComment)) continue;
      stack.push({keyword:kw, line:i});
      const ob = (noComment.match(/\{/g)||[]).length;
      const cb = (noComment.match(/\}/g)||[]).length;
      if (ob>0 && ob===cb) { stack.pop(); continue; }
      if (['while','until','for','loop'].includes(kw)) {
        if (!/\bdo\b/.test(noComment)) awaitingDo = true;
      }
      console.log(`L${i+1}: PUSH ${kw} | stack=[${stack.map(s=>s.keyword)}] | ${noComment.substring(0,60)}`);
    }
  }

  // def
  const dm = noComment.match(/^(?:pub\s+)?(?:async\s+)?def\b/);
  if (dm) {
    const di = noComment.indexOf('def');
    const ad = noComment.substring(di+3);
    const hie = /\bend\s*$/.test(ad);
    if (hie) {
      stack.push({keyword:'def',line:i});
      console.log(`L${i+1}: PUSH def (inline-end) | stack=[${stack.map(s=>s.keyword)}] | ${noComment.substring(0,60)}`);
    } else {
      const defIndent = line.search(/\S/);
      let sigEnd = i;
      if (!noComment.includes(')') || noComment.trimEnd().endsWith(',')) {
        for (let j=i+1;j<lines.length;j++) {
          const t=lines[j].trim();
          if (t===''||t.startsWith('#')) continue;
          sigEnd=j;
          if (t.includes(')')) break;
        }
      }
      const ni = nextContent(sigEnd);
      let hb = true;
      if (ni>=0) { hb = lines[ni].search(/\S/) > defIndent; }
      if (hb) {
        stack.push({keyword:'def',line:i});
        console.log(`L${i+1}: PUSH def | stack=[${stack.map(s=>s.keyword)}] | ${noComment.substring(0,60)}`);
      } else {
        console.log(`L${i+1}: SKIP def (no body) | stack=[${stack.map(s=>s.keyword)}] | ${noComment.substring(0,60)}`);
      }
    }
  }

  // match/if/unless/unsafe
  { const re=/\b(match|if|unless|unsafe)\b/g; let m;
    while ((m=re.exec(noComment))!==null) {
      if (m.index>0 && noComment[m.index-1]==='.') continue;
      if (m[1]==='unsafe') {
        const after=noComment.substring(m.index+6);
        if (/\{/.test(after)) continue;
        if (/\bdo\b/.test(after)) {
          const doi=after.search(/\bdo\b/);
          const ad2=after.substring(doi+2).trim();
          if (ad2==='') { stack.push({keyword:'unsafe',line:i}); awaitingDo=true; console.log(`L${i+1}: PUSH unsafe | stack=[${stack.map(s=>s.keyword)}]`); }
          else if (/\bend\b/.test(ad2)) { stack.push({keyword:'unsafe',line:i}); console.log(`L${i+1}: PUSH unsafe (inline-end) | stack=[${stack.map(s=>s.keyword)}]`); }
        }
        continue;
      }
      stack.push({keyword:m[1],line:i});
      console.log(`L${i+1}: PUSH ${m[1]} | stack=[${stack.map(s=>s.keyword)}] | ${noComment.substring(0,60)}`);
    }
  }

  // closures
  { const cr = /(?:^|[\(,=]|->)\s*\|[^|]*\|(?:\s*async)?\s*$/;
    if (cr.test(noComment) && !/\bend\b/.test(noComment)) {
      stack.push({keyword:'closure',line:i});
      console.log(`L${i+1}: PUSH closure | stack=[${stack.map(s=>s.keyword)}] | ${noComment.substring(0,60)}`);
    }
  }

  // do
  { const re=/\bdo\b/g; let m;
    while ((m=re.exec(noComment))!==null) {
      if (m.index>0 && noComment[m.index-1]==='.') continue;
      const before=noComment.substring(0,m.index);
      if (/\b(?:while|until|for|loop|unsafe)\b/.test(before) || awaitingDo) {
        awaitingDo=false; continue;
      }
      stack.push({keyword:'do',line:i});
      console.log(`L${i+1}: PUSH do | stack=[${stack.map(s=>s.keyword)}] | ${noComment.substring(0,60)}`);
    }
  }

  // end
  { const re=/\bend\b/g; let m;
    while ((m=re.exec(noComment))!==null) {
      if (m.index>0 && noComment[m.index-1]==='.') continue;
      if (m.index+3<noComment.length && noComment[m.index+3]===':') continue;
      { const lb=noComment.substring(0,m.index).trimEnd();
        const nc=m.index+3<noComment.length?noComment[m.index+3]:'';
        if ((lb.endsWith(',')||lb.endsWith('(')) && (nc===')'||nc===',')) continue;
      }
      if (stack.length>0) {
        const popped = stack.pop();
        console.log(`L${i+1}: END -> pop ${popped.keyword}(L${popped.line+1}) | stack=[${stack.map(s=>s.keyword)}]`);
      } else {
        console.log(`L${i+1}: END -> *** EMPTY STACK ***`);
        errors++;
      }
    }
  }
}

console.log(`\nFinal stack (${stack.length} unclosed):`);
for (const s of stack) {
  console.log(`  L${s.line+1}: ${s.keyword} — ${lines[s.line].trim().substring(0,80)}`);
}
console.log(`\nTotal: ${errors} unexpected-end + ${stack.length} unclosed = ${errors + stack.length} errors`);
