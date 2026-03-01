# Tangerine Language for VS Code

Full language support for the [Tangerine](https://github.com/tangerine-lang/tangerine) programming language.

![Tangerine](icon.png)

## Features

### Language Intelligence (via LSP)

- **Real-time Diagnostics** — See syntax errors, type errors, and warnings as you type
- **Hover Information** — View type information and documentation on hover
- **Auto-completion** — Get intelligent suggestions for keywords, types, and symbols
- **Go to Definition** — Jump to function/type/variable definitions with F12
- **Find References** — Find all usages of a symbol with Shift+F12
- **Rename Symbol** — Safely rename symbols across your project with F2
- **Signature Help** — See parameter hints when calling functions
- **Code Actions** — Quick fixes suggested by the compiler
- **Document Formatting** — Format your code with the built-in formatter

### Syntax Highlighting

- Full syntax highlighting for all Tangerine constructs
- Keywords, types, functions, comments, strings, numbers
- Contract annotations (`@pre`, `@post`, `@invariant`)
- Capability annotations (`@capability`, `@requires`)

### Commands

Access via Command Palette (`Cmd+Shift+P` / `Ctrl+Shift+P`):

| Command | Description | Keybinding |
|---------|-------------|------------|
| `Tangerine: Run Current File` | Run the active file | `Cmd+Shift+R` |
| `Tangerine: Check Current File` | Type-check the active file | `Cmd+Shift+C` |
| `Tangerine: Format Current File` | Format the active file | — |
| `Tangerine: Build Project` | Build the project | — |
| `Tangerine: Run Tests` | Run all tests | — |
| `Tangerine: Restart Language Server` | Restart the LSP server | — |
| `Tangerine: Show Version` | Show compiler version | — |

## Requirements

- **Tangerine compiler** (`tg`) must be installed and available in your PATH
- Alternatively, set the path in settings: `tangerine.executablePath`

### Installing the Tangerine Compiler

```bash
# From source
git clone https://github.com/tangerine-lang/tangerine
cd tangerine
make install

# Or via installer (if available)
curl -fsSL https://tangerine-lang.org/install.sh | sh
```

## Extension Settings

| Setting | Description | Default |
|---------|-------------|---------|
| `tangerine.executablePath` | Path to `tg` compiler | Auto-detect |
| `tangerine.mode` | Compilation mode | `Development` |
| `tangerine.edition` | Language edition | `2026` |
| `tangerine.checkOnSave` | Full check on save | `true` |
| `tangerine.formatOnSave` | Format on save | `false` |
| `tangerine.diagnostics.enabled` | Enable diagnostics | `true` |
| `tangerine.diagnostics.level` | Min severity level | `warning` |
| `tangerine.inlayHints.enabled` | Enable inlay hints | `true` |
| `tangerine.inlayHints.typeHints` | Show type hints | `true` |
| `tangerine.inlayHints.parameterHints` | Show param hints | `true` |

## Development

### Building the Extension

```bash
cd tangerine-vscode
npm install
npm run compile
```

### Running in Development

1. Open this folder in VS Code
2. Press `F5` to launch an Extension Development Host
3. Open a `.tg` file and verify features

### Packaging

```bash
npm run package
# Creates tangerine-language-x.x.x.vsix
```

### Installing from VSIX

```bash
code --install-extension tangerine-language-0.2.0.vsix
```

## Architecture

The extension uses the Language Server Protocol (LSP) to communicate with the Tangerine compiler:

```
┌─────────────────┐     JSON-RPC     ┌─────────────────┐
│   VS Code       │◄────stdio────────►│   tg lsp        │
│   Extension     │                   │   (LSP Server)  │
│   (LSP Client)  │                   │                 │
└─────────────────┘                   └─────────────────┘
```

The `tg lsp` command starts the language server, which provides:
- `textDocument/didOpen`, `textDocument/didChange` — Document sync
- `textDocument/publishDiagnostics` — Error/warning reporting
- `textDocument/hover` — Type and doc information
- `textDocument/completion` — Auto-completion
- `textDocument/definition` — Go to definition
- `textDocument/references` — Find all references
- `textDocument/rename` — Symbol renaming
- `textDocument/signatureHelp` — Function signature hints
- `textDocument/codeAction` — Quick fixes
- `textDocument/formatting` — Code formatting

## Troubleshooting

### "Tangerine compiler not found"

1. Ensure `tg` is installed: `which tg`
2. Set the path manually: `"tangerine.executablePath": "/path/to/tg"`

### LSP not starting

1. Check the Output panel → "Tangerine Language Server"
2. Run `Tangerine: Restart Language Server`
3. Ensure `tg lsp` works in terminal: `tg lsp --help`

### Diagnostics not appearing

1. Verify LSP is running (check Output panel)
2. Check `tangerine.diagnostics.enabled` is `true`
3. Try closing and reopening the file

## Contributing

See the main [Tangerine repository](https://github.com/tangerine-lang/tangerine) for contribution guidelines.

## License

MIT License — see [LICENSE](../LICENSE) for details.
