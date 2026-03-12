# Tangerine Bootstrap: Rust Stage0 Strict Implementation Checklist

## Core Philosophy: The Zero-Erasure Mandate
The Rust bridge will operate under **Zero Tolerance**: if an AST node, variable, or type constraint cannot be perfectly mapped and resolved, the compiler **must hard-crash** pointing to the exact line in the `.tg` source.

## Latest Verified State
- [x] The Rust bridge is back to a fully green validation state. Evidence: `cd stage0_rs && cargo test`, `cargo clippy --all-targets --all-features -- -D warnings`, `cargo run -- scan ../golden`, and `cargo run -- scan ../tg_compiler` all passed on 2026-03-11.
- [x] The golden corpus is fully covered by the current bridge. Evidence: `cargo run -- scan ../golden` now reports `supported=30 unsupported=0` on 2026-03-11.
- [x] The real compiler corpus now analyzes cleanly under a shared semantic environment. Evidence: `cargo run -- scan ../tg_compiler` now reports `supported=34 unsupported=0` on 2026-03-11.
- [x] The last parser frontier in `golden/conformance_runner.tg` is closed without fallback behavior. Evidence: the final unlocking slices were implemented as real AST/parser/sema support for bitwise precedence (`|`, `^`, `&`, `<<`, `>>`), multiline parameter lists, explicit `as` casts, tuple positional field access (`.0`, `.1`), contextual-keyword field access (`.pre`, `.cap`), and the newline-continuation fix for unary-start lines such as `*state = ...`.
- [x] Code generation no longer emits placeholder executable bodies or `unimplemented!()` fallback constants. Evidence: `stage0_rs/src/codegen/mod.rs` now lowers supported block/expr forms directly and raises explicit codegen errors for declaration-only bodies or unsupported const expressions.
- [x] Strict end-to-end codegen validation commands now exist. Evidence: `stage0_rs/src/driver.rs` and `stage0_rs/src/main.rs` now expose `cargo run -- codegen <file.tg>` and `cargo run -- codegen-scan <directory>` to perform parse + sema + Rust emission + `rustc` metadata validation on generated output.
- [x] Added recursive semantic compatibility for string-like, integer-like, and container-wrapped values. Evidence: `stage0_rs/src/sema/mod.rs` now accepts `String`/`&str` style call compatibility, integer-literal compatibility with builtin integer types, and recursive compatibility through `Option[...]`, tuples, arrays, and `Array`/`Vec` interchange; regression coverage was added and `cargo test` plus strict `cargo clippy --all-targets --all-features -- -D warnings` both passed on 2026-03-11.
- [x] Added borrowed and unqualified builtin enum support for `Option` / `Result`. Evidence: `stage0_rs/src/sema/mod.rs` now accepts borrowed enum pattern matching plus unqualified `Some` / `None` / `Ok` / `Err` constructor and pattern paths where the surrounding type context is sufficient; regression coverage was added and the validation loop stayed green on 2026-03-11.
- [x] Added missing intrinsic coverage for compiler-heavy collection and std paths. Evidence: `stage0_rs/src/sema/mod.rs` now recognizes `std::env::var` as `Option[String]`, `String::new`, `String::{chars,byte_at,push,push_str}`, `Array::{clone,is_empty}`, `Map::get_mut`, fallback `.to_string()`, and empty generic `Vec` / `Set` / `Map` mutation calls such as `Vec::new(); lines.push(...)`; regression coverage was added in `sema::tests::{accepts_std_env_var_as_option_string,accepts_string_iteration_and_push_str,accepts_array_clone_and_is_empty}` and `cargo test` plus strict `cargo clippy --all-targets --all-features -- -D warnings` stayed green on 2026-03-11.
- [ ] Strict end-to-end validation is not green yet. Evidence: `cargo run -- codegen-scan ../golden` currently reports `supported=11 unsupported=19`, and `cargo run -- codegen-scan ../tg_compiler` currently reports `supported=0 unsupported=34` on 2026-03-11.

---

## Phase 1: Project Scaffolding & Guardrails

### 1.1 Cargo Initialization
- [ ] Run `cargo new stage0_rs`. Evidence: not used; the crate was scaffolded manually before PATH was corrected.
- [x] Add crate scaffold manually when `cargo new` is unavailable. Evidence: `stage0_rs/Cargo.toml`, `stage0_rs/src/lib.rs`, `stage0_rs/src/main.rs`.
- [ ] Add `[workspace]` if necessary. Evidence: not needed yet; no Rust workspace exists elsewhere in repo.
- **Test:** `cargo build` must succeed with zero warnings. Evidence: executed successfully with `~/.cargo/bin/cargo build` on 2026-03-11.

### 1.2 Strict Linting Configuration
- [x] Open `Cargo.toml` or `src/lib.rs`. Evidence: `stage0_rs/Cargo.toml`, `stage0_rs/src/lib.rs`, `stage0_rs/src/main.rs` created.
- [x] Add `#![deny(clippy::all, clippy::pedantic)]`. Evidence: crate attrs present in `stage0_rs/src/lib.rs` and `stage0_rs/src/main.rs`; `warnings` also denied.
- **Test:** Strict linting must be enforced. Evidence: `~/.cargo/bin/cargo clippy --all-targets --all-features` passed after fixing every pedantic violation surfaced by the toolchain on 2026-03-11.

### 1.3 Span Definition
- [x] Create `src/span.rs`. Evidence: `stage0_rs/src/span.rs` exists.
- [x] Define `pub struct Span { pub line: usize, pub col: usize, pub start: usize, pub end: usize }`. Evidence: implemented in `stage0_rs/src/span.rs`.
- [x] Implement `Debug` and `Display` for `Span`. Evidence: `#[derive(Debug)]` plus `impl fmt::Display for Span` in `stage0_rs/src/span.rs`.
- **Test:** Write a unit test creating a `Span(1, 1, 0, 5)` and verifying its formatting string. Evidence: executed in `~/.cargo/bin/cargo test`; `span::tests::span_formats_as_expected` passed on 2026-03-11.

### 1.4 Error Infrastructure
- [x] Add `miette` or `codespan-reporting` to dependencies. Evidence: `miette` and `thiserror` added in `stage0_rs/Cargo.toml`.
- [x] Define `pub enum Stage0Error`. Evidence: implemented in `stage0_rs/src/error.rs`.
- [x] Ensure all error variants require a `Span`. Evidence: every variant in `Stage0Error` carries `span: Span`.
- **Test:** Verify `Stage0Error` cannot be instantiated without providing a `Span`. Evidence: enforced by enum shape in `stage0_rs/src/error.rs`; crate compiles and passes `~/.cargo/bin/cargo check` on 2026-03-11.

---

## Phase 2: Lexical Analysis (Granular)

### 2.1 Keyword Token Definitions
- [x] Create `src/lexer/token.rs`. Evidence: `stage0_rs/src/lexer/token.rs` exists.
- [x] Define keyword token kinds for `trait`, `dyn`, `struct`, `impl`, `fn`, `let`. Evidence: `TokenKind::{KeywordTrait, KeywordDyn, KeywordStruct, KeywordImpl, KeywordFn, KeywordLet}` in `stage0_rs/src/lexer/token.rs`.
- **Test:** Unit test matching string "trait" to `TokenKind::Trait`. Evidence: executed in `~/.cargo/bin/cargo test`; lexer keyword coverage passed on 2026-03-11.

### 2.2 Symbol Token Definitions
- [x] Add operators to `TokenKind`: `LBrace`, `RBrace`, `Colon`, `SemiColon`, `Dot`. Evidence: brace/colon/semi/dot variants implemented in `stage0_rs/src/lexer/token.rs` (`Semi` used for semicolon token).
- **Test:** Unit test mapping "{" to `TokenKind::LBrace`. Evidence: executed in `~/.cargo/bin/cargo test`; lexer symbol coverage passed on 2026-03-11.

### 2.3 The Token Struct
- [x] Define `pub struct Token { pub kind: TokenKind, pub span: Span, pub lexeme: String }`. Evidence: implemented in `stage0_rs/src/lexer/token.rs`.
- **Test:** Instantiate `Token` and assert its fields. Evidence: token construction paths executed by parser tests in `~/.cargo/bin/cargo test` on 2026-03-11.

### 2.4 Whitespace and Comments (Trivia)
 [x] Add `Whitespace` and `Comment` to `TokenKind`. Evidence: `TokenKind::{Whitespace, Comment}` implemented in `stage0_rs/src/lexer/token.rs`.
 **Test:** Lex `// comment\n  ` and verify NO tokens are dropped. Evidence: executed in `~/.cargo/bin/cargo test`; `lexer::tests::preserves_comment_and_whitespace_trivia` passed on 2026-03-11.

### 2.5 Lexing Engine Setup
- [x] Create `src/lexer/mod.rs` with `pub fn lex(input: &str) -> Result<Vec<Token>, Stage0Error>`. Evidence: public `lex` function implemented in `stage0_rs/src/lexer/mod.rs`.
 [x] Implement char-by-char stepping using `.char_indices()`. Evidence: `peek_char` and `peek_second_char` in `stage0_rs/src/lexer/mod.rs` now step with `.char_indices()`.
 **Test:** Lex a completely empty string and expect `Ok(vec![])`. Evidence: executed in `~/.cargo/bin/cargo test`; `lexer::tests::public_lex_on_empty_input_returns_no_tokens` passed on 2026-03-11.

### 2.6 The Reversibility Test
 [x] Add a test taking a token stream and `map(|t| t.lexeme).collect::<String>()`. Evidence: reversible lexer test authored in `stage0_rs/src/lexer/mod.rs`.
 **Test:** Lex `trait A { fn b(); }`, reverse it, and assert `input == output`. Evidence: executed in `~/.cargo/bin/cargo test`; `lexer::tests::reversible_lex_preserves_original_source` passed on 2026-03-11.

### 2.7 Lexer Error Handling
- [x] Introduce an invalid character path in lexing loop. Evidence: unexpected character branch in `stage0_rs/src/lexer/mod.rs` returns `Stage0Error::lex(span, ...)`.
- **Fail-First Test:** Lexer must return `Err(Stage0Error)` containing the `Span` of `$`. Evidence: executed in `~/.cargo/bin/cargo test`; `lexer::tests::rejects_unknown_character` passed on 2026-03-11.

---

## Phase 3: The Parity AST (Granular)

### 3.1 Primitive Types
- [x] Create `src/ast/types.rs`. Evidence: `stage0_rs/src/ast/types.rs` exists.
- [x] Define primitive types for `Int`, `String`, `Bool`, `Unit`. Evidence: `TypeRef::{Int, String, Bool, Unit}` implemented in `stage0_rs/src/ast/types.rs`.
- **Test:** Verify formatting of `Type::Int` is "Int". Evidence: executed in `~/.cargo/bin/cargo test`; `ast::tests::primitive_and_ref_types_preserve_shape` passed on 2026-03-11.

### 3.2 Complex Types
- [x] Add dynamic-trait and reference-capable types. Evidence: `TypeRef::{DynTrait, Named, Ref}` in `stage0_rs/src/ast/types.rs`; `Named` is currently serving the concrete-type role.
- **Test:** Construct `Type::Ref(Box::new(Type::DynTrait("Registry")))` and verify structure. Evidence: executed in `~/.cargo/bin/cargo test`; `ast::tests::primitive_and_ref_types_preserve_shape` passed on 2026-03-11.

### 3.3 Struct Declaration AST
- [x] Create `src/ast/decl.rs`. Evidence: `stage0_rs/src/ast/decl.rs` exists.
- [x] Define `StructDecl` with name, fields, and span. Evidence: `StructDecl { name, fields, span }` plus `FieldDecl` implemented in `stage0_rs/src/ast/decl.rs`.
- **Test:** Construct a generic `StructDecl` programmatically and inspect fields. Evidence: executed in `~/.cargo/bin/cargo test`; `ast::tests::module_preserves_trait_method_shape` passed on 2026-03-11.

### 3.4 Method Signatures AST
- [x] Define a method-signature AST node carrying name, params, return type, and span. Evidence: `FunctionSig` plus `Param` in `stage0_rs/src/ast/decl.rs`.
- **Test:** Assert that `MethodSig` can distinguish `fn a(b: Int)` from `fn a(b: String)`. Evidence: signature-bearing parser and semantic tests executed successfully in `~/.cargo/bin/cargo test` on 2026-03-11.

### 3.5 Trait Declaration AST
- [x] Define `TraitDecl` with name, methods, and span. Evidence: implemented in `stage0_rs/src/ast/decl.rs`.
- **Test:** Ensure traits *only* accept `MethodSig` and cannot accept fields. Evidence: executed in `~/.cargo/bin/cargo test`; `parser::tests::rejects_trait_fields` passed on 2026-03-11.

### 3.6 Impl Declaration AST
- [x] Define `pub struct ImplDecl { pub trait_name: String, pub target_type: String, pub methods: Vec<MethodBody>, pub span: Span }`. Evidence: `ImplDecl` now carries `trait_name`, `target_type`, `methods`, and `span` in `stage0_rs/src/ast/decl.rs`; `MethodBody` is currently a type alias over `FunctionDecl`.
- **Test:** Bind a dummy `method_body` to `ImplDecl`. Evidence: impl parsing and AST preservation executed in `~/.cargo/bin/cargo test`; `parser::tests::parses_trait_impl_and_struct_without_erasure` passed on 2026-03-11.

---

## Phase 4: Stage0 Parsing (Granular)

### 4.1 Parser Setup
- [x] Create `src/parser/mod.rs` with `pub struct Parser { tokens: Vec<Token>, cursor: usize }`. Evidence: implemented in `stage0_rs/src/parser/mod.rs`.
- [x] Implement `fn peek()`, `fn advance()`, `fn expect(TokenKind)`. Evidence: implemented in `stage0_rs/src/parser/mod.rs`.
- **Test:** Initialize parser with 3 tokens, call `advance` 4 times, verify EOF handling. Evidence: executed in `~/.cargo/bin/cargo test`; `parser::tests::advance_stops_at_eof` passed on 2026-03-11.

### 4.2 Parsing Primitives
- [x] Implement `parse_type()`. Evidence: `parse_type` implemented in `stage0_rs/src/parser/mod.rs`.
- **Test:** Feed `[Int]` token, expect `Type::Int`. Feed `[Dyn, Identifier("T")]`, expect `Type::DynTrait("T")`. Evidence: executed parser tests passed in `~/.cargo/bin/cargo test` on 2026-03-11.

### 4.3 Parsing Structs
- [x] Implement `parse_struct_decl()`. Evidence: `parse_struct` implemented in `stage0_rs/src/parser/mod.rs`.
- **Test:** Feed tokens for `struct Node { id: Int }`. Assert `StructDecl` AST is correct. Evidence: executed in `~/.cargo/bin/cargo test`; `parser::tests::parses_trait_impl_and_struct_without_erasure` passed on 2026-03-11.
- **Fail-First Test:** Feed `struct Node { id: }`. Ensure it fails on missing type instead of skipping. Evidence: executed in `~/.cargo/bin/cargo test`; `parser::tests::rejects_struct_field_without_type` passed on 2026-03-11.

### 4.4 Parsing Traits
- [x] Implement `parse_trait_decl()`. Evidence: `parse_trait` implemented in `stage0_rs/src/parser/mod.rs`.
- **Test:** Feed `trait Renderer { fn draw(); }`. Wait for `ast.methods.len() == 1`. Evidence: executed trait parsing tests passed in `~/.cargo/bin/cargo test` on 2026-03-11.
- **Fail-First Test:** Feed `trait Rs { a: Int }`. Parser must fail explicitly since traits lack fields. Evidence: executed in `~/.cargo/bin/cargo test`; `parser::tests::rejects_trait_fields` passed on 2026-03-11.

---

## Phase 5: Semantic Lowering & Environment

### 5.1 The Global Environment Map
- [x] Create `src/sema/env.rs`. Evidence: `stage0_rs/src/sema/env.rs` exists.
- [x] Define a global semantic environment carrying structs and traits by name. Evidence: `SemanticEnv { structs: BTreeMap<String, StructDecl>, traits: BTreeMap<String, TraitDecl>, .. }` implemented in `stage0_rs/src/sema/env.rs`.
- **Test:** Insert a `TraitDecl`. Retrieve it by name. Evidence: environment population and retrieval executed successfully in `~/.cargo/bin/cargo test`; semantic tests passed on 2026-03-11.

### 5.2 Pass 1: Cataloging
- [x] Write cataloging logic over top-level declarations. Evidence: `SemanticEnv::build` catalogs structs, traits, and impls in `stage0_rs/src/sema/env.rs`.
- **Fail-First Test:** Introduce two traits with the name `Renderer`. Catalog must return `DuplicateDeclaration` error. Evidence: executed in `~/.cargo/bin/cargo test`; `sema::tests::rejects_duplicate_trait_declarations` passed on 2026-03-11.

### 5.3 Symbol Resolution
- [x] Write `fn resolve_type(t: &Type, env: &GlobalEnv)`. Evidence: `resolve_type` implemented in `stage0_rs/src/sema/mod.rs`.
- **Fail-First Test:** Given `dyn UnknownTrait`, `resolve_type` must return `Err(Stage0Error)` stating "UnknownTrait is not defined". No generic object fallback. Evidence: executed in `~/.cargo/bin/cargo test`; `sema::tests::rejects_unknown_dyn_trait_resolution` passed on 2026-03-11.

### 5.4 Method Dispatch Constraints
- [x] Implement `fn check_method_call(obj_type: &Type, method_name: &str, env: &GlobalEnv)`. Evidence: `check_method_call` implemented in `stage0_rs/src/sema/mod.rs`.
- **Fail-First Test:** Given `obj_type == DynTrait("Registry")` and `method_name == "fetch"`, missing method throws error. Evidence: executed in `~/.cargo/bin/cargo test`; `sema::tests::rejects_missing_dyn_method` passed on 2026-03-11.

---

## Phase 6: Code Generation (Granular)

### 6.1 Struct CodeGen
- [x] Create `src/codegen/mod.rs`. Evidence: `stage0_rs/src/codegen/mod.rs` exists.
- [x] Write `fn gen_struct(decl: &StructDecl) -> String`. Evidence: `gen_struct` implemented in `stage0_rs/src/codegen/mod.rs`.
- **Test:** Output `pub struct Box { ... }`. Compare string exactly. Evidence: executed in `~/.cargo/bin/cargo test`; `codegen::tests::emits_exact_struct_and_trait_shapes` passed on 2026-03-11.

### 6.2 Trait CodeGen
- [x] Write `fn gen_trait(decl: &TraitDecl) -> String`. Evidence: `gen_trait` implemented in `stage0_rs/src/codegen/mod.rs`.
- **Test:** Input `trait A { fn b(); }`, output `pub trait A { fn b(); }`. Evidence: executed in `~/.cargo/bin/cargo test`; `codegen::tests::emits_exact_struct_and_trait_shapes` passed on 2026-03-11.

### 6.3 Interface/Dyn Emission
- [x] Write `fn gen_dyn_ref(trait_name: &str) -> String`. Evidence: `gen_dyn_ref` implemented in `stage0_rs/src/codegen/mod.rs`.
- **Test:** Input `Registry`, output `Box<dyn Registry>`. Evidence: executed in `~/.cargo/bin/cargo test`; `codegen::tests::emits_exact_struct_and_trait_shapes` passed on 2026-03-11.

### 6.4 Rustc Integration Test
- [x] Write a harness that generates a temporary `.rs` file and validates it with `rustc`. Evidence: `rustc_check_command` and `rustc_check` implemented in `stage0_rs/src/codegen/mod.rs`; the final command uses metadata-only validation because this toolchain does not support `rustc --check`.
- **Test:** Generate valid output, assert `rustc` succeeds. Generate invalid output, assert failure. Evidence: executed in `~/.cargo/bin/cargo test`; `codegen::tests::rustc_check_accepts_valid_rust_and_rejects_invalid_rust` passed on 2026-03-11.

---

## Post-Phase Extensions

### A. Real Repository `.tg` Ingestion
- [x] Wire the Rust front end to read actual `.tg` files from the repository. Evidence: `stage0_rs/src/driver.rs` provides `parse_module_from_path` and `analyze_module_from_path`.
- [x] Replace purely synthetic coverage with a source-driven fixture from the repo. Evidence: `driver::tests::analyzes_real_repo_fixture` reads `golden/frontend_01.tg` and passed in `cargo test` on 2026-03-11.

### B. Expressions, Statements, and Typed Bodies
- [x] Add expression AST nodes for integer literals, names, and binary `+`. Evidence: `stage0_rs/src/ast/expr.rs` defines `Expr` and `BinaryOp`.
- [x] Add statement AST nodes for `let` and expression statements. Evidence: `stage0_rs/src/ast/expr.rs` defines `Stmt` and block bodies.
- [x] Parse real `def ... end` Tangerine function bodies with newline-separated statements. Evidence: `stage0_rs/src/parser/mod.rs` now parses `def`, `end`, `let`, newlines, and tail expressions.
- [x] Perform typed body checking against params and local bindings. Evidence: `stage0_rs/src/sema/mod.rs` now type-checks executable function bodies and rejects unknown names, bad `+` operands, and return-type mismatches.
- [x] Validate the new layer with fail-first tests. Evidence: `parser::tests::parses_real_tangerine_function_body`, `sema::tests::accepts_typed_real_function_body`, `sema::tests::rejects_unknown_name_in_function_body`, and `sema::tests::rejects_function_return_type_mismatch` all passed in `cargo test` on 2026-03-11.

### C. Real-Syntax Expansion: Metadata, Calls, Fields, and Line-Based Decls
- [x] Parse repository metadata forms such as `@...`, `use`, `edition`, `rationale ... end`, and `cap ... end`. Evidence: `stage0_rs/src/parser/mod.rs` and `stage0_rs/src/ast/decl.rs` now model metadata declarations; `parser::tests::parses_metadata_and_inline_function_body` passed in `cargo test` on 2026-03-11.
- [x] Add string, bool, call, field, and `*` expression support. Evidence: `stage0_rs/src/ast/expr.rs`, `stage0_rs/src/parser/mod.rs`, and `stage0_rs/src/sema/mod.rs`; `sema::tests::accepts_function_calls_and_string_concat` and `sema::tests::accepts_struct_field_access` passed in `cargo test` on 2026-03-11.
- [x] Support newline-delimited `struct`, `trait`, and `impl ... for ... end` forms used by repo fixtures. Evidence: parser logic in `stage0_rs/src/parser/mod.rs`; `driver::tests::analyzes_line_based_repo_fixtures` passed in `cargo test` on 2026-03-11.
- [x] Support typed `let` bindings and struct literals used by real fixtures. Evidence: `stage0_rs/src/parser/mod.rs` and `stage0_rs/src/sema/mod.rs`; `golden/simple_test.tg` is covered by `driver::tests::analyzes_line_based_repo_fixtures` and passed in `cargo test` on 2026-03-11.

### D. Capability Clauses, Unsafe Blocks, and Coverage Measurement
- [x] Parse and type-check `requires` clauses inside function bodies. Evidence: `Stmt::Requires` in `stage0_rs/src/ast/expr.rs`, parsing in `stage0_rs/src/parser/mod.rs`, and semantic handling in `stage0_rs/src/sema/mod.rs`; `golden/capabilities_01.tg` passed in `driver::tests::analyzes_line_based_repo_fixtures` on 2026-03-11.
- [x] Parse and type-check `unsafe "..." ... end` blocks as explicit block expressions. Evidence: `Expr::UnsafeBlock` in `stage0_rs/src/ast/expr.rs`, parser support in `stage0_rs/src/parser/mod.rs`, and block typing in `stage0_rs/src/sema/mod.rs`; validated by `cargo test` and real fixture coverage on 2026-03-11.
- [x] Add CLI and directory-scan support to measure real repo coverage instead of assuming it. Evidence: `stage0_rs/src/main.rs` provides `analyze` and `scan`; `cargo run -- scan ../golden` reported `supported=5 unsupported=25` on 2026-03-11.
- [x] Keep the Rust bridge lint-clean and buildable after each expansion. Evidence: `cargo test`, `cargo clippy --all-targets --all-features -- -D warnings`, and `cargo build` all passed on 2026-03-11 after the latest syntax expansions.

### E. Recently Completed Real-Syntax Slices
- [x] Add mutable bindings, reference types, unary borrow/not, comparison/equality, modulo, and logical operators. Evidence: `stage0_rs/src/ast/expr.rs`, `stage0_rs/src/lexer/{token.rs,mod.rs}`, `stage0_rs/src/parser/mod.rs`, and `stage0_rs/src/sema/mod.rs`; `cargo test` and `cargo clippy --all-targets --all-features -- -D warnings` both passed on 2026-03-11 after these additions.
- [x] Add generic function signatures and omitted `->` return types defaulting to `Unit`. Evidence: `FunctionSig.type_params` in `stage0_rs/src/ast/decl.rs`, signature parsing in `stage0_rs/src/parser/mod.rs`, and scoped generic resolution/inference in `stage0_rs/src/sema/{env.rs,mod.rs}`; validated by green `cargo test` and `cargo clippy` on 2026-03-11.
- [x] Allow block-local `use` declarations inside executable function bodies. Evidence: `Stmt::Use` in `stage0_rs/src/ast/expr.rs`, parser support in `stage0_rs/src/parser/mod.rs`, and semantic acceptance in `stage0_rs/src/sema/mod.rs`; scan failures that previously stopped at `KeywordUse` now proceed deeper into later constructs.
- [x] Wire Part E keywords into real function and statement grammar instead of stopping at tokenization. Evidence: `stage0_rs/src/ast/{decl.rs,expr.rs}`, `stage0_rs/src/parser/mod.rs`, and `stage0_rs/src/sema/mod.rs` now support function `budget` / `pre` / `post` / `invariant` clauses, `while` / `until`, `return`, assignment statements, subtraction, division, unary negation, and `unless` expression desugaring; `cargo test` and `cargo clippy --all-targets --all-features -- -D warnings` passed on 2026-03-11 after this slice.
- [x] Carry Part E literals through all compiler layers rather than lexing them only. Evidence: `Float` and `Char` now exist in `stage0_rs/src/ast/{types.rs,expr.rs}`, parser support in `stage0_rs/src/parser/mod.rs`, semantic typing in `stage0_rs/src/sema/{env.rs,mod.rs}`, and Rust lowering in `stage0_rs/src/codegen/mod.rs`; validation stayed green on 2026-03-11.
- [x] Improve measured corpus support instead of claiming syntax by inspection. Evidence: `cargo run -- scan ../golden` progressed from `supported=7 unsupported=23` to `supported=9 unsupported=21`, then to `supported=11 unsupported=19`, then to `supported=18 unsupported=12`, then to `supported=25 unsupported=5`, and now to `supported=30 unsupported=0` on 2026-03-11.

### F. Final Verified Corpus-Unlocking Slices
- [x] Add first-class declaration support for `const` and `extern`. Evidence: `Decl::{Const, Extern}` plus `ConstDecl` and `ExternBlockDecl` now exist in `stage0_rs/src/ast/decl.rs`, with parser/env/codegen support in `stage0_rs/src/parser/mod.rs`, `stage0_rs/src/sema/env.rs`, and `stage0_rs/src/codegen/mod.rs`; the final validation loop stayed green on 2026-03-11.
- [x] Add the full bitwise precedence family rather than only token support. Evidence: `stage0_rs/src/ast/expr.rs`, `stage0_rs/src/parser/mod.rs`, and `stage0_rs/src/sema/mod.rs` now carry `BitOr`, `BitXor`, `BitAnd`, `Shl`, and `Shr`; `parser::tests::parses_deref_assignments_with_bitwise_ops` passed on 2026-03-11.
- [x] Add multiline function parameter parsing used by compiler-heavy fixtures. Evidence: `parse_signature` and `parse_params` in `stage0_rs/src/parser/mod.rs` now tolerate interior newlines; `parser::tests::parses_multiline_function_params` passed on 2026-03-11.
- [x] Add explicit `as` cast expressions across AST, parser, and sema. Evidence: `Expr::Cast` exists in `stage0_rs/src/ast/expr.rs`, parser support exists in `stage0_rs/src/parser/mod.rs`, semantic validation exists in `stage0_rs/src/sema/mod.rs`, and `parser::tests::parses_cast_expressions` passed on 2026-03-11.
- [x] Add tuple positional field access and contextual-keyword field access. Evidence: postfix field parsing in `stage0_rs/src/parser/mod.rs` now accepts both `.0`/`.1` and contextual identifiers such as `.pre` / `.cap`, while `type_of_field` in `stage0_rs/src/sema/mod.rs` resolves tuple element types; `parser::tests::parses_tuple_positional_field_access` passed on 2026-03-11.

## Missing Feature Matrix For Full Self-Hosting

The items below are the remaining language and compiler-surface gaps between the current Rust bridge and a fully self-hosting Tangerine compiler. They are derived from `docs/grammar.md`, the current `cargo run -- scan ../golden` output, and real repository fixtures under `golden/` and `tg_compiler/`.

### E. Lexer And Token Surface Still Missing
- [x] Add bracket tokens and generic punctuation: `[` `]` `<` `>` `<=` `>=` `::` `=>` `..` `..=`. Evidence: `stage0_rs/src/lexer/token.rs` and `stage0_rs/src/lexer/mod.rs` now lex `LBracket`, `RBracket`, `Lt`, `Gt`, `LtEq`, `GtEq`, `ColonColon`, `FatArrow`, `DotDot`, and `DotDotEq`; `cargo test` passed on 2026-03-11 and the latest `cargo run -- scan ../golden` reports parse errors rather than lex errors for these forms.
- [x] Add borrow, logical, comparison, and assertion operators: `&`, `&&`, `|`, `||`, `!`, `==`, `!=`, `%`, `/`, `^`, `~`, `<<`, `>>`, `?`. Evidence: `stage0_rs/src/lexer/token.rs` and `stage0_rs/src/lexer/mod.rs` now lex all of these operator families, including `Slash`, `Caret`, `Tilde`, `Shl`, `Shr`, and `Question`; `lexer::tests::lexes_extended_keyword_and_operator_surface` passed in `cargo test` on 2026-03-11.
- [x] Add remaining literals needed by compiler code: chars, floats, hex/bin/oct ints, and escaped string forms. Evidence: `stage0_rs/src/lexer/token.rs` now defines `Float` and `Char`, `stage0_rs/src/lexer/mod.rs` now lexes decimal/exponent floats, prefixed integers, char literals, `\xNN`, `\u{...}`, `\r`, and `\0`; `lexer::tests::lexes_prefixed_numbers_floats_chars_and_nested_block_comments` and `lexer::tests::rejects_invalid_prefixed_and_exponent_numbers` passed in `cargo test` on 2026-03-11.
- [x] Add remaining keywords used by the language and compiler sources: `enum`, `if`, `then`, `else`, `elsif`, `match`, `when`, `pub`, `module`, `mod`, `const`, `type`, `extern`, `return`, `break`, `next`, `mut`, `where`, `as`, `while`, `for`, `in`, `do`, `unless`, `until`, and contract/effect keywords. Evidence: `stage0_rs/src/lexer/token.rs` and `stage0_rs/src/lexer/mod.rs` now recognize the full reserved-keyword set currently needed by the grammar slice in `docs/grammar.md`; `lexer::tests::lexes_extended_keyword_and_operator_surface` passed in `cargo test` on 2026-03-11, and current golden failures have advanced to parser-level handling of `while`, `match`, `module`, `pre`, `budget`, and `unless` rather than lexical rejection.

### G. Type System And Declaration Surface Still Missing
- [x] Parse generic parameter lists on structs, enums, traits, impls, and functions. Evidence: `stage0_rs/src/ast/decl.rs` now models `TypeParam`, `stage0_rs/src/parser/mod.rs` parses bounded generic parameter lists across declaration forms, and the golden scan now advances beyond earlier generic-header failures to `supported=25 unsupported=5` on 2026-03-11.
- [x] Parse generic type application and path-qualified types such as `Option[Int]`, `Result[T]`, and `std::core::Option`. Evidence: `stage0_rs/src/parser/mod.rs` and `stage0_rs/src/ast/types.rs` now carry bracketed type args, path-qualified names, tuple types, and function-pointer types; the scan no longer fails first on basic type-application syntax.
- [x] Add enum declarations and variant payload shapes, including zero-payload and tuple-style variants. Evidence: `stage0_rs/src/ast/decl.rs`, `stage0_rs/src/parser/mod.rs`, and `stage0_rs/src/sema/{env.rs,mod.rs}` now model enum declarations, payload variants, variant constructor inference, and variant-pattern binding; `match` and enum fixtures now parse/analyze further instead of stopping at enum syntax.
- [x] Add `pub`, `type`, `module/mod`, and broader declaration visibility surface. Evidence: `stage0_rs/src/ast/decl.rs`, `stage0_rs/src/parser/mod.rs`, and `stage0_rs/src/codegen/mod.rs` now carry visibility on declarations, parse `module` / `mod` blocks and `type` aliases, and emit those forms; `golden/frontend_06.tg` now advances into later type-surface failures instead of stopping at `KeywordModule`.
- [x] Add trait inheritance, where clauses, type bounds, and function-pointer types. Evidence: `stage0_rs/src/ast/{decl.rs,types.rs}`, `stage0_rs/src/parser/mod.rs`, and `stage0_rs/src/sema/{env.rs,mod.rs}` now model supertraits, declaration/function where clauses, bounded type params, and `fn(...) -> ...` types; validation stayed green with `cargo test` and `cargo clippy --all-targets --all-features -- -D warnings` on 2026-03-11.
- [ ] Add the remaining declaration surface: nested-list `use` parsing as structure rather than opaque text, plus trait default-method / associated-type semantics beyond the current parser-first shape. Evidence: `const` and `extern` are already implemented, but richer imported-declaration semantics still need first-class lowering.

### H. Expression, Pattern, And Control-Flow Surface Still Missing
- [x] Add core range/tuple/container expression forms and precedence needed by the current corpus. Evidence: `stage0_rs/src/ast/{expr.rs,types.rs}`, `stage0_rs/src/parser/mod.rs`, and `stage0_rs/src/sema/mod.rs` now carry range expressions, tuple expressions/types, array literals, indexing, tuple destructuring in `let`, and `for .. in` over arrays/ranges; `cargo run -- scan ../golden` improved to `supported=25 unsupported=5` on 2026-03-11.
- [x] Finish `match` / `when` and richer pattern syntax for the currently failing fixture slice, including literal, tuple, binding, wildcard, and payload variant patterns plus inline `when ... then ...` forms. Evidence: `stage0_rs/src/ast/expr.rs`, `stage0_rs/src/parser/mod.rs`, and `stage0_rs/src/sema/mod.rs` now implement `Expr::Match`, `MatchArm`, and generalized `Pattern`; scan failures have moved past earlier `KeywordMatch` blockers.
- [x] Add default-parameter parsing and command-style single-argument call forms used in test-like fixtures. Evidence: `Param.default_value` plus parser support now exist in `stage0_rs/src/ast/decl.rs` and `stage0_rs/src/parser/mod.rs`, and command-style `assert expr` parsing now advances `golden/compiler_module_tests.tg` and `golden/stdlib_tests.tg` beyond their earlier statement-separator failures.
- [ ] Add slicing and the remaining collection-style expression chains. Evidence: closures are now implemented end to end across `stage0_rs/src/ast/expr.rs`, `stage0_rs/src/parser/mod.rs`, and `stage0_rs/src/sema/mod.rs`, and `golden/frontend_05.tg` is supported in the latest verified `cargo run -- scan ../golden` result (`supported=25 unsupported=5`).
- [ ] Finish the remaining statement/control-flow surface: `break`, `next` as control flow, module-local annotations in executable blocks, and the remaining separator/recovery cases in compiler-heavy fixtures. Evidence: current unsupported files still fail in these later parser corners after `for`, `match`, ranges, and defaults were wired.
- [ ] Add block-scoped contract and guard clauses (`pre`, `post`, `invariant`, `guard`) plus `try`/`catch`/`finally` once the base control-flow surface is in place. Evidence: grammar requires them and full self-host coverage will eventually need them.

### I. Semantic And Name-Resolution Surface Still Missing
- [ ] Add real path resolution for `use`, `crate`, `super`, `self`, and qualified names. Evidence: `stage0_rs/src/sema/env.rs`, `stage0_rs/src/sema/mod.rs`, and `stage0_rs/src/driver.rs` now carry alias maps, type-alias maps, qualified symbol registration, collect-without-validate env construction, alias-aware lookup/merge plumbing, and broader builtin method routing, but strict validation is still red on imported compiler symbols such as `MirModule`, `ResolvedSymbol`, and qualified enum variants like `ItemKind::Function`, so the full path-resolution gate is not closed yet.
- [ ] Finish generic type checking and substitution across all declaration and expression families. Evidence: generic functions, generic structs/enums, generic type application, and enum constructor inference are now partially implemented, but full compiler coverage still needs broader substitution and module-aware instantiation.
- [ ] Finish enum and control-flow semantics: full pattern typing, exhaustiveness checks, and `match` typing beyond the current `if` / `if let` / constructor subset. Evidence: enum-pattern identity is now more robust, but `cargo run -- codegen-scan ../tg_compiler` is still red on `match`-family typing failures such as `match arms must produce the same type`, missing qualified variants like `GraphKind::Call`, and unresolved variant lookups such as `ItemKind::Function` / `ItemKind::Impl` on 2026-03-11.
- [ ] Add assignment semantics, mutability enforcement, borrow/reference rules, and typed receiver handling beyond the current `self` field-access subset. Evidence: mutable bindings and reference expressions are now parsed and typed, and typed receiver handling was extended for more builtin/string/array methods, but `cargo run -- codegen-scan ../tg_compiler` is still red on assignment and borrow failures such as `assignment requires mutable base 'e'`, `assignment requires mutable base 'b'`, `call argument expected &Expr, found Box[Expr]`, and `unary '*' requires a reference operand, found Int` on 2026-03-11.
- [x] Add module-aware multi-file program analysis so imported compiler modules can be resolved together rather than one file at a time. Evidence: `stage0_rs/src/driver.rs` now builds a shared semantic environment across a scanned directory, and `cargo run -- scan ../tg_compiler` reports `supported=34 unsupported=0` on 2026-03-11.

### J. Self-Hosting Execution Gates
- [x] Extend the scan harness beyond `golden/` to a staged `tg_compiler/*.tg` parse-and-analyze sweep. Evidence: `cargo run -- scan ../tg_compiler` now reports `supported=34 unsupported=0` on 2026-03-11.
- [ ] Add fail-first regression tests for each newly unlocked language family before claiming coverage. Evidence: current work has been reliable only when driven by explicit tests and real fixtures.
- [x] Reach the first measured milestone of a fully green `golden/` corpus. Evidence: `cd stage0_rs && cargo run -- scan ../golden` now reports `supported=30 unsupported=0` on 2026-03-11.
- [ ] Continue from `golden/` green and `tg_compiler` analyze green to codegen/bootstrap validation. Evidence: the end-to-end gate is wired and was revalidated after the latest sema/env/intrinsic fixes, but it is still red: `cargo run -- codegen-scan ../golden` reports `supported=11 unsupported=19`, and `cargo run -- codegen-scan ../tg_compiler` reports `supported=0 unsupported=34` on 2026-03-11.

