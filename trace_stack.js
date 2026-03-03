const fs = require('fs');
const text = fs.readFileSync('tg_compiler/agentic.tg', 'utf8');
const startOnlyKeywords = ['def','struct','enum','trait','impl','for','while','loop','module','unsafe','cap','try'];
const blockStack = [];
const lines = text.split('\n');
for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const trimmed = line.trim();
    const sanitized = trimmed.replace(/"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'/g, '""');
    const noComment = sanitized.replace(/#.*$/, '').trim();
    if (trimmed.startsWith('#') || noComment === '') continue;
    const branchMatch = noComment.match(/^(elsif|else|when|catch|finally)\b/);
    if (branchMatch) {
        const branch = branchMatch[1];
        const top = blockStack.length > 0 ? blockStack[blockStack.length - 1].keyword : undefined;
        const isValidBranch =
            ((branch === 'elsif' || branch === 'else') && (top === 'if' || top === 'match')) ||
            (branch === 'when' && top === 'match') ||
            ((branch === 'catch' || branch === 'finally') && top === 'try');
        if (!isValidBranch) {
            console.log(`ERR line ${i+1}: '${branch}' but top='${top}' stack=${blockStack.length} | ${noComment.substring(0,80)}`);
        }
        continue;
    }
    for (const kw of startOnlyKeywords) {
        const regex = new RegExp(`^(?:pub\\s+)?${kw}\\b`);
        if (regex.test(noComment) && !noComment.startsWith('end')) {
            blockStack.push({keyword:kw,line:i+1});
            if (i >= 980 && i <= 1000) console.log(`PUSH-SOL ${i+1}: '${kw}' stack=${blockStack.length} | ${noComment.substring(0,80)}`);
        }
    }
    {
        const re = /\b(match|if)\b/g;
        let m;
        while ((m = re.exec(noComment)) !== null) {
            if (m.index > 0 && noComment[m.index-1] === '.') continue;
            blockStack.push({keyword:m[1],line:i+1});
            if (i >= 980 && i <= 1000) console.log(`PUSH-MI ${i+1}: '${m[1]}' stack=${blockStack.length} | ${noComment.substring(0,80)}`);
        }
    }
    {
        const re = /\bdo\b/g;
        let m;
        while ((m = re.exec(noComment)) !== null) {
            if (m.index > 0 && noComment[m.index-1] === '.') continue;
            const before = noComment.substring(0, m.index);
            if (/\b(?:while|for|loop)\b/.test(before)) continue;
            blockStack.push({keyword:'do',line:i+1});
            if (i >= 980 && i <= 1000) console.log(`PUSH-DO ${i+1}: 'do' stack=${blockStack.length} | ${noComment.substring(0,80)}`);
        }
    }
    {
        const re = /\bend\b/g;
        let m;
        while ((m = re.exec(noComment)) !== null) {
            if (m.index > 0 && noComment[m.index-1] === '.') continue;
            if (blockStack.length > 0) {
                const popped = blockStack.pop();
                if (i >= 980 && i <= 1000) console.log(`POP ${i+1}: popped '${popped.keyword}' from line ${popped.line}, stack=${blockStack.length} | ${noComment.substring(0,80)}`);
            } else {
                console.log(`ERR line ${i+1}: 'end' but stack empty | ${noComment.substring(0,80)}`);
            }
        }
    }
}
console.log(`\nFinal stack size: ${blockStack.length}`);
for (const b of blockStack) {
    console.log(`  unclosed: line ${b.line} '${b.keyword}'`);
}
