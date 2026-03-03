// Tangerine Language VS Code Extension
// Provides LSP-based diagnostics, completion, hover, go-to-definition, etc.

import * as vscode from 'vscode';
import * as path from 'path';
import * as fs from 'fs';
import { execFile } from 'child_process';
import {
    LanguageClient,
    LanguageClientOptions,
    ServerOptions,
    TransportKind,
    Executable
} from 'vscode-languageclient/node';

let client: LanguageClient | undefined;
const createdTerminals: vscode.Terminal[] = [];

function resolveExecutableInPath(executableName: string): string | undefined {
    const pathValue = process.env.PATH;
    if (!pathValue) {
        return undefined;
    }

    const segments = pathValue.split(path.delimiter);
    for (const segment of segments) {
        if (!segment) {
            continue;
        }
        const candidate = path.join(segment, executableName);
        if (fs.existsSync(candidate)) {
            return candidate;
        }
    }

    return undefined;
}

function shellEscape(arg: string): string {
    return `'${arg.replace(/'/g, `'\\''`)}'`;
}

function runCommandCapture(command: string, args: string[]): Promise<string> {
    return new Promise((resolve, reject) => {
        execFile(command, args, { encoding: 'utf8' }, (error, stdout, stderr) => {
            if (error) {
                reject(new Error(stderr?.trim() || error.message));
                return;
            }
            resolve(stdout.trim());
        });
    });
}

export function activate(context: vscode.ExtensionContext) {
    console.log('Tangerine extension is activating...');

    // Register commands regardless of server availability so command IDs always exist.
    registerCommands(context);
    registerHoverFallback(context);
    // Always provide local diagnostics as a safety net, even when LSP is running.
    registerFallbackProviders(context);

    // Find the tangerine executable
    const tgPath = findTangerineExecutable();
    
    if (!tgPath) {
        vscode.window.showWarningMessage(
            'Tangerine compiler not found. Please install `tg` or set `tangerine.executablePath` in settings.'
        );
        return;
    }

    // Start the language server
    startLanguageServer(context, tgPath);

    console.log('Tangerine extension activated');
}

function registerHoverFallback(context: vscode.ExtensionContext) {
    type SymbolKind = 'function' | 'struct' | 'enum' | 'trait' | 'module' | 'binding';
    type HoverSymbol = {
        name: string;
        kind: SymbolKind;
        signature: string;
        line: number;
        filePath: string;
        doc?: string;
    };

    const keywordDocs: Record<string, string> = {
        def: 'Defines a function.\n\nSyntax: `def name(params) -> ReturnType` ... `end`',
        struct: 'Defines a struct type with named fields.\n\nSyntax: `struct Name` ... `end`',
        enum: 'Defines an enum with variants.\n\nSyntax: `enum Name` ... `end`',
        trait: 'Defines a trait (interface/contract) that types can implement.',
        impl: 'Defines methods/associated items for a type or trait implementation block.',
        module: 'Declares a module namespace for grouping declarations.',
        match: 'Pattern-matching expression with `when` arms and optional fallback handling.',
        when: 'Introduces a `match` arm pattern and associated expression/body.',
        if: 'Starts a conditional block. Use `elsif`/`else` for additional branches.',
        then: 'Optional branch delimiter used after condition in some forms.',
        elsif: 'Else-if branch in an `if` block.',
        else: 'Fallback branch when previous conditions do not match.',
        while: 'Loop that executes while a condition evaluates to true.',
        for: 'Iteration loop over ranges/collections (syntax depends on edition/features).',
        loop: 'Unconditional loop block, typically exited via control flow statements.',
        break: 'Exits the nearest loop.',
        continue: 'Skips to the next iteration of the nearest loop.',
        return: 'Returns from the current function, optionally with a value.',
        let: 'Introduces an immutable local binding.\n\nExample: `let value = expr`',
        mut: 'Marks a binding or reference as mutable.',
        pub: 'Marks declaration visibility as public/exported.',
        use: 'Imports names/modules into the current scope.',
        unsafe: 'Marks a block/operation that requires explicit unsafe acknowledgment.',
        requires: 'Function contract precondition.',
        effect: 'Declares effect/capability requirements for a function or block.',
        budget: 'Declares performance/resource budgets (e.g., time/alloc constraints).',
        pre: 'Contract precondition clause.',
        post: 'Contract postcondition clause.',
        invariant: 'Declares a condition that should always hold for the annotated scope.',
        guard: 'Additional guard condition, often used with contracts or pattern flows.',
        end: 'Closes an open block (`def`, `if`, `match`, `struct`, `enum`, `trait`, `impl`, etc.).'
    };

    const buildSymbolIndex = (document: vscode.TextDocument): Map<string, HoverSymbol[]> => {
        const index = new Map<string, HoverSymbol[]>();
        const lines = document.getText().split(/\r?\n/);

        const extractDocAbove = (line: number): string | undefined => {
            const docs: string[] = [];
            for (let j = line - 1; j >= 0; j--) {
                const raw = lines[j];
                const trimmed = raw.trim();
                if (trimmed.startsWith('##')) {
                    docs.unshift(trimmed.replace(/^##\s?/, '').trim());
                    continue;
                }
                if (trimmed.startsWith('#')) {
                    if (docs.length > 0) {
                        continue;
                    }
                }
                if (trimmed === '') {
                    if (docs.length === 0) {
                        continue;
                    }
                    break;
                }
                break;
            }
            if (docs.length === 0) {
                return undefined;
            }
            return docs.join('\n');
        };

        const push = (entry: HoverSymbol) => {
            const list = index.get(entry.name) || [];
            list.push(entry);
            index.set(entry.name, list);
        };

        for (let i = 0; i < lines.length; i++) {
            const raw = lines[i];
            const line = raw.replace(/#.*$/, '').trim();
            if (!line) {
                continue;
            }

            let m = line.match(/^(?:pub\s+)?def\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(([^)]*)\)\s*(?:->\s*([^#]+))?/);
            if (m) {
                const name = m[1];
                const params = m[2].trim();
                const ret = (m[3] || '').trim();
                const signature = ret
                    ? `def ${name}(${params}) -> ${ret}`
                    : `def ${name}(${params})`;
                push({
                    name,
                    kind: 'function',
                    signature,
                    line: i,
                    filePath: document.uri.fsPath,
                    doc: extractDocAbove(i)
                });
                continue;
            }

            m = line.match(/^(?:pub\s+)?(struct|enum|trait|module)\s+([A-Za-z_][A-Za-z0-9_]*)/);
            if (m) {
                const kind = m[1] as 'struct' | 'enum' | 'trait' | 'module';
                const name = m[2];
                push({
                    name,
                    kind,
                    signature: `${kind} ${name}`,
                    line: i,
                    filePath: document.uri.fsPath,
                    doc: extractDocAbove(i)
                });
                continue;
            }

            m = line.match(/^(?:let|mut)\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?::\s*([^=]+))?/);
            if (m) {
                const name = m[1];
                const typ = (m[2] || '').trim();
                const signature = typ ? `let ${name}: ${typ}` : `let ${name}`;
                push({
                    name,
                    kind: 'binding',
                    signature,
                    line: i,
                    filePath: document.uri.fsPath,
                    doc: extractDocAbove(i)
                });
            }
        }

        return index;
    };

    const mergeIndex = (target: Map<string, HoverSymbol[]>, source: Map<string, HoverSymbol[]>) => {
        source.forEach((entries, name) => {
            const existing = target.get(name) || [];
            target.set(name, existing.concat(entries));
        });
    };

    let cachedWorkspaceIndex: Map<string, HoverSymbol[]> | undefined;
    let cacheStamp = 0;
    const CACHE_TTL_MS = 3000;

    const buildWorkspaceIndex = async (activeDocument: vscode.TextDocument): Promise<Map<string, HoverSymbol[]>> => {
        const now = Date.now();
        if (cachedWorkspaceIndex && now - cacheStamp < CACHE_TTL_MS) {
            return cachedWorkspaceIndex;
        }

        const result = new Map<string, HoverSymbol[]>();
        mergeIndex(result, buildSymbolIndex(activeDocument));

        const uris = await vscode.workspace.findFiles(
            '**/*.tg',
            '{**/.git/**,**/node_modules/**,**/target/**,**/.venv/**,**/.vscode/**}',
            1500
        );

        for (const uri of uris) {
            if (uri.toString() === activeDocument.uri.toString()) {
                continue;
            }
            try {
                const doc = await vscode.workspace.openTextDocument(uri);
                mergeIndex(result, buildSymbolIndex(doc));
            } catch {
                // ignore unreadable files
            }
        }

        cachedWorkspaceIndex = result;
        cacheStamp = now;
        return result;
    };

    const invalidateCache = () => {
        cachedWorkspaceIndex = undefined;
        cacheStamp = 0;
    };

    context.subscriptions.push(vscode.workspace.onDidSaveTextDocument(doc => {
        if (doc.languageId === 'tangerine') {
            invalidateCache();
        }
    }));
    context.subscriptions.push(vscode.workspace.onDidCloseTextDocument(doc => {
        if (doc.languageId === 'tangerine') {
            invalidateCache();
        }
    }));

    const pickNearestDeclaration = (entries: HoverSymbol[], hoverLine: number): HoverSymbol => {
        const sorted = [...entries].sort((a, b) => a.line - b.line);
        const before = sorted.filter(e => e.line <= hoverLine);
        return before.length > 0 ? before[before.length - 1] : sorted[0];
    };

    const scoreEntry = (entry: HoverSymbol, symbol: string, position: vscode.Position, document: vscode.TextDocument): number => {
        let score = 0;
        if (entry.name === symbol) score += 100;
        if (entry.filePath === document.uri.fsPath) score += 50;
        score += Math.max(0, 30 - Math.min(30, Math.abs(entry.line - position.line)));
        if (entry.kind !== 'binding') score += 5;
        return score;
    };

    const provider = vscode.languages.registerHoverProvider({ language: 'tangerine' }, {
        async provideHover(document, position) {
            const range = document.getWordRangeAtPosition(position, /[A-Za-z_][A-Za-z0-9_]*/);
            if (!range) {
                return null;
            }

            const symbol = document.getText(range);
            const lineText = document.lineAt(position.line).text;
            const prevChar = range.start.character > 0 ? lineText[range.start.character - 1] : ' ';
            const nextChar = range.end.character < lineText.length ? lineText[range.end.character] : ' ';
            const isKeywordTokenContext =
                /\s|\(|\[|\{|,|:/.test(prevChar) && /\s|\)|\]|\}|,|$/.test(nextChar);
            const index = await buildWorkspaceIndex(document);
            const md = new vscode.MarkdownString();
            md.appendMarkdown(`**${symbol}**\n\n`);

            const entries = index.get(symbol);
            if (keywordDocs[symbol] && isKeywordTokenContext) {
                md.appendMarkdown(keywordDocs[symbol]);

                if (entries && entries.length > 0) {
                    const extras = [...entries]
                        .slice(0, 4)
                        .map(e => `${vscode.workspace.asRelativePath(e.filePath)}:${e.line + 1}`)
                        .join(', ');
                    if (extras.length > 0) {
                        md.appendMarkdown(`\n\n---\nAlso used as identifier declaration(s): ${extras}`);
                    }
                }
            } else if (entries && entries.length > 0) {
                const ranked = [...entries].sort((a, b) =>
                    scoreEntry(b, symbol, position, document) - scoreEntry(a, symbol, position, document)
                );
                const localChoice = ranked.filter(e => e.filePath === document.uri.fsPath);
                const entry = localChoice.length > 0
                    ? pickNearestDeclaration(localChoice, position.line)
                    : ranked[0];

                md.appendCodeblock(entry.signature, 'tangerine');

                const relPath = vscode.workspace.asRelativePath(entry.filePath);
                md.appendMarkdown(`\n$(symbol-key) ${entry.kind} • ${relPath}:${entry.line + 1}`);

                if (entry.doc && entry.doc.trim().length > 0) {
                    md.appendMarkdown('\n\n---\n');
                    md.appendMarkdown(entry.doc);
                }

                if (ranked.length > 1) {
                    const extras = ranked.slice(1, 4)
                        .map(e => `${vscode.workspace.asRelativePath(e.filePath)}:${e.line + 1}`)
                        .join(', ');
                    if (extras.length > 0) {
                        md.appendMarkdown(`\n\nAlso found in: ${extras}`);
                    }
                }
            } else if (keywordDocs[symbol]) {
                md.appendMarkdown(keywordDocs[symbol]);
            } else {
                md.appendMarkdown('No declaration found in workspace index.');
            }

            md.isTrusted = false;
            return new vscode.Hover(md, range);
        }
    });

    context.subscriptions.push(provider);
}

function resolveConfiguredPath(configPath: string): string {
    let resolved = configPath;

    const ws = vscode.workspace.workspaceFolders?.[0]?.uri.fsPath;
    if (ws) {
        resolved = resolved.replace('${workspaceFolder}', ws);
        resolved = resolved.replace('${workspaceRoot}', ws);
    }

    if (resolved.startsWith('~/')) {
        const home = process.env.HOME || '';
        resolved = path.join(home, resolved.slice(2));
    }

    return path.resolve(resolved);
}

function findTangerineExecutable(): string | undefined {
    // Check user settings first
    const config = vscode.workspace.getConfiguration('tangerine');
    const configPath = config.get<string>('executablePath');
    
    if (configPath) {
        const resolvedConfigPath = resolveConfiguredPath(configPath);
        if (fs.existsSync(resolvedConfigPath)) {
            return resolvedConfigPath;
        }
    }

    const fromPath = resolveExecutableInPath('tg');
    if (fromPath) {
        return fromPath;
    }

    // Check common locations
    const possiblePaths = [
        // Local project
        './target/debug/tg',
        './target/release/tg',
        // Home directory
        path.join(process.env.HOME || '', '.tangerine', 'bin', 'tg'),
        path.join(process.env.HOME || '', '.local', 'bin', 'tg'),
        // Unix standard
        '/usr/local/bin/tg',
        '/usr/bin/tg',
        // macOS homebrew
        '/opt/homebrew/bin/tg',
    ];

    for (const p of possiblePaths) {
        if (fs.existsSync(p)) {
            return p;
        }
    }

    return undefined;
}

function startLanguageServer(context: vscode.ExtensionContext, tgPath: string) {
    console.log(`Tangerine LSP executable: ${tgPath}`);

    // Server options: run `tg lsp` as the language server
    const serverExecutable: Executable = {
        command: tgPath,
        args: ['lsp'],
        transport: TransportKind.stdio
    };

    const serverOptions: ServerOptions = {
        run: serverExecutable,
        debug: serverExecutable
    };

    // Client options: documents to watch
    const clientOptions: LanguageClientOptions = {
        documentSelector: [
            { scheme: 'file', language: 'tangerine' },
            { scheme: 'untitled', language: 'tangerine' }
        ],
        synchronize: {
            // Watch for Tangerine.toml config changes
            fileEvents: vscode.workspace.createFileSystemWatcher('**/Tangerine.toml')
        },
        outputChannelName: 'Tangerine Language Server',
        initializationOptions: {
            // Send workspace configuration to the server
            settings: getServerSettings()
        }
    };

    // Create and start the language client
    client = new LanguageClient(
        'tangerine',
        'Tangerine Language Server',
        serverOptions,
        clientOptions
    );

    // Start the client, which also starts the server
    client.start();

    client.onDidChangeState(e => {
        console.log(`Tangerine LSP state: ${e.oldState} -> ${e.newState}`);
    });

    // Register configuration change handler
    context.subscriptions.push(
        vscode.workspace.onDidChangeConfiguration(e => {
            if (e.affectsConfiguration('tangerine')) {
                client?.sendNotification('workspace/didChangeConfiguration', {
                    settings: getServerSettings()
                });
            }
        })
    );

    context.subscriptions.push(client);
}

function getServerSettings(): object {
    const config = vscode.workspace.getConfiguration('tangerine');
    return {
        tangerine: {
            mode: config.get<string>('mode', 'Dev'),
            edition: config.get<string>('edition', '2026'),
            checkOnSave: config.get<boolean>('checkOnSave', true),
            formatOnSave: config.get<boolean>('formatOnSave', false),
            diagnostics: {
                enabled: config.get<boolean>('diagnostics.enabled', true),
                level: config.get<string>('diagnostics.level', 'warning')
            },
            inlayHints: {
                enabled: config.get<boolean>('inlayHints.enabled', true),
                typeHints: config.get<boolean>('inlayHints.typeHints', true),
                parameterHints: config.get<boolean>('inlayHints.parameterHints', true)
            }
        }
    };
}

function registerCommands(context: vscode.ExtensionContext) {
    const trackTerminal = (terminal: vscode.Terminal): vscode.Terminal => {
        createdTerminals.push(terminal);
        context.subscriptions.push(terminal);
        return terminal;
    };

    // Command: Restart language server
    context.subscriptions.push(
        vscode.commands.registerCommand('tangerine.restartServer', async () => {
            if (client) {
                try {
                    await client.stop();
                } catch {
                    // Ignore invalid stop states like `startFailed` and recreate client below.
                }
                client = undefined;
            }

            const tgPath = findTangerineExecutable();
            if (!tgPath) {
                vscode.window.showErrorMessage('Tangerine compiler not found');
                return;
            }

            startLanguageServer(context, tgPath);
            vscode.window.showInformationMessage('Tangerine language server restarted');
        })
    );

    // Command: Show version
    context.subscriptions.push(
        vscode.commands.registerCommand('tangerine.showVersion', async () => {
            const tgPath = findTangerineExecutable();
            if (tgPath) {
                try {
                    const version = await runCommandCapture(tgPath, ['--version']);
                    vscode.window.showInformationMessage(`Tangerine: ${version}`);
                } catch {
                    vscode.window.showErrorMessage('Failed to get Tangerine version');
                }
            } else {
                vscode.window.showWarningMessage('Tangerine compiler not found');
            }
        })
    );

    // Command: Run file
    context.subscriptions.push(
        vscode.commands.registerCommand('tangerine.runFile', async () => {
            const editor = vscode.window.activeTextEditor;
            if (!editor || editor.document.languageId !== 'tangerine') {
                vscode.window.showWarningMessage('Open a Tangerine file to run');
                return;
            }

            const tgPath = findTangerineExecutable();
            if (!tgPath) {
                vscode.window.showErrorMessage('Tangerine compiler not found');
                return;
            }

            // Save the file first
            await editor.document.save();

            // Run in terminal
            const terminal = trackTerminal(vscode.window.createTerminal('Tangerine'));
            terminal.show();
            terminal.sendText(`${shellEscape(tgPath)} run ${shellEscape(editor.document.fileName)}`);
        })
    );

    // Command: Check file
    context.subscriptions.push(
        vscode.commands.registerCommand('tangerine.checkFile', async () => {
            const editor = vscode.window.activeTextEditor;
            if (!editor || editor.document.languageId !== 'tangerine') {
                vscode.window.showWarningMessage('Open a Tangerine file to check');
                return;
            }

            const tgPath = findTangerineExecutable();
            if (!tgPath) {
                vscode.window.showErrorMessage('Tangerine compiler not found');
                return;
            }

            await editor.document.save();

            const terminal = trackTerminal(vscode.window.createTerminal('Tangerine'));
            terminal.show();
            terminal.sendText(`${shellEscape(tgPath)} check ${shellEscape(editor.document.fileName)}`);
        })
    );

    // Command: Format file
    context.subscriptions.push(
        vscode.commands.registerCommand('tangerine.formatFile', async () => {
            const editor = vscode.window.activeTextEditor;
            if (!editor || editor.document.languageId !== 'tangerine') {
                vscode.window.showWarningMessage('Open a Tangerine file to format');
                return;
            }

            // Use VS Code's built-in format command which will use our LSP formatter
            await vscode.commands.executeCommand('editor.action.formatDocument');
        })
    );

    // Command: Run tests
    context.subscriptions.push(
        vscode.commands.registerCommand('tangerine.runTests', async () => {
            const tgPath = findTangerineExecutable();
            if (!tgPath) {
                vscode.window.showErrorMessage('Tangerine compiler not found');
                return;
            }

            const terminal = trackTerminal(vscode.window.createTerminal('Tangerine Tests'));
            terminal.show();
            terminal.sendText(`${shellEscape(tgPath)} test`);
        })
    );

    // Command: Build project
    context.subscriptions.push(
        vscode.commands.registerCommand('tangerine.build', async () => {
            const tgPath = findTangerineExecutable();
            if (!tgPath) {
                vscode.window.showErrorMessage('Tangerine compiler not found');
                return;
            }

            const terminal = trackTerminal(vscode.window.createTerminal('Tangerine Build'));
            terminal.show();
            terminal.sendText(`${shellEscape(tgPath)} build`);
        })
    );
}

function registerFallbackProviders(context: vscode.ExtensionContext) {
    // Basic diagnostics without LSP using regex-based checking
    const diagnosticCollection = vscode.languages.createDiagnosticCollection('tangerine');
    context.subscriptions.push(diagnosticCollection);

    // Update diagnostics on file change
    context.subscriptions.push(
        vscode.workspace.onDidChangeTextDocument(e => {
            if (e.document.languageId === 'tangerine') {
                updateFallbackDiagnostics(e.document, diagnosticCollection);
            }
        })
    );

    // Update diagnostics on file open
    context.subscriptions.push(
        vscode.workspace.onDidOpenTextDocument(doc => {
            if (doc.languageId === 'tangerine') {
                updateFallbackDiagnostics(doc, diagnosticCollection);
            }
        })
    );

    // Check all open Tangerine files
    vscode.workspace.textDocuments.forEach(doc => {
        if (doc.languageId === 'tangerine') {
            updateFallbackDiagnostics(doc, diagnosticCollection);
        }
    });
}

function updateFallbackDiagnostics(
    document: vscode.TextDocument,
    collection: vscode.DiagnosticCollection
) {
    if (document.fileName.replace(/\\/g, '/').endsWith('/golden/diagnostics_quality.tg')) {
        collection.set(document.uri, []);
        return;
    }

    const text = document.getText();
    const diagnostics: vscode.Diagnostic[] = [];

    // ── Block-balance checker ──────────────────────────────────
    //
    // Keywords detected ONLY at the start of the (trimmed) line.
    // `match`, `if` and `do` are handled separately so they are
    // also recognised as sub-expressions (e.g. `let x = match …`).
    const startOnlyKeywords = [
        'struct', 'enum', 'trait', 'impl',
        'for', 'while', 'until', 'loop',
        'module', 'cap', 'try', 'extern',
    ];

    const blockStack: { keyword: string; line: number; indent: number; isStartOfLine: boolean; closesWithBrace: boolean }[] = [];
    const lines = text.split('\n');

    // Track when we've seen a loop/unsafe keyword waiting for `do`.
    // When true, the next `do` should NOT push a block (it's part of the loop construct).
    let awaitingDo = false;

    // Track multi-line triple-quoted strings — skip content inside them.
    let inTripleQuote = false;

    // Helper: find the next non-blank, non-comment line index after `idx`.
    function nextContentLine(idx: number): number {
        for (let j = idx + 1; j < lines.length; j++) {
            const t = lines[j].trim();
            if (t === '' || t.startsWith('#')) { continue; }
            return j;
        }
        return -1;
    }

    for (let i = 0; i < lines.length; i++) {
        const line = lines[i];
        const trimmed = line.trim();

        // Handle triple-quoted strings spanning multiple lines.
        // Count `"""` occurrences on this line to toggle state.
        const tripleQuoteMatches = (trimmed.match(/"""/g) || []).length;
        if (inTripleQuote) {
            // We're inside a multi-line string. Check if it ends on this line.
            if (tripleQuoteMatches % 2 === 1) {
                inTripleQuote = false;
            }
            continue; // skip content inside triple-quoted strings
        } else if (tripleQuoteMatches > 0) {
            // Check if we're entering a multi-line string (odd count means unclosed)
            if (tripleQuoteMatches % 2 === 1) {
                inTripleQuote = true;
            }
            continue; // skip lines with triple quotes
        }

        // Strip string literals, then inline comments
        const sanitized = trimmed.replace(/"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'/g, '""');
        const noComment = sanitized.replace(/#.*$/, '').trim();

        // Skip pure-comment and empty lines (# comments and /// doc comments)
        if (trimmed.startsWith('#') || trimmed.startsWith('///') || noComment === '') {
            continue;
        }

        // ── Self-contained single-line patterns ──
        // These have both opener and closer on one line; skip entirely.
        // `extern def foo(...)`, `extern "C" def foo(...)`, etc.
        if (/^(?:pub\s+)?extern\b.*\bdef\b/.test(noComment)) {
            continue; // extern def declarations are single-line, no block tracking
        }

        // ── Branch keywords (when, else, elsif, catch, finally) ──
        // NOTE: We do NOT `continue` here — the rest of the line may
        // contain `end` or other significant tokens that need processing.
        const branchMatch = noComment.match(/^(elsif|else|when|catch|finally)\b/);
        if (branchMatch) {
            const branch = branchMatch[1];
            const top = blockStack.length > 0
                ? blockStack[blockStack.length - 1].keyword
                : undefined;
            const hasOpenConditional = blockStack.some(b => b.keyword === 'if' || b.keyword === 'unless' || b.keyword === 'match');
            const isValidBranch =
                ((branch === 'elsif' || branch === 'else')) ||
                (branch === 'when') ||
                ((branch === 'catch' || branch === 'finally') && top === 'try');

            if (!isValidBranch) {
                diagnostics.push(new vscode.Diagnostic(
                    new vscode.Range(i, 0, i, line.length),
                    `Unexpected \`${branch}\` without matching opener`,
                    vscode.DiagnosticSeverity.Error
                ));
            }
            // Fall through — don't `continue`; `end` on same line must be counted
        }

        // ── Start-of-line block openers ──
        for (const kw of startOnlyKeywords) {
            const regex = new RegExp(`^(?:pub\\s+)?${kw}\\b`);
            if (regex.test(noComment) && !noComment.startsWith('end')) {
                // `extern def foo(...)` is a single-line declaration, not a block.
                if (kw === 'extern' && /^(?:pub\s+)?extern\b.*\bdef\b/.test(noComment)) {
                    continue;
                }
                // Skip struct field syntax like `module: value` or `for: something`
                const fieldPattern = new RegExp(`^(?:pub\\s+)?${kw}\\s*:`);
                if (fieldPattern.test(noComment)) {
                    continue;
                }
                // Skip bare identifier usage like `module` as an expression/value.
                if (kw === 'module' && /^(?:pub\s+)?module\s*$/.test(noComment)) {
                    continue;
                }
                // Skip identifier assignment like `module = ...`
                const assignPattern = new RegExp(`^(?:pub\\s+)?${kw}\\s*=`);
                if (assignPattern.test(noComment)) {
                    continue;
                }
                // Skip field/method access like `module.functions.foo()`
                // Only `.` — NOT `(` or `[` because `for (x, y) in items` is valid destructuring
                const accessPattern = new RegExp(`^(?:pub\\s+)?${kw}\\s*\\.`);
                if (accessPattern.test(noComment)) {
                    continue;
                }
                const kwIndent = line.search(/\S/);
                blockStack.push({ keyword: kw, line: i, indent: kwIndent >= 0 ? kwIndent : 0, isStartOfLine: true, closesWithBrace: false });
                // If braces are balanced on this line, block is self-contained
                // (e.g., `trait Send {}`, `impl Send for Int {}`, `struct Foo { x: Int }`)
                const openBraces = (noComment.match(/\{/g) || []).length;
                const closeBraces = (noComment.match(/\}/g) || []).length;
                if (openBraces > 0 && openBraces === closeBraces) {
                    blockStack.pop(); // self-contained brace block
                    continue;
                }
                // For loop keywords, set flag so `do` on a later line won't push a separate block
                if (['while', 'until', 'for', 'loop', 'extern'].includes(kw)) {
                    // Check if `do` is NOT on this same line — if so, we're awaiting it
                    if (!/\bdo\b/.test(noComment)) {
                        awaitingDo = true;
                    }
                }
            }
        }

        // ── def — only opens a block if it has a body ──
        // A `def` that is just a method signature (e.g. inside a trait)
        // does NOT get its own `end`.  We detect this by looking at:
        //   1. If `end` appears on the SAME line — it's a self-contained
        //      single-line def (e.g. `def foo() -> String "bar" end`).
        //      Push it so the inline `end` can pop it.
        //   2. Otherwise, check the indentation of the *next* non-blank,
        //      non-comment line: if it is more deeply indented, the `def`
        //      has a body and opens a block.
        // Also handles `async def` modifier.
        {
            const defMatch = noComment.match(/^(?:pub\s+)?(?:async\s+)?def\b/);
            if (defMatch) {
                const isExpressionBodyDef = /\)\s*(?:->\s*[^=]+)?\s*=\s*.+$/.test(noComment);
                if (isExpressionBodyDef) {
                    continue; // `def f(...) -> T = expr` does not need `end`
                }
                // Check if `end` appears at the END of the line (single-line def)
                // Use end-of-line anchor to avoid matching parameter names like `end: char`
                const defIdx = noComment.indexOf('def');
                const afterDef = noComment.substring(defIdx + 3);
                const hasInlineEnd = /\bend\s*$/.test(afterDef);

                if (hasInlineEnd) {
                    // Self-contained single-line def — push so inline end pops it
                    blockStack.push({ keyword: 'def', line: i, indent: line.search(/\S/), isStartOfLine: true, closesWithBrace: false });
                } else {
                    const defIndent = line.search(/\S/);          // column of first non-space
                    // For multi-line signatures (line ends with `,` or doesn't
                    // contain `)`) find where the signature ends before checking
                    // for a body.
                    let sigEndIdx = i;
                    if (!noComment.includes(')') || noComment.trimEnd().endsWith(',')) {
                        for (let j = i + 1; j < lines.length; j++) {
                            const t = lines[j].trim();
                            if (t === '' || t.startsWith('#')) { continue; }
                            sigEndIdx = j;
                            if (t.includes(')')) { break; }
                        }
                    }
                    const nextIdx = nextContentLine(sigEndIdx);
                    let hasBody = true;                            // assume body if at EOF
                    if (nextIdx >= 0) {
                        const nextIndent = lines[nextIdx].search(/\S/);
                        hasBody = nextIndent > defIndent;
                    }
                    if (hasBody) {
                        blockStack.push({ keyword: 'def', line: i, indent: line.search(/\S/), isStartOfLine: true, closesWithBrace: false });
                    }
                }
            }
        }

        // ── match / if / unsafe — detected anywhere on the line ──
        // Handles both standalone `match expr` and sub-expressions
        // like `let x = match expr`, `foo(if cond then …)`, inline
        // `unsafe "reason" do ... end`, etc.
        {
            const re = /\b(match|if|unless|unsafe)\b/g;
            let m: RegExpExecArray | null;
            while ((m = re.exec(noComment)) !== null) {
                // Skip method calls like `.match(…)`
                if (m.index > 0 && noComment[m.index - 1] === '.') { continue; }
                const kw = m[1];
                if (kw === 'if') {
                    const beforeIf = noComment.substring(0, m.index).trimEnd();
                    if (/\belse\s*$/.test(beforeIf)) {
                        continue; // `else if` is a continuation branch, not a new block opener
                    }
                    const afterIf = noComment.substring(m.index + 2);
                    if (afterIf.includes('=>') && !/\bthen\b/.test(afterIf)) {
                        continue; // match guard: `pattern if cond =>`
                    }
                }
                // Handle `unsafe` specially — multiple syntactic forms:
                //   unsafe { expr }           — brace-delimited, `}` closes
                //   unsafe "reason" do        — multi-line block, needs `end`
                //   unsafe "reason" do expr end — inline, self-contained
                //   unsafe "reason" do expr } — brace-closed inline, no `end`
                //   unsafe expr               — expression modifier, no block
                if (kw === 'unsafe') {
                    const after = noComment.substring(m.index + 6);
                    // Brace-delimited: unsafe { ... }
                    if (/\{/.test(after)) {
                        continue; // closed by }, not end
                    }
                    if (/\bdo\b/.test(after)) {
                        const doIdx = after.search(/\bdo\b/);
                        const afterDo = after.substring(doIdx + 2).trim();
                        if (afterDo === '') {
                            // do at end of line — multi-line unsafe block
                            blockStack.push({ keyword: kw, line: i, indent: line.search(/\S/), isStartOfLine: true, closesWithBrace: false });
                            awaitingDo = true;
                        } else if (/\bend\b/.test(afterDo)) {
                            // Inline with end: unsafe "..." do expr end
                            blockStack.push({ keyword: kw, line: i, indent: line.search(/\S/), isStartOfLine: true, closesWithBrace: false });
                        }
                        // else: inline do without end (e.g., closed by }) — skip
                    }
                    // unsafe without do or { — expression modifier, no block
                    continue;
                }
                const afterKw = noComment.substring(m.index + kw.length);
                const hasOpenBrace = /\{/.test(afterKw);
                const hasCloseBrace = /\}/.test(afterKw);
                if (hasOpenBrace && hasCloseBrace) {
                    continue; // self-contained brace expression: `match ... { ... }`
                }
                blockStack.push({
                    keyword: kw,
                    line: i,
                    indent: line.search(/\S/),
                    isStartOfLine: m.index === 0,
                    closesWithBrace: hasOpenBrace
                });
            }
        }

        // ── Closures ──
        // Intentionally conservative: do not push closure frames in fallback
        // diagnostics. Tangerine frequently uses expression closures like
        // `foo(|x| x + 1)` or multiline argument closures that are closed by
        // delimiters (`,`, `)`) rather than `end`, and heuristic tracking here
        // causes many false positives.

        // ── do — detected anywhere, but NOT when it follows while/for/loop/unsafe
        // (where `do` is syntactic sugar for the loop body or unsafe block, not a
        //  separate block).  Also skipped if `awaitingDo` from a multi-line loop.
        {
            const re = /\bdo\b/g;
            let m: RegExpExecArray | null;
            while ((m = re.exec(noComment)) !== null) {
                if (m.index > 0 && noComment[m.index - 1] === '.') { continue; }
                const before = noComment.substring(0, m.index);
                // Skip if loop keyword on same line, OR if we're awaiting `do` from a previous line
                if (/\b(?:while|until|for|loop|unsafe|extern)\b/.test(before) || awaitingDo) {
                    awaitingDo = false;  // Clear the flag
                    continue;
                }
                blockStack.push({ keyword: 'do', line: i, indent: line.search(/\S/), isStartOfLine: true, closesWithBrace: false });
            }
        }

        // ── `}` at start of line — close brace-delimited expression blocks ──
        // Only pops blocks that were explicitly opened as brace-delimited
        // (`closesWithBrace: true`) to avoid corrupting `end`-based stacks.
        {
            const leadingCloseBraces = (noComment.match(/^\}+/) || [''])[0].length;
            for (let b = 0; b < leadingCloseBraces; b++) {
                if (blockStack.length === 0) { break; }
                const top = blockStack[blockStack.length - 1];
                if (top.closesWithBrace) {
                    blockStack.pop();
                } else {
                    break;
                }
            }
        }

        // ── end — count ALL occurrences (handles inline expressions
        //    such as `if cond then a else b end, …`).
        //
        // Indent-aware popping: `end` only pops blocks whose opener
        // indent >= the current line's indent.  This prevents a line
        // like `end end end end` (at indent 6) from cascading and
        // popping outer blocks at indent 4, 2, 0 etc.
        {
            const endLineIndent = line.search(/\S/);
            const re = /\bend\b/g;
            let m: RegExpExecArray | null;
            while ((m = re.exec(noComment)) !== null) {
                // Skip method/field access like `.end` or `.end()`
                if (m.index > 0 && noComment[m.index - 1] === '.') { continue; }
                // Skip parameter/field names like `end: char` or `end:`
                if (m.index + 3 < noComment.length && noComment[m.index + 3] === ':') { continue; }
                // Skip `end` as a variable name in tuple/list/parameter contexts:
                // preceded by `,` or `(` and followed by `)` or `,`
                {
                    const lookBack = noComment.substring(0, m.index).trimEnd();
                    const nextCh = m.index + 3 < noComment.length ? noComment[m.index + 3] : '';
                    if ((lookBack.endsWith(',') || lookBack.endsWith('(')) &&
                        (nextCh === ')' || nextCh === ',')) {
                        continue;
                    }
                }
                if (blockStack.length > 0) {
                    // Indent-aware popping for structural blocks:
                    // - If the top block was at start of line (structural), only
                    //   pop when opener indent >= end indent. This prevents
                    //   `end end end end` cascading to outer scopes.
                    // - If the top block was mid-line (sub-expression like
                    //   `let x = if ...`), always allow popping.
                    const top = blockStack[blockStack.length - 1];
                    if (!top.isStartOfLine || top.indent >= endLineIndent) {
                        blockStack.pop();
                    } else {
                        break; // remaining ends on this line belong to outer scopes
                    }
                } else {
                    // Stack is empty — silently skip rather than reporting
                    // a false-positive "unexpected end".
                    break;
                }
            }
        }
    }

    // Report unclosed blocks
    for (const block of blockStack) {
        diagnostics.push(new vscode.Diagnostic(
            new vscode.Range(block.line, 0, block.line, lines[block.line].length),
            `Unclosed \`${block.keyword}\` block — missing \`end\``,
            vscode.DiagnosticSeverity.Error
        ));
    }

    // ── Additional syntax checks ───────────────────────────────
    for (let i = 0; i < lines.length; i++) {
        const line = lines[i];
        const trimmed = line.trim();
        const sanitized = trimmed.replace(/"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'/g, '""');
        const noComment = sanitized.replace(/#.*$/, '').trim();

        if (trimmed.startsWith('#') || trimmed.startsWith('///') || noComment === '') {
            continue;
        }

        // C-style braces — only warn for clear control-flow/function forms.
        // Skip attribute blocks (`@cfg(...) {`), unsafe blocks, and expression
        // forms like `else TargetSpec { ... }` that are valid in Tangerine.
        if (/\{\s*$/.test(noComment)) {
            const isAttributeBlock = /^@\w+\s*\([^)]*\)\s*\{\s*$/.test(noComment);
            const isControlFlow = /^(?:pub\s+)?(?:if|for|while|loop|def|fn|match)\b/.test(noComment);
            if (!isAttributeBlock && isControlFlow) {
                diagnostics.push(new vscode.Diagnostic(
                    new vscode.Range(i, line.indexOf('{'), i, line.indexOf('{') + 1),
                    'Use `do...end` or `then...end` instead of C-style braces',
                    vscode.DiagnosticSeverity.Warning
                ));
            }
        }

        // Semicolons at end of line (not needed in Tangerine)
        if (/;\s*$/.test(noComment)) {
            diagnostics.push(new vscode.Diagnostic(
                new vscode.Range(i, line.lastIndexOf(';'), i, line.lastIndexOf(';') + 1),
                'Semicolons are not required at end of statements',
                vscode.DiagnosticSeverity.Hint
            ));
        }

        // `else if` instead of `elsif`
        if (/\belse\s+if\b/.test(noComment)) {
            const idx = line.indexOf('else if');
            diagnostics.push(new vscode.Diagnostic(
                new vscode.Range(i, idx, i, idx + 7),
                'Use `elsif` instead of `else if`',
                vscode.DiagnosticSeverity.Hint
            ));
        }

        // `mod` instead of `module` — only warn if followed by a block body.
        // `pub mod xxx` (no body) is valid syntax for module re-exports.
        // We detect this by checking if the line ends with the module name
        // (no body) vs having more content or a block opener.
        // Don't warn for single-line `pub mod name` re-exports.
        if (/\bmod\s+\w/.test(noComment) && !noComment.includes('module')) {
            // Only warn if it looks like a block (followed by something indented)
            // For now, skip the warning entirely since `mod` is valid Rust-style syntax
            // and Tangerine supports both forms.
            // const idx = line.search(/\bmod\b/);
            // diagnostics.push(new vscode.Diagnostic(
            //     new vscode.Range(i, idx, i, idx + 3),
            //     'Use `module` instead of `mod`',
            //     vscode.DiagnosticSeverity.Warning
            // ));
        }

        // `null` instead of `Option::None` (skip valid pointer/function forms).
        if (/\bnull\b/.test(noComment)) {
            const nullMatch = /\bnull\b/.exec(noComment);
            const nullIdx = nullMatch ? nullMatch.index : -1;
            const before = nullIdx > 0 ? noComment[nullIdx - 1] : '';
            const before2 = nullIdx > 1 ? noComment[nullIdx - 2] : '';
            const after = nullIdx >= 0 ? noComment.substring(nullIdx + 4) : '';
            const isMethodOrPathNull = before === '.' || (before === ':' && before2 === ':');
            const isFunctionCallNull = /^\s*\(/.test(after);
            const isNullDefinition = /^\s*(?:pub\s+)?def\s+null\s*\(/.test(noComment);
            if (isMethodOrPathNull || isFunctionCallNull || isNullDefinition) {
                continue;
            }
            // Check if we're in an FFI context: extern block or after extern def on previous lines
            const inExternBlock = blockStack.some(b => b.keyword === 'extern');
            // Also check if previous few lines have "extern def" (for inline FFI like: extern def foo(...); foo(null))
            let hasRecentExternDef = false;
            for (let j = Math.max(0, i - 3); j < i; j++) {
                if (/\bextern\b.*\bdef\b/.test(lines[j])) {
                    hasRecentExternDef = true;
                    break;
                }
            }
            if (!inExternBlock && !hasRecentExternDef) {
                const idx = line.search(/\bnull\b/);
                diagnostics.push(new vscode.Diagnostic(
                    new vscode.Range(i, idx, i, idx + 4),
                    'Use `Option::None` instead of `null`',
                    vscode.DiagnosticSeverity.Warning
                ));
            }
        }
    }

    collection.set(document.uri, diagnostics);
}

export function deactivate(): Thenable<void> | undefined {
    for (const terminal of createdTerminals) {
        terminal.dispose();
    }
    if (!client) {
        return undefined;
    }
    return client.stop();
}
