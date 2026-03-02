# Dependency, Licensing, and Supply-Chain Controls — TG-GFX-UI-SPEC-001 v0.1

> Normative reference for §36 of the graphics/UI development checklist.

---

## 1. Third-Party Dependency Inventory

### 1.1 Host Runtime Dependencies

| Dependency       | Version | License     | Purpose                              | Critical Path |
|------------------|---------|-------------|--------------------------------------|---------------|
| (none — v0.1)   | —       | —           | v0.1 is self-contained (no 3rd-party)| —             |

> **Note:** The v0.1 reference implementation is intentionally dependency-free.
> All algorithms (CRC-32, Adler-32, PNG decode/encode, geometry math) are
> implemented in Tangerine stdlib code.

### 1.2 Backend Dependencies (per backend)

| Backend         | Dependency       | Version | License    | Purpose                |
|-----------------|------------------|---------|------------|------------------------|
| macOS native    | Core Graphics    | System  | Apple EULA | 2D rendering           |
| macOS native    | Core Text        | System  | Apple EULA | Text shaping/layout    |
| macOS native    | AppKit           | System  | Apple EULA | Windowing              |
| Linux native    | X11 / Wayland    | System  | MIT/Wayland| Windowing              |
| Linux native    | FreeType         | System  | FreeType   | Font rasterization     |
| Linux native    | Fontconfig       | System  | MIT        | Font discovery         |
| Windows native  | Win32 / COM      | System  | MS EULA    | Windowing              |
| Windows native  | DirectWrite      | System  | MS EULA    | Text shaping/layout    |
| Software ref    | (none)           | —       | —          | Pure Tangerine impl    |

### 1.3 Build/Dev Dependencies

| Dependency   | Version | License | Purpose            |
|-------------|---------|---------|---------------------|
| GNU Make     | ≥ 4.0   | GPL-3   | Build orchestration |
| Python 3     | ≥ 3.8   | PSF     | Build scripts       |

---

## 2. License Acceptability

### 2.1 Approved License Categories

| Category          | Licenses                           | Status     |
|-------------------|------------------------------------|------------|
| Permissive        | MIT, BSD-2, BSD-3, Apache-2.0, ISC | ✅ Approved |
| System/Platform   | Apple EULA, MS EULA, LGPL          | ✅ Approved (system libs only) |
| Weak copyleft     | LGPL-2.1, MPL-2.0                  | ✅ Approved (dynamic linking)  |
| FreeType          | FreeType License (BSD-like)        | ✅ Approved |
| Strong copyleft   | GPL-2, GPL-3                       | ⚠️ Build tools only |
| Proprietary       | —                                  | ❌ Forbidden for runtime deps  |

### 2.2 Verification

All dependencies are verified at merge time:
- CI checks license declarations against the approved list.
- New dependencies require explicit approval via ADR.

---

## 3. Software Bill of Materials (SBOM)

### 3.1 Format

SBOMs are generated in [CycloneDX](https://cyclonedx.org/) JSON format.

### 3.2 Contents

Each SBOM includes:
- Component name, version, license, and supplier.
- Dependency tree (direct + transitive).
- Build environment fingerprint (toolchain version, OS).
- Cryptographic hash of each component binary.

### 3.3 Publication

- SBOM is generated during the release pipeline.
- Published alongside release artifacts as `sbom.json`.
- Signed with the same key as release artifacts.

---

## 4. Vulnerability Scanning

### 4.1 CI Integration

- Dependency vulnerability scanning runs on every PR and release build.
- Scanner checks against CVE databases (NVD, GitHub Advisory DB).
- Critical/High vulnerabilities block merge.
- Medium/Low vulnerabilities are tracked as issues with SLA.

### 4.2 SLA

| Severity | Response SLA        |
|----------|---------------------|
| Critical | Patch within 24 hrs |
| High     | Patch within 72 hrs |
| Medium   | Patch within 2 wks  |
| Low      | Next release cycle  |

---

## 5. Patch/Update Cadence

- **Security-critical dependencies:** Patched within SLA (see §4.2).
- **System libraries:** Follow platform vendor update cycle.
- **Build tools:** Updated quarterly or on security advisory.
- **Dependency audit:** Full audit performed each release cycle.

---

## 6. Plugin Package Provenance/Signature

### 6.1 Supported Verification

- Plugins may include a detached signature (`.sig`) file.
- The host loader can optionally verify plugin signatures before loading.
- Signature verification is controlled by `LoaderConfig` settings.

### 6.2 Process

1. Plugin author signs the shared library with their key.
2. Public key is registered in the plugin registry.
3. Host verifies signature during `tg_backend_manifest_v1` load.
4. Unsigned plugins are loaded only if `LoaderConfig.allow_unsigned = true`.

### 6.3 Default Policy

- Development builds: unsigned plugins allowed.
- Release builds: unsigned plugins **rejected** by default.
