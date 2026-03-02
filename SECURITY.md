# Security Policy

## Supported Versions

Tangerine is pre-1.0 and evolves quickly. Security fixes are applied to the latest `main` branch first and may be backported to release tags when feasible.

## Reporting a Vulnerability

Please report vulnerabilities privately and do not open a public issue.

- Email: security@tangerine-lang.org
- Include: affected version/commit, reproduction steps, impact, and any suggested mitigation.

We will acknowledge receipt as soon as possible and coordinate disclosure once a fix is available.

## Security Scope

Reports are welcome for:

- Compiler and language tooling (`tg_compiler/`)
- Standard library modules (`std/`)
- Build and release workflows (`.github/workflows/`)
- VS Code extension (`tangerine-vscode/`)

## Disclosure Process

1. Acknowledge report.
2. Triage severity and affected components.
3. Develop and test a fix.
4. Publish patch notes in `CHANGELOG.md`.
