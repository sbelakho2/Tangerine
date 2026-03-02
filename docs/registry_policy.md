# Tangerine Package Registry Policy

## Overview

The Tangerine package registry at `registry.tangerine-lang.org` is the canonical
source for distributing and discovering Tangerine packages.  This document
defines the governance rules, publishing requirements, and operational policies
for the registry.

---

## 1. Publishing Requirements

### 1.1 Account & Identity

- Every publisher must authenticate with a verified email address.
- Multi-factor authentication (MFA) is required for publishing.
- Packages are published under a namespace that matches the account owner.

### 1.2 Package Metadata

Every published package **must** include a valid `Tangerine.toml` with:

| Field          | Required | Description                                  |
|----------------|----------|----------------------------------------------|
| `name`         | Yes      | Unique package name (see §2 Naming)          |
| `version`      | Yes      | SemVer 2.0.0 compliant version string        |
| `edition`      | Yes      | Tangerine edition (e.g., `"2026"`)           |
| `authors`      | Yes      | List of author names / emails                |
| `license`      | Yes      | SPDX license identifier                      |
| `description`  | Yes      | One-line summary (≤ 140 characters)          |
| `repository`   | No       | URL to source repository                     |
| `documentation`| No       | URL to hosted documentation                  |
| `keywords`     | No       | Up to 5 search keywords                      |
| `categories`   | No       | Up to 3 registry categories                  |

### 1.3 Integrity

- Every tarball uploaded is verified against a SHA-256 checksum.
- The registry stores checksums immutably; once published, a version
  **cannot be republished** with different content.
- All downloads are served over HTTPS with checksum verification on the client.

### 1.4 Size Limits

- Maximum tarball size: **10 MB** (compressed).
- A `.tgignore` file controls which files are excluded from the tarball.
  By default, `.git/`, `target/`, and `*.o` are excluded.

---

## 2. Naming Policy

### 2.1 Valid Names

- Package names consist of lowercase ASCII letters, digits, hyphens (`-`), and
  underscores (`_`).
- Names must be 1–64 characters long.
- Names must start with a letter.

### 2.2 Name Squatting

The registry reserves the right to transfer or remove packages that:

- Are published solely to reserve a name with no meaningful content.
- Have had no updates and no downloads for **6 months** after initial publish.
- Impersonate or confusingly resemble official Tangerine packages.

A package is considered "squatted" if it contains no source files and fewer
than 10 lines of non-boilerplate code.  The registry team may contact the
owner before taking action.

### 2.3 Reserved Prefixes

The following prefixes are reserved for official use:

- `std-*` — Standard library extensions
- `tg-*` — Compiler and toolchain packages
- `tangerine-*` — Official project packages

---

## 3. Yanking and Removal

### 3.1 Yanking

A published version can be **yanked** by the owner:

- Yanked versions are not selected during fresh dependency resolution.
- Existing `Tangerine.lock` files that reference a yanked version continue
  to resolve (for reproducibility).
- Yanking is reversible (un-yank).

### 3.2 Removal

Complete package removal (all versions) is exceptional and requires:

- A request from the package owner **and** registry team approval, or
- A legal/security requirement (e.g., malware, license violation, DMCA).

Removed packages leave a tombstone to prevent name reuse for 90 days.

---

## 4. Security

### 4.1 Malware Scanning

- All uploads pass through automated static analysis before publication.
- Packages containing obfuscated code, binary blobs without justification,
  or known malicious patterns are rejected.

### 4.2 Dependency Confusion Prevention

- The registry rejects package names that shadow standard library modules
  (`core`, `collections`, `io`, etc.). These names are reserved in the package
  namespace and cannot be published as third-party crates, even though standard
  library modules are imported as `std::<module>` in source code.
- Private registries can be configured in `Tangerine.toml` with explicit
  scoping to prevent cross-registry confusion.

### 4.3 Vulnerability Reporting

- Security vulnerabilities in registry packages follow the process in
  `SECURITY.md`.
- The registry supports a machine-readable advisory database at
  `registry.tangerine-lang.org/advisories/`.

### 4.4 Audit Trail

- All publish/yank/transfer operations are logged in an append-only audit log.
- The audit log is publicly queryable via the registry API.

---

## 5. Rate Limits and Quotas

| Operation     | Limit                         |
|---------------|-------------------------------|
| Publish       | 30 versions per package / day |
| Download      | No limit (CDN-backed)         |
| API queries   | 1000 requests / minute / IP   |
| Account       | 500 packages per account      |

---

## 6. Governance

### 6.1 Registry Team

The registry is operated by the Tangerine project maintainers.  Decisions
on policy changes, name disputes, and removals are made by consensus of
the registry team (minimum 2 approvals).

### 6.2 Appeals

Package owners may appeal moderation decisions by filing an issue in the
`tangerine-lang/registry-policy` repository.  Appeals are reviewed within
14 days.

### 6.3 Policy Changes

Changes to this policy follow the RFC process described in
[rfc_process.md](rfc_process.md).  Minor clarifications may be made
without an RFC at the registry team's discretion.

---

## 7. API Endpoints

| Endpoint                                  | Method | Description                     |
|-------------------------------------------|--------|---------------------------------|
| `/api/v1/packages`                        | GET    | List / search packages          |
| `/api/v1/packages/{name}`                 | GET    | Package metadata                |
| `/api/v1/packages/{name}/{version}`       | GET    | Version-specific metadata       |
| `/api/v1/packages/{name}/{version}/download` | GET | Download tarball              |
| `/api/v1/packages/new`                    | PUT    | Publish a new version           |
| `/api/v1/packages/{name}/{version}/yank`  | DELETE | Yank a version                  |
| `/api/v1/packages/{name}/{version}/unyank`| PUT    | Un-yank a version               |
| `/api/v1/packages/{name}/owners`          | GET    | List owners                     |
| `/api/v1/packages/{name}/owners`          | PUT    | Add owner                       |
| `/api/v1/packages/{name}/owners`          | DELETE | Remove owner                    |

All endpoints require authentication via bearer token except `GET` requests.

---

## 8. Mirror Policy

- Third-party mirrors are permitted and encouraged for geographic distribution.
- Mirrors must serve unmodified tarballs with matching checksums.
- The official registry provides a public replication feed for mirrors.
