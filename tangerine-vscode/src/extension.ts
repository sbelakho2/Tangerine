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

    // Find the tangerine executable
    const tgPath = findTangerineExecutable();
    
    if (!tgPath) {
        vscode.window.showWarningMessage(
            'Tangerine compiler not found. Please install `tg` or set `tangerine.executablePath` in settings.'
        );
        // Still provide basic features without LSP
        registerFallbackProviders(context);
        return;
    }

    // Start the language server
    startLanguageServer(context, tgPath);

    // Register additional commands
    registerCommands(context);

    console.log('Tangerine extension activated');
}

function findTangerineExecutable(): string | undefined {
    // Check user settings first
    const config = vscode.workspace.getConfiguration('tangerine');
    const configPath = config.get<string>('executablePath');
    
    if (configPath && fs.existsSync(configPath)) {
        return configPath;
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
                await client.stop();
                await client.start();
                vscode.window.showInformationMessage('Tangerine language server restarted');
            }
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
    const text = document.getText();
    const diagnostics: vscode.Diagnostic[] = [];

    // Check for unbalanced blocks
    const blockKeywords = ['def', 'struct', 'enum', 'trait', 'impl', 'if', 'match', 'for', 'while', 'loop', 'module', 'unsafe', 'do'];
    const blockStack: { keyword: string; line: number }[] = [];

    const lines = text.split('\n');
    for (let i = 0; i < lines.length; i++) {
        const line = lines[i];
        const trimmed = line.trim();
        const sanitized = trimmed.replace(/"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'/g, '""');

        // Skip comments
        if (trimmed.startsWith('#')) {
            continue;
        }

        // Handle mid-block keywords that should not open new blocks
        const branchMatch = sanitized.match(/^(elsif|else|when|catch|finally)\b/);
        if (branchMatch) {
            const branch = branchMatch[1];
            const top = blockStack.length > 0 ? blockStack[blockStack.length - 1].keyword : undefined;
            const isValidBranch =
                ((branch === 'elsif' || branch === 'else') && top === 'if') ||
                (branch === 'when' && top === 'match') ||
                ((branch === 'catch' || branch === 'finally') && top === 'try');

            if (!isValidBranch) {
                diagnostics.push(new vscode.Diagnostic(
                    new vscode.Range(i, 0, i, line.length),
                    `Unexpected \`${branch}\` without matching opener`,
                    vscode.DiagnosticSeverity.Error
                ));
            }
            continue;
        }

        // Check for block openers
        for (const kw of blockKeywords) {
            const regex = new RegExp(`^(?:pub\\s+)?${kw}\\b`);
            if (regex.test(sanitized) && !sanitized.startsWith('end')) {
                blockStack.push({ keyword: kw, line: i });
            }
        }

        // Check for `end` to close blocks
        if (/\bend\b/.test(sanitized)) {
            if (blockStack.length > 0) {
                blockStack.pop();
            } else {
                diagnostics.push(new vscode.Diagnostic(
                    new vscode.Range(i, 0, i, line.length),
                    'Unexpected `end` without matching block opener',
                    vscode.DiagnosticSeverity.Error
                ));
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

    // Check for common syntax errors
    for (let i = 0; i < lines.length; i++) {
        const line = lines[i];
        const trimmed = line.trim();
        const sanitized = trimmed.replace(/"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'/g, '""');

        // Skip comments and empty lines
        if (trimmed.startsWith('#') || trimmed === '') {
            continue;
        }

        // Check for C-style braces (should use do...end)
        if (/\{\s*$/.test(sanitized)) {
            diagnostics.push(new vscode.Diagnostic(
                new vscode.Range(i, line.indexOf('{'), i, line.indexOf('{') + 1),
                'Use `do...end` or `then...end` instead of C-style braces',
                vscode.DiagnosticSeverity.Warning
            ));
        }

        // Check for semicolons at end of line (not needed in Tangerine)
        if (/;\s*$/.test(sanitized)) {
            diagnostics.push(new vscode.Diagnostic(
                new vscode.Range(i, line.lastIndexOf(';'), i, line.lastIndexOf(';') + 1),
                'Semicolons are not required at end of statements',
                vscode.DiagnosticSeverity.Hint
            ));
        }

        // Check for `else if` instead of `elsif`
        if (/\belse\s+if\b/.test(sanitized)) {
            const idx = line.indexOf('else if');
            diagnostics.push(new vscode.Diagnostic(
                new vscode.Range(i, idx, i, idx + 7),
                'Use `elsif` instead of `else if`',
                vscode.DiagnosticSeverity.Warning
            ));
        }

        // Check for `mod` instead of `module`
        if (/\bmod\s+\w/.test(sanitized) && !sanitized.includes('module')) {
            const idx = line.search(/\bmod\b/);
            diagnostics.push(new vscode.Diagnostic(
                new vscode.Range(i, idx, i, idx + 3),
                'Use `module` instead of `mod`',
                vscode.DiagnosticSeverity.Warning
            ));
        }

        // Check for `null` instead of `nil`/`None`
        if (/\bnull\b/.test(sanitized)) {
            const idx = line.search(/\bnull\b/);
            diagnostics.push(new vscode.Diagnostic(
                new vscode.Range(i, idx, i, idx + 4),
                'Use `Option::None` instead of `null`',
                vscode.DiagnosticSeverity.Warning
            ));
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
