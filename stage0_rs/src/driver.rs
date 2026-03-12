use std::collections::BTreeSet;
use std::fs;
use std::path::Path;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::ast::decl::{
    EnumDecl, FieldDecl, FunctionDecl, FunctionSig, Module, Param, StructDecl, TraitDecl, TypeAliasDecl, TypeParam,
    VariantDecl, WherePredicate,
};
use crate::ast::types::TypeRef;
use crate::codegen::{emit_rust, rustc_check};
use crate::error::Stage0Error;
use crate::lexer::lex;
use crate::parser::Parser;
use crate::sema::{analyze, analyze_with_env, SemanticEnv};
use crate::span::Span;

pub type FileAnalysis = (PathBuf, Result<Module, Stage0Error>);
pub type CodegenAnalysis = (PathBuf, Result<(), Stage0Error>);

/// Read, lex, parse, and analyze a Tangerine source file.
///
/// # Errors
/// Returns `Stage0Error` if the file cannot be read or if any compiler phase fails.
pub fn analyze_module_from_path(path: &Path) -> Result<(Module, SemanticEnv), Stage0Error> {
    let module = parse_module_from_path(path)?;
    let env = analyze(&module)?;
    Ok((module, env))
}

/// Read, lex, parse, analyze, emit Rust, and validate the generated Rust for a Tangerine file.
/// 
/// # Errors
/// Returns `Stage0Error` if any compiler phase fails or if generated Rust fails `rustc` metadata validation.
pub fn codegen_module_from_path(path: &Path) -> Result<(), Stage0Error> {
    let (module, env) = analyze_module_from_path(path)?;
    let rust = emit_rust(&module, &env)?;
    let temp_path = write_temp_rust_file(path, &rust)?;
    let check_result = rustc_check(&temp_path);
    remove_codegen_artifacts(&temp_path);
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
/// # Errors
/// Returns `Stage0Error` if the directory itself cannot be read.
pub fn analyze_directory(path: &Path) -> Result<Vec<FileAnalysis>, Stage0Error> {
    let parsed = parse_directory_modules(path)?;
    let support_env = build_support_env(path)?;
    let mut shared_env = support_env.clone();
    let mut file_envs = Vec::with_capacity(parsed.len());
    for (file_path, result) in &parsed {
        let file_env = match result {
            Ok(module) => SemanticEnv::collect(module).map(normalize_semantic_env_aliases),
            Err(error) => Err(error.clone()),
        };
        if let Ok(env) = &file_env {
            merge_semantic_env(&mut shared_env, &qualify_semantic_env(env.clone(), file_path), false);
        }
        file_envs.push(file_env);
    }
    let raw_name_counts = collect_raw_name_counts(&file_envs);
    for file_env in &file_envs {
        if let Ok(env) = file_env {
            merge_unique_raw_semantic_env(&mut shared_env, env, &raw_name_counts);
        }
    }

    let mut results = Vec::with_capacity(parsed.len());
    for ((file_path, result), file_env) in parsed.into_iter().zip(file_envs) {
        let analyzed = match (result, file_env) {
            (Ok(module), Ok(file_specific_env)) => {
                let mut env = shared_env.clone();
                merge_semantic_env(&mut env, &file_specific_env, true);
                analyze_with_env(&module, &env).map(|()| module)
            }
            (Ok(module), Err(_)) => Ok(module),
            (Err(error), _) => Err(error),
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
    let mut file_envs = Vec::with_capacity(parsed.len());
    for (file_path, parsed_module) in &parsed {
        let file_env = match parsed_module {
            Ok(module) => SemanticEnv::collect(module).map(normalize_semantic_env_aliases),
            Err(error) => Err(error.clone()),
        };
        if let Ok(env) = &file_env {
            merge_semantic_env(&mut merged_env, &qualify_semantic_env(env.clone(), file_path), false);
        }
        file_envs.push(file_env);
    }
    let raw_name_counts = collect_raw_name_counts(&file_envs);
    for file_env in &file_envs {
        if let Ok(env) = file_env {
            merge_unique_raw_semantic_env(&mut merged_env, env, &raw_name_counts);
        }
    }

    let mut results = Vec::with_capacity(parsed.len());
    for ((file_path, parsed_module), file_env) in parsed.into_iter().zip(file_envs) {
        let result = match (parsed_module, file_env) {
            (Ok(module), Ok(file_specific_env)) => {
                let mut env = merged_env.clone();
                merge_semantic_env(&mut env, &file_specific_env, true);
                analyze_with_env(&module, &env)
                    .and_then(|()| emit_rust(&module, &env))
                    .and_then(|rust| {
                        let temp_path = write_temp_rust_file(&file_path, &rust)?;
                        let check_result = rustc_check(&temp_path);
                        remove_codegen_artifacts(&temp_path);
                        check_result
                    })
            }
            (Err(error), _) | (_, Err(error)) => Err(error),
        };
        results.push((file_path, result));
    }

    Ok(results)
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
    for support_name in ["std", "tg_compiler"] {
        let support_dir = repo_root.join(support_name);
        if !support_dir.is_dir() || support_dir == path {
            continue;
        }

        let mut file_envs = Vec::new();

        for (file_path, parsed_module) in parse_directory_modules(&support_dir)? {
            if let Ok(module) = parsed_module {
                if let Ok(env) = SemanticEnv::collect(&module) {
                    let env = normalize_semantic_env_aliases(env);
                    if support_name == "std" {
                        merge_semantic_env(&mut support_env, &env, false);
                    } else {
                        file_envs.push(env.clone());
                    }
                    merge_semantic_env(&mut support_env, &qualify_semantic_env(env, &file_path), false);
                }
            }
        }

        if support_name == "tg_compiler" {
            let raw_name_counts = collect_raw_name_counts(
                &file_envs
                    .iter()
                    .cloned()
                    .map(Ok)
                    .collect::<Vec<Result<SemanticEnv, Stage0Error>>>(),
            );
            for env in &file_envs {
                merge_unique_raw_semantic_env(&mut support_env, env, &raw_name_counts);
            }
        }
    }

    Ok(support_env)
}

fn qualify_semantic_env(env: SemanticEnv, file_path: &Path) -> SemanticEnv {
    let Some(stem) = file_path.file_stem().and_then(|stem| stem.to_str()) else {
        return env;
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

    for prefix in &prefixes {
        insert_prefixed_structs(&mut qualified.structs, &env.structs, prefix, &local_type_names, &aliases);
        insert_prefixed_enums(&mut qualified.enums, &env.enums, prefix, &local_type_names, &aliases);
        insert_prefixed_traits(&mut qualified.traits, &env.traits, prefix, &local_type_names, &aliases);
        insert_prefixed_functions(&mut qualified.functions, &env.functions, prefix, &local_type_names, &aliases);
        insert_prefixed_type_aliases(&mut qualified.type_aliases, &env.type_aliases, prefix, &local_type_names, &aliases);
        insert_prefixed_consts(&mut qualified.consts, &env.consts, prefix, &local_type_names, &aliases);
        insert_prefixed_globals(&mut qualified.globals, &env.globals, prefix, &local_type_names, &aliases);
        insert_prefixed_aliases(&mut qualified.aliases, &env.aliases, prefix, &local_type_names, &aliases);
        for impl_info in &env.impls {
            qualified.impls.push(qualify_impl_info(impl_info, prefix, &local_type_names, &aliases));
        }
    }

    qualified
}

fn normalize_semantic_env_aliases(env: SemanticEnv) -> SemanticEnv {
    let aliases = env.aliases.clone();
    let local_type_names = BTreeSet::new();
    let empty_prefix = "";

    SemanticEnv {
        structs: env
            .structs
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
            .collect(),
        enums: env
            .enums
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
            .collect(),
        traits: env
            .traits
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
                            body: method.body.clone(),
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
            .collect(),
        functions: env
            .functions
            .into_iter()
            .map(|(name, sig)| (name, qualify_function_sig(&sig, empty_prefix, &local_type_names, &aliases)))
            .collect(),
        type_aliases: env
            .type_aliases
            .into_iter()
            .map(|(name, ty)| (name, qualify_type_ref(&ty, empty_prefix, &local_type_names, &aliases)))
            .collect(),
        consts: env
            .consts
            .into_iter()
            .map(|(name, ty)| (name, qualify_type_ref(&ty, empty_prefix, &local_type_names, &aliases)))
            .collect(),
        globals: env
            .globals
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
            .collect(),
        aliases: env.aliases,
        impls: env
            .impls
            .iter()
            .map(|impl_info| qualify_impl_info(impl_info, empty_prefix, &local_type_names, &aliases))
            .collect(),
        active_trait: env.active_trait,
    }
}

fn resolve_imported_alias(name: &str, aliases: &std::collections::BTreeMap<String, String>) -> String {
    if let Some(resolved) = aliases.get(name) {
        return resolved.clone();
    }
    if let Some((head, tail)) = name.split_once("::") {
        if let Some(prefix) = aliases.get(head) {
            return format!("{prefix}::{tail}");
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
    let resolved = resolve_imported_alias(name, aliases);
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
                    body: method.body.clone(),
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
    merge_map(&mut target.structs, &source.structs, overwrite);
    merge_map(&mut target.enums, &source.enums, overwrite);
    merge_map(&mut target.traits, &source.traits, overwrite);
    merge_map(&mut target.functions, &source.functions, overwrite);
    merge_map(&mut target.type_aliases, &source.type_aliases, overwrite);
    merge_map(&mut target.consts, &source.consts, overwrite);
    merge_map(&mut target.globals, &source.globals, overwrite);
    merge_map(&mut target.aliases, &source.aliases, overwrite);
    target.impls.extend(source.impls.clone());
}

fn collect_raw_name_counts(file_envs: &[Result<SemanticEnv, Stage0Error>]) -> RawNameCounts {
    let mut counts = RawNameCounts::default();
    for file_env in file_envs {
        let Ok(env) = file_env else {
            continue;
        };
        count_raw_names(&mut counts.structs, env.structs.keys());
        count_raw_names(&mut counts.enums, env.enums.keys());
        count_raw_names(&mut counts.traits, env.traits.keys());
        count_raw_names(&mut counts.functions, env.functions.keys());
        count_raw_names(&mut counts.type_aliases, env.type_aliases.keys());
        count_raw_names(&mut counts.consts, env.consts.keys());
        count_raw_names(&mut counts.globals, env.globals.keys());
    }
    counts
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
    merge_unique_raw_map(&mut target.structs, &source.structs, &counts.structs);
    merge_unique_raw_map(&mut target.enums, &source.enums, &counts.enums);
    merge_unique_raw_map(&mut target.traits, &source.traits, &counts.traits);
    merge_unique_raw_map(&mut target.functions, &source.functions, &counts.functions);
    merge_unique_raw_map(&mut target.type_aliases, &source.type_aliases, &counts.type_aliases);
    merge_unique_raw_map(&mut target.consts, &source.consts, &counts.consts);
    merge_unique_raw_map(&mut target.globals, &source.globals, &counts.globals);
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

fn remove_codegen_artifacts(path: &Path) {
    let _ = fs::remove_file(path);
    let _ = fs::remove_file(path.with_extension("rmeta"));
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use crate::ast::decl::{EnumDecl, FunctionSig, VariantDecl};
    use crate::sema::SemanticEnv;

    use super::{analyze_directory, analyze_module_from_path, build_support_env, codegen_module_from_path, merge_semantic_env, parse_module_from_path, qualify_semantic_env};

    #[test]
    fn analyzes_real_repo_fixture() {
        let repo_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("stage0_rs should live directly under the repo root")
            .to_path_buf();
        let fixture = repo_root.join("golden/frontend_01.tg");
        let (module, env) = analyze_module_from_path(&fixture).expect("fixture should analyze successfully");
        assert_eq!(module.decls.len(), 3);
        assert!(env.structs.is_empty());
        assert!(env.traits.is_empty());
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
        assert!(results.iter().any(|(path, result)| {
            path.ends_with("negative_tests.tg") && result.is_ok()
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
        env.functions.insert(
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
        let qualified = qualify_semantic_env(env, &repo_root.join("tg_compiler/lib.tg"));

        assert!(qualified.functions.contains_key("tg_compiler::tokenize"));
        assert!(qualified.functions.contains_key("tg_compiler::lib::tokenize"));
    }

    #[test]
    fn qualifies_imported_alias_types_in_function_signatures() {
        let mut env = SemanticEnv::default();
        env.aliases.insert("Value".to_string(), "std::serde::Value".to_string());
        env.functions.insert(
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
        let qualified = qualify_semantic_env(env, &repo_root.join("std/json.tg"));
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
        json_env.aliases.insert("Value".to_string(), "std::serde::Value".to_string());

        let repo_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("stage0_rs should live directly under the repo root")
            .to_path_buf();
        let qualified_json_env = qualify_semantic_env(json_env, &repo_root.join("std/json.tg"));

        let mut merged = SemanticEnv::default();
        merged.enums.insert(
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
        merged.aliases.insert("Value".to_string(), "std::json::Value".to_string());
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

        let qualified_serde_env = qualify_semantic_env(serde_env, &repo_root.join("std/serde.tg"));
        assert!(qualified_serde_env.enums.contains_key("std::serde::Value"));

        let support_env = build_support_env(&repo_root.join("golden")).expect("support env should build");
        let value_enum = support_env
            .enums
            .get("std::serde::Value")
            .expect("std::serde::Value should exist in support env");

        assert!(value_enum.variants.iter().any(|variant| variant.name == "Object"));
    }
}