# Security Policy — Tangerine

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 0.1.x   | :white_check_mark: |

Only the latest minor release receives security patches.
Once 1.0 is released, the two most recent minor releases will be maintained.

## Reporting a Vulnerability

**Do NOT open a public issue for security vulnerabilities.**

1. Email **security@tangerine-lang.org** with:
   - A description of the vulnerability.
   - Steps to reproduce (minimal `.tg` source, compiler flags, OS/arch).
   - Expected vs actual behavior.
   - Impact assessment (crash, code execution, information leak, etc.).

2. You will receive an acknowledgement within **48 hours**.

3. The team will triage within **7 days** and provide an ETA for a fix.

4. A CVE will be requested when appropriate.

## Disclosure Timeline

| Step                        | SLA           |
| --------------------------- | ------------- |
| Acknowledgement             | 48 hours      |
| Triage & severity rating    | 7 days        |
| Patch available (critical)  | 14 days       |
| Patch available (high)      | 30 days       |
| Public disclosure           | 90 days max   |

We follow **coordinated disclosure**: reporters are credited once the fix is released,
unless they request anonymity.

## Scope

The following components are in-scope for security reports:

- **Compiler** (`tg_compiler/`): Crashes, code execution during compilation,
  output of incorrect safety guarantees (e.g., borrow checker accepts unsound code).
- **Standard library** (`std/`): Memory safety violations, unsound APIs,
  incorrect `unsafe` boundaries.
- **Package manager** (`tg dep`, `tg install`): Dependency confusion, tarball
  extraction vulnerabilities, checksum bypass.
- **Runtime**: Allocator bugs, FFI boundary violations, stack overflow handling.

Out-of-scope:
- Third-party packages published to the registry (report to package owners).
- Denial of service via pathological input to the compiler (tracked as bugs, not CVEs).

## Unsafe Code Policy

Tangerine requires all `unsafe` blocks to:
1. Have a `# SAFETY:` comment documenting the invariant.
2. Pass the built-in unsafe audit (`tg lint --deny unsafe-usage`).
3. Be reviewed by at least two core maintainers.

The compiler itself (`tg_compiler/`) and standard library (`std/`) contain `unsafe`
code gated behind the capability system. Each `unsafe` usage is catalogued by
`borrow_check.tg`'s unsafe audit infrastructure and can be inspected with:

```
tg check --unsafe-report
```

## Security-Related Compiler Features

- **Borrow checker**: Prevents use-after-free, double-free, and data races at compile time.
- **Capability system** (`std/capabilities.tg`): IO, network, and process access are
  gated by capabilities that must be explicitly granted.
- **Effect system** (`std/effects.tg`): Side effects are tracked in the type system.
- **Send/Sync enforcement** (`tg_compiler/types.tg`): Thread-safety of types is
  verified at compile time.
- **Contract system** (`std/contracts.tg`): Pre/post-conditions and invariants are
  checked at runtime in debug builds.

## Acknowledgements

We thank all security researchers who responsibly disclose vulnerabilities.
Contributors will be listed here after fixes are released.
