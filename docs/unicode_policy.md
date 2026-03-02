# Tangerine Unicode Policy

**Version:** 1.0
**Status:** Normative
**Last Updated:** 2026-02-28

This document specifies how Tangerine handles Unicode throughout the language,
from source code to string processing at runtime.

---

## 1. Source Code Encoding

### 1.1 Required Encoding
All Tangerine source files **MUST** be valid UTF-8. The compiler rejects files
with invalid UTF-8 byte sequences.

### 1.2 BOM Handling
- UTF-8 BOM (0xEF 0xBB 0xBF) is **permitted** but **discouraged**.
- If present, the BOM is skipped and not treated as part of the source.
- The formatter removes BOMs on output.

### 1.3 Line Endings
- LF (`\n`), CR+LF (`\r\n`), and CR (`\r`) are all recognized as line terminators.
- The formatter normalizes to LF.
- Line/column numbers in diagnostics always count lines by line terminators.

---

## 2. Identifiers

### 2.1 Identifier Syntax
Identifiers follow **Unicode Standard Annex #31** (UAX31) with some restrictions:

```
identifier := XID_Start XID_Continue*
```

Where:
- `XID_Start` = Unicode property `XID_Start` (letters, letter-numbers, and `_`)
- `XID_Continue` = Unicode property `XID_Continue` (includes digits, combining marks)

### 2.2 ASCII-Only Mode
For maximum portability, projects **MAY** enforce ASCII-only identifiers via:
```toml
[lint]
ascii-identifiers = "deny"
```

### 2.3 Normalization
Identifiers are compared using **NFC normalization**. Two identifiers that
normalize to the same NFC form are considered identical:

```tangerine
let café = 1       # U+0065 U+0301 (e + combining acute)
let café = 2       # U+00E9 (precomposed é)
# Error: duplicate definition — both normalize to the same identifier
```

### 2.4 Confusable Detection
The linter **WARNS** on identifiers that are visually confusable with others
in scope, using Unicode Technical Standard #39 (UTS39) confusable detection:

```tangerine
let foo = 1
let fοο = 2    # Warning: 'fοο' (Greek ο) is confusable with 'foo' (Latin o)
```

### 2.5 Reserved Identifiers
The following patterns are reserved:
- `__.*__` — Double-underscore prefix and suffix (implementation details)
- `_[A-Z].*` — Single underscore followed by uppercase (future language use)

---

## 3. Character Literals

### 3.1 Char Type
`Char` represents a **Unicode scalar value** (USV):
- Range: U+0000 to U+D7FF and U+E000 to U+10FFFF
- Surrogates (U+D800 to U+DFFF) are **not valid** `Char` values.

### 3.2 Escape Sequences
| Escape    | Meaning                          |
|-----------|----------------------------------|
| `\n`      | Line feed (U+000A)               |
| `\r`      | Carriage return (U+000D)         |
| `\t`      | Horizontal tab (U+0009)          |
| `\\`      | Backslash (U+005C)               |
| `\'`      | Single quote (U+0027)            |
| `\"`      | Double quote (U+0022)            |
| `\0`      | Null (U+0000)                    |
| `\xNN`    | Byte value (00-FF)               |
| `\u{NNNN}`| Unicode code point (1-6 hex digits) |

### 3.3 Example
```tangerine
let heart: Char = '\u{2764}'    # ❤
let snowman: Char = '\u{2603}'  # ☃
```

---

## 4. String Type

### 4.1 Internal Representation
`String` is a **UTF-8 encoded** sequence of bytes. It is:
- Owned and mutable via mutable bindings/references
- Length is byte count, not grapheme/codepoint count

### 4.2 String Operations

| Operation          | Behavior                                    |
|--------------------|---------------------------------------------|
| `s.len()`          | Byte length                                 |
| `s.chars()`        | Iterator over `Char` (scalar values)        |
| `s.graphemes()`    | Iterator over extended grapheme clusters    |
| `s.bytes()`        | Iterator over `UInt8`                       |
| `s[i]`             | **Error** — indexing by byte not allowed    |
| `s.char_at(i)`     | `Option[Char]` at byte index (if valid boundary) |
| `s.slice(a, b)`    | Substring (panics if not on char boundaries)|

### 4.3 Grapheme Clusters
For user-visible text operations (e.g., cursor movement, display width),
use **extended grapheme clusters** (UAX29):

```tangerine
let flag = "🇯🇵"
flag.len()           # 8 (bytes)
flag.chars().count() # 2 (regional indicators)
flag.graphemes().count() # 1 (single flag emoji)
```

### 4.4 Display Width
For terminal output alignment, use `std::fmt::display_width()`:

```tangerine
use std::fmt::display_width

display_width("hello")   # 5
display_width("你好")    # 4 (2 cells per CJK character)
display_width("🎉")      # 2 (emoji is double-width)
```

---

## 5. Normalization Policy

### 5.1 Source Code
- **Identifiers**: NFC-normalized for comparison
- **String literals**: Preserved as-is (no normalization)
- **Comments**: Preserved as-is

### 5.2 Runtime Strings
Strings are **not** automatically normalized. Use explicit normalization:

```tangerine
use std::unicode::{nfc, nfd, nfkc, nfkd}

let s1 = "café"
let s2 = nfc(s1)    # NFC-normalized
let s3 = nfkc(s1)   # NFKC-normalized (compatibility decomposition)
```

### 5.3 Comparison
By default, string comparison is **byte-wise** (fast, deterministic).
For Unicode-aware comparison, use:

```tangerine
use std::unicode::collate

collate(s1, s2, Locale::en_US)  # Locale-aware comparison
```

---

## 6. Security Considerations

### 6.1 Bidi Override Detection
The lexer **rejects** source files containing bidirectional override characters:
- U+202A (LRE), U+202B (RLE), U+202C (PDF)
- U+202D (LRO), U+202E (RLO)
- U+2066 (LRI), U+2067 (RLI), U+2068 (FSI), U+2069 (PDI)

These can be used for "Trojan Source" attacks.

### 6.2 Zero-Width Characters
The linter **warns** on zero-width characters in identifiers:
- U+200B (ZWSP), U+200C (ZWNJ), U+200D (ZWJ), U+FEFF (BOM as ZWNBSP)

### 6.3 Homoglyph Attacks
See §2.4 — confusable detection is enabled by default.

---

## 7. Standard Library Support

### 7.1 std::unicode Module

```tangerine
module std::unicode

# Normalization
def nfc(s: String) -> String
def nfd(s: String) -> String
def nfkc(s: String) -> String
def nfkd(s: String) -> String

# Properties
def is_alphabetic(c: Char) -> Bool
def is_numeric(c: Char) -> Bool
def is_alphanumeric(c: Char) -> Bool
def is_whitespace(c: Char) -> Bool
def is_uppercase(c: Char) -> Bool
def is_lowercase(c: Char) -> Bool

# Case mapping
def to_uppercase(s: String) -> String
def to_lowercase(s: String) -> String
def to_titlecase(s: String) -> String

# Grapheme iteration
def graphemes(s: String) -> Iterator[String]

# Width calculation
def display_width(s: String) -> UInt

# Collation
def collate(a: String, b: String, locale: Locale) -> Ordering
```

### 7.2 Locale Support
Tangerine uses CLDR for locale data. Supported locales are documented
in `std::locale`.

---

## 8. Versioning

This policy tracks **Unicode version 16.0+**. When Tangerine updates to a
newer Unicode version:
1. The version is documented in release notes.
2. New characters/properties are available immediately.
3. Identifier validity may expand (but never contract).
4. Existing valid programs remain valid.

---

## 9. Implementation Notes

### 9.1 Lexer
- Uses `std::unicode::is_xid_start()` and `is_xid_continue()` for identifier scanning.
- Normalizes identifiers to NFC before symbol table insertion.

### 9.2 Performance
- Identifier normalization: O(n) with small constant factor.
- Grapheme iteration: O(n) using state machine from UAX29.
- Display width: O(n) using East Asian Width + emoji properties.

### 9.3 Dependencies
The compiler bundles pre-computed Unicode tables (derived from UCD) for:
- XID_Start / XID_Continue
- NFC normalization quick-check
- Grapheme break properties
- East Asian Width

---

## References

- [UAX#31 Unicode Identifier and Pattern Syntax](https://unicode.org/reports/tr31/)
- [UAX#15 Unicode Normalization Forms](https://unicode.org/reports/tr15/)
- [UAX#29 Unicode Text Segmentation](https://unicode.org/reports/tr29/)
- [UTS#39 Unicode Security Mechanisms](https://unicode.org/reports/tr39/)
- [Trojan Source Attack](https://trojansource.codes/)
