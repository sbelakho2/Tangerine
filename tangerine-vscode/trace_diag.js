// Trace the fallback diagnostics algorithm on agentic.tg to find where the stack diverges
const fs = require('fs');
const path = require('path');

const filePath = path.resolve(__dirname, '..', 'tg_compiler', 'agentic.tg');
const text = fs.readFileSync(filePath, 'utf-8');

const startOnlyKeywords = [
    'def', 'struct', 'enum', 'trait', 'impl',
    'for', 'while', 'loop',
    'module', 'unsafe', 'cap', 'try',
];

const blockStack = [];
const lines = text.split('\n');
const diagnostics = [];

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
            diagnostics.push({ line: i + 1, msg: `Unexpected '${branch}' without matching opener (top='${top}', stack=${blockStack.length})` });
            console.log(`ERROR line ${i+1}: Unexpected '${branch}' (top='${top}', depth=${blockStack.length}) | ${noComment.substring(0, 60)}`);
        }
        continue;
    }

    const prevDepth = blockStack.length;

    for (const kw of startOnlyKeywords) {
        const regex = new RegExp(`^(?:pub\\s+)?${kw}\\b`);
        if (regex.test(noComment) && !noComment.startsWith('end')) {
            blockStack.push({ keyword: kw, line: i });
        }
    }

    {
        const re = /\b(match|if)\b/g;
        let m;
        while ((m = re.exec(noComment)) !== null) {
            if (m.index > 0 && noComment[m.index - 1] === '.') continue;
            blockStack.push({ keyword: m[1], line: i });
        }
    }

    {
        const re = /\bdo\b/g;
        let m;
        while ((m = re.exec(noComment)) !== null) {
            if (m.index > 0 && noComment[m.index - 1] === '.') continue;
            const before = noComment.substring(0, m.index);
            if (/\b(?:while|for|loop)\b/.test(before)) continue;
            blockStack.push({ keyword: 'do', line: i });
        }
    }

    {
        const re = /\bend\b/g;
        let m;
        while ((m = re.exec(noComment)) !== null) {
            if (m.index > 0 && noComment[m.index - 1] === '.') continue;
            if (blockStack.length > 0) {
                blockStack.pop();
            } else {
                diagnostics.push({ line: i + 1, msg: `Unexpected 'end' without matching block opener` });
                console.log(`ERROR line ${i+1}: Unexpected 'end' (stack empty) | ${noComment.substring(0, 60)}`);
            }
        }
    }

    if (blockStack.length !== prevDepth) {
        // Show stack changes
        const top5 = blockStack.slice(-5).map(b => `${b.keyword}@${b.line+1}`).join(', ');
        // Only print around error-prone areas
        if (i >= 980 && i <= 1025 || i >= 1140 && i <= 1195) {
            console.log(`  line ${i+1}: depth ${prevDepth} -> ${blockStack.length} top=[${top5}] | ${noComment.substring(0, 80)}`);
        }
    }
}

// Print unclosed blocks
for (const block of blockStack) {
    console.log(`UNCLOSED: '${block.keyword}' at line ${block.line + 1}`);
}

console.log(`\nTotal diagnostics: ${diagnostics.length}`);
console.log(`Final stack depth: ${blockStack.length}`);
if (diagnostics.length > 0) {
    console.log('\nFirst 20 diagnostics:');
    diagnostics.slice(0, 20).forEach(d => console.log(`  L${d.line}: ${d.msg}`));
}
