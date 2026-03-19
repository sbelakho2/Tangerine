use std::collections::BTreeSet;
use std::fs;
use std::path::Path;
use std::path::PathBuf;
use std::rc::Rc;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::ast::decl::{
    Decl, EnumDecl, FieldDecl, FunctionDecl, FunctionSig, Module, Param, StructDecl, TraitDecl, TypeAliasDecl,
    TypeParam, VariantDecl, WherePredicate,
};
use crate::ast::expr::{BlockBody, FunctionBody};
use crate::ast::types::TypeRef;
use crate::codegen::{emit_rust_with_support_sources, rustc_build_binary, rustc_check, SupportSourceModule};
use crate::error::Stage0Error;
use crate::lexer::lex;
use crate::parser::Parser;
use crate::sema::{analyze_with_env, SemanticEnv};
use crate::span::Span;

pub type FileAnalysis = (PathBuf, Result<Module, Stage0Error>);
pub type CodegenAnalysis = (PathBuf, Result<(), Stage0Error>);

fn vm_size_kb() -> u64 {
    std::fs::read_to_string("/proc/self/status")
        .ok()
        .and_then(|s| {
            for line in s.lines() {
                if line.starts_with("VmSize:") {
                    return line.split_whitespace().nth(1)?.parse::<u64>().ok();
                }
            }
            None
        })
        .unwrap_or(0)
}

/// Ask glibc to release unused heap pages back to the OS.
///
/// The support-environment build loop allocates and frees many intermediate
/// objects.  glibc's `brk`-based allocator never shrinks the data segment,
/// so the virtual-memory footprint can grow to ~2 GB even though peak live
/// data is only ~35 MB.  A single `malloc_trim(0)` call after the heavy
/// allocation phase lets glibc `MADV_DONTNEED` the freed pages, reclaiming
/// address space for the analysis phase.
#[cfg(target_os = "linux")]
fn trim_heap() {
    unsafe {
        extern "C" {
            fn malloc_trim(pad: usize) -> i32;
        }
        malloc_trim(0);
    }
}

#[cfg(not(target_os = "linux"))]
fn trim_heap() {}

fn brk_addr() -> String {
    extern "C" {
        fn sbrk(increment: isize) -> *mut u8;
    }
    let addr = unsafe { sbrk(0) };
    format!("{addr:?}")
}


/// Read, lex, parse, and analyze a Tangerine source file.
///
/// When the file lives inside a repository that contains a `std/` folder,
/// standard-library definitions are loaded automatically so that `use std::*`
/// imports resolve.
///
/// # Errors
/// Returns `Stage0Error` if the file cannot be read or if any compiler phase fails.
pub fn analyze_module_from_path(path: &Path) -> Result<(Module, SemanticEnv), Stage0Error> {
    let module = parse_module_from_path(path)?;
    if std::env::var("TG_TRACE").is_ok() {
        eprintln!("[driver] after parse: vm={} KB brk={}", vm_size_kb(), brk_addr());
    }
    let support_env = build_support_env_for_file(path)?;
    if std::env::var("TG_TRACE").is_ok() {
        eprintln!("[driver] after build_support_env: vm={} KB brk={} env_items={} impls={}", vm_size_kb(), brk_addr(),
            support_env.structs.len() + support_env.enums.len() + support_env.traits.len()
            + support_env.functions.len() + support_env.type_aliases.len()
            + support_env.consts.len() + support_env.globals.len()
            + support_env.aliases.len() + support_env.impls.len(),
            support_env.impls.len());
    }
    let mut file_env = SemanticEnv::collect(&module).map(normalize_semantic_env_aliases)?;
    if std::env::var("TG_TRACE").is_ok() {
        eprintln!("[driver] after file_env collect: vm={} KB brk={} file_items={}", vm_size_kb(), brk_addr(),
            file_env.structs.len() + file_env.enums.len() + file_env.traits.len()
            + file_env.functions.len() + file_env.type_aliases.len()
            + file_env.consts.len() + file_env.globals.len()
            + file_env.aliases.len() + file_env.impls.len());
    }
    merge_semantic_env(&mut file_env, &support_env, false);
    if std::env::var("TG_TRACE").is_ok() {
        eprintln!("[driver] after merge: vm={} KB brk={} merged_items={} impls={}", vm_size_kb(), brk_addr(),
            file_env.structs.len() + file_env.enums.len() + file_env.traits.len()
            + file_env.functions.len() + file_env.type_aliases.len()
            + file_env.consts.len() + file_env.globals.len()
            + file_env.aliases.len() + file_env.impls.len(),
            file_env.impls.len());
    }
    drop(support_env);
    // After building the support environment, the heap is heavily fragmented
    // (glibc brk grows to ~2 GB despite only ~35 MB peak live data).
    // Force glibc to release unused heap pages back to the OS so that
    // subsequent allocations during analysis can succeed within ulimit -v.
    trim_heap();
    if std::env::var("TG_TRACE").is_ok() {
        eprintln!("[driver] after drop support_env + trim: vm={} KB brk={}", vm_size_kb(), brk_addr());
    }
    analyze_with_env(&module, &file_env)?;
    Ok((module, file_env))
}

/// Read, lex, parse, analyze, emit Rust, and validate the generated Rust for a Tangerine file.
/// 
/// # Errors
/// Returns `Stage0Error` if any compiler phase fails or if generated Rust fails `rustc` metadata validation.
pub fn codegen_module_from_path(path: &Path) -> Result<(), Stage0Error> {
    let (module, env) = analyze_module_from_path(path)?;
    let support_sources = build_support_source_modules_for_file(path)?;
    let rust = emit_rust_with_support_sources(&module, &env, &support_sources)?;
    let temp_path = write_temp_rust_file(path, &rust)?;
    let check_result = rustc_check(&temp_path);
    if !should_keep_codegen_artifacts() {
        remove_codegen_artifacts(&temp_path);
    }
    check_result
}

/// Read, lex, and parse a Tangerine source file.
///
/// # Errors
/// Returns `Stage0Error` if the file cannot be read or the source cannot be parsed.
pub fn parse_module_from_path(path: &Path) -> Result<Module, Stage0Error> {
    let source = fs::read_to_string(path).map_err(|error| {
        Stage0Error::parse(
            Span::new(1, 1, 0, 0),
            format!("failed to read {}: {error}", path.display()),
        )
    })?;
    let tokens = lex(&source)?;
    Parser::new(tokens).parse_module()
}

/// Analyze every `.tg` file directly inside a repository folder and return successes and failures.
///
/// Memory-efficient: environments are re-collected from ASTs on demand rather
/// than stored simultaneously, keeping peak memory close to `shared_env` + one
/// file env instead of `shared_env` + N file envs.
///
/// # Errors
/// Returns `Stage0Error` if the directory itself cannot be read.
pub fn analyze_directory(path: &Path) -> Result<Vec<FileAnalysis>, Stage0Error> {
    let parsed = parse_directory_modules(path)?;
    let mut shared_env = build_support_env(path)?;

    // Phase 1: qualify and merge each file env + count raw names (one at a time).
    let mut raw_name_counts = RawNameCounts::default();
    for (file_path, result) in &parsed {
        if let Ok(module) = result {
            if let Ok(env) = SemanticEnv::collect(module).map(normalize_semantic_env_aliases) {
                merge_semantic_env(&mut shared_env, &qualify_semantic_env(&env, file_path), false);
                count_raw_names(&mut raw_name_counts.structs, env.structs.keys());
                count_raw_names(&mut raw_name_counts.enums, env.enums.keys());
                count_raw_names(&mut raw_name_counts.traits, env.traits.keys());
                count_raw_names(&mut raw_name_counts.functions, env.functions.keys());
                count_raw_names(&mut raw_name_counts.type_aliases, env.type_aliases.keys());
                count_raw_names(&mut raw_name_counts.consts, env.consts.keys());
                count_raw_names(&mut raw_name_counts.globals, env.globals.keys());
            }
        }
    }


    // Phase 2: merge unique raw names (one env at a time, re-collected).
    for (_file_path, result) in &parsed {
        if let Ok(module) = result {
            if let Ok(env) = SemanticEnv::collect(module).map(normalize_semantic_env_aliases) {
                merge_unique_raw_semantic_env(&mut shared_env, &env, &raw_name_counts);
            }
        }
    }

    // Phase 3: analyze each file (re-collect file env as needed).
    let mut results = Vec::with_capacity(parsed.len());
    for (_i, (file_path, result)) in parsed.into_iter().enumerate() {
        let analyzed = match result {
            Ok(module) => {
                match SemanticEnv::collect(&module).map(normalize_semantic_env_aliases) {
                    Ok(file_specific_env) => {
                        let snapshot_keys = snapshot_new_keys(&shared_env, &file_specific_env);
                        merge_semantic_env(&mut shared_env, &file_specific_env, true);
                        let result = analyze_with_env(&module, &shared_env).map(|()| module);
                        remove_snapshot_keys(&mut shared_env, &snapshot_keys);
                        result
                    }
                    Err(_) => Ok(module),
                }
            }
            Err(error) => Err(error),
        };
        results.push((file_path, analyzed));
    }

    Ok(results)
}

/// Run strict end-to-end validation over every `.tg` file directly inside a directory.
///
/// Each file is parsed, analyzed against a merged repository environment,
/// emitted to Rust, and checked with `rustc` in metadata-only mode.
///
/// # Errors
/// Returns `Stage0Error` if the directory cannot be read.
pub fn codegen_directory(path: &Path) -> Result<Vec<CodegenAnalysis>, Stage0Error> {
    let parsed = parse_directory_modules(path)?;

    let mut merged_env = build_support_env(path)?;

    // Phase 1: qualify and merge + count raw names (one env at a time).
    let mut raw_name_counts = RawNameCounts::default();
    for (file_path, parsed_module) in &parsed {
        if let Ok(module) = parsed_module {
            if let Ok(env) = SemanticEnv::collect(module).map(normalize_semantic_env_aliases) {
                merge_semantic_env(&mut merged_env, &qualify_semantic_env(&env, file_path), false);
                count_raw_names(&mut raw_name_counts.structs, env.structs.keys());
                count_raw_names(&mut raw_name_counts.enums, env.enums.keys());
                count_raw_names(&mut raw_name_counts.traits, env.traits.keys());
                count_raw_names(&mut raw_name_counts.functions, env.functions.keys());
                count_raw_names(&mut raw_name_counts.type_aliases, env.type_aliases.keys());
                count_raw_names(&mut raw_name_counts.consts, env.consts.keys());
                count_raw_names(&mut raw_name_counts.globals, env.globals.keys());
            }
        }
    }

    // Phase 2: merge unique raw names (re-collect one at a time).
    for (_file_path, parsed_module) in &parsed {
        if let Ok(module) = parsed_module {
            if let Ok(env) = SemanticEnv::collect(module).map(normalize_semantic_env_aliases) {
                merge_unique_raw_semantic_env(&mut merged_env, &env, &raw_name_counts);
            }
        }
    }

    // Phase 3: analyze + codegen each file (re-collect env as needed).
    let mut results = Vec::with_capacity(parsed.len());
    for (file_path, parsed_module) in parsed {
        let result = match parsed_module {
            Ok(module) => {
                match SemanticEnv::collect(&module).map(normalize_semantic_env_aliases) {
                    Ok(file_specific_env) => {
                        let snapshot_keys = snapshot_new_keys(&merged_env, &file_specific_env);
                        merge_semantic_env(&mut merged_env, &file_specific_env, true);
                        let support_sources = build_support_source_modules_for_file(&file_path)?;
                        let result = analyze_with_env(&module, &merged_env)
                            .and_then(|()| emit_rust_with_support_sources(&module, &merged_env, &support_sources))
                            .and_then(|rust| {
                                let temp_path = write_temp_rust_file(&file_path, &rust)?;
                                let check_result = rustc_check(&temp_path);
                                remove_codegen_artifacts(&temp_path);
                                check_result
                            });
                        remove_snapshot_keys(&mut merged_env, &snapshot_keys);
                        result
                    }
                    Err(error) => Err(error),
                }
            }
            Err(error) => Err(error),
        };
        results.push((file_path, result));
    }

    Ok(results)
}

/// Build a Tangerine directory as a native executable.
///
/// The directory entrypoint follows Tangerine package conventions: prefer
/// `main.tg`, then fall back to `lib.tg`, then to the sole `.tg` file when
/// the directory contains exactly one source file.
///
/// # Errors
/// Returns `Stage0Error` if the directory has no valid entrypoint, if the
/// entry module fails compilation, or if the generated Rust binary fails to
/// build with `rustc`.
pub fn build_directory_binary(path: &Path, output: &Path) -> Result<(), Stage0Error> {
    let entry_path = select_binary_entrypoint(path)?;
    let (module, env) = analyze_module_from_path(&entry_path)?;
    let support_sources = build_support_source_modules_for_file(&entry_path)?;
    let rust = emit_rust_with_support_sources(&module, &env, &support_sources)?;
    let generated_path = write_temp_rust_file(&entry_path, &rust)?;
    let wrapper_path = write_binary_wrapper_file(&entry_path, &module, &generated_path)?;

    if let Some(parent) = output.parent().filter(|parent| !parent.as_os_str().is_empty()) {
        fs::create_dir_all(parent).map_err(|error| {
            Stage0Error::codegen(
                Span::new(1, 1, 0, 0),
                format!("failed to create output directory {}: {error}", parent.display()),
            )
        })?;
    }

    let build_result = rustc_build_binary(&wrapper_path, output);
    if !should_keep_codegen_artifacts() {
        let _ = fs::remove_file(&wrapper_path);
        remove_codegen_artifacts(&generated_path);
    }
    build_result
}

fn parse_directory_modules(path: &Path) -> Result<Vec<FileAnalysis>, Stage0Error> {
    let mut parsed = Vec::new();
    let entries = fs::read_dir(path).map_err(|error| {
        Stage0Error::parse(
            Span::new(1, 1, 0, 0),
            format!("failed to read directory {}: {error}", path.display()),
        )
    })?;
    for entry in entries {
        let entry = entry.map_err(|error| {
            Stage0Error::parse(Span::new(1, 1, 0, 0), format!("failed to read directory entry: {error}"))
        })?;
        let file_path = entry.path();
        if file_path.extension().and_then(|ext| ext.to_str()) == Some("tg") {
            parsed.push((file_path.clone(), parse_module_from_path(&file_path)));
        }
    }
    parsed.sort_by(|left, right| left.0.cmp(&right.0));
    Ok(parsed)
}

fn build_support_env(path: &Path) -> Result<SemanticEnv, Stage0Error> {
    let mut support_env = SemanticEnv::default();
    let Some(repo_root) = path.parent() else {
        return Ok(support_env);
    };
    load_support_dirs(&mut support_env, repo_root, path)?;
    Ok(support_env)
}

/// Build a support environment for analysing a single `.tg` file.
/// Walks up the directory tree from the file to find a repo root that
/// contains a `std/` folder.
fn build_support_env_for_file(file_path: &Path) -> Result<SemanticEnv, Stage0Error> {
    let mut support_env = SemanticEnv::default();
    let abs = file_path
        .canonicalize()
        .unwrap_or_else(|_| file_path.to_path_buf());
    let mut candidate = abs.parent();
    while let Some(dir) = candidate {
        if dir.join("std").is_dir() {
            load_support_dirs(&mut support_env, dir, &abs)?;
            break;
        }
        candidate = dir.parent();
    }
    Ok(support_env)
}

pub(crate) fn build_support_source_modules_for_file(file_path: &Path) -> Result<Vec<SupportSourceModule>, Stage0Error> {
    let abs = file_path
        .canonicalize()
        .unwrap_or_else(|_| file_path.to_path_buf());
    let mut candidate = abs.parent();
    while let Some(dir) = candidate {
        if dir.join("std").is_dir() {
            return load_support_source_dirs(dir, &abs);
        }
        candidate = dir.parent();
    }
    Ok(Vec::new())
}

fn load_support_source_dirs(repo_root: &Path, caller_path: &Path) -> Result<Vec<SupportSourceModule>, Stage0Error> {
    let caller_canonical = caller_path.canonicalize().unwrap_or_else(|_| caller_path.to_path_buf());
    let mut support_sources = Vec::new();
    for support_name in ["std", "tg_compiler"] {
        let support_dir = repo_root.join(support_name);
        if !support_dir.is_dir() {
            continue;
        }
        let support_canonical = support_dir.canonicalize().unwrap_or_else(|_| support_dir.clone());
        if support_canonical == caller_canonical {
            continue;
        }
        for file_path in sorted_tg_paths(&support_dir)? {
            let file_canonical = file_path.canonicalize().unwrap_or_else(|_| file_path.clone());
            if file_canonical == caller_canonical {
                continue;
            }
            let module = parse_module_from_path(&file_path)?;
            support_sources.push(SupportSourceModule {
                prefixes: support_prefixes_for_module(&file_path, &module),
                module,
            });
        }
    }
    Ok(support_sources)
}

fn support_prefixes_for_module(file_path: &Path, module: &Module) -> Vec<String> {
    if has_explicit_top_level_module_decl(module) {
        return vec![String::new()];
    }

    let Some(stem) = file_path.file_stem().and_then(|stem| stem.to_str()) else {
        return Vec::new();
    };
    let mut prefixes = vec![stem.to_string()];
    if let Some(dir_name) = file_path
        .parent()
        .and_then(|parent| parent.file_name())
        .and_then(|name| name.to_str())
    {
        prefixes.push(format!("{dir_name}::{stem}"));
        if stem == "lib" {
            prefixes.push(dir_name.to_string());
        }
    }
    prefixes
}

fn has_explicit_top_level_module_decl(module: &Module) -> bool {
    module
        .decls
        .iter()
        .any(|decl| matches!(decl, Decl::Module(module_decl) if module_decl.name.contains("::")))
}

fn load_support_dirs(
    support_env: &mut SemanticEnv,
    repo_root: &Path,
    caller_path: &Path,
) -> Result<(), Stage0Error> {
    let caller_canonical = caller_path.canonicalize().unwrap_or_else(|_| caller_path.to_path_buf());
    for support_name in ["std", "tg_compiler"] {
        let support_dir = repo_root.join(support_name);
        if !support_dir.is_dir() {
            continue;
        }
        let support_canonical = support_dir.canonicalize().unwrap_or_else(|_| support_dir.clone());
        if support_canonical == caller_canonical {
            continue;
        }

        // Collect sorted file paths first (lightweight).
        let file_paths = sorted_tg_paths(&support_dir)?;
        let mut raw_counts = RawNameCounts::default();

        // First pass: parse one file at a time, collect qualified names and count raw names.
        for (i, file_path) in file_paths.iter().enumerate() {
            let file_canonical = file_path.canonicalize().unwrap_or_else(|_| file_path.clone());
            if file_canonical == caller_canonical {
                continue;
            }
            if let Ok(module) = parse_module_from_path(file_path) {
                if let Ok(env) = SemanticEnv::collect(&module) {
                    let env = normalize_semantic_env_aliases(env);
                    merge_semantic_env(support_env, &qualify_semantic_env(&env, file_path), false);
                    if support_name == "std" {
                        merge_semantic_env(support_env, &env, false);
                    } else {
                        count_raw_names(&mut raw_counts.structs, env.structs.keys());
                        count_raw_names(&mut raw_counts.enums, env.enums.keys());
                        count_raw_names(&mut raw_counts.traits, env.traits.keys());
                        count_raw_names(&mut raw_counts.functions, env.functions.keys());
                        count_raw_names(&mut raw_counts.type_aliases, env.type_aliases.keys());
                        count_raw_names(&mut raw_counts.consts, env.consts.keys());
                        count_raw_names(&mut raw_counts.globals, env.globals.keys());
                    }
                }
            }
            if std::env::var("TG_TRACE").is_ok() {
                let vm = vm_size_kb();
                eprintln!("[driver] pass1 {support_name} {}/{}: vm={vm} KB – {}", i + 1, file_paths.len(), file_path.file_name().unwrap_or_default().to_string_lossy());
            }
            // module and env dropped here — only one alive at a time
        }
        trim_heap();

        // Second pass for tg_compiler: merge unique raw names (re-parse one at a time).
        if support_name == "tg_compiler" {
            for (i, file_path) in file_paths.iter().enumerate() {
                let file_canonical = file_path.canonicalize().unwrap_or_else(|_| file_path.clone());
                if file_canonical == caller_canonical {
                    continue;
                }
                if let Ok(module) = parse_module_from_path(file_path) {
                    if let Ok(env) = SemanticEnv::collect(&module) {
                        let env = normalize_semantic_env_aliases(env);
                        merge_unique_raw_semantic_env(support_env, &env, &raw_counts);
                    }
                }
                if std::env::var("TG_TRACE").is_ok() {
                    let vm = vm_size_kb();
                    eprintln!("[driver] pass2 {support_name} {}/{}: vm={vm} KB – {}", i + 1, file_paths.len(), file_path.file_name().unwrap_or_default().to_string_lossy());
                }
            }
            trim_heap();
        }
    }

    Ok(())
}

/// Collect sorted `.tg` file paths from a directory without parsing.
fn sorted_tg_paths(dir: &Path) -> Result<Vec<PathBuf>, Stage0Error> {
    let entries = fs::read_dir(dir).map_err(|error| {
        Stage0Error::parse(
            Span::new(1, 1, 0, 0),
            format!("failed to read directory {}: {error}", dir.display()),
        )
    })?;
    let mut paths = Vec::new();
    for entry in entries {
        let entry = entry.map_err(|error| {
            Stage0Error::parse(Span::new(1, 1, 0, 0), format!("failed to read directory entry: {error}"))
        })?;
        let path = entry.path();
        if path.extension().and_then(|ext| ext.to_str()) == Some("tg") {
            paths.push(path);
        }
    }
    paths.sort();
    Ok(paths)
}

fn qualify_semantic_env(env: &SemanticEnv, file_path: &Path) -> SemanticEnv {
    let Some(stem) = file_path.file_stem().and_then(|stem| stem.to_str()) else {
        return env.clone();
    };
    let mut qualified = SemanticEnv::default();
    let mut prefixes = vec![stem.to_string()];
    if let Some(dir_name) = file_path
        .parent()
        .and_then(|parent| parent.file_name())
        .and_then(|name| name.to_str())
    {
        prefixes.push(format!("{dir_name}::{stem}"));
        if stem == "lib" {
            prefixes.push(dir_name.to_string());
        }
    }

    let local_type_names = env
        .structs
        .keys()
        .chain(env.enums.keys())
        .chain(env.traits.keys())
        .chain(env.type_aliases.keys())
        .filter(|name| !name.contains("::"))
        .cloned()
        .collect::<BTreeSet<_>>();
    let aliases = env.aliases.clone();

    // Deduplicate impls within the source env first by (trait_name, for_type) key
    let mut seen_impl_keys: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();
    let mut unique_impls: Vec<crate::sema::env::ImplInfo> = Vec::new();
    for impl_info in env.impls.iter() {
        let key = format!("{} for {}", impl_info.trait_name, impl_info.for_type);
        if seen_impl_keys.insert(key) {
            unique_impls.push(impl_info.clone());
        }
    }

    for prefix in &prefixes {
        insert_prefixed_structs(Rc::make_mut(&mut qualified.structs), &env.structs, prefix, &local_type_names, &aliases);
        insert_prefixed_enums(Rc::make_mut(&mut qualified.enums), &env.enums, prefix, &local_type_names, &aliases);
        insert_prefixed_traits(Rc::make_mut(&mut qualified.traits), &env.traits, prefix, &local_type_names, &aliases);
        insert_prefixed_functions(Rc::make_mut(&mut qualified.functions), &env.functions, prefix, &local_type_names, &aliases);
        insert_prefixed_type_aliases(Rc::make_mut(&mut qualified.type_aliases), &env.type_aliases, prefix, &local_type_names, &aliases);
        insert_prefixed_consts(Rc::make_mut(&mut qualified.consts), &env.consts, prefix, &local_type_names, &aliases);
        insert_prefixed_globals(Rc::make_mut(&mut qualified.globals), &env.globals, prefix, &local_type_names, &aliases);
        insert_prefixed_aliases(Rc::make_mut(&mut qualified.aliases), &env.aliases, prefix, &local_type_names, &aliases);
        for impl_info in unique_impls.iter() {
            Rc::make_mut(&mut qualified.impls).push(qualify_impl_info(impl_info, prefix, &local_type_names, &aliases));
        }
    }

    qualified
}

/// Unwrap an `Rc`, returning the inner value if the reference count is one,
/// or cloning the contents otherwise.
fn unwrap_rc<T: Clone>(rc: Rc<T>) -> T {
    Rc::try_unwrap(rc).unwrap_or_else(|rc| (*rc).clone())
}

fn compact_function_body(body: &FunctionBody) -> FunctionBody {
    match body {
        FunctionBody::Declaration { span } => FunctionBody::Declaration { span: *span },
        FunctionBody::Block(block) => FunctionBody::Block(BlockBody {
            stmts: Vec::new(),
            tail: None,
            span: block.span,
        }),
    }
}

fn normalize_semantic_env_aliases(env: SemanticEnv) -> SemanticEnv {
    let aliases = env.aliases.clone();
    let local_type_names = BTreeSet::new();
    let empty_prefix = "";

    SemanticEnv {
        structs: Rc::new(unwrap_rc(env.structs)
            .into_iter()
            .map(|(name, decl)| {
                let normalized = StructDecl {
                    name: decl.name,
                    public: decl.public,
                    type_params: qualify_type_params(&decl.type_params, empty_prefix, &local_type_names, &aliases),
                    where_clause: qualify_where_clause(&decl.where_clause, empty_prefix, &local_type_names, &aliases),
                    fields: qualify_fields(&decl.fields, empty_prefix, &local_type_names, &aliases),
                    span: decl.span,
                };
                (name, normalized)
            })
            .collect()),
        enums: Rc::new(unwrap_rc(env.enums)
            .into_iter()
            .map(|(name, decl)| {
                let normalized = EnumDecl {
                    name: decl.name,
                    public: decl.public,
                    type_params: qualify_type_params(&decl.type_params, empty_prefix, &local_type_names, &aliases),
                    where_clause: qualify_where_clause(&decl.where_clause, empty_prefix, &local_type_names, &aliases),
                    variants: decl
                        .variants
                        .iter()
                        .map(|variant| VariantDecl {
                            name: variant.name.clone(),
                            tuple_fields: variant
                                .tuple_fields
                                .iter()
                                .map(|field| qualify_type_ref(field, empty_prefix, &local_type_names, &aliases))
                                .collect(),
                            named_fields: qualify_fields(&variant.named_fields, empty_prefix, &local_type_names, &aliases),
                            span: variant.span,
                        })
                        .collect(),
                    span: decl.span,
                };
                (name, normalized)
            })
            .collect()),
        traits: Rc::new(unwrap_rc(env.traits)
            .into_iter()
            .map(|(name, decl)| {
                let normalized = TraitDecl {
                    name: decl.name,
                    public: decl.public,
                    type_params: qualify_type_params(&decl.type_params, empty_prefix, &local_type_names, &aliases),
                    supertraits: decl
                        .supertraits
                        .iter()
                        .map(|trait_name| qualify_named_symbol(trait_name, empty_prefix, &local_type_names, &aliases))
                        .collect(),
                    where_clause: qualify_where_clause(&decl.where_clause, empty_prefix, &local_type_names, &aliases),
                    methods: decl
                        .methods
                        .iter()
                        .map(|method| FunctionDecl {
                            sig: qualify_function_sig(&method.sig, empty_prefix, &local_type_names, &aliases),
                            clauses: method.clauses.clone(),
                            body: compact_function_body(&method.body),
                            span: method.span,
                        })
                        .collect(),
                    associated_types: decl
                        .associated_types
                        .iter()
                        .map(|assoc| TypeAliasDecl {
                            name: assoc.name.clone(),
                            public: assoc.public,
                            target: assoc
                                .target
                                .as_ref()
                                .map(|target| qualify_type_ref(target, empty_prefix, &local_type_names, &aliases)),
                            span: assoc.span,
                        })
                        .collect(),
                    span: decl.span,
                };
                (name, normalized)
            })
            .collect()),
        functions: Rc::new(unwrap_rc(env.functions)
            .into_iter()
            .map(|(name, sig)| (name, qualify_function_sig(&sig, empty_prefix, &local_type_names, &aliases)))
            .collect()),
        type_aliases: Rc::new(unwrap_rc(env.type_aliases)
            .into_iter()
            .map(|(name, ty)| (name, qualify_type_ref(&ty, empty_prefix, &local_type_names, &aliases)))
            .collect()),
        consts: Rc::new(unwrap_rc(env.consts)
            .into_iter()
            .map(|(name, ty)| (name, qualify_type_ref(&ty, empty_prefix, &local_type_names, &aliases)))
            .collect()),
        globals: Rc::new(unwrap_rc(env.globals)
            .into_iter()
            .map(|(name, global)| {
                (
                    name,
                    crate::sema::env::GlobalInfo {
                        ty: qualify_type_ref(&global.ty, empty_prefix, &local_type_names, &aliases),
                        mutable: global.mutable,
                    },
                )
            })
            .collect()),
        aliases: env.aliases,
        impls: Rc::new(env
            .impls
            .iter()
            .map(|impl_info| qualify_impl_info(impl_info, empty_prefix, &local_type_names, &aliases))
            .collect()),
        active_trait: env.active_trait,
        active_self_type: env.active_self_type,
        fn_return_type: None,
    }
}

fn is_self_referencing_alias(alias: &str, target: &str) -> bool {
    target.starts_with(alias)
        && target
            .get(alias.len()..)
            .is_some_and(|suffix| suffix.starts_with("::"))
}

fn resolve_imported_alias(
    name: &str,
    prefix: &str,
    aliases: &std::collections::BTreeMap<String, String>,
) -> String {
    if let Some(resolved) = aliases.get(name) {
        if !prefix.is_empty() && is_self_referencing_alias(name, resolved) {
            return format!("{prefix}::{resolved}");
        }
        return resolved.clone();
    }
    if let Some((head, tail)) = name.split_once("::") {
        if let Some(target) = aliases.get(head) {
            if !prefix.is_empty() && is_self_referencing_alias(head, target) {
                return format!("{prefix}::{name}");
            }
            return format!("{target}::{tail}");
        }
    }
    name.to_string()
}

fn qualify_named_symbol(
    name: &str,
    prefix: &str,
    local_type_names: &BTreeSet<String>,
    aliases: &std::collections::BTreeMap<String, String>,
) -> String {
    let resolved = resolve_imported_alias(name, prefix, aliases);
    if resolved != name {
        return resolved;
    }
    if name.contains("::") || !local_type_names.contains(name) {
        name.to_string()
    } else {
        format!("{prefix}::{name}")
    }
}

fn qualify_type_ref(
    ty: &TypeRef,
    prefix: &str,
    local_type_names: &BTreeSet<String>,
    aliases: &std::collections::BTreeMap<String, String>,
) -> TypeRef {
    match ty {
        TypeRef::Tuple { elements, span } => TypeRef::Tuple {
            elements: elements
                .iter()
                .map(|element| qualify_type_ref(element, prefix, local_type_names, aliases))
                .collect(),
            span: *span,
        },
        TypeRef::Array { element, len, span } => TypeRef::Array {
            element: Box::new(qualify_type_ref(element, prefix, local_type_names, aliases)),
            len: len.clone(),
            span: *span,
        },
        TypeRef::Named { name, type_args, span } => TypeRef::Named {
            name: qualify_named_symbol(name, prefix, local_type_names, aliases),
            type_args: type_args
                .iter()
                .map(|arg| qualify_type_ref(arg, prefix, local_type_names, aliases))
                .collect(),
            span: *span,
        },
        TypeRef::Function { params, return_type, span } => TypeRef::Function {
            params: params
                .iter()
                .map(|param| qualify_type_ref(param, prefix, local_type_names, aliases))
                .collect(),
            return_type: Box::new(qualify_type_ref(return_type, prefix, local_type_names, aliases)),
            span: *span,
        },
        TypeRef::DynTrait { trait_name, span } => TypeRef::DynTrait {
            trait_name: qualify_named_symbol(trait_name, prefix, local_type_names, aliases),
            span: *span,
        },
        TypeRef::Ref { inner, mutable, span } => TypeRef::Ref {
            inner: Box::new(qualify_type_ref(inner, prefix, local_type_names, aliases)),
            mutable: *mutable,
            span: *span,
        },
        _ => ty.clone(),
    }
}

fn qualify_type_params(
    type_params: &[TypeParam],
    prefix: &str,
    local_type_names: &BTreeSet<String>,
    aliases: &std::collections::BTreeMap<String, String>,
) -> Vec<TypeParam> {
    type_params
        .iter()
        .map(|param| TypeParam {
            name: param.name.clone(),
            bounds: param
                .bounds
                .iter()
                .map(|bound| qualify_named_symbol(bound, prefix, local_type_names, aliases))
                .collect(),
            span: param.span,
        })
        .collect()
}

fn qualify_where_clause(
    predicates: &[WherePredicate],
    prefix: &str,
    local_type_names: &BTreeSet<String>,
    aliases: &std::collections::BTreeMap<String, String>,
) -> Vec<WherePredicate> {
    predicates
        .iter()
        .map(|predicate| WherePredicate {
            ty: qualify_type_ref(&predicate.ty, prefix, local_type_names, aliases),
            bounds: predicate
                .bounds
                .iter()
                .map(|bound| qualify_named_symbol(bound, prefix, local_type_names, aliases))
                .collect(),
            span: predicate.span,
        })
        .collect()
}

fn qualify_fields(
    fields: &[FieldDecl],
    prefix: &str,
    local_type_names: &BTreeSet<String>,
    aliases: &std::collections::BTreeMap<String, String>,
) -> Vec<FieldDecl> {
    fields
        .iter()
        .map(|field| FieldDecl {
            public: field.public,
            name: field.name.clone(),
            ty: qualify_type_ref(&field.ty, prefix, local_type_names, aliases),
            span: field.span,
        })
        .collect()
}

fn qualify_function_sig(
    sig: &FunctionSig,
    prefix: &str,
    local_type_names: &BTreeSet<String>,
    aliases: &std::collections::BTreeMap<String, String>,
) -> FunctionSig {
    FunctionSig {
        name: sig.name.clone(),
        public: sig.public,
        type_params: qualify_type_params(&sig.type_params, prefix, local_type_names, aliases),
        params: sig
            .params
            .iter()
            .map(|param| Param {
                name: param.name.clone(),
                mutable: param.mutable,
                ty: qualify_type_ref(&param.ty, prefix, local_type_names, aliases),
                default_value: param.default_value.clone(),
                span: param.span,
            })
            .collect(),
        return_type: qualify_type_ref(&sig.return_type, prefix, local_type_names, aliases),
        where_clause: qualify_where_clause(&sig.where_clause, prefix, local_type_names, aliases),
        span: sig.span,
    }
}

fn insert_prefixed_structs(
    target: &mut std::collections::BTreeMap<String, StructDecl>,
    source: &std::collections::BTreeMap<String, StructDecl>,
    prefix: &str,
    local_type_names: &BTreeSet<String>,
    aliases: &std::collections::BTreeMap<String, String>,
) {
    for (name, decl) in source {
        if name.contains("::") {
            continue;
        }
        let qualified_name = format!("{prefix}::{name}");
        let _ = target.entry(qualified_name.clone()).or_insert_with(|| StructDecl {
            name: qualified_name,
            public: decl.public,
            type_params: qualify_type_params(&decl.type_params, prefix, local_type_names, aliases),
            where_clause: qualify_where_clause(&decl.where_clause, prefix, local_type_names, aliases),
            fields: qualify_fields(&decl.fields, prefix, local_type_names, aliases),
            span: decl.span,
        });
    }
}

fn insert_prefixed_enums(
    target: &mut std::collections::BTreeMap<String, EnumDecl>,
    source: &std::collections::BTreeMap<String, EnumDecl>,
    prefix: &str,
    local_type_names: &BTreeSet<String>,
    aliases: &std::collections::BTreeMap<String, String>,
) {
    for (name, decl) in source {
        if name.contains("::") {
            continue;
        }
        let qualified_name = format!("{prefix}::{name}");
        let _ = target.entry(qualified_name.clone()).or_insert_with(|| EnumDecl {
            name: qualified_name,
            public: decl.public,
            type_params: qualify_type_params(&decl.type_params, prefix, local_type_names, aliases),
            where_clause: qualify_where_clause(&decl.where_clause, prefix, local_type_names, aliases),
            variants: decl
                .variants
                .iter()
                .map(|variant| VariantDecl {
                    name: variant.name.clone(),
                    tuple_fields: variant
                        .tuple_fields
                        .iter()
                        .map(|field| qualify_type_ref(field, prefix, local_type_names, aliases))
                        .collect(),
                    named_fields: qualify_fields(&variant.named_fields, prefix, local_type_names, aliases),
                    span: variant.span,
                })
                .collect(),
            span: decl.span,
        });
    }
}

fn insert_prefixed_traits(
    target: &mut std::collections::BTreeMap<String, TraitDecl>,
    source: &std::collections::BTreeMap<String, TraitDecl>,
    prefix: &str,
    local_type_names: &BTreeSet<String>,
    aliases: &std::collections::BTreeMap<String, String>,
) {
    for (name, decl) in source {
        if name.contains("::") {
            continue;
        }
        let qualified_name = format!("{prefix}::{name}");
        let _ = target.entry(qualified_name.clone()).or_insert_with(|| TraitDecl {
            name: qualified_name,
            public: decl.public,
            type_params: qualify_type_params(&decl.type_params, prefix, local_type_names, aliases),
            supertraits: decl
                .supertraits
                .iter()
                .map(|trait_name| qualify_named_symbol(trait_name, prefix, local_type_names, aliases))
                .collect(),
            where_clause: qualify_where_clause(&decl.where_clause, prefix, local_type_names, aliases),
            methods: decl
                .methods
                .iter()
                .map(|method| FunctionDecl {
                    sig: qualify_function_sig(&method.sig, prefix, local_type_names, aliases),
                    clauses: method.clauses.clone(),
                    body: compact_function_body(&method.body),
                    span: method.span,
                })
                .collect(),
            associated_types: decl
                .associated_types
                .iter()
                .map(|assoc| TypeAliasDecl {
                    name: assoc.name.clone(),
                    public: assoc.public,
                    target: assoc
                        .target
                        .as_ref()
                        .map(|target| qualify_type_ref(target, prefix, local_type_names, aliases)),
                    span: assoc.span,
                })
                .collect(),
            span: decl.span,
        });
    }
}

fn insert_prefixed_functions(
    target: &mut std::collections::BTreeMap<String, FunctionSig>,
    source: &std::collections::BTreeMap<String, FunctionSig>,
    prefix: &str,
    local_type_names: &BTreeSet<String>,
    aliases: &std::collections::BTreeMap<String, String>,
) {
    for (name, sig) in source {
        if name.contains("::") {
            continue;
        }
        let qualified_name = format!("{prefix}::{name}");
        let _ = target.entry(qualified_name.clone()).or_insert_with(|| {
            let mut qualified = qualify_function_sig(sig, prefix, local_type_names, aliases);
            qualified.name = qualified_name;
            qualified
        });
    }
}

fn insert_prefixed_type_aliases(
    target: &mut std::collections::BTreeMap<String, TypeRef>,
    source: &std::collections::BTreeMap<String, TypeRef>,
    prefix: &str,
    local_type_names: &BTreeSet<String>,
    aliases: &std::collections::BTreeMap<String, String>,
) {
    for (name, ty) in source {
        if name.contains("::") {
            continue;
        }
        let qualified_name = format!("{prefix}::{name}");
        let _ = target
            .entry(qualified_name)
            .or_insert_with(|| qualify_type_ref(ty, prefix, local_type_names, aliases));
    }
}

fn insert_prefixed_consts(
    target: &mut std::collections::BTreeMap<String, TypeRef>,
    source: &std::collections::BTreeMap<String, TypeRef>,
    prefix: &str,
    local_type_names: &BTreeSet<String>,
    aliases: &std::collections::BTreeMap<String, String>,
) {
    for (name, ty) in source {
        if name.contains("::") {
            continue;
        }
        let qualified_name = format!("{prefix}::{name}");
        let _ = target
            .entry(qualified_name)
            .or_insert_with(|| qualify_type_ref(ty, prefix, local_type_names, aliases));
    }
}

fn insert_prefixed_globals(
    target: &mut std::collections::BTreeMap<String, crate::sema::env::GlobalInfo>,
    source: &std::collections::BTreeMap<String, crate::sema::env::GlobalInfo>,
    prefix: &str,
    local_type_names: &BTreeSet<String>,
    aliases: &std::collections::BTreeMap<String, String>,
) {
    for (name, global) in source {
        if name.contains("::") {
            continue;
        }
        let qualified_name = format!("{prefix}::{name}");
        let _ = target.entry(qualified_name).or_insert_with(|| crate::sema::env::GlobalInfo {
            ty: qualify_type_ref(&global.ty, prefix, local_type_names, aliases),
            mutable: global.mutable,
        });
    }
}

fn insert_prefixed_aliases(
    target: &mut std::collections::BTreeMap<String, String>,
    source: &std::collections::BTreeMap<String, String>,
    prefix: &str,
    local_type_names: &BTreeSet<String>,
    aliases: &std::collections::BTreeMap<String, String>,
) {
    for (name, alias_target) in source {
        if name.contains("::") {
            continue;
        }
        let qualified_name = format!("{prefix}::{name}");
        let qualified_target = qualify_named_symbol(alias_target, prefix, local_type_names, aliases);
        let _ = target.entry(qualified_name).or_insert(qualified_target);
    }
}

fn qualify_impl_info(
    impl_info: &crate::sema::env::ImplInfo,
    prefix: &str,
    local_type_names: &BTreeSet<String>,
    aliases: &std::collections::BTreeMap<String, String>,
) -> crate::sema::env::ImplInfo {
    let mut qualified = impl_info.clone();
    if !qualified.for_type.contains("::") {
        qualified.for_type = qualify_named_symbol(&qualified.for_type, prefix, local_type_names, aliases);
    }
    if !qualified.trait_name.is_empty() && !qualified.trait_name.contains("::") {
        qualified.trait_name = qualify_named_symbol(&qualified.trait_name, prefix, local_type_names, aliases);
    }
    qualified.methods = qualified
        .methods
        .iter()
        .map(|(name, sig)| (name.clone(), qualify_function_sig(sig, prefix, local_type_names, aliases)))
        .collect();
    qualified.associated_types = qualified
        .associated_types
        .iter()
        .map(|(name, ty)| (name.clone(), qualify_type_ref(ty, prefix, local_type_names, aliases)))
        .collect();
    qualified
}

fn merge_semantic_env(target: &mut SemanticEnv, source: &SemanticEnv, overwrite: bool) {
    merge_map(Rc::make_mut(&mut target.structs), &source.structs, overwrite);
    merge_map(Rc::make_mut(&mut target.enums), &source.enums, overwrite);
    merge_map(Rc::make_mut(&mut target.traits), &source.traits, overwrite);
    merge_map(Rc::make_mut(&mut target.functions), &source.functions, overwrite);
    merge_map(Rc::make_mut(&mut target.type_aliases), &source.type_aliases, overwrite);
    merge_map(Rc::make_mut(&mut target.consts), &source.consts, overwrite);
    merge_map(Rc::make_mut(&mut target.globals), &source.globals, overwrite);
    merge_map(Rc::make_mut(&mut target.aliases), &source.aliases, overwrite);
    
    // Deduplicate impls by (trait_name, for_type) key to prevent unbounded growth
    let target_impls = Rc::make_mut(&mut target.impls);
    let mut seen_impls = std::collections::BTreeSet::new();
    for impl_info in target_impls.iter() {
        let key = format!("{} for {}", impl_info.trait_name, impl_info.for_type);
        seen_impls.insert(key);
    }
    for impl_info in source.impls.iter() {
        let key = format!("{} for {}", impl_info.trait_name, impl_info.for_type);
        if overwrite || !seen_impls.contains(&key) {
            if seen_impls.insert(key) {
                target_impls.push(impl_info.clone());
            }
        }
    }
}

/// Record which keys from `source` are new (absent from `target`) so they can
/// be removed after a temporary merge.
struct EnvKeySnapshot {
    structs: Vec<String>,
    enums: Vec<String>,
    traits: Vec<String>,
    functions: Vec<String>,
    type_aliases: Vec<String>,
    consts: Vec<String>,
    globals: Vec<String>,
    aliases: Vec<String>,
}

fn snapshot_new_keys(target: &SemanticEnv, source: &SemanticEnv) -> EnvKeySnapshot {
    EnvKeySnapshot {
        structs: new_map_keys(&target.structs, &source.structs),
        enums: new_map_keys(&target.enums, &source.enums),
        traits: new_map_keys(&target.traits, &source.traits),
        functions: new_map_keys(&target.functions, &source.functions),
        type_aliases: new_map_keys(&target.type_aliases, &source.type_aliases),
        consts: new_map_keys(&target.consts, &source.consts),
        globals: new_map_keys(&target.globals, &source.globals),
        aliases: new_map_keys(&target.aliases, &source.aliases),
    }
}

fn new_map_keys<V1, V2>(target: &std::collections::BTreeMap<String, V1>, source: &std::collections::BTreeMap<String, V2>) -> Vec<String> {
    source.keys().filter(|k| !target.contains_key(*k)).cloned().collect()
}

fn remove_snapshot_keys(env: &mut SemanticEnv, snapshot: &EnvKeySnapshot) {
    for key in &snapshot.structs { Rc::make_mut(&mut env.structs).remove(key); }
    for key in &snapshot.enums { Rc::make_mut(&mut env.enums).remove(key); }
    for key in &snapshot.traits { Rc::make_mut(&mut env.traits).remove(key); }
    for key in &snapshot.functions { Rc::make_mut(&mut env.functions).remove(key); }
    for key in &snapshot.type_aliases { Rc::make_mut(&mut env.type_aliases).remove(key); }
    for key in &snapshot.consts { Rc::make_mut(&mut env.consts).remove(key); }
    for key in &snapshot.globals { Rc::make_mut(&mut env.globals).remove(key); }
    for key in &snapshot.aliases { Rc::make_mut(&mut env.aliases).remove(key); }
}

fn count_raw_names<'a>(counts: &mut std::collections::BTreeMap<String, usize>, names: impl Iterator<Item = &'a String>) {
    for name in names {
        if name.contains("::") {
            continue;
        }
        *counts.entry(name.clone()).or_insert(0) += 1;
    }
}

fn merge_unique_raw_semantic_env(target: &mut SemanticEnv, source: &SemanticEnv, counts: &RawNameCounts) {
    merge_unique_raw_map(Rc::make_mut(&mut target.structs), &source.structs, &counts.structs);
    merge_unique_raw_map(Rc::make_mut(&mut target.enums), &source.enums, &counts.enums);
    merge_unique_raw_map(Rc::make_mut(&mut target.traits), &source.traits, &counts.traits);
    merge_unique_raw_map(Rc::make_mut(&mut target.functions), &source.functions, &counts.functions);
    merge_unique_raw_map(Rc::make_mut(&mut target.type_aliases), &source.type_aliases, &counts.type_aliases);
    merge_unique_raw_map(Rc::make_mut(&mut target.consts), &source.consts, &counts.consts);
    merge_unique_raw_map(Rc::make_mut(&mut target.globals), &source.globals, &counts.globals);
}

fn merge_unique_raw_map<T: Clone>(
    target: &mut std::collections::BTreeMap<String, T>,
    source: &std::collections::BTreeMap<String, T>,
    counts: &std::collections::BTreeMap<String, usize>,
) {
    for (name, value) in source {
        if name.contains("::") {
            continue;
        }
        if counts.get(name).copied() == Some(1) && !target.contains_key(name) {
            let _ = target.insert(name.clone(), value.clone());
        }
    }
}

#[derive(Default)]
struct RawNameCounts {
    structs: std::collections::BTreeMap<String, usize>,
    enums: std::collections::BTreeMap<String, usize>,
    traits: std::collections::BTreeMap<String, usize>,
    functions: std::collections::BTreeMap<String, usize>,
    type_aliases: std::collections::BTreeMap<String, usize>,
    consts: std::collections::BTreeMap<String, usize>,
    globals: std::collections::BTreeMap<String, usize>,
}

fn merge_map<T: Clone>(target: &mut std::collections::BTreeMap<String, T>, source: &std::collections::BTreeMap<String, T>, overwrite: bool) {
    for (name, value) in source {
        if overwrite || !target.contains_key(name) {
            let _ = target.insert(name.clone(), value.clone());
        }
    }
}

fn write_temp_rust_file(source_path: &Path, rust: &str) -> Result<PathBuf, Stage0Error> {
    let unique = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system time should be after unix epoch")
        .as_nanos();
    let stem = source_path
        .file_stem()
        .and_then(|stem| stem.to_str())
        .unwrap_or("stage0");
    let temp_path = std::env::temp_dir().join(format!("stage0_rs_codegen_{stem}_{unique}.rs"));
    fs::write(&temp_path, rust).map_err(|error| {
        Stage0Error::codegen(
            Span::new(1, 1, 0, 0),
            format!("failed to write generated Rust {}: {error}", temp_path.display()),
        )
    })?;
    Ok(temp_path)
}

fn select_binary_entrypoint(path: &Path) -> Result<PathBuf, Stage0Error> {
    for candidate_name in ["main.tg", "lib.tg"] {
        let candidate = path.join(candidate_name);
        if candidate.is_file() {
            return Ok(candidate);
        }
    }

    let tg_paths = sorted_tg_paths(path)?;
    if tg_paths.len() == 1 {
        return Ok(tg_paths[0].clone());
    }

    Err(Stage0Error::codegen(
        Span::new(1, 1, 0, 0),
        format!(
            "failed to choose binary entrypoint in {}: expected main.tg, lib.tg, or exactly one .tg file",
            path.display()
        ),
    ))
}

fn write_binary_wrapper_file(source_path: &Path, module: &Module, generated_path: &Path) -> Result<PathBuf, Stage0Error> {
    let wrapper = render_binary_wrapper(module, generated_path)?;
    write_temp_rust_file(source_path, &wrapper)
}

fn render_binary_wrapper(module: &Module, generated_path: &Path) -> Result<String, Stage0Error> {
    let Some(main_return_type) = find_top_level_main_return_type(module) else {
        return Err(Stage0Error::codegen(
            Span::new(1, 1, 0, 0),
            "build-bin requires a top-level main function in the selected entry module".to_string(),
        ));
    };

    let include_path = format!("{:?}", generated_path.to_string_lossy());
    let wrapper_main = if returns_exit_code(main_return_type) {
        "fn main() {\n    ::std::process::exit(tangerine_entry::main() as i32);\n}\n".to_string()
    } else if returns_unit_or_never(main_return_type) {
        "fn main() {\n    tangerine_entry::main();\n}\n".to_string()
    } else {
        "fn main() -> ::std::process::ExitCode {\n    ::std::process::Termination::report(tangerine_entry::main())\n}\n".to_string()
    };

    let module_reexports = render_binary_wrapper_reexports(generated_path)?;

    Ok(format!(
        "#[path = {include_path}]\nmod tangerine_entry;\n\n{module_reexports}{wrapper_main}"
    ))
}

fn render_binary_wrapper_reexports(generated_path: &Path) -> Result<String, Stage0Error> {
    let generated = fs::read_to_string(generated_path).map_err(|error| {
        Stage0Error::codegen(
            Span::new(1, 1, 0, 0),
            format!("failed to read generated Rust {}: {error}", generated_path.display()),
        )
    })?;

    let modules = collect_top_level_public_modules(&generated);
    if modules.is_empty() {
        return Ok(String::new());
    }

    Ok(modules
        .into_iter()
        .map(|name| format!("pub use tangerine_entry::{name};\n"))
        .collect())
}

fn collect_top_level_public_modules(generated: &str) -> Vec<String> {
    let mut modules = BTreeSet::new();
    for line in generated.lines().filter(|line| line.starts_with("pub mod ")) {
        let rest = &line["pub mod ".len()..];
        if let Some(name) = rest
            .split(|ch: char| !(ch.is_ascii_alphanumeric() || ch == '_'))
            .next()
            .filter(|name| !name.is_empty())
        {
            modules.insert(name.to_string());
        }
    }
    modules.into_iter().collect()
}

fn find_top_level_main_return_type(module: &Module) -> Option<&TypeRef> {
    module.decls.iter().find_map(|decl| match decl {
        Decl::Function(function_decl) if function_decl.sig.name == "main" => Some(&function_decl.sig.return_type),
        _ => None,
    })
}

fn returns_exit_code(ty: &TypeRef) -> bool {
    matches!(ty, TypeRef::Int { .. })
}

fn returns_unit_or_never(ty: &TypeRef) -> bool {
    matches!(ty, TypeRef::Unit { .. })
        || matches!(ty, TypeRef::Named { name, .. } if name == "Nil" || name == "!")
}

fn should_keep_codegen_artifacts() -> bool {
    std::env::var("TG_KEEP_CODEGEN_ARTIFACTS")
        .map(|value| matches!(value.as_str(), "1" | "true" | "TRUE" | "yes" | "YES"))
        .unwrap_or(false)
}

fn remove_codegen_artifacts(path: &Path) {
    let _ = fs::remove_file(path);
    let _ = fs::remove_file(path.with_extension("rmeta"));
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::path::PathBuf;
    use std::rc::Rc;
    use std::time::{SystemTime, UNIX_EPOCH};

    use crate::ast::decl::{EnumDecl, FunctionSig, VariantDecl};
    use crate::sema::SemanticEnv;

    use super::{analyze_directory, analyze_module_from_path, build_support_env, build_support_env_for_file, codegen_module_from_path, collect_top_level_public_modules, has_explicit_top_level_module_decl, merge_semantic_env, parse_module_from_path, qualify_semantic_env, render_binary_wrapper, support_prefixes_for_module};

    #[test]
    fn analyzes_real_repo_fixture() {
        let repo_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("stage0_rs should live directly under the repo root")
            .to_path_buf();
        let fixture = repo_root.join("golden/frontend_01.tg");
        let (module, env) = analyze_module_from_path(&fixture).expect("fixture should analyze successfully");
        assert_eq!(module.decls.len(), 3);
        assert!(env.functions.contains_key("add"));
        assert!(env.functions.contains_key("identity"));
        assert!(env.functions.contains_key("constant"));
    }

    #[test]
    fn analyzes_additional_repo_fixture() {
        let repo_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("stage0_rs should live directly under the repo root")
            .to_path_buf();
        let fixture = repo_root.join("golden/rationale_01.tg");
        let (module, _) = analyze_module_from_path(&fixture).expect("rationale fixture should analyze successfully");
        assert_eq!(module.decls.len(), 3);
    }

    #[test]
    fn analyzes_line_based_repo_fixtures() {
        let repo_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("stage0_rs should live directly under the repo root")
            .to_path_buf();
        analyze_module_from_path(&repo_root.join("golden/frontend_03.tg"))
            .expect("frontend_03 should analyze successfully");
        analyze_module_from_path(&repo_root.join("golden/simple_test.tg"))
            .expect("simple_test should analyze successfully");
        analyze_module_from_path(&repo_root.join("golden/capabilities_01.tg"))
            .expect("capabilities_01 should analyze successfully");
    }

    #[test]
    fn directory_analysis_surfaces_supported_and_unsupported_files() {
        let repo_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("stage0_rs should live directly under the repo root")
            .to_path_buf();
        let results = analyze_directory(&repo_root.join("golden")).expect("golden directory should be readable");
        assert!(results.iter().any(|(path, result)| {
            path.ends_with("frontend_01.tg") && result.is_ok()
        }));
        assert!(results.iter().any(|(path, result)| {
            path.ends_with("frontend_03.tg") && result.is_ok()
        }));
        assert!(results.iter().any(|(path, result)| {
            path.ends_with("capabilities_01.tg") && result.is_ok()
        }));
        assert!(results.iter().any(|(path, result)| {
            path.ends_with("frontend_05.tg") && result.is_ok()
        }));
    }

    #[test]
    fn codegen_validates_simple_repo_fixture() {
        let repo_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("stage0_rs should live directly under the repo root")
            .to_path_buf();
        codegen_module_from_path(&repo_root.join("golden/simple_test.tg"))
            .expect("simple_test should pass end-to-end codegen validation");
    }

    #[test]
    fn qualifies_lib_exports_at_directory_root() {
        let mut env = SemanticEnv::default();
        Rc::make_mut(&mut env.functions).insert(
            "tokenize".to_string(),
            FunctionSig {
                name: "tokenize".to_string(),
                public: true,
                type_params: Vec::new(),
                params: Vec::new(),
                return_type: crate::ast::types::TypeRef::Unit {
                    span: crate::span::Span::new(1, 1, 0, 0),
                },
                where_clause: Vec::new(),
                span: crate::span::Span::new(1, 1, 0, 0),
            },
        );

        let repo_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("stage0_rs should live directly under the repo root")
            .to_path_buf();
        let qualified = qualify_semantic_env(&env, &repo_root.join("tg_compiler/lib.tg"));

        assert!(qualified.functions.contains_key("tg_compiler::tokenize"));
        assert!(qualified.functions.contains_key("tg_compiler::lib::tokenize"));
    }

    #[test]
    fn qualifies_imported_alias_types_in_function_signatures() {
        let mut env = SemanticEnv::default();
        Rc::make_mut(&mut env.aliases).insert("Value".to_string(), "std::serde::Value".to_string());
        Rc::make_mut(&mut env.functions).insert(
            "json_parse".to_string(),
            FunctionSig {
                name: "json_parse".to_string(),
                public: true,
                type_params: Vec::new(),
                params: Vec::new(),
                return_type: crate::ast::types::TypeRef::Named {
                    name: "Value".to_string(),
                    type_args: Vec::new(),
                    span: crate::span::Span::new(1, 1, 0, 0),
                },
                where_clause: Vec::new(),
                span: crate::span::Span::new(1, 1, 0, 0),
            },
        );

        let repo_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("stage0_rs should live directly under the repo root")
            .to_path_buf();
        let qualified = qualify_semantic_env(&env, &repo_root.join("std/json.tg"));
        let json_parse = qualified
            .functions
            .get("std::json::json_parse")
            .expect("std::json::json_parse should be qualified");

        assert_eq!(
            json_parse.return_type,
            crate::ast::types::TypeRef::Named {
                name: "std::serde::Value".to_string(),
                type_args: Vec::new(),
                span: crate::span::Span::new(1, 1, 0, 0),
            }
        );
    }

    #[test]
    fn preserves_qualified_alias_chains_for_reexports() {
        let mut json_env = SemanticEnv::default();
        Rc::make_mut(&mut json_env.aliases).insert("Value".to_string(), "std::serde::Value".to_string());

        let repo_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("stage0_rs should live directly under the repo root")
            .to_path_buf();
        let qualified_json_env = qualify_semantic_env(&json_env, &repo_root.join("std/json.tg"));

        let mut merged = SemanticEnv::default();
        Rc::make_mut(&mut merged.enums).insert(
            "std::serde::Value".to_string(),
            EnumDecl {
                name: "std::serde::Value".to_string(),
                public: true,
                type_params: Vec::new(),
                where_clause: Vec::new(),
                variants: vec![VariantDecl {
                    name: "Object".to_string(),
                    tuple_fields: Vec::new(),
                    named_fields: Vec::new(),
                    span: crate::span::Span::new(1, 1, 0, 0),
                }],
                span: crate::span::Span::new(1, 1, 0, 0),
            },
        );
        Rc::make_mut(&mut merged.aliases).insert("Value".to_string(), "std::json::Value".to_string());
        merge_semantic_env(&mut merged, &qualified_json_env, false);

        assert_eq!(merged.resolve_alias_path("Value"), "std::serde::Value");
        assert_eq!(
            merged.canonical_map_key("Value", &merged.enums),
            Some("std::serde::Value".to_string())
        );
    }

    #[test]
    fn support_env_exposes_std_serde_value_object_variant() {
        let repo_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("stage0_rs should live directly under the repo root")
            .to_path_buf();
        let serde_module = parse_module_from_path(&repo_root.join("std/serde.tg"))
            .expect("std/serde.tg should parse directly");
        let serde_env = crate::sema::SemanticEnv::collect(&serde_module)
            .expect("std/serde.tg declarations should collect directly");
        assert!(serde_env.enums.contains_key("Value"));

        let qualified_serde_env = qualify_semantic_env(&serde_env, &repo_root.join("std/serde.tg"));
        assert!(qualified_serde_env.enums.contains_key("std::serde::Value"));

        let support_env = build_support_env(&repo_root.join("golden")).expect("support env should build");
        let value_enum = support_env
            .enums
            .get("std::serde::Value")
            .expect("std::serde::Value should exist in support env");

        assert!(value_enum.variants.iter().any(|variant| variant.name == "Object"));
    }

    #[test]
    fn support_env_preserves_borrow_check_signature_shape() {
        let repo_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("stage0_rs should live directly under the repo root")
            .to_path_buf();
        let driver_path = repo_root.join("tg_compiler/driver.tg");

        let support_env = build_support_env_for_file(&driver_path)
            .expect("support env should build for tg_compiler/driver.tg");
        assert_eq!(
            support_env.aliases.get("tg_compiler::borrow_check").cloned(),
            Some("tg_compiler::borrow_check::borrow_check".to_string())
        );
        assert_eq!(
            support_env.aliases.get("tg_compiler::driver::borrow_check").cloned(),
            Some("tg_compiler::borrow_check::borrow_check".to_string())
        );
        assert_eq!(
            support_env.aliases.get("tg_compiler::BorrowError").cloned(),
            Some("tg_compiler::borrow_check::BorrowError".to_string())
        );

        let borrow_check_key = "tg_compiler::borrow_check::borrow_check".to_string();
        let borrow_check_sig = support_env
            .functions
            .get(&borrow_check_key)
            .expect("qualified borrow_check signature should be present");

        assert_eq!(borrow_check_sig.params.len(), 1, "borrow_check params: {borrow_check_sig:?}");
        match &borrow_check_sig.params[0].ty {
            crate::ast::types::TypeRef::Ref { inner, .. } => match inner.as_ref() {
                crate::ast::types::TypeRef::Named { name, .. } => {
                    assert_eq!(name, "tg_compiler::ast::Program", "borrow_check param: {borrow_check_sig:?}");
                }
                other => panic!("borrow_check param should reference Program, found {other:?}"),
            },
            other => panic!("borrow_check param should be a ref, found {other:?}"),
        }

        match &borrow_check_sig.return_type {
            crate::ast::types::TypeRef::Named { name, type_args, .. } => {
                assert_eq!(name, "std::collections::Vec", "borrow_check return: {borrow_check_sig:?}");
                assert_eq!(type_args.len(), 1, "borrow_check return: {borrow_check_sig:?}");
                match &type_args[0] {
                    crate::ast::types::TypeRef::Named { name, .. } => {
                        assert_eq!(name, "tg_compiler::borrow_check::BorrowError", "borrow_check return: {borrow_check_sig:?}");
                    }
                    other => panic!("borrow_check return element should be BorrowError, found {other:?}"),
                }
            }
            other => panic!("borrow_check return should be Vec[BorrowError], found {other:?}"),
        }
    }

    #[test]
    fn support_source_prefixes_defer_to_explicit_top_level_module_decls() {
        let repo_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("stage0_rs should live directly under the repo root")
            .to_path_buf();
        let semver_path = repo_root.join("std/semver.tg");
        let semver_module = parse_module_from_path(&semver_path)
            .expect("std/semver.tg should parse directly");

        assert!(
            has_explicit_top_level_module_decl(&semver_module),
            "std/semver.tg should expose an explicit top-level module decl"
        );
        assert_eq!(support_prefixes_for_module(&semver_path, &semver_module), vec![String::new()]);
    }

    #[test]
    fn support_source_prefixes_fall_back_to_file_paths_without_explicit_module_decls() {
        let repo_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("stage0_rs should live directly under the repo root")
            .to_path_buf();
        let bindgen_path = repo_root.join("tg_compiler/bindgen.tg");
        let bindgen_module = parse_module_from_path(&bindgen_path)
            .expect("tg_compiler/bindgen.tg should parse directly");

        assert!(
            !has_explicit_top_level_module_decl(&bindgen_module),
            "tg_compiler/bindgen.tg should rely on file-based support prefixes"
        );
        assert_eq!(
            support_prefixes_for_module(&bindgen_path, &bindgen_module),
            vec!["bindgen".to_string(), "tg_compiler::bindgen".to_string()]
        );
    }

    #[test]
    fn binary_wrapper_uses_path_module_instead_of_include_macro() {
        let repo_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("stage0_rs should live directly under the repo root")
            .to_path_buf();
        let fixture = repo_root.join("golden/simple_test.tg");
        let module = parse_module_from_path(&fixture).expect("simple_test fixture should parse");
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system time should be after unix epoch")
            .as_nanos();
        let generated = std::env::temp_dir().join(format!("stage0_rs_wrapper_test_{}_{}.rs", std::process::id(), unique));
        fs::write(&generated, "#![allow(dead_code)]\npub mod helper {}\npub fn main() {}\n")
            .expect("test should be able to create a generated rust fixture");

        let wrapper = render_binary_wrapper(&module, &generated)
            .expect("binary wrapper should render for simple_test fixture");

        fs::remove_file(&generated).expect("test should clean up generated rust fixture");

        let expected_path = format!("#[path = {:?}]", generated.to_string_lossy());
        assert!(wrapper.contains(&expected_path));
        assert!(wrapper.contains("mod tangerine_entry;"));
        assert!(wrapper.contains("pub use tangerine_entry::helper;"));
        assert!(!wrapper.contains("include!("));
    }

    #[test]
    fn collect_top_level_public_modules_ignores_nested_modules() {
        let generated = concat!(
            "pub mod first {\n",
            "    pub fn render() -> &'static str { \"{not a module}\" }\n",
            "    pub mod nested {\n",
            "        pub fn helper() {}\n",
            "    }\n",
            "}\n",
            "pub mod second {\n",
            "    pub fn run() {}\n",
            "}\n"
        );

        assert_eq!(collect_top_level_public_modules(generated), vec!["first".to_string(), "second".to_string()]);
    }
}