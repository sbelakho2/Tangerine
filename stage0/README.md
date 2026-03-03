# Tangerine stage0 (clean rebuild)

This stage0 is a clean, resilient bootstrap frontend focused on:
- robust lexing for Tangerine syntax,
- structural parsing/validation (blocks and delimiters),
- consistent diagnostics,
- stable CLI commands for tooling pipelines.

## Commands

- `main.exe help`
- `main.exe lex <file>`
- `main.exe parse <file>`
- `main.exe compile <file...>`

`compile` currently validates input files and reports structural syntax diagnostics.
