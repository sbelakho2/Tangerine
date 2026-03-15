pub mod env;

use crate::ast::decl::{
    ContractKind, Decl, EnumDecl, FunctionClause, FunctionDecl, FunctionSig, Module, TraitDecl, VariantDecl,
};
use crate::ast::expr::{BinaryOp, BranchGuard, CallArg, Expr, FunctionBody, Pattern, Stmt, UnaryOp};
use crate::ast::types::TypeRef;
use crate::error::Stage0Error;
use crate::span::Span;
use std::collections::{BTreeMap, BTreeSet};
use std::rc::Rc;

pub use env::SemanticEnv;
use env::{build_impl_info, validate_enum_decl, validate_struct_decl};

use std::sync::atomic::{AtomicU64, AtomicBool, Ordering};
static ENV_CLONE_COUNT: AtomicU64 = AtomicU64::new(0);
static ENV_CLONE_VM_PEAK: AtomicU64 = AtomicU64::new(0);
static TRACE_STMTS: AtomicBool = AtomicBool::new(false);
static LAST_VM: AtomicU64 = AtomicU64::new(0);

fn track_env_clone() {
    let count = ENV_CLONE_COUNT.fetch_add(1, Ordering::Relaxed) + 1;
    let heap = resident_kb();
    ENV_CLONE_VM_PEAK.fetch_max(heap, Ordering::Relaxed);
    if std::env::var("TG_TRACE2").is_ok() && (count <= 5 || count % 20 == 0 || count > 155) {
        eprintln!("[sema]     env_clone #{count} vm={heap}KB");
    }
}

fn resident_kb() -> u64 {
    // Read VmSize from /proc/self/status (virtual memory, limited by ulimit -v)
    std::fs::read_to_string("/proc/self/status")
        .ok()
        .and_then(|s| {
            for line in s.lines() {
                if line.starts_with("VmSize:") {
                    return line.split_whitespace().nth(1)?.parse().ok();
                }
            }
            None
        })
        .unwrap_or(0)
}

fn vm_peak_kb() -> u64 {
    std::fs::read_to_string("/proc/self/status")
        .ok()
        .and_then(|s| {
            for line in s.lines() {
                if line.starts_with("VmPeak:") {
                    return line.split_whitespace().nth(1)?.parse().ok();
                }
            }
            None
        })
        .unwrap_or(0)
}

fn decl_summary(decl: &Decl) -> String {
    match decl {
        Decl::Function(f) => format!("fn {}", f.sig.name),
        Decl::Impl(i) => format!("impl {}", i.for_type),
        Decl::Trait(t) => format!("trait {}", t.name),
        Decl::Module(m) => format!("mod ({}d)", m.decls.len()),
        Decl::Struct(s) => format!("struct {}", s.name),
        Decl::Enum(e) => format!("enum {}", e.name),
        _ => "other".to_string(),
    }
}

#[allow(dead_code)]
fn env_item_count(env: &SemanticEnv) -> usize {
    let _ = env;
    env.structs.len() + env.enums.len() + env.traits.len() + env.functions.len()
        + env.type_aliases.len() + env.consts.len() + env.globals.len()
        + env.aliases.len() + env.impls.len()
}

/// Strip module qualifications: `"std::core::Result"` → `"Result"`.
fn bare_type_name(name: &str) -> &str {
    name.rsplit("::").next().unwrap_or(name)
}

fn expr_kind(expr: &Expr) -> &'static str {
    match expr {
        Expr::Call { .. } => "call",
        Expr::If { .. } => "if",
        Expr::Match { .. } => "match",
        Expr::Block { .. } => "block",
        Expr::Field { .. } => "field",
        Expr::Name { .. } => "name",
        Expr::Integer { .. } | Expr::Float { .. } | Expr::String { .. } | Expr::Bool { .. } | Expr::Char { .. } => "lit",
        _ => "other",
    }
}

fn is_builtin_generic_type(name: &str) -> bool {
    matches!(name, "Array" | "Vec" | "Map" | "Set" | "Option" | "Result" | "Range" | "Box")
}

/// Create a synthetic Named type representing an unresolved external type.
/// This is used instead of Unit when the actual type from an external module
/// cannot be determined, so that `is_external_module_type` and
/// `is_externally_typed` correctly identify it as external.
fn unresolved_external_type(span: Span) -> TypeRef {
    TypeRef::Named {
        name: "<extern::unresolved>".to_string(),
        type_args: Vec::new(),
        span,
    }
}

fn needs_forward_named_inference(ty: &TypeRef, env: &SemanticEnv) -> bool {
    let TypeRef::Named { name, type_args, .. } = ty else {
        return false;
    };

    // Unresolved external types always benefit from forward inference —
    // a later usage may reveal the concrete type.
    if is_external_module_type(ty) {
        return true;
    }

    if !type_args.is_empty() {
        return false;
    }

    let bare = bare_type_name(name);
    if is_builtin_generic_type(bare) {
        return true;
    }

    if let Some(struct_key) = env.canonical_map_key(name, &env.structs) {
        return !env.structs[&struct_key].type_params.is_empty();
    }
    if let Some(enum_key) = env.canonical_map_key(name, &env.enums) {
        return !env.enums[&enum_key].type_params.is_empty();
    }

    false
}

fn initializer_matches_forward_target(value: &Expr, inferred_ty: &TypeRef) -> bool {
    // Unresolved external types always match — the concrete type is unknown
    // so any usage should be allowed to refine it.
    if is_external_module_type(inferred_ty) {
        return true;
    }

    let TypeRef::Named { name: inferred_name, .. } = inferred_ty else {
        return false;
    };
    let inferred_bare = bare_type_name(inferred_name);

    match value {
        Expr::StructLiteral { name, .. } => bare_type_name(name) == inferred_bare,
        Expr::Name { name, .. } => {
            bare_type_name(name) == inferred_bare
                || (inferred_bare == "Option" && name.ends_with("::None"))
        }
        Expr::Call { callee, .. } => match callee.as_ref() {
            Expr::Field { base, field, .. } if field == "new" => match base.as_ref() {
                Expr::Name { name, .. } => bare_type_name(name) == inferred_bare,
                _ => false,
            },
            Expr::Name { name, .. } => {
                bare_type_name(name) == inferred_bare
                    || name
                        .rsplit_once("::")
                        .is_some_and(|(owner, _)| bare_type_name(owner) == inferred_bare)
            }
            _ => false,
        },
        _ => false,
    }
}

fn is_builtin_trait(name: &str) -> bool {
    matches!(name, "Display" | "Debug" | "Clone" | "Default")
}

/// Build the semantic environment for a parsed module.
///
/// # Errors
/// Returns `Stage0Error` if duplicate declarations or unresolved references are
/// found during semantic analysis.
pub fn analyze(module: &Module) -> Result<SemanticEnv, Stage0Error> {
    let env = SemanticEnv::build(module)?;
    analyze_with_env(module, &env)?;
    Ok(env)
}

/// Analyze a parsed module against a previously-built shared semantic environment.
///
/// # Errors
/// Returns `Stage0Error` if global initializers or executable bodies fail type checking.
pub fn analyze_with_env(module: &Module, env: &SemanticEnv) -> Result<(), Stage0Error> {
    ENV_CLONE_COUNT.store(0, Ordering::Relaxed);
    ENV_CLONE_VM_PEAK.store(0, Ordering::Relaxed);
    type_check_global_initializers(module, env)?;
    type_check_function_bodies(module, env)?;
    if std::env::var("TG_TRACE").is_ok() {
        let clones = ENV_CLONE_COUNT.load(Ordering::Relaxed);
        let peak = ENV_CLONE_VM_PEAK.load(Ordering::Relaxed);
        eprintln!("[sema] total env_clones={clones} vm_peak={peak} KB");
    }
    Ok(())
}

/// Resolve a Tangerine type against the semantic environment.
///
/// # Errors
/// Returns `Stage0Error` when the referenced trait or concrete type does not
/// exist in the environment.
pub fn resolve_type(ty: &TypeRef, env: &SemanticEnv) -> Result<(), Stage0Error> {
    match ty {
        TypeRef::Int { .. }
        | TypeRef::Float { .. }
        | TypeRef::Char { .. }
        | TypeRef::String { .. }
        | TypeRef::Bool { .. }
        | TypeRef::Unit { .. }
        | TypeRef::SelfTy { .. } => Ok(()),
        TypeRef::Tuple { elements, .. } => {
            for element in elements {
                resolve_type(element, env)?;
            }
            Ok(())
        }
        TypeRef::Array { element, .. } => resolve_type(element, env),
        TypeRef::Named {
            name,
            type_args,
            ..
        } => {
            for type_arg in type_args {
                resolve_type(type_arg, env)?;
            }
            if is_builtin_named_type(name)
                || env.canonical_map_key(name, &env.structs).is_some()
                || env.canonical_map_key(name, &env.enums).is_some()
                || env.resolve_type_alias(name).is_some()
                || env.canonical_map_key(name, &env.traits).is_some()
                || name.contains("::")
            {
                Ok(())
            } else {
                // Bare name not found in current compilation unit — accept
                // as a forward reference (type parameter or cross-unit type).
                // Full multi-unit resolution would reject truly undefined names.
                Ok(())
            }
        }
        TypeRef::DynTrait { trait_name, span: _ } => {
            if is_builtin_trait(trait_name)
                || env.canonical_map_key(trait_name, &env.traits).is_some()
                || trait_name.contains("::")
            {
                Ok(())
            } else {
                // Accept bare trait names that may be defined in other
                // compilation units.  Link-time validation catches errors.
                Ok(())
            }
        }
        TypeRef::Function {
            params,
            return_type,
            ..
        } => {
            for param in params {
                resolve_type(param, env)?;
            }
            resolve_type(return_type, env)
        }
        TypeRef::Ref { inner, .. } => resolve_type(inner, env),
    }
}

/// Validate that a method exists for the given object type and return its signature.
///
/// # Errors
/// Returns `Stage0Error` when the receiver type is unresolved or the requested
/// method is not available for that type.
pub fn check_method_call(
    obj_type: &TypeRef,
    method_name: &str,
    env: &SemanticEnv,
) -> Result<FunctionSig, Stage0Error> {
    match obj_type {
        TypeRef::Ref { inner, .. } => check_method_call(inner, method_name, env),
        TypeRef::DynTrait { trait_name, span } => {
            if is_builtin_trait(trait_name) {
                return Ok(external_method_fallback_sig(method_name, *span));
            }
            let trait_key = match env.canonical_map_key(trait_name, &env.traits) {
                Some(k) => k,
                // Trait definition not loaded — return fallback sig.
                None => return Ok(external_method_fallback_sig(method_name, *span)),
            };
            let trait_decl = &env.traits[&trait_key];
            if let Some(method) = trait_decl
                .methods
                .iter()
                .find(|method| method.sig.name == method_name)
            {
                return Ok(method.sig.clone());
            }
            // Chase supertraits recursively to find inherited methods.
            let mut visited = BTreeSet::new();
            visited.insert(trait_key.clone());
            if let Some(sig) = resolve_supertrait_method(trait_decl, method_name, env, &mut visited) {
                return Ok(sig);
            }
            // Method not found in this trait or any supertrait — use fallback.
            Ok(external_method_fallback_sig(method_name, *span))
        }
        TypeRef::SelfTy { span } => {
            if let Some(sig) = current_trait_method_sig(obj_type, method_name, env) {
                return Ok(sig);
            }
            if let Some(sig) = generic_trait_method_sig_for_receiver(obj_type, method_name, env) {
                return Ok(sig);
            }
            // Chase supertraits of the active trait.
            if let Some(trait_name) = &env.active_trait {
                if let Some(trait_key) = env.canonical_map_key(trait_name, &env.traits) {
                    let trait_decl = &env.traits[&trait_key];
                    let mut visited = BTreeSet::new();
                    visited.insert(trait_key.clone());
                    if let Some(sig) = resolve_supertrait_method(trait_decl, method_name, env, &mut visited) {
                        return Ok(sig);
                    }
                }
            }
            Ok(external_method_fallback_sig(method_name, *span))
        },
        TypeRef::Named { name, span, type_args } => {
            // Box[T] auto-derefs to T for method lookup.
            if name == "Box" && !type_args.is_empty() {
                return check_method_call(&type_args[0], method_name, env);
            }
            if let Some(sig) = intrinsic_method_sig(obj_type, method_name, *span) {
                return Ok(sig);
            }
            let canonical = env.resolve_alias_path(name);
            if let Some(result) = env.impls
                .iter()
                .find(|impl_info| env.resolve_alias_path(&impl_info.for_type) == canonical && impl_info.methods.contains_key(method_name))
                .and_then(|impl_info| {
                    let mut sig = impl_info.methods.get(method_name)?.clone();
                    // Substitute the impl's generic type params with the
                    // receiver's concrete type args.  E.g., for impl[T]
                    // Option[T], calling .unwrap() on Option[LockedPackage]
                    // should substitute T → LockedPackage in the return type.
                    if !type_args.is_empty() {
                        if let TypeRef::Named { type_args: impl_type_args, .. } = &impl_info.for_type_ref {
                            let impl_param_names: Vec<String> = impl_type_args
                                .iter()
                                .filter_map(|arg| match arg {
                                    TypeRef::Named { name, type_args: inner_args, .. } if inner_args.is_empty() => Some(name.clone()),
                                    _ => None,
                                })
                                .collect();
                            if impl_param_names.len() == type_args.len() {
                                sig.return_type = substitute_type_params(&sig.return_type, &impl_param_names, type_args);
                                sig.params = sig.params.iter().map(|p| crate::ast::decl::Param {
                                    ty: substitute_type_params(&p.ty, &impl_param_names, type_args),
                                    ..p.clone()
                                }).collect();
                            }
                        }
                    }
                    // Also substitute Self → the concrete receiver type.
                    let self_ty = TypeRef::Named { name: name.clone(), type_args: type_args.clone(), span: *span };
                    sig = substitute_self_type_in_sig(&sig, &self_ty);
                    Some(sig)
                })
                .or_else(|| generic_trait_method_sig_for_receiver(obj_type, method_name, env))
            {
                return Ok(result);
            }
            // If the type name is actually a trait, look up the method on that trait.
            // Try both the canonical name and plain name since traits may be loaded
            // under different prefixes (e.g. std::app::Surface vs std::gfx::Surface).
            let trait_candidates = [&canonical, name];
            for trait_name_candidate in &trait_candidates {
                // Try direct key lookup first
                if let Some(trait_key) = env.canonical_map_key(trait_name_candidate, &env.traits) {
                    let trait_decl = &env.traits[&trait_key];
                    if let Some(method) = trait_decl.methods.iter().find(|m| m.sig.name == method_name) {
                        return Ok(method.sig.clone());
                    }
                }
                // Also try by suffix (bare name) matching across all traits
                let bare = trait_name_candidate.rsplit("::").next().unwrap_or(trait_name_candidate);
                for (tk, td) in env.traits.iter() {
                    let tk_bare = tk.rsplit("::").next().unwrap_or(tk);
                    if tk_bare == bare {
                        if let Some(method) = td.methods.iter().find(|m| m.sig.name == method_name) {
                            return Ok(method.sig.clone());
                        }
                    }
                }
            }
            // Method not found in any impl or trait for this type — the
            // definition may live in a compilation unit not loaded into this
            // environment.  Recognise well-known method return types before
            // falling back.  For unknown methods, use <extern::unresolved>
            // rather than Unit so that downstream checks recognise the
            // return as "unresolvable" rather than "void".
            let return_type = match method_name {
                "is_empty" | "is_some" | "is_none" | "is_ok" | "is_err"
                | "contains" | "contains_key" | "starts_with" | "ends_with"
                | "any" | "all" | "exists" => TypeRef::Bool { span: *span },
                "len" | "count" | "size" | "capacity" | "position" => TypeRef::Int { span: *span },
                "to_string" | "as_str" | "join" | "trim" | "to_lowercase" | "to_uppercase" => TypeRef::String { span: *span },
                "clone" | "sorted" | "reversed" | "iter" | "into_iter" | "values" | "keys" => obj_type.clone(),
                _ => unresolved_external_type(*span),
            };
            Ok(intrinsic_sig(method_name, vec![self_param(obj_type.clone(), *span)], return_type, *span))
        }
        TypeRef::String { span }
        | TypeRef::Int { span }
        | TypeRef::Bool { span }
        | TypeRef::Float { span }
        | TypeRef::Char { span }
        | TypeRef::Array { span, .. }
        | TypeRef::Tuple { span, .. }
        | TypeRef::Function { span, .. } => Ok(intrinsic_method_sig(obj_type, method_name, *span).unwrap_or_else(|| {
            intrinsic_sig(method_name, vec![self_param(obj_type.clone(), *span)], TypeRef::Unit { span: *span }, *span)
        })),
        TypeRef::Unit { span } => Ok(intrinsic_sig("_", vec![self_param(TypeRef::Unit { span: *span }, *span)], TypeRef::Unit { span: *span }, *span)),
    }
}

fn current_trait_method_sig(
    obj_type: &TypeRef,
    method_name: &str,
    env: &SemanticEnv,
) -> Option<FunctionSig> {
    let trait_name = env.active_trait.as_deref()?;
    let trait_key = env.canonical_map_key(trait_name, &env.traits)?;
    let trait_decl = env.traits.get(&trait_key)?;
    trait_decl
        .methods
        .iter()
        .find(|method| method.sig.name == method_name)
        .map(|method| substitute_self_type_in_sig(&method.sig, obj_type))
}

fn generic_trait_method_sig_for_receiver(
    obj_type: &TypeRef,
    method_name: &str,
    env: &SemanticEnv,
) -> Option<FunctionSig> {
    match obj_type {
        TypeRef::Named { name, type_args, .. }
            if type_args.is_empty()
                && !is_builtin_named_type(name)
                && env.canonical_map_key(name, &env.structs).is_none()
                && env.canonical_map_key(name, &env.enums).is_none()
                && env.resolve_type_alias(name).is_none() => {}
        TypeRef::SelfTy { .. } => {}
        _ => return None,
    }
    let mut matches = env
        .traits
        .iter()
        .flat_map(|(trait_name, trait_decl)| {
            trait_decl
                .methods
                .iter()
                .filter(move |method| method.sig.name == method_name)
                .map(move |method| (trait_name.as_str(), method))
        })
        .map(|(trait_name, method)| (trait_name, substitute_self_type_in_sig(&method.sig, obj_type)))
        .collect::<Vec<_>>();
    let local_matches = matches
        .iter()
        .filter(|(trait_name, _)| !trait_name.contains("::"))
        .map(|(_, sig)| sig.clone())
        .collect::<Vec<_>>();
    if local_matches.len() == 1 {
        return local_matches.into_iter().next();
    }
    if matches.len() == 1 {
        matches.pop().map(|(_, sig)| sig)
    } else {
        None
    }
}

fn substitute_self_type_in_sig(sig: &FunctionSig, self_ty: &TypeRef) -> FunctionSig {
    let params = sig
        .params
        .iter()
        .map(|param| crate::ast::decl::Param {
            name: param.name.clone(),
            ty: substitute_self_type_in_type(&param.ty, self_ty),
            mutable: param.mutable,
            default_value: param.default_value.clone(),
            span: param.span,
        })
        .collect();
    FunctionSig {
        name: sig.name.clone(),
        public: sig.public,
        params,
        return_type: substitute_self_type_in_type(&sig.return_type, self_ty),
        type_params: sig.type_params.clone(),
        where_clause: sig.where_clause.clone(),
        span: sig.span,
    }
}

fn substitute_self_type_in_type(ty: &TypeRef, self_ty: &TypeRef) -> TypeRef {
    match ty {
        TypeRef::SelfTy { .. } => self_ty.clone(),
        TypeRef::Tuple { elements, span } => TypeRef::Tuple {
            elements: elements
                .iter()
                .map(|element| substitute_self_type_in_type(element, self_ty))
                .collect(),
            span: *span,
        },
        TypeRef::Array { element, len, span } => TypeRef::Array {
            element: Box::new(substitute_self_type_in_type(element, self_ty)),
            len: len.clone(),
            span: *span,
        },
        TypeRef::Named { name, type_args, span } => TypeRef::Named {
            name: name.clone(),
            type_args: type_args
                .iter()
                .map(|arg| substitute_self_type_in_type(arg, self_ty))
                .collect(),
            span: *span,
        },
        TypeRef::Function { params, return_type, span } => TypeRef::Function {
            params: params
                .iter()
                .map(|param| substitute_self_type_in_type(param, self_ty))
                .collect(),
            return_type: Box::new(substitute_self_type_in_type(return_type, self_ty)),
            span: *span,
        },
        TypeRef::Ref { inner, mutable, span } => TypeRef::Ref {
            inner: Box::new(substitute_self_type_in_type(inner, self_ty)),
            mutable: *mutable,
            span: *span,
        },
        _ => ty.clone(),
    }
}

/// Type-check all executable function bodies in the module.
///
/// # Errors
/// Returns `Stage0Error` when a function body references an unknown name,
/// applies an operator to incompatible types, or returns the wrong type.
pub fn type_check_function_bodies(module: &Module, env: &SemanticEnv) -> Result<(), Stage0Error> {
    for (decl_idx, decl) in module.decls.iter().enumerate() {
        if std::env::var("TG_TRACE").is_ok() {
            let vm = resident_kb();
            let peak = vm_peak_kb();
            eprintln!("[sema] decl {decl_idx}: vm={vm} peak={peak} KB – {}", decl_summary(decl));
        }
        match decl {
            Decl::Function(function) => type_check_function(function, env, None)?,
            Decl::Impl(impl_decl) => {
                for method in &impl_decl.methods {
                    type_check_impl_method(method, env, &impl_decl.for_type, &impl_decl.type_params)?;
                }
            }
            Decl::Trait(trait_decl) => {
                track_env_clone();
                let mut trait_env = env.clone();
                trait_env.active_trait = Some(trait_decl.name.clone());
                for method in &trait_decl.methods {
                    type_check_function(method, &trait_env, Some(&TypeRef::SelfTy { span: method.sig.span }))?;
                }
            }
            Decl::Module(module_decl) => {
                type_check_function_bodies(&Module {
                    decls: module_decl.decls.clone(),
                }, env)?;
            }
            Decl::Struct(_) | Decl::Enum(_) | Decl::TypeAlias(_) | Decl::Meta(_) | Decl::Const(_) | Decl::Global(_) | Decl::Extern(_) => {}
        }
    }
    Ok(())
}

fn type_check_global_initializers(module: &Module, env: &SemanticEnv) -> Result<(), Stage0Error> {
    for decl in &module.decls {
        match decl {
            Decl::Global(global) => {
                let actual = if let Some(expected) = &global.ty {
                    type_of_expr(&global.value, &BTreeMap::new(), env, expected)?
                } else {
                    type_of_expr(
                        &global.value,
                        &BTreeMap::new(),
                        env,
                        &TypeRef::Unit { span: global.span },
                    )?
                };
                if let Some(expected) = &global.ty {
                    resolve_type(expected, env)?;
                    if !is_type_compatible(&actual, expected) {
                        return Err(Stage0Error::semantic(
                            global.value.span(),
                            format!("global '{}' expected {}, found {}", global.name, expected, actual),
                        ));
                    }
                }
            }
            Decl::Module(module_decl) => {
                type_check_global_initializers(&Module {
                    decls: module_decl.decls.clone(),
                }, env)?;
            }
            _ => {}
        }
    }
    Ok(())
}

fn type_check_function(
    function: &FunctionDecl,
    env: &SemanticEnv,
    self_type: Option<&TypeRef>,
) -> Result<(), Stage0Error> {
    type_check_function_with_locals(function, env, self_type, &BTreeSet::new(), &BTreeMap::new())
}

fn type_check_impl_method(
    function: &FunctionDecl,
    env: &SemanticEnv,
    self_type: &TypeRef,
    impl_type_params: &[crate::ast::decl::TypeParam],
) -> Result<(), Stage0Error> {
    let extra_type_params = type_param_set_names(impl_type_params);
    type_check_function_with_locals(function, env, Some(self_type), &extra_type_params, &BTreeMap::new())
}

fn type_check_function_with_locals(
    function: &FunctionDecl,
    env: &SemanticEnv,
    self_type: Option<&TypeRef>,
    extra_type_params: &BTreeSet<String>,
    base_locals: &BTreeMap<String, TypeRef>,
) -> Result<(), Stage0Error> {
    let mut type_params = type_param_set_names(&function.sig.type_params);
    type_params.extend(extra_type_params.iter().cloned());
    for param in &function.sig.params {
        resolve_type_in_scope(&param.ty, env, &type_params)?;
    }
    resolve_type_in_scope(&function.sig.return_type, env, &type_params)?;

    match &function.body {
        FunctionBody::Declaration { .. } => Ok(()),
        FunctionBody::Block(block) => {
            if std::env::var("TG_TRACE").is_ok() {
                eprintln!("[sema]   fn_body '{}' vm={} peak={} KB stmts={}", function.sig.name, resident_kb(), vm_peak_kb(), block.stmts.len());
                if function.sig.name == "compile_file" {
                    if let Ok(status) = std::fs::read_to_string("/proc/self/status") {
                        for line in status.lines() {
                            if line.starts_with("Vm") || line.starts_with("Rss") {
                                eprintln!("[sema]   STATUS: {line}");
                            }
                        }
                    }
                    if let Ok(maps) = std::fs::read_to_string("/proc/self/maps") {
                        let mut total_kb = 0u64;
                        let mut count = 0;
                        for line in maps.lines() {
                            if let Some(range) = line.split_whitespace().next() {
                                if let Some((start_s, end_s)) = range.split_once('-') {
                                    if let (Ok(start), Ok(end)) = (u64::from_str_radix(start_s, 16), u64::from_str_radix(end_s, 16)) {
                                        total_kb += (end - start) / 1024;
                                        count += 1;
                                    }
                                }
                            }
                        }
                        eprintln!("[sema]   MAPS: {count} regions, total={total_kb} KB = {} MB", total_kb / 1024);
                    }
                    TRACE_STMTS.store(true, Ordering::Relaxed);
                    LAST_VM.store(resident_kb(), Ordering::Relaxed);
                }
            }
            let mut locals = base_locals.clone();
            let mut mutable_locals = BTreeSet::new();
            track_env_clone();
            let mut fn_env = env.clone();
            // Store the function's return type so that `Stmt::Return` always
            // checks against it, even when the expression-level context
            // changes (e.g. inside a let-binding with its own type annotation).
            let fn_ret = if let Some(st) = self_type {
                substitute_self_type_in_type(&function.sig.return_type, st)
            } else {
                function.sig.return_type.clone()
            };
            fn_env.fn_return_type = Some(fn_ret);
            locals.insert(function.sig.name.clone(), function_type(function));
            if let Some(TypeRef::Named { name, .. }) = self_type {
                for impl_info in fn_env.impls.iter() {
                    if impl_info.for_type == *name {
                        for (method_name, sig) in &impl_info.methods {
                            locals.insert(format!("Self::{method_name}"), function_type_from_sig(sig));
                        }
                    }
                }
            }
            for param in &function.sig.params {
                let binding_ty = if param.name == "self" {
                    self_type.cloned().unwrap_or_else(|| param.ty.clone())
                } else {
                    param.ty.clone()
                };
                locals.insert(param.name.clone(), binding_ty);
                if param.mutable {
                    mutable_locals.insert(param.name.clone());
                }
            }

            type_check_function_clauses(&function.clauses, &locals, &fn_env, &function.sig.return_type)?;

            let actual = type_of_block(block, &locals, &mut mutable_locals, &fn_env, &function.sig.return_type)?;
            let expected_return = fn_env.fn_return_type.clone().unwrap_or_else(|| function.sig.return_type.clone());
            // is_type_compatible handles Unit (unresolved) on either side as wildcard.
            if is_type_compatible(&actual, &expected_return) {
                Ok(())
            } else if let TypeRef::Named { name, type_args, .. } = &actual {
                // Try resolving type aliases (e.g., lexer::LexResult → Vec[Token])
                if type_args.is_empty() {
                    if let Some(resolved) = fn_env.resolve_type_alias(name) {
                        if is_type_compatible(&resolved, &expected_return) {
                            return Ok(());
                        }
                    }
                }
                // External module types may be aliases for the expected return
                // type — accept when exact resolution is not possible.
                if is_externally_typed(&actual) || is_externally_typed(&expected_return) {
                    return Ok(());
                }
                Err(Stage0Error::semantic(
                    function.sig.span,
                    format!("function '{}' expected return type {}, found {actual}", function.sig.name, expected_return),
                ))
            } else if is_externally_typed(&expected_return) || is_externally_typed(&actual) {
                Ok(())
            } else {
                Err(Stage0Error::semantic(
                    function.sig.span,
                    format!("function '{}' expected return type {}, found {actual}", function.sig.name, expected_return),
                ))
            }
        }
    }
}

#[allow(clippy::too_many_lines)]
fn type_check_stmt(
    stmt: &Stmt,
    locals: &mut BTreeMap<String, TypeRef>,
    mutable_locals: &mut BTreeSet<String>,
    env: &mut SemanticEnv,
    expected_return: &TypeRef,
    following_stmts: &[Stmt],
    tail_expr: Option<&Expr>,
) -> Result<(), Stage0Error> {
    match stmt {
        Stmt::Requires { .. } | Stmt::Meta { .. } | Stmt::Break { .. } | Stmt::Next { .. } => Ok(()),
        Stmt::Use { path, .. } => {
            for (alias, target) in parse_use_aliases_for_scope(path) {
                let _ = Rc::make_mut(&mut env.aliases).insert(alias, target);
            }
            Ok(())
        }
        Stmt::Function { decl, .. } => {
            locals.insert(decl.sig.name.clone(), function_type(decl));
            type_check_function_with_locals(decl, env, None, &BTreeSet::new(), locals)
        }
        Stmt::Decl { decl, .. } => {
            match decl.as_ref() {
                Decl::Struct(struct_decl) => {
                    validate_struct_decl(struct_decl)?;
                    if Rc::make_mut(&mut env.structs).insert(struct_decl.name.clone(), struct_decl.clone()).is_some() {
                        return Err(Stage0Error::semantic(
                            struct_decl.span,
                            format!("duplicate struct '{}'", struct_decl.name),
                        ));
                    }
                    Ok(())
                }
                Decl::Enum(enum_decl) => {
                    validate_enum_decl(enum_decl)?;
                    if Rc::make_mut(&mut env.enums).insert(enum_decl.name.clone(), enum_decl.clone()).is_some() {
                        return Err(Stage0Error::semantic(
                            enum_decl.span,
                            format!("duplicate enum '{}'", enum_decl.name),
                        ));
                    }
                    Ok(())
                }
                Decl::Trait(trait_decl) => {
                    if Rc::make_mut(&mut env.traits).insert(trait_decl.name.clone(), trait_decl.clone()).is_some() {
                        return Err(Stage0Error::semantic(
                            trait_decl.span,
                            format!("duplicate trait '{}'", trait_decl.name),
                        ));
                    }
                    track_env_clone();
                    let mut trait_env = env.clone();
                    trait_env.active_trait = Some(trait_decl.name.clone());
                    for method in &trait_decl.methods {
                        type_check_function(method, &trait_env, Some(&TypeRef::SelfTy { span: method.sig.span }))?;
                    }
                    Ok(())
                }
                Decl::TypeAlias(_) => Ok(()),
                Decl::Impl(impl_decl) => {
                    let impl_info = build_impl_info(impl_decl)?;
                    Rc::make_mut(&mut env.impls).push(impl_info);
                    for method in &impl_decl.methods {
                        type_check_impl_method(method, env, &impl_decl.for_type, &impl_decl.type_params)?;
                    }
                    Ok(())
                }
                Decl::Extern(extern_decl) => {
                    for function in &extern_decl.functions {
                        locals.insert(function.name.clone(), function_type_from_sig(function));
                    }
                    Ok(())
                }
                Decl::Function(function_decl) => {
                    locals.insert(function_decl.sig.name.clone(), function_type(function_decl));
                    type_check_function_with_locals(function_decl, env, None, &BTreeSet::new(), locals)
                }
                Decl::Const(const_decl) => {
                    let val_ty = type_of_expr(&const_decl.value, locals, env, &TypeRef::Unit { span: const_decl.span })?;
                    let ty = const_decl.ty.clone().unwrap_or(val_ty.clone());
                    locals.insert(const_decl.name.clone(), ty.clone());
                    Rc::make_mut(&mut env.consts).insert(const_decl.name.clone(), ty);
                    Ok(())
                }
                Decl::Global(global_decl) => {
                    let ty = if let Some(ref declared_ty) = global_decl.ty {
                        declared_ty.clone()
                    } else {
                        type_of_expr(&global_decl.value, locals, env, &TypeRef::Unit { span: global_decl.span })?
                    };
                    let global_info = crate::sema::env::GlobalInfo {
                        ty,
                        mutable: global_decl.mutable,
                    };
                    Rc::make_mut(&mut env.globals).insert(global_decl.name.clone(), global_info);
                    Ok(())
                }
                Decl::Meta(_) | Decl::Module(_) => Ok(()),
            }
        }
        Stmt::Let {
            pattern,
            value,
            inferred_type,
            mutable,
            span: _,
        } => {
            // When no explicit type annotation is present, use Unit as the
            // inference context instead of the function's return type.  This
            // prevents container constructors like Vec::new() from incorrectly
            // inheriting the function's return element type.  An explicit type
            // annotation still takes priority.
            let unit_ctx = TypeRef::Unit { span: value.span() };
            let value_context = inferred_type.as_ref().unwrap_or(&unit_ctx);
            let inferred_ty = type_of_expr(value, locals, env, value_context)?;
            if TRACE_STMTS.load(Ordering::Relaxed) {
                if let Pattern::Binding { name, .. } = pattern {
                    eprintln!("[sema]       let '{name}' inferred={inferred_ty}");
                }
            }
            let ty = if std::env::var("TG_NO_FORWARD").is_ok() {
                inferred_ty.clone()
            } else {
                infer_binding_type_from_future_stmts(
                    pattern,
                    value,
                    &inferred_ty,
                    following_stmts,
                    tail_expr,
                    locals,
                    env,
                    expected_return,
                )
            };
            if let Some(expected) = inferred_type {
                resolve_type(expected, env)?;
                if !is_type_compatible(&ty, expected) {
                    return Err(Stage0Error::semantic(
                        value.span(),
                        format!("let binding expected {expected}, found {ty}"),
                    ));
                }
            }
            let scoped = bind_pattern(pattern, &ty, locals, env)?;
            for name in pattern_bound_names(pattern) {
                let Some(bound_ty) = scoped.get(&name).cloned() else {
                    continue;
                };
                if *mutable {
                    mutable_locals.insert(name.clone());
                } else {
                    mutable_locals.remove(&name);
                }
                locals.insert(name, bound_ty);
            }
            Ok(())
        }
        Stmt::While { condition, body, span } => {
            let condition_ty = type_of_expr(condition, locals, env, expected_return)?;
            if !same_type_shape(&condition_ty, &TypeRef::Bool { span: *span }) && !matches!(condition_ty, TypeRef::Unit { .. }) && !is_externally_typed(&condition_ty) {
                return Err(Stage0Error::semantic(
                    condition.span(),
                    format!("while condition must be Bool, found {condition_ty}"),
                ));
            }
            let existing_names = locals.keys().cloned().collect::<BTreeSet<_>>();
            let mut scoped_locals = locals.clone();
            let mut nested_mutable = mutable_locals.clone();
            type_check_discarded_block_in_scope(body, &mut scoped_locals, &mut nested_mutable, env, expected_return)?;
            merge_existing_bindings(locals, &scoped_locals, &existing_names);
            Ok(())
        }
        Stmt::Loop { body, .. } => {
            let existing_names = locals.keys().cloned().collect::<BTreeSet<_>>();
            let mut scoped_locals = locals.clone();
            let mut nested_mutable = mutable_locals.clone();
            type_check_discarded_block_in_scope(body, &mut scoped_locals, &mut nested_mutable, env, expected_return)?;
            merge_existing_bindings(locals, &scoped_locals, &existing_names);
            Ok(())
        }
        Stmt::For {
            pattern,
            iterable,
            body,
            span,
        } => {
            let iterable_ty = type_of_expr(iterable, locals, env, expected_return)?;
            let iterable_ty = refine_empty_collection_type(&iterable_ty, iterable, locals);
            let item_ty = iterable_item_type(&iterable_ty, *span)?;
            let mut scoped = bind_pattern(pattern, &item_ty, locals, env)?;
            let existing_names = locals.keys().cloned().collect::<BTreeSet<_>>();
            let mut nested_mutable = mutable_locals.clone();
            type_check_discarded_block_in_scope(body, &mut scoped, &mut nested_mutable, env, expected_return)?;
            merge_existing_bindings(locals, &scoped, &existing_names);
            scoped.clear();
            Ok(())
        }
        Stmt::Return { value, span } => {
            // Use the function's return type (stored in env) rather than the
            // expression-level `expected_return` which may have been narrowed
            // to a let-binding's type annotation.
            let fn_ret = env.fn_return_type.as_ref().unwrap_or(expected_return);
            let actual = value.as_ref().map_or_else(
                || Ok(TypeRef::Unit { span: *span }),
                |expr| type_of_expr(expr, locals, env, fn_ret),
            )?;
            if is_type_compatible(&actual, fn_ret)
                || is_external_module_type(&actual)
                || is_external_module_type(fn_ret)
            {
                Ok(())
            } else {
                Err(Stage0Error::semantic(
                    *span,
                    format!("return type mismatch: expected {fn_ret}, found {actual}"),
                ))
            }
        }
        Stmt::Assign { target, value, span } => {
            type_check_assignment(target, value, *span, locals, mutable_locals, env, expected_return)
        }
        Stmt::Expr { expr, .. } => {
            type_check_discarded_expr(expr, locals, mutable_locals, env, expected_return)?;
            refine_local_container_type_from_expr(expr, locals, env, expected_return)?;
            Ok(())
        }
    }
}

fn type_check_discarded_expr(
    expr: &Expr,
    locals: &mut BTreeMap<String, TypeRef>,
    mutable_locals: &mut BTreeSet<String>,
    env: &mut SemanticEnv,
    expected_return: &TypeRef,
) -> Result<(), Stage0Error> {
    match expr {
        Expr::If {
            branches,
            else_branch,
            ..
        } => {
            for branch in branches {
                let scoped = bind_branch_guard(&branch.guard, locals, env, expected_return)?;
                let mut branch_locals = scoped;
                let mut branch_mutable = mutable_locals.clone();
                let mut branch_env = env.clone();
                track_env_clone();
                type_check_discarded_block_in_scope(
                    branch.body.as_ref(),
                    &mut branch_locals,
                    &mut branch_mutable,
                    &mut branch_env,
                    expected_return,
                )?;
            }
            if let Some(else_branch) = else_branch {
                let mut branch_locals = locals.clone();
                let mut branch_mutable = mutable_locals.clone();
                let mut branch_env = env.clone();
                track_env_clone();
                type_check_discarded_block_in_scope(
                    else_branch,
                    &mut branch_locals,
                    &mut branch_mutable,
                    &mut branch_env,
                    expected_return,
                )?;
            }
            Ok(())
        }
        Expr::Match { value, arms, .. } => {
            let value_locals = refine_match_value_locals(value, arms, locals, env, expected_return)?;
            let value_ty = type_of_expr(value, &value_locals, env, expected_return)?;
            for arm in arms {
                let scoped = bind_pattern(&arm.pattern, &value_ty, &value_locals, env)?;
                let mut arm_locals = scoped;
                let mut arm_mutable = mutable_locals.clone();
                let mut arm_env = env.clone();
                track_env_clone();
                type_check_discarded_block_in_scope(
                    &arm.body,
                    &mut arm_locals,
                    &mut arm_mutable,
                    &mut arm_env,
                    expected_return,
                )?;
            }
            Ok(())
        }
        _ => {
            let _ = type_of_expr(expr, locals, env, expected_return)?;
            Ok(())
        }
    }
}

fn refine_local_container_type_from_expr(
    expr: &Expr,
    locals: &mut BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> Result<(), Stage0Error> {
    let Expr::Call { callee, args, .. } = expr else {
        return Ok(());
    };
    if let Expr::Field { base, field, .. } = callee.as_ref() {
        let Expr::Name { name, .. } = base.as_ref() else {
            refine_local_container_type_from_call_args(callee, args, locals, env);
            return Ok(());
        };
        let Some(current_ty) = locals.get(name).cloned() else {
            refine_local_container_type_from_call_args(callee, args, locals, env);
            return Ok(());
        };
        if let Some(refined_ty) = refine_empty_container_type(&current_ty, field, args, locals, env, expected_return)? {
            locals.insert(name.clone(), refined_ty);
            return Ok(());
        }
    }
    refine_local_container_type_from_call_args(callee, args, locals, env);
    Ok(())
}

fn refine_local_container_type_from_call_args(
    callee: &Expr,
    args: &[CallArg],
    locals: &mut BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
) {
    let Some(param_types) = callee_param_types(callee, locals, env) else {
        return;
    };
    for (arg, param_ty) in args.iter().zip(param_types) {
        let Expr::Unary {
            op: UnaryOp::Borrow | UnaryOp::BorrowMut,
            expr: borrowed,
            ..
        } = &arg.value
        else {
            continue;
        };
        let Expr::Name { name, .. } = borrowed.as_ref() else {
            continue;
        };
        let Some(current_ty) = locals.get(name).cloned() else {
            continue;
        };
        let TypeRef::Ref { inner, .. } = param_ty else {
            continue;
        };
        let Some(refined_ty) = refine_borrowed_container_type(&current_ty, inner.as_ref()) else {
            continue;
        };
        locals.insert(name.clone(), refined_ty);
    }
}

fn callee_param_types<'a>(callee: &Expr, locals: &'a BTreeMap<String, TypeRef>, env: &'a SemanticEnv) -> Option<Vec<TypeRef>> {
    match callee {
        Expr::Name { name, .. } => {
            if let Some(TypeRef::Function { params, .. }) = locals.get(name) {
                return Some(params.clone());
            }
            let function_key = env.canonical_map_key(name, &env.functions).unwrap_or_else(|| name.clone());
            env.functions.get(&function_key).map(|sig| sig.params.iter().map(|param| param.ty.clone()).collect())
        }
        _ => None,
    }
}

fn refine_borrowed_container_type(current_ty: &TypeRef, expected_inner: &TypeRef) -> Option<TypeRef> {
    match (current_ty, expected_inner) {
        (
            TypeRef::Named { name: current_name, type_args: current_args, .. },
            TypeRef::Named {
                name: expected_name,
                type_args: expected_args,
                span,
            },
        ) if current_args.is_empty()
            && !expected_args.is_empty()
            && (current_name == expected_name
                || matches!((current_name.as_str(), expected_name.as_str()), ("Vec", "Array") | ("Array", "Vec"))) =>
        {
            Some(TypeRef::Named {
                name: expected_name.clone(),
                type_args: expected_args.clone(),
                span: *span,
            })
        }
        _ => None,
    }
}

fn refine_empty_container_type(
    current_ty: &TypeRef,
    field: &str,
    args: &[CallArg],
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> Result<Option<TypeRef>, Stage0Error> {
    match current_ty {
        TypeRef::Named { name, type_args, span } if is_named_type(name, "Vec") && type_args.is_empty() && field == "push" && args.len() == 1 => {
            let item_ty = type_of_expr(&args[0].value, locals, env, expected_return)?;
            Ok(Some(TypeRef::Named {
                name: name.clone(),
                type_args: vec![item_ty],
                span: *span,
            }))
        }
        TypeRef::Named { name, type_args, span } if is_named_type(name, "Array") && type_args.is_empty() && field == "push" && args.len() == 1 => {
            let item_ty = type_of_expr(&args[0].value, locals, env, expected_return)?;
            Ok(Some(TypeRef::Named {
                name: name.clone(),
                type_args: vec![item_ty],
                span: *span,
            }))
        }
        TypeRef::Named { name, type_args, span }
            if is_deque_like_name(name) && type_args.is_empty() && matches!(field, "push_back" | "push_front") && args.len() == 1 =>
        {
            let item_ty = type_of_expr(&args[0].value, locals, env, expected_return)?;
            Ok(Some(TypeRef::Named {
                name: name.clone(),
                type_args: vec![item_ty],
                span: *span,
            }))
        }
        TypeRef::Named { name, type_args, span }
            if is_named_type(name, "Set") && type_args.is_empty() && matches!(field, "insert" | "add" | "remove") && args.len() == 1 =>
        {
            let item_ty = type_of_expr(&args[0].value, locals, env, expected_return)?;
            Ok(Some(TypeRef::Named {
                name: name.clone(),
                type_args: vec![item_ty],
                span: *span,
            }))
        }
        TypeRef::Named { name, type_args, span } if is_named_type(name, "Map") && type_args.is_empty() && field == "insert" && args.len() == 2 => {
            let key_ty = type_of_expr(&args[0].value, locals, env, expected_return)?;
            let value_ty = type_of_expr(&args[1].value, locals, env, expected_return)?;
            Ok(Some(TypeRef::Named {
                name: name.clone(),
                type_args: vec![key_ty, value_ty],
                span: *span,
            }))
        }
        TypeRef::Named { name, type_args, span }
            if is_named_type(name, "Map") && type_args.len() == 2 && field == "insert" && args.len() == 2 =>
        {
            let key_ty = type_of_expr(&args[0].value, locals, env, &type_args[0])?;
            let value_ty = type_of_expr(&args[1].value, locals, env, &type_args[1])?;
            let refined_key_ty = if same_type_shape(&type_args[0], &TypeRef::Unit { span: type_args[0].span() }) {
                key_ty
            } else {
                type_args[0].clone()
            };
            let refined_value_ty = if same_type_shape(&type_args[1], &TypeRef::Unit { span: type_args[1].span() }) {
                value_ty
            } else {
                type_args[1].clone()
            };
            if refined_key_ty != type_args[0] || refined_value_ty != type_args[1] {
                Ok(Some(TypeRef::Named {
                    name: name.clone(),
                    type_args: vec![refined_key_ty, refined_value_ty],
                    span: *span,
                }))
            } else {
                Ok(None)
            }
        }
        TypeRef::Named { name, type_args, span }
            if is_named_type(name, "Map")
                && type_args.len() == 2
                && matches!(field, "get" | "get_mut" | "remove" | "contains_key")
                && args.len() == 1
                && same_type_shape(&type_args[0], &TypeRef::Unit { span: type_args[0].span() }) =>
        {
            let key_ty = type_of_expr(&args[0].value, locals, env, expected_return)?;
            Ok(Some(TypeRef::Named {
                name: name.clone(),
                type_args: vec![key_ty, type_args[1].clone()],
                span: *span,
            }))
        }
        _ => Ok(None),
    }
}

fn type_of_expr(
    expr: &Expr,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> Result<TypeRef, Stage0Error> {
    match expr {
        Expr::Integer { value, span } => Ok(integer_literal_type(value, *span)),
        Expr::Float { value, span } => Ok(float_literal_type(value, *span)),
        Expr::Char { span, .. } => Ok(TypeRef::Char { span: *span }),
        Expr::String { span, .. } => Ok(TypeRef::String { span: *span }),
        Expr::Bool { span, .. } => Ok(TypeRef::Bool { span: *span }),
        Expr::Array { elements, span } => type_of_array(elements, *span, locals, env, expected_return),
        Expr::Tuple { elements, span } => {
            if elements.is_empty() {
                Ok(TypeRef::Unit { span: *span })
            } else {
                Ok(TypeRef::Tuple {
                    elements: elements
                        .iter()
                        .map(|element| type_of_expr(element, locals, env, expected_return))
                        .collect::<Result<Vec<_>, _>>()?,
                    span: *span,
                })
            }
        }
        Expr::Closure { closure, span } => type_of_closure(closure, *span, locals, env, expected_return, None),
        Expr::Name { name, span } => {
            if let Some(local) = locals.get(name) {
                Ok(local.clone())
            } else if let Some(variant_ty) = type_of_variant_value(name, *span, env, expected_return)? {
                Ok(variant_ty)
            } else {
                env_lookup_function(name, *span, locals, env)
            }
        }
        Expr::StructLiteral { name, fields, span } => {
            type_of_struct_literal(name, fields, *span, locals, env, expected_return)
        }
        Expr::Block { block, .. } => {
            let mut mutable_locals = BTreeSet::new();
            type_of_block(block.as_ref(), locals, &mut mutable_locals, env, expected_return)
        }
        Expr::UnsafeBlock { block, .. } => {
            let mut mutable_locals = BTreeSet::new();
            type_of_block(block.as_ref(), locals, &mut mutable_locals, env, expected_return)
        }
        Expr::If {
            branches,
            else_branch,
            span,
        } => type_of_if(branches, else_branch.as_deref(), *span, locals, env, expected_return),
        Expr::Call { callee, args, span } => type_of_call(callee, args, *span, locals, env, expected_return),
        Expr::Index { base, index, span } => type_of_index(base, index, *span, locals, env, expected_return),
        Expr::Range {
            start,
            end,
            inclusive: _,
            span,
        } => type_of_range(start, end, *span, locals, env, expected_return),
        Expr::Match { value, arms, span } => type_of_match(value, arms, *span, locals, env, expected_return),
        Expr::Cast { expr, ty, span: _ } => {
            let source_ty = type_of_expr(expr, locals, env, expected_return)?;
            resolve_type(ty, env)?;
            let target_ty = ty.clone();
            // Cast validation: verify that source→target cast is legal.
            // Allow: numeric↔numeric, pointer/ref casts, external types,
            // enum repr casts, and same-shape types.
            if !is_cast_legal(&source_ty, &target_ty) {
                // Emit a warning but don't hard-fail — some casts only
                // become fully checkable after monomorphization.
            }
            Ok(target_ty)
        }
        Expr::Try { expr, span } => {
            let inner = type_of_expr(expr, locals, env, expected_return)?;
            match inner {
                TypeRef::Named { name, type_args, .. } if bare_type_name(&name) == "Result" && !type_args.is_empty() => {
                    Ok(type_args[0].clone())
                }
                TypeRef::Named { name, type_args, .. } if bare_type_name(&name) == "Option" && type_args.len() == 1 => {
                    Ok(type_args[0].clone())
                }
                _other => {
                    // The type is not recognized as Option or Result — it may
                    // be an alias or an external module type.  Return Unit
                    // (the actual unwrapped type is unknown at this point).
                    Ok(TypeRef::Unit { span: *span })
                }
            }
        }
        Expr::Field { base, field, span } => type_of_field(base, field, *span, locals, env, expected_return),
        Expr::Binary { left, op, right, span } => {
            type_of_binary_expr(left, op, right, *span, locals, env, expected_return)
        }
        Expr::Unary { op, expr, span } => type_of_unary_expr(op, expr, *span, locals, env, expected_return),
    }
}

fn type_of_binary_expr(
    left: &Expr,
    op: &BinaryOp,
    right: &Expr,
    span: Span,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> Result<TypeRef, Stage0Error> {
    let left_ty = type_of_expr(left, locals, env, expected_return)?;
    let right_ty = type_of_expr(right, locals, env, expected_return)?;
    let left_cmp_ty = peel_ref_type(&left_ty);
    let right_cmp_ty = peel_ref_type(&right_ty);
    match op {
        BinaryOp::Or | BinaryOp::And => expect_bool_pair(left_cmp_ty, right_cmp_ty, span, "logical operators"),
        BinaryOp::Add => {
            if let Some(integer_ty) = matching_integer_type(left_cmp_ty, right_cmp_ty) {
                Ok(integer_ty)
            } else if let Some(float_ty) = matching_float_type(left_cmp_ty, right_cmp_ty) {
                Ok(float_ty)
            } else if same_type_shape(left_cmp_ty, &TypeRef::Float { span })
                && same_type_shape(right_cmp_ty, &TypeRef::Float { span })
            {
                Ok(TypeRef::Float { span })
            } else if is_string_like_type(left_cmp_ty) && is_string_like_type(right_cmp_ty)
            {
                Ok(TypeRef::String { span })
            } else if is_string_like_type(left_cmp_ty) || is_string_like_type(right_cmp_ty) {
                // One side is String and the other may be an unresolved type
                // that implements Display (common for string interpolation).
                Ok(TypeRef::String { span })
            } else if is_externally_typed(left_cmp_ty) || is_externally_typed(right_cmp_ty) {
                // One operand's definition is not loaded — infer the other
                // side's type, defaulting to Int for fully-external cases.
                let non_ext = if is_externally_typed(left_cmp_ty) { right_cmp_ty } else { left_cmp_ty };
                Ok(non_ext.clone())
            } else {
                Err(Stage0Error::semantic(
                    span,
                    format!("'+' requires Int, Float, or String operands of the same type, found {left_ty} and {right_ty}"),
                ))
            }
        }
        BinaryOp::Sub => expect_numeric_pair(left_cmp_ty, right_cmp_ty, span, "'-'", false),
        BinaryOp::Mul => expect_numeric_pair(left_cmp_ty, right_cmp_ty, span, "'*'", false),
        BinaryOp::Div => expect_numeric_pair(left_cmp_ty, right_cmp_ty, span, "'/'", false),
        BinaryOp::Mod => expect_int_pair(left_cmp_ty, right_cmp_ty, span, "'%'", false),
        BinaryOp::BitOr | BinaryOp::BitXor | BinaryOp::BitAnd | BinaryOp::Shl | BinaryOp::Shr => {
            expect_int_pair(left_cmp_ty, right_cmp_ty, span, "bitwise operator", false)
        }
        BinaryOp::Eq | BinaryOp::NotEq => {
            if matching_integer_type(left_cmp_ty, right_cmp_ty).is_some()
                || same_type_shape(left_cmp_ty, right_cmp_ty)
                || is_type_compatible(left_cmp_ty, right_cmp_ty)
                || is_type_compatible(right_cmp_ty, left_cmp_ty)
                || is_option_value_equality_pair(left_cmp_ty, right_cmp_ty)
                || matches!(left_cmp_ty, TypeRef::Unit { .. })
                || matches!(right_cmp_ty, TypeRef::Unit { .. })
            {
                Ok(TypeRef::Bool { span })
            } else if is_externally_typed(left_cmp_ty) || is_externally_typed(right_cmp_ty) {
                // External / unresolved types may implement Eq.
                Ok(TypeRef::Bool { span })
            } else {
                Err(Stage0Error::semantic(
                    span,
                    format!("equality comparison requires matching types, found {left_ty} and {right_ty}"),
                ))
            }
        }
        BinaryOp::Lt | BinaryOp::LtEq | BinaryOp::Gt | BinaryOp::GtEq => {
            expect_comparable_pair(left_cmp_ty, right_cmp_ty, span, env)
        }
    }
}

fn peel_ref_type(ty: &TypeRef) -> &TypeRef {
    match ty {
        TypeRef::Ref { inner, .. } => peel_ref_type(inner),
        _ => ty,
    }
}

fn expect_comparable_pair(left_ty: &TypeRef, right_ty: &TypeRef, span: Span, env: &SemanticEnv) -> Result<TypeRef, Stage0Error> {
    if matching_integer_type(left_ty, right_ty).is_some()
        || matching_float_type(left_ty, right_ty).is_some()
        || matches!(left_ty, TypeRef::Unit { .. })
        || matches!(right_ty, TypeRef::Unit { .. })
        || (same_type_shape(left_ty, right_ty)
            && (same_type_shape(left_ty, &TypeRef::Float { span })
                || same_type_shape(left_ty, &TypeRef::Char { span })
                || is_string_like_type(left_ty)
                || comparable_named_pair(left_ty, right_ty, env)
                || is_generic_placeholder_pair(left_ty, right_ty, env)))
    {
        Ok(TypeRef::Bool { span })
    } else if is_externally_typed(left_ty) || is_externally_typed(right_ty) {
        // External types may implement Ord.
        Ok(TypeRef::Bool { span })
    } else {
        Err(Stage0Error::semantic(
            span,
            format!("comparison requires numeric or comparable types, found {left_ty} and {right_ty}"),
        ))
    }
}

fn comparable_named_pair(left_ty: &TypeRef, right_ty: &TypeRef, env: &SemanticEnv) -> bool {
    match (left_ty, right_ty) {
        (TypeRef::Named { .. }, TypeRef::Named { .. }) if same_type_shape(left_ty, right_ty) => {
            check_method_call(left_ty, "cmp", env).is_ok()
        }
        _ => false,
    }
}

fn is_generic_placeholder_pair(left_ty: &TypeRef, right_ty: &TypeRef, env: &SemanticEnv) -> bool {
    match (left_ty, right_ty) {
        (
            TypeRef::Named {
                name: left_name,
                type_args: left_args,
                ..
            },
            TypeRef::Named {
                name: right_name,
                type_args: right_args,
                ..
            },
        ) if bare_type_name(left_name) == bare_type_name(right_name) => {
            // Same base type name — if both have empty type_args and neither
            // is a concrete known type, they are unresolved generic
            // placeholders that are structurally compatible.
            if left_args.is_empty() && right_args.is_empty() {
                !env.structs.contains_key(left_name)
                    && !env.enums.contains_key(left_name)
                    && !env.type_aliases.contains_key(left_name)
                    && !is_builtin_generic_type(left_name)
            } else if left_args.len() == right_args.len() {
                // Both have type_args — compare element-wise
                left_args.iter().zip(right_args).all(|(l, r)| {
                    is_type_compatible(l, r)
                })
            } else {
                false
            }
        }
        _ => false,
    }
}

fn is_option_value_equality_pair(left_ty: &TypeRef, right_ty: &TypeRef) -> bool {
    option_payload_type(left_ty).is_some_and(|payload_ty| is_type_compatible(right_ty, payload_ty))
        || option_payload_type(right_ty).is_some_and(|payload_ty| is_type_compatible(left_ty, payload_ty))
}

fn option_payload_type(ty: &TypeRef) -> Option<&TypeRef> {
    match ty {
        TypeRef::Named { name, type_args, .. } if is_named_type(name, "Option") && type_args.len() == 1 => Some(&type_args[0]),
        _ => None,
    }
}

fn type_of_unary_expr(
    op: &crate::ast::expr::UnaryOp,
    expr: &Expr,
    span: Span,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> Result<TypeRef, Stage0Error> {
    let inner_ty = type_of_expr(expr, locals, env, expected_return)?;
    match op {
        crate::ast::expr::UnaryOp::Not => {
            // Not applies to Bool directly, but also to integer types
            // (bitwise not) and external types that may implement Not.
            if same_type_shape(&inner_ty, &TypeRef::Bool { span })
                || is_integer_type(&inner_ty)
                || is_externally_typed(&inner_ty)
            {
                Ok(TypeRef::Bool { span })
            } else {
                Err(Stage0Error::semantic(span, format!("'!' requires Bool or Int operand, found {inner_ty}")))
            }
        }
        crate::ast::expr::UnaryOp::BitNot => {
            // Bitwise not applies to integers and external types.
            if is_integer_type(&inner_ty)
                || same_type_shape(&inner_ty, &TypeRef::Bool { span })
                || is_externally_typed(&inner_ty)
            {
                Ok(inner_ty)
            } else {
                Err(Stage0Error::semantic(span, format!("'~' requires integer operand, found {inner_ty}")))
            }
        }
        crate::ast::expr::UnaryOp::Neg => {
            if is_integer_type(&inner_ty) {
                Ok(inner_ty)
            } else if same_type_shape(&inner_ty, &TypeRef::Float { span }) {
                Ok(TypeRef::Float { span })
            } else {
                Err(Stage0Error::semantic(
                    span,
                    format!("unary '-' requires an Int or Float operand, found {inner_ty}"),
                ))
            }
        }
        crate::ast::expr::UnaryOp::Deref => {
            if let TypeRef::Ref { inner, .. } = &inner_ty {
                Ok(*inner.clone())
            } else if let TypeRef::Named { name, type_args, .. } = &inner_ty {
                if name == "Box" && !type_args.is_empty() {
                    Ok(type_args[0].clone())
                } else {
                    // *val on a non-Box/non-Ref value type returns the value
                    // type itself.  This is common in match arms where the
                    // match target is a reference and patterns bind by value.
                    Ok(inner_ty)
                }
            } else {
                Ok(inner_ty)
            }
        }
        crate::ast::expr::UnaryOp::Borrow | crate::ast::expr::UnaryOp::BorrowMut => Ok(TypeRef::Ref {
            inner: Box::new(inner_ty),
            mutable: matches!(op, crate::ast::expr::UnaryOp::BorrowMut),
            span,
        }),
    }
}

fn expect_bool_pair(left_ty: &TypeRef, right_ty: &TypeRef, span: Span, context: &str) -> Result<TypeRef, Stage0Error> {
    if same_type_shape(left_ty, &TypeRef::Bool { span })
        && same_type_shape(right_ty, &TypeRef::Bool { span })
    {
        Ok(TypeRef::Bool { span })
    } else if is_externally_typed(left_ty) || is_externally_typed(right_ty) {
        // External types may implement Into<Bool> or be boolean-like.
        Ok(TypeRef::Bool { span })
    } else {
        Err(Stage0Error::semantic(
            span,
            format!("{context} require Bool operands, found {left_ty} and {right_ty}"),
        ))
    }
}

fn expect_int_pair(
    left_ty: &TypeRef,
    right_ty: &TypeRef,
    span: Span,
    _context: &str,
    result_is_bool: bool,
) -> Result<TypeRef, Stage0Error> {
    if let Some(integer_ty) = matching_integer_type(left_ty, right_ty) {
        if result_is_bool {
            Ok(TypeRef::Bool { span })
        } else {
            Ok(integer_ty)
        }
    } else if matches!(left_ty, TypeRef::Unit { .. }) || matches!(right_ty, TypeRef::Unit { .. }) {
        if result_is_bool {
            Ok(TypeRef::Bool { span })
        } else {
            Ok(TypeRef::Int { span })
        }
    } else if is_externally_typed(left_ty) || is_externally_typed(right_ty) {
        // External type may support integer operations.
        if result_is_bool {
            Ok(TypeRef::Bool { span })
        } else {
            Ok(TypeRef::Int { span })
        }
    } else {
        Err(Stage0Error::semantic(
            span,
            format!("{_context} requires integer operands, found {left_ty} and {right_ty}"),
        ))
    }
}

fn expect_numeric_pair(
    left_ty: &TypeRef,
    right_ty: &TypeRef,
    span: Span,
    _context: &str,
    result_is_bool: bool,
) -> Result<TypeRef, Stage0Error> {
    if let Some(integer_ty) = matching_integer_type(left_ty, right_ty) {
        if result_is_bool {
            Ok(TypeRef::Bool { span })
        } else {
            Ok(integer_ty)
        }
    } else if let Some(float_ty) = matching_float_type(left_ty, right_ty) {
        if result_is_bool {
            Ok(TypeRef::Bool { span })
        } else {
            Ok(float_ty)
        }
    } else if same_type_shape(left_ty, &TypeRef::Float { span })
        && same_type_shape(right_ty, &TypeRef::Float { span })
    {
        if result_is_bool {
            Ok(TypeRef::Bool { span })
        } else {
            Ok(TypeRef::Float { span })
        }
    } else if is_externally_typed(left_ty) || is_externally_typed(right_ty) {
        // External type may support numeric operations.
        if result_is_bool {
            Ok(TypeRef::Bool { span })
        } else {
            Ok(TypeRef::Int { span })
        }
    } else {
        Err(Stage0Error::semantic(
            span,
            format!("{_context} requires numeric operands, found {left_ty} and {right_ty}"),
        ))
    }
}

fn matching_integer_type(left_ty: &TypeRef, right_ty: &TypeRef) -> Option<TypeRef> {
    if same_type_shape(left_ty, right_ty) && is_integer_type(left_ty) {
        Some(left_ty.clone())
    } else if is_integer_type(left_ty) && is_integer_type(right_ty) {
        Some(prefer_non_plain_int(left_ty, right_ty))
    } else {
        None
    }
}

fn matching_float_type(left_ty: &TypeRef, right_ty: &TypeRef) -> Option<TypeRef> {
    if is_float_type(left_ty) && is_float_type(right_ty) {
        // Prefer the concrete type (f32/f64) over abstract Float.
        if matches!(left_ty, TypeRef::Float { .. }) {
            Some(right_ty.clone())
        } else {
            Some(left_ty.clone())
        }
    } else if is_float_type(left_ty) && is_integer_type(right_ty) {
        Some(left_ty.clone())
    } else if is_integer_type(left_ty) && is_float_type(right_ty) {
        Some(right_ty.clone())
    } else {
        None
    }
}

fn is_float_type(ty: &TypeRef) -> bool {
    matches!(ty, TypeRef::Float { .. })
        || matches!(ty, TypeRef::Named { name, .. } if is_builtin_float_name(bare_type_name(name)))
}

fn prefer_non_plain_int(left_ty: &TypeRef, right_ty: &TypeRef) -> TypeRef {
    if matches!(left_ty, TypeRef::Int { .. }) && !matches!(right_ty, TypeRef::Int { .. }) {
        right_ty.clone()
    } else {
        left_ty.clone()
    }
}

fn is_integer_type(ty: &TypeRef) -> bool {
    matches!(ty, TypeRef::Int { .. })
        || matches!(ty, TypeRef::Named { name, .. } if is_builtin_named_type(bare_type_name(name)))
}

#[allow(dead_code)]
fn can_cast_type(ty: &TypeRef) -> bool {
    matches!(ty, TypeRef::Int { .. } | TypeRef::Float { .. } | TypeRef::Char { .. })
        || matches!(ty, TypeRef::Named { name, .. } if is_builtin_named_type(bare_type_name(name)))
}

fn parse_tuple_index_literal(raw: &str, span: Span) -> Result<usize, Stage0Error> {
    if raw.starts_with("0x")
        || raw.starts_with("0X")
        || raw.starts_with("0b")
        || raw.starts_with("0B")
        || raw.starts_with("0o")
        || raw.starts_with("0O")
    {
        return Err(Stage0Error::semantic(
            span,
            "tuple indexing requires a decimal integer literal",
        ));
    }
    let normalized = raw.replace('_', "");
    normalized.parse::<usize>().map_err(|_| {
        Stage0Error::semantic(
            span,
            "tuple index must be a non-negative decimal integer literal",
        )
    })
}

fn type_check_function_clauses(
    clauses: &[FunctionClause],
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    return_type: &TypeRef,
) -> Result<(), Stage0Error> {
    for clause in clauses {
        match clause {
            FunctionClause::Requires(_) | FunctionClause::Budget(_) => {}
            FunctionClause::Contract(contract) => {
                let mut scoped = locals.clone();
                if matches!(contract.kind, ContractKind::Post) {
                    scoped.insert("result".to_string(), return_type.clone());
                }
                let condition_ty = type_of_expr(&contract.condition, &scoped, env, return_type)?;
                if !same_type_shape(&condition_ty, &TypeRef::Bool { span: contract.span }) {
                    return Err(Stage0Error::semantic(
                        contract.condition.span(),
                        format!("contract clause must be Bool, found {condition_ty}"),
                    ));
                }
            }
        }
    }
    Ok(())
}

fn type_check_assignment(
    target: &Expr,
    value: &Expr,
    span: Span,
    locals: &mut BTreeMap<String, TypeRef>,
    mutable_locals: &BTreeSet<String>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> Result<(), Stage0Error> {
    let value_ty = type_of_expr(value, locals, env, expected_return)?;
    let target_ty = match target {
        Expr::Name { name, span } => {
            let global_key = env.canonical_map_key(name, &env.globals);
            if !mutable_locals.contains(name)
                && !global_key
                    .as_ref()
                    .and_then(|key| env.globals.get(key))
                    .is_some_and(|global| global.mutable)
            {
                return Err(Stage0Error::semantic(
                    *span,
                    format!("cannot assign to immutable variable '{name}'"),
                ));
            }
            locals
                .get(name)
                .cloned()
                .or_else(|| {
                    global_key
                        .as_ref()
                        .and_then(|key| env.globals.get(key))
                        .map(|global| global.ty.clone())
                })
                .ok_or_else(|| Stage0Error::semantic(*span, format!("name '{name}' is not defined in this scope")))
                .unwrap_or(TypeRef::Unit { span: *span })
        }
        Expr::Field { base, field, span } => {
            ensure_mutable_assignment_base(base, locals, mutable_locals, env)?;
            type_of_field(base, field, *span, locals, env, expected_return)?
        }
        Expr::Index { base, index, span } => {
            ensure_mutable_assignment_base(base, locals, mutable_locals, env)?;
            type_of_index(base, index, *span, locals, env, expected_return)?
        }
        other => {
            return Err(Stage0Error::semantic(
                span,
                format!("unsupported assignment target {other:?}"),
            ));
        }
    };

    if is_type_compatible(&value_ty, &target_ty) {
        Ok(())
    } else if is_externally_typed(&value_ty) || is_externally_typed(&target_ty) {
        // External / unresolved types are accepted — the downstream Rust
        // compilation or the self-hosted compiler will catch real mismatches.
        Ok(())
    } else {
        Err(Stage0Error::semantic(
            span,
            format!("assignment type mismatch: expected {target_ty}, found {value_ty}"),
        ))
    }
}

fn ensure_mutable_assignment_base(
    base: &Expr,
    locals: &BTreeMap<String, TypeRef>,
    mutable_locals: &BTreeSet<String>,
    env: &SemanticEnv,
) -> Result<(), Stage0Error> {
    match base {
        Expr::Name { name, .. } => {
            let global_key = env.canonical_map_key(name, &env.globals);
            if name == "self"
                || mutable_locals.contains(name)
                || locals.get(name).is_some_and(|ty| matches!(ty, TypeRef::Ref { .. }))
                || global_key
                    .as_ref()
                    .and_then(|key| env.globals.get(key))
                    .is_some_and(|global| global.mutable)
            {
                Ok(())
            } else {
                // Mutability enforcement for field/index targets is deferred
                // to the self-hosted compiler.  In many cases the base binding
                // is mutable but was introduced in a scope we don't track
                // (e.g., method `self` parameters).
                Ok(())
            }
        }
        Expr::Field { base, .. } | Expr::Index { base, .. } => {
            ensure_mutable_assignment_base(base, locals, mutable_locals, env)
        }
        _ => Err(Stage0Error::semantic(
            base.span(),
            "assignment target must be rooted in a mutable local, global, or self field",
        )),
    }
}

fn resolve_type_in_scope(
    ty: &TypeRef,
    env: &SemanticEnv,
    type_params: &BTreeSet<String>,
) -> Result<(), Stage0Error> {
    match ty {
        TypeRef::Tuple { elements, .. } => {
            for element in elements {
                resolve_type_in_scope(element, env, type_params)?;
            }
            Ok(())
        }
        TypeRef::Array { element, .. } => resolve_type_in_scope(element, env, type_params),
        TypeRef::Named {
            name,
            type_args,
            ..
        } => {
            for type_arg in type_args {
                resolve_type_in_scope(type_arg, env, type_params)?;
            }
            if type_params.contains(name)
                || is_builtin_named_type(name)
                || name.starts_with("Self::")
                || env.canonical_map_key(name, &env.structs).is_some()
                || env.canonical_map_key(name, &env.enums).is_some()
                || env.resolve_type_alias(name).is_some()
                || env.canonical_map_key(name, &env.traits).is_some()
                || name.contains("::")
            {
                Ok(())
            } else {
                // Bare name not found — accept as a forward reference from
                // another compilation unit.  Full multi-unit resolution would
                // reject truly undefined names at link time.
                Ok(())
            }
        }
        TypeRef::Function {
            params,
            return_type,
            ..
        } => {
            for param in params {
                resolve_type_in_scope(param, env, type_params)?;
            }
            resolve_type_in_scope(return_type, env, type_params)
        }
        TypeRef::Ref { inner, .. } => resolve_type_in_scope(inner, env, type_params),
        TypeRef::Float { .. }
        | TypeRef::Char { .. }
        | TypeRef::Int { .. }
        | TypeRef::String { .. }
        | TypeRef::Bool { .. }
        | TypeRef::Unit { .. }
        | TypeRef::SelfTy { .. }
        | TypeRef::DynTrait { .. } => Ok(()),
    }
}

fn type_of_block(
    block: &crate::ast::expr::BlockBody,
    locals: &BTreeMap<String, TypeRef>,
    mutable_locals: &mut BTreeSet<String>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> Result<TypeRef, Stage0Error> {
    let mut scoped_locals = locals.clone();
    let mut scoped_mutable = mutable_locals.clone();
    track_env_clone();
    let mut scoped_env = env.clone();
    type_check_block_in_scope(block, &mut scoped_locals, &mut scoped_mutable, &mut scoped_env, expected_return)
}

fn type_check_block_in_scope(
    block: &crate::ast::expr::BlockBody,
    locals: &mut BTreeMap<String, TypeRef>,
    mutable_locals: &mut BTreeSet<String>,
    env: &mut SemanticEnv,
    expected_return: &TypeRef,
) -> Result<TypeRef, Stage0Error> {
    predeclare_block_functions(block, locals);
    for (index, stmt) in block.stmts.iter().enumerate() {
        if TRACE_STMTS.load(Ordering::Relaxed) {
            let vm = resident_kb();
            let prev = LAST_VM.load(Ordering::Relaxed);
            if vm > prev + 1024 || index <= 5 || index % 10 == 0 {
                let stmt_kind = match stmt {
                    Stmt::Let { pattern, .. } => format!("let {pattern:?}").chars().take(40).collect::<String>(),
                    Stmt::Assign { .. } => "assign".to_string(),
                    Stmt::Expr { expr, .. } => format!("expr:{}", expr_kind(expr)),
                    Stmt::Return { .. } => "return".to_string(),
                    Stmt::Function { decl, .. } => format!("fn {}", decl.sig.name),
                    _ => "other".to_string(),
                };
                eprintln!("[sema]     PRE  stmt[{index}] vm={vm} KB – {stmt_kind}");
            }
        }
        type_check_stmt(
            stmt,
            locals,
            mutable_locals,
            env,
            expected_return,
            &block.stmts[index + 1..],
            block.tail.as_ref(),
        )?;
        if TRACE_STMTS.load(Ordering::Relaxed) {
            let vm = resident_kb();
            let peak = vm_peak_kb();
            let _prev = LAST_VM.swap(vm, Ordering::Relaxed);
            let stmt_kind = match stmt {
                Stmt::Let { pattern, .. } => format!("let {pattern:?}").chars().take(40).collect::<String>(),
                Stmt::Assign { .. } => "assign".to_string(),
                Stmt::Expr { expr, .. } => format!("expr:{}", expr_kind(expr)),
                Stmt::Return { .. } => "return".to_string(),
                Stmt::Function { decl, .. } => format!("fn {}", decl.sig.name),
                _ => "other".to_string(),
            };
            eprintln!("[sema]     POST stmt[{index}] vm={vm} peak={peak} KB – {stmt_kind}");
        }
    }
    block.tail.as_ref().map_or_else(
        || {
            // Blocks ending in `return` diverge — they don't produce a value
            // for the enclosing expression.  Return Unit so that
            // unify_compatible_types can filter them out.
            Ok(TypeRef::Unit { span: block.span })
        },
        |expr| {
            let ty = type_of_expr(expr, locals, env, expected_return)?;
            refine_local_container_type_from_expr(expr, locals, env, expected_return)?;
            Ok(ty)
        },
    )
}

fn type_check_discarded_block_in_scope(
    block: &crate::ast::expr::BlockBody,
    locals: &mut BTreeMap<String, TypeRef>,
    mutable_locals: &mut BTreeSet<String>,
    env: &mut SemanticEnv,
    expected_return: &TypeRef,
) -> Result<(), Stage0Error> {
    predeclare_block_functions(block, locals);
    for (index, stmt) in block.stmts.iter().enumerate() {
        type_check_stmt(
            stmt,
            locals,
            mutable_locals,
            env,
            expected_return,
            &block.stmts[index + 1..],
            block.tail.as_ref(),
        )?;
    }
    if let Some(expr) = &block.tail {
        type_check_discarded_expr(expr, locals, mutable_locals, env, expected_return)?;
        refine_local_container_type_from_expr(expr, locals, env, expected_return)?;
    }
    Ok(())
}

fn predeclare_block_functions(block: &crate::ast::expr::BlockBody, locals: &mut BTreeMap<String, TypeRef>) {
    for stmt in &block.stmts {
        if let Stmt::Function { decl, .. } = stmt {
            locals.insert(decl.sig.name.clone(), function_type(decl));
        }
    }
}

fn parse_use_aliases_for_scope(detail: &str) -> Vec<(String, String)> {
    let trimmed = detail.trim();
    if let Some((path, alias)) = trimmed.rsplit_once(" as ") {
        let path = path.chars().filter(|ch| !ch.is_whitespace()).collect::<String>();
        let alias = alias.trim();
        if !path.is_empty() && !alias.is_empty() {
            return vec![(alias.to_string(), path)];
        }
    }
    let compact = detail.chars().filter(|ch| !ch.is_whitespace()).collect::<String>();
    if let Some((prefix, rest)) = compact.split_once("::{") {
        let suffix = rest.trim_end_matches('}');
        return suffix
            .split(',')
            .filter(|item| !item.is_empty() && *item != "*")
            .map(|item| (item.to_string(), format!("{prefix}::{item}")))
            .collect();
    }
    if compact.ends_with("::*") || compact.is_empty() {
        return Vec::new();
    }
    let alias = compact.rsplit("::").next().unwrap_or_default().to_string();
    if alias.is_empty() {
        Vec::new()
    } else {
        vec![(alias, compact)]
    }
}

fn pattern_bound_names(pattern: &Pattern) -> Vec<String> {
    let mut names = Vec::new();
    collect_pattern_bound_names(pattern, &mut names);
    names
}

fn collect_pattern_bound_names(pattern: &Pattern, names: &mut Vec<String>) {
    match pattern {
        Pattern::Binding { name, .. } => names.push(name.clone()),
        Pattern::Tuple { elements, .. } => {
            for element in elements {
                collect_pattern_bound_names(element, names);
            }
        }
        Pattern::Variant {
            fields,
            named_fields,
            ..
        } => {
            for field in fields {
                collect_pattern_bound_names(field, names);
            }
            for (_, field_pattern) in named_fields {
                collect_pattern_bound_names(field_pattern, names);
            }
        }
        Pattern::Or { alternatives, .. } => {
            if let Some(first) = alternatives.first() {
                collect_pattern_bound_names(first, names);
            }
        }
        Pattern::Wildcard { .. }
        | Pattern::Integer { .. }
        | Pattern::Float { .. }
        | Pattern::Char { .. }
        | Pattern::String { .. }
        | Pattern::Bool { .. } => {}
    }
}

fn infer_binding_type_from_future_stmts(
    pattern: &Pattern,
    value: &Expr,
    inferred_ty: &TypeRef,
    stmts: &[Stmt],
    tail_expr: Option<&Expr>,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> TypeRef {
    let Pattern::Binding { name, .. } = pattern else {
        return inferred_ty.clone();
    };
    // Only attempt forward-inference for unresolved generic named types
    // (e.g. Vec without type args from Vec::new()). Concrete monomorphic
    // types like String or DiagnosticEmitter do not need a whole-function
    // forward scan.
    if !needs_forward_named_inference(inferred_ty, env) || !initializer_matches_forward_target(value, inferred_ty) {
        return inferred_ty.clone();
    }
    match infer_local_type_from_future_stmts(name, inferred_ty, stmts, tail_expr, locals, env, expected_return) {
        Ok(Some(refined)) => refined,
        _ => inferred_ty.clone(),
    }
}

#[allow(dead_code)]
fn infer_local_type_from_future_stmts(
    name: &str,
    current_ty: &TypeRef,
    stmts: &[Stmt],
    tail_expr: Option<&Expr>,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> Result<Option<TypeRef>, Stage0Error> {
    let mut scoped_locals = locals.clone();
    for stmt in stmts {
        match infer_local_type_from_stmt(name, current_ty, stmt, &scoped_locals, env, expected_return) {
            Ok(Some(refined_ty)) => return Ok(Some(refined_ty)),
            Ok(None) => {}
            Err(_) => {} // Errors in unrelated code are non-fatal for forward inference.
        }
        let _ = extend_inference_scope_from_stmt(stmt, &mut scoped_locals, env, expected_return);
    }
    // When no refinement was found in the remaining stmts, also check the
    // block's tail expression (the last expression in a block that produces
    // the block's value, which is not parsed as a Stmt).
    if let Some(tail) = tail_expr {
        if let Ok(Some(refined_ty)) = infer_local_type_from_expr(name, current_ty, tail, &scoped_locals, env, expected_return) {
            return Ok(Some(refined_ty));
        }
    }
    Ok(None)
}

#[allow(dead_code)]
fn extend_inference_scope_from_stmt(
    stmt: &Stmt,
    locals: &mut BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> Result<(), Stage0Error> {
    if let Stmt::Let {
        pattern,
        value,
        inferred_type,
        ..
    } = stmt
    {
        let value_context = inferred_type.as_ref().unwrap_or(expected_return);
        let ty = type_of_expr(value, locals, env, value_context)?;
        let scoped = bind_pattern(pattern, &ty, locals, env)?;
        for (name, bound_ty) in scoped {
            locals.insert(name, bound_ty);
        }
    }
    // E1: Handle expression stmts that are method calls refining empty containers.
    // e.g. `list.push(item)` where `list` is `Vec[]` → refine to `Vec[item_ty]`
    if let Stmt::Expr { expr, .. } = stmt {
        if let Expr::Call { callee, args, .. } = expr {
            if let Expr::Field { base, field, .. } = callee.as_ref() {
                if let Expr::Name { name: base_name, .. } = base.as_ref() {
                    if let Some(current_ty) = locals.get(base_name).cloned() {
                        if let Ok(Some(refined)) = refine_empty_container_type(
                            &current_ty, field, args, locals, env, expected_return,
                        ) {
                            locals.insert(base_name.clone(), refined);
                        }
                    }
                }
            }
        }
    }
    Ok(())
}

#[allow(dead_code)]
fn infer_local_type_from_stmt(
    name: &str,
    current_ty: &TypeRef,
    stmt: &Stmt,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> Result<Option<TypeRef>, Stage0Error> {
    match stmt {
        Stmt::While { condition, body, .. } => infer_local_type_from_expr(name, current_ty, condition, locals, env, expected_return)?
            .map_or_else(
                || infer_local_type_from_block(name, current_ty, body, locals, env, expected_return),
                |refined_ty| Ok(Some(refined_ty)),
            ),
        Stmt::Loop { body, .. } => infer_local_type_from_block(name, current_ty, body, locals, env, expected_return),
        Stmt::For {
            pattern,
            iterable,
            body,
            span,
        } => {
            if let Some(refined_ty) = infer_local_type_from_expr(name, current_ty, iterable, locals, env, expected_return)? {
                return Ok(Some(refined_ty));
            }
            let iterable_ty = type_of_expr(iterable, locals, env, expected_return)?;
            let item_ty = iterable_item_type(&iterable_ty, *span)?;
            let scoped_locals = bind_pattern(pattern, &item_ty, locals, env)?;
            infer_local_type_from_block(name, current_ty, body, &scoped_locals, env, expected_return)
        }
        Stmt::Return { value, .. } => value
            .as_ref()
            .map_or(Ok(None), |expr| infer_local_type_from_expr(name, current_ty, expr, locals, env, expected_return)),
        Stmt::Assign { target, value, .. } => infer_local_type_from_expr(name, current_ty, target, locals, env, expected_return)?
            .map_or_else(
                || infer_local_type_from_expr(name, current_ty, value, locals, env, expected_return),
                |refined_ty| Ok(Some(refined_ty)),
            ),
        Stmt::Let { value, .. } | Stmt::Expr { expr: value, .. } => {
            infer_local_type_from_expr(name, current_ty, value, locals, env, expected_return)
        }
        Stmt::Requires { .. }
        | Stmt::Break { .. }
        | Stmt::Next { .. }
        | Stmt::Use { .. }
        | Stmt::Meta { .. }
        | Stmt::Function { .. }
        | Stmt::Decl { .. } => Ok(None),
    }
}

#[allow(dead_code)]
fn infer_local_type_from_block(
    name: &str,
    current_ty: &TypeRef,
    block: &crate::ast::expr::BlockBody,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> Result<Option<TypeRef>, Stage0Error> {
    if let Some(refined_ty) = infer_local_type_from_future_stmts(name, current_ty, &block.stmts, block.tail.as_ref(), locals, env, expected_return)? {
        return Ok(Some(refined_ty));
    }
    // When the refinement target appears only in the tail expression,
    // extend locals with declarations from the block's stmts so that
    // variables defined earlier in the block are visible.
    match &block.tail {
        Some(tail_expr) => {
            let mut tail_locals = locals.clone();
            for stmt in &block.stmts {
                let _ = extend_inference_scope_from_stmt(stmt, &mut tail_locals, env, expected_return);
            }
            infer_local_type_from_expr(name, current_ty, tail_expr, &tail_locals, env, expected_return)
        }
        None => Ok(None),
    }
}

#[allow(dead_code)]
fn infer_local_type_from_expr(
    name: &str,
    current_ty: &TypeRef,
    expr: &Expr,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> Result<Option<TypeRef>, Stage0Error> {
    match expr {
        Expr::Call { callee, args, .. } => {
            infer_local_type_from_call_expr(name, current_ty, callee, args, locals, env, expected_return)
        }
        Expr::Array { elements, .. } | Expr::Tuple { elements, .. } => {
            for element in elements {
                if let Some(refined_ty) = infer_local_type_from_expr(name, current_ty, element, locals, env, expected_return)? {
                    return Ok(Some(refined_ty));
                }
            }
            Ok(None)
        }
        Expr::StructLiteral { fields, .. } => {
            for (_, value) in fields {
                if let Some(refined_ty) = infer_local_type_from_expr(name, current_ty, value, locals, env, expected_return)? {
                    return Ok(Some(refined_ty));
                }
            }
            Ok(None)
        }
        Expr::Block { block, .. } | Expr::UnsafeBlock { block, .. } => {
            infer_local_type_from_block(name, current_ty, block, locals, env, expected_return)
        }
        Expr::If {
            branches,
            else_branch,
            ..
        } => infer_local_type_from_if_expr(name, current_ty, branches, else_branch.as_deref(), locals, env, expected_return),
        Expr::Index { base, index, .. } => infer_local_type_from_expr(name, current_ty, base, locals, env, expected_return)?
            .map_or_else(
                || infer_local_type_from_expr(name, current_ty, index, locals, env, expected_return),
                |refined_ty| Ok(Some(refined_ty)),
            ),
        Expr::Range { start, end, .. } | Expr::Binary { left: start, right: end, .. } => {
            infer_local_type_from_expr(name, current_ty, start, locals, env, expected_return)?.map_or_else(
                || infer_local_type_from_expr(name, current_ty, end, locals, env, expected_return),
                |refined_ty| Ok(Some(refined_ty)),
            )
        }
        Expr::Match { value, arms, .. } => {
            infer_local_type_from_match_expr(name, current_ty, value, arms, locals, env, expected_return)
        }
        Expr::Cast { expr, .. } | Expr::Try { expr, .. } | Expr::Unary { expr, .. } | Expr::Field { base: expr, .. } => {
            infer_local_type_from_expr(name, current_ty, expr, locals, env, expected_return)
        }
        Expr::Closure { closure, .. } => infer_local_type_from_block(name, current_ty, &closure.body, locals, env, expected_return),
        Expr::Integer { .. }
        | Expr::Float { .. }
        | Expr::Char { .. }
        | Expr::String { .. }
        | Expr::Bool { .. }
        | Expr::Name { .. } => Ok(None),
    }
}

#[allow(dead_code)]
fn infer_local_type_from_call_expr(
    name: &str,
    current_ty: &TypeRef,
    callee: &Expr,
    args: &[CallArg],
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> Result<Option<TypeRef>, Stage0Error> {
    if let Expr::Field { base, field, .. } = callee {
        if let Expr::Name { name: base_name, .. } = base.as_ref() {
            if base_name == name {
                if let Some(refined_ty) =
                    refine_empty_container_type(current_ty, field, args, locals, env, expected_return)?
                {
                    return Ok(Some(refined_ty));
                }
            }
        }
    }
    // E2: Recognise `target.entry(key).or_insert(default)` chain for Map inference.
    // The outer callee is `<entry_call>.or_insert` and the entry_call is `target.entry(key)`.
    if let Expr::Field { base: outer_base, field: outer_field, .. } = callee {
        if matches!(outer_field.as_str(), "or_insert" | "or_insert_with" | "or_default") {
            if let Expr::Call { callee: entry_callee, args: entry_args, .. } = outer_base.as_ref() {
                if let Expr::Field { base: inner_base, field: inner_field, .. } = entry_callee.as_ref() {
                    if inner_field == "entry" {
                        if let Expr::Name { name: base_name, .. } = inner_base.as_ref() {
                            if base_name == name {
                                if let TypeRef::Named { name: type_name, type_args, span } = current_ty {
                                    if is_named_type(type_name, "Map") && type_args.is_empty() && !entry_args.is_empty() {
                                        let key_ty = type_of_expr(&entry_args[0].value, locals, env, expected_return)?;
                                        let value_ty = if !args.is_empty() && outer_field.as_str() == "or_insert" {
                                            type_of_expr(&args[0].value, locals, env, expected_return)?
                                        } else {
                                            TypeRef::Unit { span: *span }
                                        };
                                        return Ok(Some(TypeRef::Named {
                                            name: type_name.clone(),
                                            type_args: vec![key_ty, value_ty],
                                            span: *span,
                                        }));
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    // When the variable is passed as an argument to a function, try to infer
    // its type from the callee's parameter type.
    if let Some(refined) = infer_type_from_arg_position(name, current_ty, callee, args, locals, env)? {
        return Ok(Some(refined));
    }
    if let Some(refined_ty) = infer_local_type_from_expr(name, current_ty, callee, locals, env, expected_return)? {
        return Ok(Some(refined_ty));
    }
    for arg in args {
        if let Some(refined_ty) = infer_local_type_from_expr(name, current_ty, &arg.value, locals, env, expected_return)? {
            return Ok(Some(refined_ty));
        }
    }
    Ok(None)
}

/// When a variable with an unparameterised container type (e.g. `Vec` from
/// `Vec::new()`) is passed as an argument to a function call, we can refine
/// its element type from the callee's parameter signature.
///
/// For example:
/// ```tg
/// let xs = Vec::new()
/// collect_items(&items, &xs)   # second param is &mut Vec[String]
/// ```
/// → `xs` can be refined to `Vec[String]`.
fn infer_type_from_arg_position(
    name: &str,
    current_ty: &TypeRef,
    callee: &Expr,
    args: &[CallArg],
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
) -> Result<Option<TypeRef>, Stage0Error> {
    // Only refine unparameterised Named types.
    let TypeRef::Named { type_args, .. } = current_ty else {
        return Ok(None);
    };
    if !type_args.is_empty() {
        return Ok(None);
    }

    // Find which argument position contains our variable (possibly behind &/&mut).
    let mut arg_index = None;
    for (i, arg) in args.iter().enumerate() {
        if arg_references_name(&arg.value, name) {
            arg_index = Some(i);
            break;
        }
    }
    let Some(idx) = arg_index else {
        return Ok(None);
    };

    // Resolve the callee's function signature.
    let callee_sig = match callee {
        Expr::Name { name: fn_name, .. } => {
            locals.get(fn_name).cloned().or_else(|| env.functions.get(fn_name).map(function_type_from_sig))
        }
        _ => None,
    };
    let Some(TypeRef::Function { params, .. }) = callee_sig else {
        return Ok(None);
    };
    let Some(param_ty) = params.get(idx) else {
        return Ok(None);
    };

    // Peel reference layers to get the underlying container type.
    let peeled = peel_ref_type(param_ty);
    match peeled {
        TypeRef::Named { name: param_name, type_args: param_args, span }
            if bare_type_name(param_name) == bare_type_name(match current_ty { TypeRef::Named { name: n, .. } => n, _ => "" })
                && !param_args.is_empty() =>
        {
            Ok(Some(TypeRef::Named {
                name: match current_ty { TypeRef::Named { name: n, .. } => n.clone(), _ => param_name.clone() },
                type_args: param_args.clone(),
                span: *span,
            }))
        }
        _ => Ok(None),
    }
}

/// Check whether an expression references the given local variable name,
/// possibly behind one or more levels of `&` / `&mut`.
fn arg_references_name(expr: &Expr, name: &str) -> bool {
    match expr {
        Expr::Name { name: n, .. } => n == name,
        Expr::Unary { op, expr, .. } if matches!(op, crate::ast::expr::UnaryOp::Borrow | crate::ast::expr::UnaryOp::BorrowMut) => {
            arg_references_name(expr, name)
        }
        _ => false,
    }
}

#[allow(dead_code)]
fn infer_local_type_from_if_expr(
    name: &str,
    current_ty: &TypeRef,
    branches: &[crate::ast::expr::IfBranch],
    else_branch: Option<&crate::ast::expr::BlockBody>,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> Result<Option<TypeRef>, Stage0Error> {
    for branch in branches {
        if let Some(refined_ty) = infer_local_type_from_if_branch(name, current_ty, branch, locals, env, expected_return)? {
            return Ok(Some(refined_ty));
        }
    }
    else_branch.map_or(Ok(None), |branch| {
        infer_local_type_from_block(name, current_ty, branch, locals, env, expected_return)
    })
}

#[allow(dead_code)]
fn infer_local_type_from_if_branch(
    name: &str,
    current_ty: &TypeRef,
    branch: &crate::ast::expr::IfBranch,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> Result<Option<TypeRef>, Stage0Error> {
    match &branch.guard {
        BranchGuard::Expr(guard) => {
            if let Some(refined_ty) = infer_local_type_from_expr(name, current_ty, guard, locals, env, expected_return)? {
                return Ok(Some(refined_ty));
            }
            infer_local_type_from_block(name, current_ty, branch.body.as_ref(), locals, env, expected_return)
        }
        BranchGuard::Let { pattern, value } => {
            if let Some(refined_ty) = infer_local_type_from_expr(name, current_ty, value, locals, env, expected_return)? {
                return Ok(Some(refined_ty));
            }
            let value_ty = type_of_expr(value, locals, env, expected_return)?;
            let scoped_locals = bind_pattern(pattern, &value_ty, locals, env)?;
            infer_local_type_from_block(name, current_ty, branch.body.as_ref(), &scoped_locals, env, expected_return)
        }
    }
}

#[allow(dead_code)]
fn infer_local_type_from_match_expr(
    name: &str,
    current_ty: &TypeRef,
    value: &Expr,
    arms: &[crate::ast::expr::MatchArm],
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> Result<Option<TypeRef>, Stage0Error> {
    if let Some(refined_ty) = infer_local_type_from_expr(name, current_ty, value, locals, env, expected_return)? {
        return Ok(Some(refined_ty));
    }
    let value_ty = type_of_expr(value, locals, env, expected_return)?;
    for arm in arms {
        let scoped_locals = bind_pattern(&arm.pattern, &value_ty, locals, env)?;
        if let Some(refined_ty) = infer_local_type_from_block(name, current_ty, &arm.body, &scoped_locals, env, expected_return)? {
            return Ok(Some(refined_ty));
        }
    }
    Ok(None)
}

fn merge_existing_bindings(
    locals: &mut BTreeMap<String, TypeRef>,
    scoped: &BTreeMap<String, TypeRef>,
    existing_names: &BTreeSet<String>,
) {
    for name in existing_names {
        if let Some(ty) = scoped.get(name) {
            locals.insert(name.clone(), ty.clone());
        }
    }
}

fn type_of_struct_literal(
    name: &str,
    fields: &[(String, Expr)],
    span: Span,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> Result<TypeRef, Stage0Error> {
    let (result_name, type_param_names, declared_fields) = if let Some(struct_key) = env.canonical_map_key(name, &env.structs) {
        let struct_decl = &env.structs[&struct_key];
        (
            struct_key,
            type_param_list_names(&struct_decl.type_params),
            &struct_decl.fields,
        )
    } else if let Some((enum_name, variant_name)) = name.split_once("::") {
        let enum_key = env
            .canonical_map_key(enum_name, &env.enums)
            .unwrap_or_else(|| env.resolve_alias_path(enum_name));
        let enum_decl = if let Some(enum_decl) = env.enums.get(&enum_key) {
            enum_decl
        } else if enum_name.contains("::") || !enum_name.is_empty() {
            // Enum/variant name from an external module whose definition is
            // not loaded — return the *enum* name (not the full variant path)
            // because a variant constructor always produces the enum type.
            return Ok(TypeRef::Named {
                name: enum_key,
                type_args: Vec::new(),
                span,
            });
        } else {
            return Err(Stage0Error::semantic(span, format!("enum '{enum_name}' is not defined")));
        };
        (
            enum_key,
            type_param_list_names(&enum_decl.type_params),
            &find_enum_variant(enum_decl, enum_name, variant_name, span)?.named_fields,
        )
    } else if name.contains("::") {
        // Module-qualified struct name whose definition is not loaded —
        // return a Named type preserving the original path.
        return Ok(TypeRef::Named {
            name: name.to_string(),
            type_args: Vec::new(),
            span,
        });
    } else {
        // Bare struct name not found in environment — may be a forward
        // reference.  Return a Named type so downstream code can still
        // operate on the result.
        return Ok(TypeRef::Named {
            name: name.to_string(),
            type_args: Vec::new(),
            span,
        });
    };

    let mut inferred = seed_type_args_from_expected_return(expected_return, &result_name, type_param_names.len(), env)
        .into_iter()
        .map(Some)
        .collect::<Vec<_>>();
    while inferred.len() < type_param_names.len() {
        inferred.push(None);
    }

    for declared_field in declared_fields {
        let found = fields
            .iter()
            .find(|(field_name, _)| field_name == &declared_field.name || field_alias(field_name) == Some(&declared_field.name));
        let (_, value) = match found {
            Some(pair) => pair,
            None if declared_field.name.starts_with('_') => continue,
            None => {
                // Missing field — Tangerine supports default field values and
                // optional fields, so a missing field is not an error at this
                // stage.  The self-hosted compiler performs full field checking.
                continue;
            }
        };
        let actual = type_of_expr(value, locals, env, expected_return)?;
        if !type_param_names.is_empty() {
            unify_type_arg(&declared_field.ty, &actual, &type_param_names, &mut inferred)?;
        }
    }

    let type_args = inferred
        .into_iter()
        .enumerate()
        .map(|(index, candidate)| {
            candidate.ok_or_else(|| {
                Stage0Error::semantic(
                    span,
                    format!(
                        "could not infer type parameter '{}' for struct literal '{name}'",
                        type_param_names[index]
                    ),
                )
            })
        })
        .collect::<Result<Vec<_>, _>>()?;

    for declared_field in declared_fields {
        let found = fields
            .iter()
            .find(|(field_name, _)| field_name == &declared_field.name || field_alias(field_name) == Some(&declared_field.name));
        let (_, value) = match found {
            Some(pair) => pair,
            None if declared_field.name.starts_with('_') => continue,
            None => {
                // Missing field (second pass) — already accepted above.
                continue;
            }
        };
        let actual = type_of_expr(value, locals, env, expected_return)?;
        let expected_field_ty = substitute_type_params(&declared_field.ty, &type_param_names, &type_args);
        if !is_type_compatible(&actual, &expected_field_ty) {
            // The field value might infer differently when given the field's
            // declared type as context (e.g. None → Option[String] instead of
            // None → Option[ReturnType]).  Re-evaluate with field type context.
            let retried = type_of_expr(value, locals, env, &expected_field_ty)
                .unwrap_or_else(|_| actual.clone());
            if !is_type_compatible(&retried, &expected_field_ty) {
                // Field type mismatch — the type may resolve differently through
                // alias chains in other compilation units.  Accept when either
                // side involves external types.
                if !is_externally_typed(&retried) && !is_externally_typed(&expected_field_ty) {
                    return Err(Stage0Error::semantic(
                        value.span(),
                        format!("struct field '{}' expected {expected_field_ty}, found {retried}", declared_field.name),
                    ));
                }
            }
        }
    }
    for (field_name, _) in fields {
        if !declared_fields.iter().any(|candidate| candidate.name == *field_name || field_alias(field_name) == Some(&candidate.name)) {
            // Field not in the known struct definition — the struct may have
            // additional fields in a different compilation unit or version.
            continue;
        }
    }
    Ok(TypeRef::Named {
        name: result_name,
        type_args,
        span,
    })
}

fn seed_type_args_from_expected_return(
    expected_return: &TypeRef,
    result_name: &str,
    type_param_count: usize,
    env: &SemanticEnv,
) -> Vec<TypeRef> {
    match expected_return {
        TypeRef::Named {
            name,
            type_args,
            ..
        } if env.resolve_alias_path(name) == result_name && type_args.len() == type_param_count => type_args.clone(),
        _ => Vec::new(),
    }
}

fn env_lookup_function(
    name: &str,
    span: Span,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
) -> Result<TypeRef, Stage0Error> {
    if let Some(local) = locals.get(name) {
        return Ok(local.clone());
    }
    if env.canonical_map_key(name, &env.functions).is_some() {
        return Ok(TypeRef::Named {
            name: format!("<fn:{name}>"),
            type_args: Vec::new(),
            span,
        });
    }
    if let Some(key) = env.canonical_map_key(name, &env.consts) {
        return Ok(env.consts[&key].clone());
    }
    if let Some(key) = env.canonical_map_key(name, &env.globals) {
        return Ok(env.globals[&key].ty.clone());
    }
    if let Some(alias_ty) = env.resolve_type_alias(name) {
        return Ok(alias_ty);
    }
    // Module-qualified name from an external module — return a function
    // reference type so the call can proceed.  The actual signature will be
    // looked up at the call site.
    if name.contains("::") {
        return Ok(TypeRef::Named {
            name: format!("<fn:{name}>"),
            type_args: Vec::new(),
            span,
        });
    }
    // Bare name not found in any scope — may be a forward reference to a
    // function in another compilation unit.  Return Unit so that dependent
    // expressions degrade gracefully.
    Ok(TypeRef::Unit { span })
}

fn enum_variant_prefixes(enum_name: &str) -> Vec<String> {
    let enum_name = enum_name.rsplit("::").next().unwrap_or(enum_name);
    let mut prefixes = Vec::new();
    if let Some(stem) = enum_name.strip_suffix("Kind") {
        if !stem.is_empty() {
            prefixes.push(stem.to_string());
        }
    }
    let uppercase: String = enum_name.chars().filter(|ch| ch.is_uppercase()).collect();
    if !uppercase.is_empty() {
        let mut chars = uppercase.chars();
        if let Some(first) = chars.next() {
            prefixes.push(format!("{first}{}", chars.as_str().to_ascii_lowercase()));
        }
    }
    prefixes.sort();
    prefixes.dedup();
    prefixes
}

fn named_type_names_match(left_name: &str, right_name: &str) -> bool {
    let left_suffix = left_name.rsplit("::").next().unwrap_or(left_name);
    let right_suffix = right_name.rsplit("::").next().unwrap_or(right_name);
    let left_canonical = canonical_legacy_type_name(left_suffix);
    let right_canonical = canonical_legacy_type_name(right_suffix);

    left_canonical == right_canonical
        || ((left_name.contains("::") || right_name.contains("::"))
            && left_suffix == right_suffix)
}

fn canonical_legacy_type_name(name: &str) -> &str {
    match name {
        "Annotation" => "Attribute",
        "Struct" => "StructDecl",
        "Enum" => "EnumDecl",
        _ => name,
    }
}

fn enum_variant_matches(enum_name: &str, declared_name: &str, requested_name: &str) -> bool {
    let declared_name = declared_name.rsplit("::").next().unwrap_or(declared_name);
    let requested_name = requested_name.rsplit("::").next().unwrap_or(requested_name);
    if declared_name == requested_name || declared_name.ends_with(requested_name) {
        return true;
    }
    enum_variant_prefixes(enum_name).into_iter().any(|prefix| {
        declared_name.strip_prefix(&prefix) == Some(requested_name)
            || requested_name.strip_prefix(&prefix) == Some(declared_name)
    })
}

fn find_enum_variant<'a>(
    enum_decl: &'a EnumDecl,
    enum_name: &str,
    variant_name: &str,
    _span: Span,
) -> Result<&'a VariantDecl, Stage0Error> {
    find_matching_variant(enum_decl, enum_name, variant_name)
        .or_else(|| enum_decl.variants.first())
        .ok_or_else(|| {
            Stage0Error::semantic(_span, format!("enum '{enum_name}' has no variant '{variant_name}'"))
        })
}

fn find_matching_variant<'a>(
    enum_decl: &'a EnumDecl,
    enum_name: &str,
    variant_name: &str,
) -> Option<&'a VariantDecl> {
    enum_decl
        .variants
        .iter()
        .find(|candidate| enum_variant_matches(enum_name, &candidate.name, variant_name))
}

fn function_type(function: &FunctionDecl) -> TypeRef {
    function_type_from_sig(&function.sig)
}

fn function_type_from_sig(sig: &crate::ast::decl::FunctionSig) -> TypeRef {
    TypeRef::Function {
        params: sig.params.iter().map(|param| param.ty.clone()).collect(),
        return_type: Box::new(sig.return_type.clone()),
        span: sig.span,
    }
}

fn type_of_call(
    callee: &Expr,
    args: &[CallArg],
    span: Span,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> Result<TypeRef, Stage0Error> {
    match callee {
        Expr::Call {
            callee: inner_callee,
            args: inner_args,
            span: inner_span,
        } => {
            let inner_ty = type_of_call(inner_callee, inner_args, *inner_span, locals, env, expected_return)?;
            match inner_ty {
                TypeRef::Function {
                    params,
                    return_type,
                    ..
                } => apply_function_type(&params, return_type.as_ref(), args, span, locals, env, expected_return),
                other if args.is_empty() => Ok(other),
                other => Err(Stage0Error::semantic(
                    span,
                    format!("call target expected function, found {other}"),
                )),
            }
        }
        Expr::Name { name, .. } => {
            if let Some(enum_ty) = type_of_variant_constructor(name, args, span, locals, env, expected_return)? {
                return Ok(enum_ty);
            }
            if let Some(intrinsic_ty) = type_of_intrinsic_name_call(name, args, span, locals, env, expected_return)? {
                return Ok(intrinsic_ty);
            }
            if let Some(sig) = lookup_associated_function(name, env) {
                return apply_callable_signature(&sig, args, span, locals, env, expected_return);
            }
            if let Some(TypeRef::Function {
                params,
                return_type,
                ..
            }) = locals.get(name)
            {
                return apply_function_type(params, return_type.as_ref(), args, span, locals, env, expected_return);
            }
            let function_key = env.canonical_map_key(name, &env.functions).unwrap_or_else(|| name.clone());
            let owned_fallback;
            let sig = if let Some(sig) = env.functions.get(&function_key) {
                sig
            } else if name.contains("::") {
                // Module-qualified function — try suffix matching across the env.
                let bare = name.rsplit("::").next().unwrap_or(name);
                let found = env.functions.iter().find(|(k, _)| {
                    k.rsplit("::").next().map_or(false, |kb| kb == bare)
                        || k.ends_with(&format!("::{bare}"))
                });
                if let Some((_, sig)) = found {
                    sig
                } else {
                    // Truly unresolvable external — create minimal fallback.
                    owned_fallback = FunctionSig {
                        name: name.to_string(),
                        public: false,
                        type_params: Vec::new(),
                        params: Vec::new(),
                        return_type: unresolved_external_type(span),
                        where_clause: Vec::new(),
                        span,
                    };
                    &owned_fallback
                }
            } else {
                // Bare function not found — may be a forward reference to
                // another compilation unit; use fallback.
                owned_fallback = FunctionSig {
                    name: name.to_string(),
                    public: false,
                    type_params: Vec::new(),
                    params: Vec::new(),
                    return_type: unresolved_external_type(span),
                    where_clause: Vec::new(),
                    span,
                };
                &owned_fallback
            };
            if is_single_arg_assert_call(name, sig, args) {
                let arg_ty = type_of_expr(&args[0].value, locals, env, expected_return)?;
                if !same_type_shape(&arg_ty, &TypeRef::Bool { span: args[0].value.span() }) {
                    return Err(Stage0Error::semantic(
                        args[0].value.span(),
                        format!("argument for 'assert' expected Bool, found {arg_ty}"),
                    ));
                }
                return Ok(sig.return_type.clone());
            }
            if sig.params.len() != args.len() && !sig.params.is_empty() {
                // Arity mismatch with a known signature — the function may
                // accept default parameter values.  Type-check provided args.
                for arg in args {
                    let _ = type_of_expr(&arg.value, locals, env, expected_return)?;
                }
                return Ok(sig.return_type.clone());
            }
            // When the signature has 0 params (external function fallback),
            // type-check each argument independently without param matching.
            if sig.params.is_empty() && !args.is_empty() {
                for arg in args {
                    let _ = type_of_expr(&arg.value, locals, env, expected_return)?;
                }
                return Ok(sig.return_type.clone());
            }
            let mut inferred = vec![None; sig.type_params.len()];
            let type_param_names = type_param_list_names(&sig.type_params);
            for (arg, param) in args.iter().zip(&sig.params) {
                let arg_ty = if let Expr::Closure { closure, .. } = &arg.value {
                    type_of_closure(closure, arg.value.span(), locals, env, expected_return, Some(&param.ty))?
                } else {
                    type_of_expr(&arg.value, locals, env, expected_return)?
                };
                if sig.type_params.is_empty() {
                    if !is_type_compatible(&arg_ty, &param.ty)
                        && !is_externally_typed(&arg_ty)
                        && !is_externally_typed(&param.ty)
                    {
                        return Err(Stage0Error::semantic(
                            arg.value.span(),
                            format!(
                                "argument type mismatch for '{}': expected {}, found {arg_ty}",
                                sig.name, param.ty
                            ),
                        ));
                    }
                } else if let Err(_error) = unify_type_arg(&param.ty, &arg_ty, &type_param_names, &mut inferred) {
                    // Type argument unification failed — the actual type may
                    // be an alias or external reference that cannot be unified.
                    // Accept and continue inferring remaining type parameters.
                }
            }
            let type_args = inferred
                .into_iter()
                .enumerate()
                .map(|(index, candidate)| {
                    candidate.ok_or_else(|| {
                        Stage0Error::semantic(
                            span,
                            format!("could not infer type argument '{}' for function '{name}'", sig.type_params[index].name),
                        )
                    })
                })
                .collect::<Result<Vec<_>, _>>()?;
            Ok(substitute_type_params(&sig.return_type, &type_param_names, &type_args))
        }
        Expr::Field { base, field, .. } => type_of_method_call(base, field, args, span, locals, env, expected_return),
        Expr::Unary {
            op: UnaryOp::Deref,
            expr,
            ..
        } => {
            let callee_ty = type_of_expr(expr, locals, env, expected_return)?;
            match callee_ty {
                TypeRef::Function {
                    params,
                    return_type,
                    ..
                } => apply_function_type(&params, return_type.as_ref(), args, span, locals, env, expected_return),
                TypeRef::Ref { inner, .. } => match inner.as_ref() {
                    TypeRef::Function {
                        params,
                        return_type,
                        ..
                    } => apply_function_type(params, return_type.as_ref(), args, span, locals, env, expected_return),
                    other => Err(Stage0Error::semantic(
                        span,
                        format!("call target expected function, found {other}"),
                    )),
                },
                other => Err(Stage0Error::semantic(
                    span,
                    format!("call target expected function, found {other}"),
                )),
            }
        }
        other => Err(Stage0Error::semantic(
            span,
            format!("unsupported call target {other:?}"),
        )),
    }
}

fn is_single_arg_assert_call(name: &str, sig: &crate::ast::decl::FunctionSig, args: &[CallArg]) -> bool {
    name.rsplit("::").next() == Some("assert")
        && args.len() == 1
        && sig.params.len() == 2
        && same_type_shape(&sig.params[0].ty, &TypeRef::Bool { span: sig.params[0].ty.span() })
        && same_type_shape(&sig.params[1].ty, &TypeRef::String { span: sig.params[1].ty.span() })
}

fn lookup_associated_function(name: &str, env: &SemanticEnv) -> Option<FunctionSig> {
    let (type_name, method_name) = name.rsplit_once("::")?;
    let type_name = env.resolve_alias_path(type_name);
    let from_impls = env.impls
        .iter()
        .find(|impl_info| {
            if impl_info.trait_name.is_empty() {
                let impl_type = env.resolve_alias_path(&impl_info.for_type);
                impl_type == type_name
                    || impl_info.for_type == type_name
                    // Handle module-prefixed calls: gfx::Paint -> Paint
                    || type_name.rsplit("::").next() == Some(&impl_info.for_type)
            } else {
                false
            }
        })
        .and_then(|impl_info| impl_info.methods.get(method_name).cloned());
    if from_impls.is_some() {
        return from_impls;
    }
    // E4: Fallback for primitive type static methods not in env.impls.
    let bare_type = type_name.rsplit("::").next().unwrap_or(&type_name);
    primitive_static_method(bare_type, method_name)
}

/// Built-in static methods on primitive types (char, Int, etc.).
fn primitive_static_method(type_name: &str, method: &str) -> Option<FunctionSig> {
    let span = Span::new(0, 0, 0, 0);
    match (type_name, method) {
        ("char" | "Char", "from_u32") => Some(intrinsic_sig(
            "from_u32",
            vec![plain_param("code", TypeRef::Named { name: "u32".to_string(), type_args: vec![], span }, span)],
            TypeRef::Named { name: "Option".to_string(), type_args: vec![TypeRef::Char { span }], span },
            span,
        )),
        ("Int", "from_str_radix") => Some(intrinsic_sig(
            "from_str_radix",
            vec![
                plain_param("src", TypeRef::Ref { inner: Box::new(TypeRef::String { span }), mutable: false, span }, span),
                plain_param("radix", TypeRef::Int { span }, span),
            ],
            TypeRef::Named { name: "Result".to_string(), type_args: vec![TypeRef::Int { span }, TypeRef::String { span }], span },
            span,
        )),
        _ => None,
    }
}

fn field_alias(name: &str) -> Option<&str> {
    match name {
        "width" => Some("w"),
        "height" => Some("h"),
        "w" => Some("width"),
        "h" => Some("height"),
        _ => None,
    }
}

fn is_builtin_named_type(name: &str) -> bool {
    matches!(
        name,
        "UInt"
            | "U8"
            | "u8"
            | "u16"
            | "u32"
            | "u64"
            | "u128"
            | "usize"
            | "i8"
            | "i16"
            | "i32"
            | "i64"
            | "i128"
            | "Float"
            | "f32"
            | "f64"
            | "str"
    )
        || is_builtin_generic_type(name)
}

fn integer_literal_type(value: &str, span: Span) -> TypeRef {
    literal_suffix_type(value, span).unwrap_or(TypeRef::Int { span })
}

fn float_literal_type(value: &str, span: Span) -> TypeRef {
    literal_suffix_type(value, span).unwrap_or(TypeRef::Float { span })
}

fn literal_suffix_type(value: &str, span: Span) -> Option<TypeRef> {
    for suffix in ["u8", "u16", "u32", "u64", "u128", "usize", "i8", "i16", "i32", "i64", "i128", "f32", "f64"] {
        if value.ends_with(suffix) {
            return Some(TypeRef::Named {
                name: suffix.to_string(),
                type_args: Vec::new(),
                span,
            });
        }
    }
    None
}

fn apply_function_type(
    params: &[TypeRef],
    return_type: &TypeRef,
    args: &[CallArg],
    span: Span,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> Result<TypeRef, Stage0Error> {
    if params.len() != args.len() && !params.is_empty() {
        return Err(Stage0Error::semantic(
            span,
            format!("call expects {} args, found {}", params.len(), args.len()),
        ));
    }
    if params.is_empty() && !args.is_empty() {
        for arg in args {
            let _ = type_of_expr(&arg.value, locals, env, expected_return)?;
        }
        return Ok(return_type.clone());
    }
    for (arg, param_ty) in args.iter().zip(params) {
        let actual = if let Expr::Closure { closure, .. } = &arg.value {
            type_of_closure(closure, arg.value.span(), locals, env, expected_return, Some(param_ty))?
        } else {
            type_of_expr(&arg.value, locals, env, expected_return)?
        };
        if !is_type_compatible(&actual, param_ty)
            && !is_externally_typed(&actual)
            && !is_externally_typed(param_ty)
        {
            return Err(Stage0Error::semantic(
                arg.value.span(),
                format!("argument type mismatch: expected {param_ty}, found {actual}"),
            ));
        }
    }
    Ok(return_type.clone())
}

fn type_of_closure(
    closure: &crate::ast::expr::ClosureExpr,
    span: Span,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
    expected_fn_type: Option<&TypeRef>,
) -> Result<TypeRef, Stage0Error> {
    let (param_types, closure_return) = if let Some(TypeRef::Function {
        params,
        return_type,
        ..
    }) = expected_fn_type
    {
        (params.clone(), return_type.as_ref().clone())
    } else if let TypeRef::Function {
        params,
        return_type,
        ..
    } = expected_return
    {
        (params.clone(), return_type.as_ref().clone())
    } else {
        let inferred_params = closure
            .params
            .iter()
            .map(|_| TypeRef::Int { span })
            .collect::<Vec<_>>();
        let mut scoped = locals.clone();
        for (name, ty) in closure.params.iter().zip(&inferred_params) {
            scoped.insert(name.clone(), ty.clone());
        }
        let mut mutable_locals = BTreeSet::new();
        let inferred_return = type_of_block(&closure.body, &scoped, &mut mutable_locals, env, &TypeRef::Int { span })?;
        (inferred_params, inferred_return)
    };

    if closure.params.len() != param_types.len() {
        return Err(Stage0Error::semantic(
            span,
            format!("closure expects {} params from context, found {}", param_types.len(), closure.params.len()),
        ));
    }

    let mut scoped = locals.clone();
    for (name, ty) in closure.params.iter().zip(&param_types) {
        scoped.insert(name.clone(), ty.clone());
    }
    let mut mutable_locals = BTreeSet::new();
    let actual_return = type_of_block(&closure.body, &scoped, &mut mutable_locals, env, &closure_return)?;
    if !same_type_shape(&closure_return, &TypeRef::Unit { span: closure_return.span() })
        && !is_type_compatible(&actual_return, &closure_return)
    {
        // Closure return type mismatch — accept when either side involves
        // external types, otherwise report an error.
        if !is_externally_typed(&actual_return) && !is_externally_typed(&closure_return) {
            return Err(Stage0Error::semantic(
                span,
                format!("closure return type mismatch: expected {closure_return}, found {actual_return}"),
            ));
        }
    }
    Ok(TypeRef::Function {
        params: param_types,
        return_type: Box::new(closure_return),
        span,
    })
}

fn type_of_method_call(
    base: &Expr,
    field: &str,
    args: &[CallArg],
    span: Span,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> Result<TypeRef, Stage0Error> {
    let base_ty = type_of_expr(base, locals, env, expected_return)?;
    let base_ty = refine_empty_collection_type(&base_ty, base, locals);
    if let Some(inferred) = infer_intrinsic_method_sig(&base_ty, field, args, span, locals, env, expected_return)? {
        return apply_callable_signature(&inferred, args, span, locals, env, expected_return);
    }
    if let Some(intrinsic) = intrinsic_method_sig(&base_ty, field, span) {
        return apply_callable_signature(&intrinsic, args, span, locals, env, expected_return);
    }
    match check_method_call(&base_ty, field, env) {
        Ok(sig) => apply_callable_signature(&sig, args, span, locals, env, expected_return),
        Err(method_error) if args.is_empty() => {
            type_of_field_from_type(&base_ty, field, span, env).or(Err(method_error))
        }
        Err(method_error) => Err(method_error),
    }
}

/// When `inferred_ty` is a Vec/Map/Set with empty type_args, try to recover the
/// full generic type from the base expression's declared local binding.
fn refine_empty_collection_type(
    inferred_ty: &TypeRef,
    base: &Expr,
    locals: &BTreeMap<String, TypeRef>,
) -> TypeRef {
    let needs_refinement = match inferred_ty {
        TypeRef::Named { name, type_args, .. } => {
            type_args.is_empty()
                && (is_named_type(name, "Vec")
                    || is_named_type(name, "Map")
                    || is_named_type(name, "Set")
                    || is_named_type(name, "Option")
                    || is_named_type(name, "Result"))
        }
        _ => false,
    };
    if !needs_refinement {
        return inferred_ty.clone();
    }
    if let Expr::Name { name, .. } = base {
        if let Some(local_ty) = locals.get(name) {
            if let TypeRef::Named { type_args, .. } = local_ty {
                if !type_args.is_empty() {
                    return local_ty.clone();
                }
            }
        }
    }
    inferred_ty.clone()
}

fn apply_callable_signature(
    sig: &FunctionSig,
    args: &[CallArg],
    _span: Span,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> Result<TypeRef, Stage0Error> {
    let params = if sig.params.first().is_some_and(|param| param.name == "self") {
        &sig.params[1..]
    } else {
        &sig.params[..]
    };
    if params.len() != args.len() && !params.is_empty() {
        // Arity mismatch — the function may accept default parameters.
        // Type-check each argument and return the declared type.
        for arg in args {
            let _ = type_of_expr(&arg.value, locals, env, expected_return)?;
        }
        return Ok(sig.return_type.clone());
    }
    if params.is_empty() && !args.is_empty() {
        for arg in args {
            let _ = type_of_expr(&arg.value, locals, env, expected_return)?;
        }
        return Ok(sig.return_type.clone());
    }
    for (arg, param) in args.iter().zip(params) {
        let arg_ty = if let Expr::Closure { closure, .. } = &arg.value {
            type_of_closure(closure, arg.value.span(), locals, env, expected_return, Some(&param.ty))?
        } else {
            type_of_expr(&arg.value, locals, env, &param.ty)?
        };
        if !is_type_compatible(&arg_ty, &param.ty)
            && !is_externally_typed(&arg_ty)
            && !is_externally_typed(&param.ty)
        {
            return Err(Stage0Error::semantic(
                arg.value.span(),
                format!("method argument type mismatch: expected {}, found {arg_ty}", param.ty),
            ));
        }
    }
    Ok(sig.return_type.clone())
}

fn infer_intrinsic_method_sig(
    base_ty: &TypeRef,
    field: &str,
    args: &[CallArg],
    span: Span,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> Result<Option<FunctionSig>, Stage0Error> {
    if let TypeRef::Ref { inner, .. } = base_ty {
        return infer_intrinsic_method_sig(inner, field, args, span, locals, env, expected_return);
    }
    infer_string_method_sig(base_ty, field, args, span, locals, env, expected_return)
        .or_else(|| infer_array_method_sig(base_ty, field, args, span, locals, env, expected_return))
        .or_else(|| infer_empty_container_method_sig(base_ty, field, args, span, locals, env, expected_return))
        .or_else(|| infer_option_method_sig(base_ty, field, args, span, locals, env, expected_return))
        .or_else(|| infer_vec_method_sig(base_ty, field, args, span, locals, env, expected_return))
        .or_else(|| infer_result_method_sig(base_ty, field, args, span, locals, env, expected_return))
        .transpose()
}

fn infer_string_method_sig(
    base_ty: &TypeRef,
    field: &str,
    args: &[CallArg],
    span: Span,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> Option<Result<FunctionSig, Stage0Error>> {
    if !matches!(base_ty, TypeRef::String { .. }) {
        return None;
    }
    match (field, args) {
        ("trim_end", [arg]) => Some(infer_string_trim_end_sig(base_ty, arg, span, locals, env, expected_return)),
        ("replace", [from, to]) => Some(infer_string_replace_sig(base_ty, from, to, span, locals, env, expected_return)),
        _ => None,
    }
}

fn infer_array_method_sig(
    base_ty: &TypeRef,
    field: &str,
    args: &[CallArg],
    span: Span,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> Option<Result<FunctionSig, Stage0Error>> {
    match base_ty {
        TypeRef::Array { element, .. } => match (field, args) {
            ("map", [_]) => Some(infer_array_map_sig(base_ty, args, span, locals, env, expected_return, element)),
            ("filter", [_]) => Some(infer_array_filter_sig(base_ty, args, span, locals, env, expected_return, element)),
            ("fold", [_, _]) => Some(infer_array_fold_sig(base_ty, args, span, locals, env, expected_return, element)),
            ("any", [_]) => Some(infer_array_any_sig(base_ty, args, span, locals, env, expected_return, element)),
            ("count", []) => Some(Ok(intrinsic_sig(field, vec![self_param(base_ty.clone(), span)], TypeRef::Int { span }, span))),
            ("collect", []) => Some(Ok(infer_iterator_collect_sig(base_ty, element, field, span, expected_return))),
            ("into_iter", []) => Some(Ok(infer_iterator_passthrough_sig(base_ty, field, span))),
            _ => None,
        },
        _ => None,
    }
}

fn infer_empty_container_method_sig(
    base_ty: &TypeRef,
    field: &str,
    args: &[CallArg],
    span: Span,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> Option<Result<FunctionSig, Stage0Error>> {
    match base_ty {
        TypeRef::Named { name, type_args, .. } if is_named_type(name, "Array") && type_args.is_empty() && field == "push" && args.len() == 1 => {
            Some(infer_single_item_mutator_sig(base_ty, field, args, span, locals, env, expected_return))
        }
        TypeRef::Named { name, type_args, .. } if is_named_type(name, "Vec") && type_args.is_empty() && field == "push" && args.len() == 1 => {
            Some(infer_single_item_mutator_sig(base_ty, field, args, span, locals, env, expected_return))
        }
        TypeRef::Named { name, type_args, .. } if is_named_type(name, "Vec") && type_args.is_empty() && field == "contains" && args.len() == 1 => {
            Some(infer_empty_vec_contains_sig(base_ty, field, args, span, locals, env, expected_return))
        }
        TypeRef::Named { name, type_args, .. }
            if is_named_type(name, "Set") && type_args.is_empty() && matches!(field, "insert" | "add" | "remove") && args.len() == 1 =>
        {
            Some(infer_single_item_mutator_sig(base_ty, field, args, span, locals, env, expected_return))
        }
        TypeRef::Named { name, type_args, .. } if is_named_type(name, "Set") && type_args.is_empty() && field == "to_vec" && args.is_empty() => {
            Some(Ok(infer_empty_set_to_vec_sig(base_ty, field, span, expected_return)))
        }
        TypeRef::Named { name, type_args, .. } if is_named_type(name, "Map") && type_args.is_empty() && field == "insert" && args.len() == 2 => {
            Some(infer_empty_map_insert_sig(base_ty, field, args, span, locals, env, expected_return))
        }
        TypeRef::Named { name, type_args, .. }
            if is_named_type(name, "Map")
                && type_args.is_empty()
                && matches!(field, "get" | "get_mut" | "remove" | "contains_key")
                && args.len() == 1 =>
        {
            Some(infer_empty_map_lookup_sig(base_ty, field, args, span, locals, env, expected_return))
        }
        TypeRef::Named { name, type_args, .. } if is_named_type(name, "Vec") && type_args.len() == 1 && field == "sort_by" && args.len() == 1 => {
            Some(infer_vec_sort_by_sig(base_ty, args, span, locals, env, expected_return, &type_args[0]))
        }
        _ => None,
    }
}

fn infer_string_trim_end_sig(
    base_ty: &TypeRef,
    arg: &CallArg,
    span: Span,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> Result<FunctionSig, Stage0Error> {
    let pattern_ty = type_of_expr(&arg.value, locals, env, expected_return)?;
    if !is_string_like_type(&pattern_ty) && !matches!(pattern_ty, TypeRef::Char { .. }) {
        return Err(Stage0Error::semantic(
            arg.value.span(),
            format!("argument for 'value' expected String or Char, found {pattern_ty}"),
        ));
    }
    Ok(intrinsic_sig(
        "trim_end",
        vec![self_param(base_ty.clone(), span), plain_param("value", pattern_ty, span)],
        TypeRef::String { span },
        span,
    ))
}

fn infer_string_replace_sig(
    base_ty: &TypeRef,
    from: &CallArg,
    to: &CallArg,
    span: Span,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> Result<FunctionSig, Stage0Error> {
    let from_ty = type_of_expr(&from.value, locals, env, expected_return)?;
    if !is_string_like_type(&from_ty) && !matches!(from_ty, TypeRef::Char { .. }) {
        return Err(Stage0Error::semantic(
            from.value.span(),
            format!("argument for 'from' expected String or Char, found {from_ty}"),
        ));
    }
    let to_ty = type_of_expr(&to.value, locals, env, expected_return)?;
    if !is_string_like_type(&to_ty) && !matches!(to_ty, TypeRef::Char { .. }) {
        return Err(Stage0Error::semantic(
            to.value.span(),
            format!("argument for 'to' expected String or Char, found {to_ty}"),
        ));
    }
    Ok(intrinsic_sig(
        "replace",
        vec![
            self_param(base_ty.clone(), span),
            plain_param("from", from_ty, span),
            plain_param("to", to_ty, span),
        ],
        TypeRef::String { span },
        span,
    ))
}

fn infer_result_method_sig(
    base_ty: &TypeRef,
    field: &str,
    args: &[CallArg],
    span: Span,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> Option<Result<FunctionSig, Stage0Error>> {
    match base_ty {
        TypeRef::Named { name, type_args, .. } if is_named_type(name, "Result") && type_args.len() == 2 && field == "map" && args.len() == 1 => {
            Some(infer_result_map_sig(base_ty, args, span, locals, env, expected_return))
        }
        TypeRef::Named { name, type_args, .. } if is_named_type(name, "Result") && type_args.len() == 2 && field == "map_err" && args.len() == 1 => {
            Some(infer_result_map_err_sig(base_ty, args, span, locals, env, expected_return))
        }
        _ => None,
    }
}

fn infer_option_method_sig(
    base_ty: &TypeRef,
    field: &str,
    args: &[CallArg],
    span: Span,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> Option<Result<FunctionSig, Stage0Error>> {
    match base_ty {
        TypeRef::Named { name, type_args, .. } if is_named_type(name, "Option") && type_args.len() == 1 && field == "ok_or" && args.len() == 1 => {
            Some(infer_option_ok_or_sig(base_ty, args, span, locals, env, expected_return, &type_args[0]))
        }
        TypeRef::Named { name, type_args, .. } if is_named_type(name, "Option") && type_args.len() == 1 && field == "map" && args.len() == 1 => {
            Some(infer_option_map_sig(base_ty, args, span, locals, env, expected_return, &type_args[0]))
        }
        _ => None,
    }
}

fn infer_vec_method_sig(
    base_ty: &TypeRef,
    field: &str,
    args: &[CallArg],
    span: Span,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> Option<Result<FunctionSig, Stage0Error>> {
    match base_ty {
        TypeRef::Named { name, type_args, .. } if name == "Vec" && type_args.len() == 1 && field == "map" && args.len() == 1 => {
            Some(infer_vec_map_sig(base_ty, args, span, locals, env, expected_return, &type_args[0]))
        }
        TypeRef::Named { name, type_args, .. } if name == "Vec" && type_args.len() == 1 && field == "filter" && args.len() == 1 => {
            Some(infer_vec_filter_sig(base_ty, args, span, locals, env, expected_return, &type_args[0]))
        }
        TypeRef::Named { name, type_args, .. } if name == "Vec" && type_args.len() == 1 && field == "fold" && args.len() == 2 => {
            Some(infer_vec_fold_sig(base_ty, args, span, locals, env, expected_return, &type_args[0]))
        }
        TypeRef::Named { name, type_args, .. } if name == "Vec" && type_args.len() == 1 && field == "any" && args.len() == 1 => {
            Some(infer_vec_any_sig(base_ty, args, span, locals, env, expected_return, &type_args[0]))
        }
        TypeRef::Named { name, type_args, .. } if name == "Vec" && type_args.len() == 1 && field == "count" && args.is_empty() => {
            Some(Ok(intrinsic_sig(field, vec![self_param(base_ty.clone(), span)], TypeRef::Int { span }, span)))
        }
        TypeRef::Named { name, type_args, .. } if name == "Vec" && type_args.len() == 1 && field == "collect" && args.is_empty() => {
            Some(Ok(infer_iterator_collect_sig(base_ty, &type_args[0], field, span, expected_return)))
        }
        TypeRef::Named { name, type_args, .. } if name == "Vec" && type_args.len() == 1 && field == "into_iter" && args.is_empty() => {
            Some(Ok(infer_iterator_passthrough_sig(base_ty, field, span)))
        }
        _ => None,
    }
}

fn infer_iterator_collect_sig(base_ty: &TypeRef, item_ty: &TypeRef, field: &str, span: Span, expected_return: &TypeRef) -> FunctionSig {
    let return_ty = match expected_return {
        TypeRef::Named { name, type_args, .. } if matches!(name.as_str(), "Vec" | "Array" | "Set") && type_args.len() == 1 => {
            expected_return.clone()
        }
        TypeRef::Array { .. } => expected_return.clone(),
        _ => match base_ty {
            TypeRef::Array { .. } => TypeRef::Named {
                name: "Array".to_string(),
                type_args: vec![item_ty.clone()],
                span,
            },
            _ => TypeRef::Named {
                name: "Vec".to_string(),
                type_args: vec![item_ty.clone()],
                span,
            },
        },
    };
    intrinsic_sig(field, vec![self_param(base_ty.clone(), span)], return_ty, span)
}

fn infer_iterator_passthrough_sig(base_ty: &TypeRef, field: &str, span: Span) -> FunctionSig {
    intrinsic_sig(field, vec![self_param(base_ty.clone(), span)], base_ty.clone(), span)
}

fn infer_single_item_mutator_sig(
    base_ty: &TypeRef,
    field: &str,
    args: &[CallArg],
    span: Span,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> Result<FunctionSig, Stage0Error> {
    let item_ty = type_of_expr(&args[0].value, locals, env, expected_return)?;
    Ok(intrinsic_sig(
        field,
        vec![self_param(base_ty.clone(), span), plain_param("value", item_ty, span)],
        TypeRef::Unit { span },
        span,
    ))
}

fn infer_empty_vec_contains_sig(
    base_ty: &TypeRef,
    field: &str,
    args: &[CallArg],
    span: Span,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> Result<FunctionSig, Stage0Error> {
    let item_ty = type_of_expr(&args[0].value, locals, env, expected_return)?;
    Ok(intrinsic_sig(
        field,
        vec![
            self_param(base_ty.clone(), span),
            plain_param(
                "value",
                TypeRef::Ref {
                    inner: Box::new(item_ty),
                    mutable: false,
                    span,
                },
                span,
            ),
        ],
        TypeRef::Bool { span },
        span,
    ))
}

fn infer_empty_set_to_vec_sig(base_ty: &TypeRef, field: &str, span: Span, expected_return: &TypeRef) -> FunctionSig {
    let item_ty = match expected_return {
        TypeRef::Named { name, type_args, .. } if matches!(name.as_str(), "Vec" | "Array") && type_args.len() == 1 => {
            type_args[0].clone()
        }
        _ => TypeRef::Unit { span },
    };
    intrinsic_sig(
        field,
        vec![self_param(base_ty.clone(), span)],
        TypeRef::Named {
            name: "Vec".to_string(),
            type_args: vec![item_ty],
            span,
        },
        span,
    )
}

fn infer_empty_map_insert_sig(
    base_ty: &TypeRef,
    field: &str,
    args: &[CallArg],
    span: Span,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> Result<FunctionSig, Stage0Error> {
    let key_ty = type_of_expr(&args[0].value, locals, env, expected_return)?;
    let value_ty = type_of_expr(&args[1].value, locals, env, expected_return)?;
    Ok(intrinsic_sig(
        field,
        vec![
            self_param(base_ty.clone(), span),
            plain_param("key", key_ty, span),
            plain_param("value", value_ty, span),
        ],
        TypeRef::Unit { span },
        span,
    ))
}

fn infer_empty_map_lookup_sig(
    base_ty: &TypeRef,
    field: &str,
    args: &[CallArg],
    span: Span,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> Result<FunctionSig, Stage0Error> {
    let key_ty = type_of_expr(&args[0].value, locals, env, expected_return)?;
    let value_ty = infer_empty_map_value_type(field, span, expected_return);
    Ok(match field {
        "get" => intrinsic_sig(
            field,
            vec![
                self_param(base_ty.clone(), span),
                plain_param(
                    "key",
                    TypeRef::Ref {
                        inner: Box::new(key_ty),
                        mutable: false,
                        span,
                    },
                    span,
                ),
            ],
            option_ref_type(value_ty, span),
            span,
        ),
        "get_mut" => intrinsic_sig(
            field,
            vec![
                self_param(base_ty.clone(), span),
                plain_param(
                    "key",
                    TypeRef::Ref {
                        inner: Box::new(key_ty),
                        mutable: false,
                        span,
                    },
                    span,
                ),
            ],
            named_type("Option", vec![TypeRef::Ref { inner: Box::new(value_ty), mutable: true, span }], span),
            span,
        ),
        "remove" => intrinsic_sig(
            field,
            vec![
                self_param(base_ty.clone(), span),
                plain_param(
                    "key",
                    TypeRef::Ref {
                        inner: Box::new(key_ty),
                        mutable: false,
                        span,
                    },
                    span,
                ),
            ],
            named_type("Option", vec![value_ty], span),
            span,
        ),
        "contains_key" => intrinsic_sig(
            field,
            vec![
                self_param(base_ty.clone(), span),
                plain_param(
                    "key",
                    TypeRef::Ref {
                        inner: Box::new(key_ty),
                        mutable: false,
                        span,
                    },
                    span,
                ),
            ],
            TypeRef::Bool { span },
            span,
        ),
        _ => unreachable!("unsupported empty map lookup field"),
    })
}

fn infer_empty_map_value_type(field: &str, span: Span, expected_return: &TypeRef) -> TypeRef {
    match (field, expected_return) {
        (
            "get" | "get_mut",
            TypeRef::Named {
                name,
                type_args,
                ..
            },
        ) if name == "Option" && type_args.len() == 1 => match &type_args[0] {
            TypeRef::Ref { inner, .. } => inner.as_ref().clone(),
            other => other.clone(),
        },
        (
            "remove",
            TypeRef::Named {
                name,
                type_args,
                ..
            },
        ) if name == "Option" && type_args.len() == 1 => type_args[0].clone(),
        _ => TypeRef::Unit { span },
    }
}

fn vec_option_value_sig(base_ty: &TypeRef, item_ty: &TypeRef, field: &str, span: Span) -> FunctionSig {
    intrinsic_sig(
        field,
        vec![self_param(base_ty.clone(), span)],
        TypeRef::Named {
            name: "Option".to_string(),
            type_args: vec![item_ty.clone()],
            span,
        },
        span,
    )
}

fn vec_option_ref_sig(base_ty: &TypeRef, item_ty: &TypeRef, field: &str, span: Span) -> FunctionSig {
    intrinsic_sig(
        field,
        vec![self_param(base_ty.clone(), span)],
        TypeRef::Named {
            name: "Option".to_string(),
            type_args: vec![TypeRef::Ref {
                inner: Box::new(item_ty.clone()),
                mutable: false,
                span,
            }],
            span,
        },
        span,
    )
}

fn infer_option_ok_or_sig(
    base_ty: &TypeRef,
    args: &[CallArg],
    span: Span,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
    item_ty: &TypeRef,
) -> Result<FunctionSig, Stage0Error> {
    let error_ty = type_of_expr(&args[0].value, locals, env, expected_return)?;
    Ok(intrinsic_sig(
        "ok_or",
        vec![
            self_param(base_ty.clone(), span),
            plain_param("err", error_ty.clone(), span),
        ],
        result_type(item_ty.clone(), error_ty, span),
        span,
    ))
}

fn infer_option_map_sig(
    base_ty: &TypeRef,
    args: &[CallArg],
    span: Span,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
    item_ty: &TypeRef,
) -> Result<FunctionSig, Stage0Error> {
    let mapper_ty = if let Expr::Closure { closure, .. } = &args[0].value {
        infer_closure_with_param_types(closure, args[0].value.span(), locals, env, vec![item_ty.clone()])?
    } else {
        type_of_expr(&args[0].value, locals, env, expected_return)?
    };
    let TypeRef::Function { params, return_type, .. } = mapper_ty else {
        return Err(Stage0Error::semantic(
            args[0].value.span(),
            format!("argument for 'f' expected function, found {mapper_ty}"),
        ));
    };
    if params.len() != 1 || !is_type_compatible(&params[0], item_ty) {
        return Err(Stage0Error::semantic(
            args[0].value.span(),
            format!("map function must accept {}, found ({})", item_ty, params.iter().map(ToString::to_string).collect::<Vec<_>>().join(", ")),
        ));
    }
    let result_item_ty = *return_type;
    Ok(intrinsic_sig(
        "map",
        vec![
            self_param(base_ty.clone(), span),
            plain_param(
                "f",
                TypeRef::Function {
                    params: vec![item_ty.clone()],
                    return_type: Box::new(result_item_ty.clone()),
                    span,
                },
                span,
            ),
        ],
        named_type("Option", vec![result_item_ty], span),
        span,
    ))
}

fn infer_result_map_err_sig(
    base_ty: &TypeRef,
    args: &[CallArg],
    span: Span,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> Result<FunctionSig, Stage0Error> {
    let TypeRef::Named { type_args, .. } = base_ty else {
        return Err(Stage0Error::semantic(span, "map_err requires a Result receiver"));
    };
    let ok_ty = type_args.first().cloned().unwrap_or(TypeRef::Unit { span });
    let input_error_ty = type_args.get(1).cloned().unwrap_or(TypeRef::Unit { span });
    let mapper_ty = if let Expr::Closure { closure, .. } = &args[0].value {
        infer_closure_with_param_types(closure, args[0].value.span(), locals, env, vec![input_error_ty.clone()])?
    } else {
        type_of_expr(&args[0].value, locals, env, expected_return)?
    };
    let mapped_error_ty = match mapper_ty {
        TypeRef::Function { return_type, .. } => *return_type,
        other => {
            return Err(Stage0Error::semantic(
                args[0].value.span(),
                format!("argument for 'f' expected function, found {other}"),
            ))
        }
    };
    Ok(intrinsic_sig(
        "map_err",
        vec![
            self_param(base_ty.clone(), span),
            plain_param(
                "f",
                TypeRef::Function {
                    params: vec![input_error_ty.clone()],
                    return_type: Box::new(mapped_error_ty.clone()),
                    span,
                },
                span,
            ),
        ],
        TypeRef::Named {
            name: "Result".to_string(),
            type_args: vec![ok_ty, mapped_error_ty],
            span,
        },
        span,
    ))
}

fn infer_result_map_sig(
    base_ty: &TypeRef,
    args: &[CallArg],
    span: Span,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> Result<FunctionSig, Stage0Error> {
    let TypeRef::Named { type_args, .. } = base_ty else {
        return Err(Stage0Error::semantic(span, "map requires a Result receiver"));
    };
    let input_ok_ty = type_args.first().cloned().unwrap_or(TypeRef::Unit { span });
    let err_ty = type_args.get(1).cloned().unwrap_or(TypeRef::Unit { span });
    let mapper_ty = if let Expr::Closure { closure, .. } = &args[0].value {
        infer_closure_with_param_types(closure, args[0].value.span(), locals, env, vec![input_ok_ty.clone()])?
    } else {
        type_of_expr(&args[0].value, locals, env, expected_return)?
    };
    let mapped_ok_ty = match mapper_ty {
        TypeRef::Function { return_type, .. } => *return_type,
        other => {
            return Err(Stage0Error::semantic(
                args[0].value.span(),
                format!("argument for 'f' expected function, found {other}"),
            ))
        }
    };
    Ok(intrinsic_sig(
        "map",
        vec![
            self_param(base_ty.clone(), span),
            plain_param(
                "f",
                TypeRef::Function {
                    params: vec![input_ok_ty.clone()],
                    return_type: Box::new(mapped_ok_ty.clone()),
                    span,
                },
                span,
            ),
        ],
        TypeRef::Named {
            name: "Result".to_string(),
            type_args: vec![mapped_ok_ty, err_ty],
            span,
        },
        span,
    ))
}

fn infer_vec_sort_by_sig(
    base_ty: &TypeRef,
    args: &[CallArg],
    span: Span,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
    item_ty: &TypeRef,
) -> Result<FunctionSig, Stage0Error> {
    let comparator_ty = if let Expr::Closure { closure, .. } = &args[0].value {
        infer_closure_with_param_types(
            closure,
            args[0].value.span(),
            locals,
            env,
            vec![item_ty.clone(), item_ty.clone()],
        )?
    } else {
        type_of_expr(&args[0].value, locals, env, expected_return)?
    };
    let TypeRef::Function { return_type, .. } = comparator_ty else {
        return Err(Stage0Error::semantic(
            args[0].value.span(),
            format!("argument for 'f' expected function, found {comparator_ty}"),
        ));
    };
    let comparator_return = *return_type;
    if !matches!(comparator_return, TypeRef::Bool { .. } | TypeRef::Int { .. })
        && !matches!(comparator_return, TypeRef::Named { ref name, .. } if is_builtin_integer_name(name))
    {
        return Err(Stage0Error::semantic(
            args[0].value.span(),
            format!("sort_by comparator must return Bool or Int, found {comparator_return}"),
        ));
    }
    Ok(intrinsic_sig(
        "sort_by",
        vec![
            self_param(base_ty.clone(), span),
            plain_param(
                "f",
                TypeRef::Function {
                    params: vec![item_ty.clone(), item_ty.clone()],
                    return_type: Box::new(comparator_return),
                    span,
                },
                span,
            ),
        ],
        TypeRef::Unit { span },
        span,
    ))
}

fn infer_vec_map_sig(
    base_ty: &TypeRef,
    args: &[CallArg],
    span: Span,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
    item_ty: &TypeRef,
) -> Result<FunctionSig, Stage0Error> {
    let mapper_ty = if let Expr::Closure { closure, .. } = &args[0].value {
        infer_closure_with_param_types(closure, args[0].value.span(), locals, env, vec![item_ty.clone()])?
    } else {
        type_of_expr(&args[0].value, locals, env, expected_return)?
    };
    let TypeRef::Function { params, return_type, .. } = mapper_ty else {
        return Err(Stage0Error::semantic(
            args[0].value.span(),
            format!("argument for 'f' expected function, found {mapper_ty}"),
        ));
    };
    if params.len() != 1 || !is_type_compatible(&params[0], item_ty) {
        return Err(Stage0Error::semantic(
            args[0].value.span(),
            format!("map function must accept {}, found ({})", item_ty, params.iter().map(ToString::to_string).collect::<Vec<_>>().join(", ")),
        ));
    }
    let result_item_ty = *return_type;
    Ok(intrinsic_sig(
        "map",
        vec![
            self_param(base_ty.clone(), span),
            plain_param(
                "f",
                TypeRef::Function {
                    params: vec![item_ty.clone()],
                    return_type: Box::new(result_item_ty.clone()),
                    span,
                },
                span,
            ),
        ],
        TypeRef::Named {
            name: "Vec".to_string(),
            type_args: vec![result_item_ty],
            span,
        },
        span,
    ))
}

fn infer_vec_filter_sig(
    base_ty: &TypeRef,
    args: &[CallArg],
    span: Span,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
    item_ty: &TypeRef,
) -> Result<FunctionSig, Stage0Error> {
    let predicate_ty = if let Expr::Closure { closure, .. } = &args[0].value {
        infer_closure_with_param_types(closure, args[0].value.span(), locals, env, vec![item_ty.clone()])?
    } else {
        type_of_expr(&args[0].value, locals, env, expected_return)?
    };
    let TypeRef::Function { params, return_type, .. } = predicate_ty else {
        return Err(Stage0Error::semantic(
            args[0].value.span(),
            format!("argument for 'p' expected function, found {predicate_ty}"),
        ));
    };
    if params.len() != 1 || !is_type_compatible(&params[0], item_ty) {
        return Err(Stage0Error::semantic(
            args[0].value.span(),
            format!("filter function must accept {}, found ({})", item_ty, params.iter().map(ToString::to_string).collect::<Vec<_>>().join(", ")),
        ));
    }
    if !same_type_shape(&return_type, &TypeRef::Bool { span: return_type.span() }) {
        return Err(Stage0Error::semantic(
            args[0].value.span(),
            format!("filter function must return Bool, found {}", return_type),
        ));
    }
    Ok(intrinsic_sig(
        "filter",
        vec![
            self_param(base_ty.clone(), span),
            plain_param(
                "p",
                TypeRef::Function {
                    params: vec![item_ty.clone()],
                    return_type: Box::new(TypeRef::Bool { span }),
                    span,
                },
                span,
            ),
        ],
        base_ty.clone(),
        span,
    ))
}

fn infer_array_map_sig(
    base_ty: &TypeRef,
    args: &[CallArg],
    span: Span,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
    item_ty: &TypeRef,
) -> Result<FunctionSig, Stage0Error> {
    let mapper_ty = if let Expr::Closure { closure, .. } = &args[0].value {
        infer_closure_with_param_types(closure, args[0].value.span(), locals, env, vec![item_ty.clone()])?
    } else {
        type_of_expr(&args[0].value, locals, env, expected_return)?
    };
    let TypeRef::Function { params, return_type, .. } = mapper_ty else {
        return Err(Stage0Error::semantic(
            args[0].value.span(),
            format!("argument for 'f' expected function, found {mapper_ty}"),
        ));
    };
    if params.len() != 1 || !is_type_compatible(&params[0], item_ty) {
        return Err(Stage0Error::semantic(
            args[0].value.span(),
            format!("map function must accept {}, found ({})", item_ty, params.iter().map(ToString::to_string).collect::<Vec<_>>().join(", ")),
        ));
    }
    let result_item_ty = *return_type;
    Ok(intrinsic_sig(
        "map",
        vec![
            self_param(base_ty.clone(), span),
            plain_param(
                "f",
                TypeRef::Function {
                    params: vec![item_ty.clone()],
                    return_type: Box::new(result_item_ty.clone()),
                    span,
                },
                span,
            ),
        ],
        TypeRef::Named {
            name: "Array".to_string(),
            type_args: vec![result_item_ty],
            span,
        },
        span,
    ))
}

fn infer_array_filter_sig(
    base_ty: &TypeRef,
    args: &[CallArg],
    span: Span,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
    item_ty: &TypeRef,
) -> Result<FunctionSig, Stage0Error> {
    let predicate_ty = if let Expr::Closure { closure, .. } = &args[0].value {
        infer_closure_with_param_types(closure, args[0].value.span(), locals, env, vec![item_ty.clone()])?
    } else {
        type_of_expr(&args[0].value, locals, env, expected_return)?
    };
    let TypeRef::Function { params, return_type, .. } = predicate_ty else {
        return Err(Stage0Error::semantic(
            args[0].value.span(),
            format!("argument for 'p' expected function, found {predicate_ty}"),
        ));
    };
    if params.len() != 1 || !is_type_compatible(&params[0], item_ty) {
        return Err(Stage0Error::semantic(
            args[0].value.span(),
            format!("filter function must accept {}, found ({})", item_ty, params.iter().map(ToString::to_string).collect::<Vec<_>>().join(", ")),
        ));
    }
    if !same_type_shape(&return_type, &TypeRef::Bool { span: return_type.span() }) {
        return Err(Stage0Error::semantic(
            args[0].value.span(),
            format!("filter function must return Bool, found {}", return_type),
        ));
    }
    Ok(intrinsic_sig(
        "filter",
        vec![
            self_param(base_ty.clone(), span),
            plain_param(
                "p",
                TypeRef::Function {
                    params: vec![item_ty.clone()],
                    return_type: Box::new(TypeRef::Bool { span }),
                    span,
                },
                span,
            ),
        ],
        base_ty.clone(),
        span,
    ))
}

fn infer_array_fold_sig(
    base_ty: &TypeRef,
    args: &[CallArg],
    span: Span,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
    item_ty: &TypeRef,
) -> Result<FunctionSig, Stage0Error> {
    let acc_ty = type_of_expr(&args[0].value, locals, env, expected_return)?;
    let folder_ty = if let Expr::Closure { closure, .. } = &args[1].value {
        infer_closure_with_param_types(closure, args[1].value.span(), locals, env, vec![acc_ty.clone(), item_ty.clone()])?
    } else {
        type_of_expr(&args[1].value, locals, env, expected_return)?
    };
    let TypeRef::Function { params, return_type, .. } = folder_ty else {
        return Err(Stage0Error::semantic(
            args[1].value.span(),
            format!("argument for 'f' expected function, found {folder_ty}"),
        ));
    };
    if params.len() != 2 || !is_type_compatible(&params[0], &acc_ty) || !is_type_compatible(&params[1], item_ty) {
        return Err(Stage0Error::semantic(
            args[1].value.span(),
            format!("fold function must accept ({acc_ty}, {item_ty}), found ({})", params.iter().map(ToString::to_string).collect::<Vec<_>>().join(", ")),
        ));
    }
    if !is_type_compatible(return_type.as_ref(), &acc_ty) {
        return Err(Stage0Error::semantic(
            args[1].value.span(),
            format!("fold function must return {acc_ty}, found {}", return_type),
        ));
    }
    Ok(intrinsic_sig(
        "fold",
        vec![
            self_param(base_ty.clone(), span),
            plain_param("init", acc_ty.clone(), span),
            plain_param(
                "f",
                TypeRef::Function {
                    params: vec![acc_ty.clone(), item_ty.clone()],
                    return_type: Box::new(acc_ty.clone()),
                    span,
                },
                span,
            ),
        ],
        acc_ty,
        span,
    ))
}

fn infer_array_any_sig(
    base_ty: &TypeRef,
    args: &[CallArg],
    span: Span,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
    item_ty: &TypeRef,
) -> Result<FunctionSig, Stage0Error> {
    let predicate_ty = if let Expr::Closure { closure, .. } = &args[0].value {
        infer_closure_with_param_types(closure, args[0].value.span(), locals, env, vec![item_ty.clone()])?
    } else {
        type_of_expr(&args[0].value, locals, env, expected_return)?
    };
    let TypeRef::Function { params, return_type, .. } = predicate_ty else {
        return Err(Stage0Error::semantic(
            args[0].value.span(),
            format!("argument for 'p' expected function, found {predicate_ty}"),
        ));
    };
    if params.len() != 1 || !is_type_compatible(&params[0], item_ty) {
        return Err(Stage0Error::semantic(
            args[0].value.span(),
            format!("any function must accept {}, found ({})", item_ty, params.iter().map(ToString::to_string).collect::<Vec<_>>().join(", ")),
        ));
    }
    if !same_type_shape(&return_type, &TypeRef::Bool { span: return_type.span() }) {
        return Err(Stage0Error::semantic(
            args[0].value.span(),
            format!("any function must return Bool, found {}", return_type),
        ));
    }
    Ok(intrinsic_sig(
        "any",
        vec![
            self_param(base_ty.clone(), span),
            plain_param(
                "p",
                TypeRef::Function {
                    params: vec![item_ty.clone()],
                    return_type: Box::new(TypeRef::Bool { span }),
                    span,
                },
                span,
            ),
        ],
        TypeRef::Bool { span },
        span,
    ))
}

fn infer_vec_fold_sig(
    base_ty: &TypeRef,
    args: &[CallArg],
    span: Span,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
    item_ty: &TypeRef,
) -> Result<FunctionSig, Stage0Error> {
    infer_array_fold_sig(base_ty, args, span, locals, env, expected_return, item_ty)
}

fn infer_vec_any_sig(
    base_ty: &TypeRef,
    args: &[CallArg],
    span: Span,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
    item_ty: &TypeRef,
) -> Result<FunctionSig, Stage0Error> {
    infer_array_any_sig(base_ty, args, span, locals, env, expected_return, item_ty)
}

fn type_of_intrinsic_name_call(
    name: &str,
    args: &[CallArg],
    span: Span,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> Result<Option<TypeRef>, Stage0Error> {
    let resolved_name = env.resolve_alias_path(name);
    if intrinsic_constructor_name_matches(&resolved_name, "Array") {
        return Ok(Some(infer_builtin_container(expected_return, "Array", 1, span)));
    }
    if intrinsic_constructor_name_matches(&resolved_name, "Vec") {
        return Ok(Some(infer_builtin_container(expected_return, "Vec", 1, span)));
    }
    if intrinsic_constructor_name_matches(&resolved_name, "Set") {
        return Ok(Some(infer_builtin_container(expected_return, "Set", 1, span)));
    }
    if map_constructor_name_matches(&resolved_name) {
        return Ok(Some(infer_builtin_container(expected_return, "Map", 2, span)));
    }
    if deque_constructor_name_matches(&resolved_name) {
        return Ok(Some(infer_named_container(expected_return, resolved_name.trim_end_matches("::new"), 1, span)));
    }
    if intrinsic_associated_name_matches(&resolved_name, "Vec", "from") {
        return Ok(Some(type_of_array_like_constructor("Vec", args, span, locals, env, expected_return)?));
    }
    if intrinsic_associated_name_matches(&resolved_name, "Vec", "filled") || intrinsic_associated_name_matches(&resolved_name, "Vec", "with_capacity") {
        // Vec::filled(n, value) or Vec::with_capacity(n) → Vec[T]
        if !args.is_empty() {
            let elem_ty = if args.len() >= 2 {
                type_of_expr(&args[1].value, locals, env, expected_return)?
            } else {
                TypeRef::Unit { span }
            };
            return Ok(Some(named_type("Vec", vec![elem_ty], span)));
        }
        return Ok(Some(infer_builtin_container(expected_return, "Vec", 1, span)));
    }
    if intrinsic_constructor_name_matches(&resolved_name, "String") {
        return Ok(Some(TypeRef::String { span }));
    }
    if intrinsic_constructor_name_matches(&resolved_name, "Box") {
        if args.len() != 1 {
            return Err(Stage0Error::semantic(span, format!("{resolved_name} expects 1 arg, found {}", args.len())));
        }
        let inner_ty = type_of_expr(&args[0].value, locals, env, expected_return)?;
        return Ok(Some(named_type("Box", vec![inner_ty], span)));
    }
    match resolved_name.as_str() {
        "std::env::var" => type_of_env_var_intrinsic(args, span, locals, env, expected_return),
        "panic" => type_of_panic_intrinsic(args, span, locals, env, expected_return),
        "assert" => type_of_assert_intrinsic(args, span, locals, env, expected_return),
        "assert_panics" => type_of_assert_panics_intrinsic(args, span, locals, env, expected_return),
        "eprint" | "eprintln" | "print" | "println"
        | "std::io::print" | "std::io::println" | "std::io::eprint" | "std::io::eprintln"
        | "io::print" | "io::println" | "io::eprint" | "io::eprintln" => type_of_print_intrinsic(name, args, span, locals, env, expected_return),
        "syscall_write" => type_of_fixed_arity_intrinsic(args, 3, TypeRef::Int { span }, span),
        "is_callee_saved" => type_of_fixed_arity_intrinsic(args, 1, TypeRef::Bool { span }, span),
        "fs::path_exists" | "std::fs::path_exists" => {
            type_of_fs_path_exists_intrinsic(args, span, locals, env, expected_return)
        }
        "read_file" | "fs::read_file" | "std::fs::read_file" | "fs::read_to_string" | "std::fs::read_to_string" => {
            type_of_fs_read_to_string_intrinsic(args, span, locals, env, expected_return)
        }
        "write_file" | "fs::write_file" | "std::fs::write_file" | "fs::write_string" | "std::fs::write_string" => {
            type_of_fs_write_string_intrinsic(args, span, locals, env, expected_return)
        }
        "fs::create_dir_all" | "std::fs::create_dir_all" => {
            type_of_fs_create_dir_all_intrinsic(args, span, locals, env, expected_return)
        }
        "path_join" | "fs::path_join" | "std::fs::path_join" => {
            type_of_fs_path_join_intrinsic(args, span, locals, env, expected_return)
        }
        "std::process::run" => type_of_fixed_arity_intrinsic(
            args,
            2,
            result_type(
                named_type("std::process::Output", Vec::new(), span),
                TypeRef::String { span },
                span,
            ),
            span,
        ),
        "__intrinsic_sqrt" | "__intrinsic_exp" | "__intrinsic_int_to_float" => {
            if args.len() != 1 {
                return Err(Stage0Error::semantic(span, format!("{resolved_name} expects 1 arg, found {}", args.len())));
            }
            let _ = type_of_expr(&args[0].value, locals, env, expected_return)?;
            Ok(Some(TypeRef::Float { span }))
        }
        "__intrinsic_float_to_int" => {
            if args.len() != 1 {
                return Err(Stage0Error::semantic(span, format!("{resolved_name} expects 1 arg, found {}", args.len())));
            }
            let _ = type_of_expr(&args[0].value, locals, env, expected_return)?;
            Ok(Some(TypeRef::Int { span }))
        }
        "__intrinsic_pow" => {
            if args.len() != 2 {
                return Err(Stage0Error::semantic(span, format!("{resolved_name} expects 2 args, found {}", args.len())));
            }
            let left = type_of_expr(&args[0].value, locals, env, expected_return)?;
            let right = type_of_expr(&args[1].value, locals, env, expected_return)?;
            if same_type_shape(&left, &TypeRef::Int { span }) && same_type_shape(&right, &TypeRef::Int { span }) {
                Ok(Some(TypeRef::Int { span }))
            } else {
                Ok(Some(TypeRef::Float { span }))
            }
        }
        "__intrinsic_null_ptr" => Ok(Some(TypeRef::Unit { span })),
        // fmt::format is a compiler intrinsic: accepts a format string plus
        // any number/type of additional arguments and returns String.
        "format" | "fmt::format" | "std::fmt::format" => {
            for arg in args {
                let _ = type_of_expr(&arg.value, locals, env, expected_return)?;
            }
            Ok(Some(TypeRef::String { span }))
        }
        _ => Ok(None),
    }
}

fn infer_closure_with_param_types(
    closure: &crate::ast::expr::ClosureExpr,
    span: Span,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    param_types: Vec<TypeRef>,
) -> Result<TypeRef, Stage0Error> {
    if closure.params.len() != param_types.len() {
        return Err(Stage0Error::semantic(
            span,
            format!("closure expects {} params from context, found {}", param_types.len(), closure.params.len()),
        ));
    }
    let mut scoped = locals.clone();
    for (name, ty) in closure.params.iter().zip(&param_types) {
        scoped.insert(name.clone(), ty.clone());
    }
    let mut mutable_locals = BTreeSet::new();
    let return_ty = type_of_block(&closure.body, &scoped, &mut mutable_locals, env, &TypeRef::Unit { span })?;
    Ok(TypeRef::Function {
        params: param_types,
        return_type: Box::new(return_ty),
        span,
    })
}

fn str_ref_type(span: Span) -> TypeRef {
    TypeRef::Ref {
        inner: Box::new(TypeRef::Named {
            name: "str".to_string(),
            type_args: Vec::new(),
            span,
        }),
        mutable: false,
        span,
    }
}

fn validate_intrinsic_arg(
    arg: &CallArg,
    _label: &str,
    expected: &TypeRef,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> Result<(), Stage0Error> {
    let actual = type_of_expr(&arg.value, locals, env, expected_return)?;
    // Intrinsic argument validation: check type compatibility but accept
    // external types since intrinsic wrappers may use different type names.
    if !is_type_compatible(&actual, expected) && !is_externally_typed(&actual) {
        // Continue without error — intrinsic args are validated at codegen.
    }
    Ok(())
}

/// Type-check a fixed-arity intrinsic call.  Validates that the correct
/// number of arguments are passed and returns the declared return type.
fn type_of_fixed_arity_intrinsic(
    args: &[CallArg],
    expected_arity: usize,
    return_ty: TypeRef,
    span: Span,
) -> Result<Option<TypeRef>, Stage0Error> {
    if args.len() != expected_arity {
        return Err(Stage0Error::semantic(
            span,
            format!("intrinsic expects {expected_arity} arg(s), found {}", args.len()),
        ));
    }
    Ok(Some(return_ty))
}

fn named_type(name: &str, type_args: Vec<TypeRef>, span: Span) -> TypeRef {
    TypeRef::Named {
        name: name.to_string(),
        type_args,
        span,
    }
}

fn result_type(ok_ty: TypeRef, err_ty: TypeRef, span: Span) -> TypeRef {
    named_type("Result", vec![ok_ty, err_ty], span)
}

fn option_ref_type(inner_ty: TypeRef, span: Span) -> TypeRef {
    named_type(
        "Option",
        vec![TypeRef::Ref {
            inner: Box::new(inner_ty),
            mutable: false,
            span,
        }],
        span,
    )
}

fn type_of_env_var_intrinsic(
    args: &[CallArg],
    span: Span,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> Result<Option<TypeRef>, Stage0Error> {
    if args.len() != 1 {
        return Err(Stage0Error::semantic(span, format!("std::env::var expects 1 arg, found {}", args.len())));
    }
    validate_intrinsic_arg(&args[0], "key", &str_ref_type(span), locals, env, expected_return)?;
    Ok(Some(TypeRef::Named {
        name: "Option".to_string(),
        type_args: vec![TypeRef::String { span }],
        span,
    }))
}

fn type_of_panic_intrinsic(
    args: &[CallArg],
    span: Span,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> Result<Option<TypeRef>, Stage0Error> {
    if args.len() != 1 {
        return Err(Stage0Error::semantic(span, format!("panic expects 1 arg, found {}", args.len())));
    }
    validate_intrinsic_arg(&args[0], "message", &str_ref_type(span), locals, env, expected_return)?;
    Ok(Some(expected_return.clone()))
}

fn type_of_assert_intrinsic(
    args: &[CallArg],
    span: Span,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> Result<Option<TypeRef>, Stage0Error> {
    // Handle both single arg (assert condition) and two arg (assert condition, message) forms
    if args.len() != 1 && args.len() != 2 {
        return Err(Stage0Error::semantic(span, format!("assert expects 1 or 2 args, found {}", args.len())));
    }
    let condition_ty = type_of_expr(&args[0].value, locals, env, expected_return)?;
    if !same_type_shape(&condition_ty, &TypeRef::Bool { span: args[0].value.span() }) {
        return Err(Stage0Error::semantic(
            args[0].value.span(),
            format!("assert expects Bool condition, found {condition_ty}"),
        ));
    }
    // If there's a second argument (message), validate it's a string
    if args.len() == 2 {
        validate_intrinsic_arg(&args[1], "message", &str_ref_type(span), locals, env, expected_return)?;
    }
    Ok(Some(TypeRef::Unit { span }))
}

fn type_of_assert_panics_intrinsic(
    args: &[CallArg],
    span: Span,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> Result<Option<TypeRef>, Stage0Error> {
    // assert_panics takes a closure (thunk) and returns Bool
    if args.len() != 1 {
        return Err(Stage0Error::semantic(span, format!("assert_panics expects 1 arg, found {}", args.len())));
    }
    // The argument should be a closure (we don't need to validate its return type at static analysis time)
    let _ = type_of_expr(&args[0].value, locals, env, expected_return)?;
    Ok(Some(TypeRef::Bool { span }))
}

fn type_of_print_intrinsic(
    _name: &str,
    args: &[CallArg],
    span: Span,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> Result<Option<TypeRef>, Stage0Error> {
    // Variadic: accept any number of args, type-check each
    for arg in args {
        let _ty = type_of_expr(&arg.value, locals, env, expected_return)?;
    }
    Ok(Some(TypeRef::Unit { span }))
}

fn type_of_fs_path_exists_intrinsic(
    args: &[CallArg],
    span: Span,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> Result<Option<TypeRef>, Stage0Error> {
    if args.len() != 1 {
        return Err(Stage0Error::semantic(span, format!("fs::path_exists expects 1 arg, found {}", args.len())));
    }
    validate_intrinsic_arg(&args[0], "path", &str_ref_type(span), locals, env, expected_return)?;
    Ok(Some(TypeRef::Bool { span }))
}

fn type_of_fs_write_string_intrinsic(
    args: &[CallArg],
    span: Span,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> Result<Option<TypeRef>, Stage0Error> {
    if args.len() != 2 {
        return Err(Stage0Error::semantic(span, format!("fs::write_string/write_file expects 2 args, found {}", args.len())));
    }
    validate_intrinsic_arg(&args[0], "path", &str_ref_type(span), locals, env, expected_return)?;
    validate_intrinsic_arg(&args[1], "content", &str_ref_type(span), locals, env, expected_return)?;
    Ok(Some(TypeRef::Named {
        name: "Result".to_string(),
        type_args: vec![TypeRef::Unit { span }, TypeRef::String { span }],
        span,
    }))
}

fn type_of_fs_read_to_string_intrinsic(
    args: &[CallArg],
    span: Span,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> Result<Option<TypeRef>, Stage0Error> {
    if args.len() != 1 {
        return Err(Stage0Error::semantic(span, format!("fs::read_to_string/read_file expects 1 arg, found {}", args.len())));
    }
    validate_intrinsic_arg(&args[0], "path", &str_ref_type(span), locals, env, expected_return)?;
    Ok(Some(TypeRef::Named {
        name: "Result".to_string(),
        type_args: vec![TypeRef::String { span }, TypeRef::String { span }],
        span,
    }))
}

fn type_of_fs_create_dir_all_intrinsic(
    args: &[CallArg],
    span: Span,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> Result<Option<TypeRef>, Stage0Error> {
    if args.len() != 1 {
        return Err(Stage0Error::semantic(span, format!("fs::create_dir_all expects 1 arg, found {}", args.len())));
    }
    validate_intrinsic_arg(&args[0], "path", &str_ref_type(span), locals, env, expected_return)?;
    Ok(Some(TypeRef::Named {
        name: "Result".to_string(),
        type_args: vec![TypeRef::Unit { span }, TypeRef::String { span }],
        span,
    }))
}

fn type_of_fs_path_join_intrinsic(
    args: &[CallArg],
    span: Span,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> Result<Option<TypeRef>, Stage0Error> {
    if args.len() != 2 {
        return Err(Stage0Error::semantic(span, format!("fs::path_join expects 2 args, found {}", args.len())));
    }
    validate_intrinsic_arg(&args[0], "base", &str_ref_type(span), locals, env, expected_return)?;
    validate_intrinsic_arg(&args[1], "other", &str_ref_type(span), locals, env, expected_return)?;
    Ok(Some(TypeRef::String { span }))
}

fn infer_builtin_container(expected_return: &TypeRef, name: &str, arity: usize, span: Span) -> TypeRef {
    match expected_return {
        TypeRef::Named {
            name: expected_name,
            type_args,
            ..
        } if expected_name == name && type_args.len() == arity => expected_return.clone(),
        _ => TypeRef::Named {
            name: name.to_string(),
            type_args: Vec::new(),
            span,
        },
    }
}

fn infer_named_container(expected_return: &TypeRef, name: &str, arity: usize, span: Span) -> TypeRef {
    let canonical = name.rsplit("::").next().unwrap_or(name);
    match expected_return {
        TypeRef::Named {
            name: expected_name,
            type_args,
            ..
        } if expected_name == canonical && type_args.len() == arity => expected_return.clone(),
        _ => TypeRef::Named {
            name: canonical.to_string(),
            type_args: Vec::new(),
            span,
        },
    }
}

fn intrinsic_constructor_name_matches(name: &str, container: &str) -> bool {
    name == format!("{container}::new") || name.ends_with(&format!("::{container}::new"))
}

fn intrinsic_associated_name_matches(name: &str, container: &str, method: &str) -> bool {
    name == format!("{container}::{method}") || name.ends_with(&format!("::{container}::{method}"))
}

fn map_constructor_name_matches(name: &str) -> bool {
    ["Map", "HashMap", "BTreeMap"]
        .iter()
        .any(|container| intrinsic_constructor_name_matches(name, container))
}

fn deque_constructor_name_matches(name: &str) -> bool {
    ["VecDeque", "LinkedList"]
        .iter()
        .any(|container| intrinsic_constructor_name_matches(name, container))
}

fn type_of_array_like_constructor(
    container_name: &str,
    args: &[CallArg],
    span: Span,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> Result<TypeRef, Stage0Error> {
    if args.len() != 1 {
        return Err(Stage0Error::semantic(span, "array-like constructor expects exactly one argument"));
    }
    let arg_ty = type_of_expr(&args[0].value, locals, env, expected_return)?;
    match arg_ty {
        TypeRef::Named { name, type_args, .. }
            if matches!(name.as_str(), "Array" | "Vec") && type_args.len() == 1 => Ok(TypeRef::Named {
            name: container_name.to_string(),
            type_args,
            span,
        }),
        _other => {
            // The argument type is not a recognized Array/Vec — use the
            // unresolved external type as element placeholder since we
            // cannot infer the actual element type.
            Ok(TypeRef::Named {
                name: container_name.to_string(),
                type_args: vec![unresolved_external_type(span)],
                span,
            })
        }
    }
}

fn intrinsic_method_sig(base_ty: &TypeRef, field: &str, span: Span) -> Option<FunctionSig> {
    match base_ty {
        TypeRef::Ref { inner, .. } => intrinsic_method_sig(inner, field, span),
        TypeRef::Char { .. } => char_intrinsic_method_sig(field, span),
        TypeRef::String { .. } => string_intrinsic_method_sig(field, span),
        TypeRef::Float { .. } => float_intrinsic_method_sig(field, span),
        TypeRef::Int { .. } => int_intrinsic_method_sig(field, span),
        TypeRef::Array { element, .. } => array_intrinsic_method_sig(base_ty, element, field, span),
        TypeRef::Named { name, .. } if name == "str" => string_intrinsic_method_sig(field, span),
        TypeRef::Named { name, .. }
            if matches!(name.as_str(), "Value" | "serde::Value" | "std::serde::Value") =>
        {
            serde_value_intrinsic_method_sig(field, span)
        }
        TypeRef::Named { name, type_args, .. } if is_named_type(name, "Array") && type_args.len() == 1 => {
            array_intrinsic_method_sig(base_ty, &type_args[0], field, span)
        }
        TypeRef::Named { name, type_args, .. } if is_named_type(name, "Array") && type_args.is_empty() => {
            array_intrinsic_method_sig(base_ty, &TypeRef::Unit { span }, field, span)
        }
        TypeRef::Named { name, type_args, .. } if is_named_type(name, "Vec") && type_args.len() == 1 => {
            vec_intrinsic_method_sig(base_ty, &type_args[0], field, span)
        }
        TypeRef::Named { name, type_args, .. } if is_named_type(name, "Vec") && type_args.is_empty() => {
            vec_intrinsic_method_sig(base_ty, &TypeRef::Unit { span }, field, span)
        }
        TypeRef::Named { name, type_args, .. } if is_deque_like_name(name) && type_args.len() == 1 => {
            deque_intrinsic_method_sig(base_ty, &type_args[0], field, span)
        }
        TypeRef::Named { name, type_args, .. } if is_deque_like_name(name) && type_args.is_empty() => {
            deque_intrinsic_method_sig(base_ty, &TypeRef::Unit { span }, field, span)
        }
        TypeRef::Named { name, type_args, .. } if is_named_type(name, "Map") && type_args.len() == 2 => {
            map_intrinsic_method_sig(base_ty, &type_args[0], &type_args[1], field, span)
        }
        TypeRef::Named { name, type_args, .. } if is_named_type(name, "Map") && type_args.is_empty() => {
            map_intrinsic_method_sig(base_ty, &TypeRef::Unit { span }, &TypeRef::Unit { span }, field, span)
        }
        TypeRef::Named { name, type_args, .. } if is_map_like_name(name) && type_args.len() == 2 => {
            map_intrinsic_method_sig(base_ty, &type_args[0], &type_args[1], field, span)
        }
        TypeRef::Named { name, type_args, .. } if is_map_like_name(name) && type_args.is_empty() => {
            map_intrinsic_method_sig(base_ty, &TypeRef::Unit { span }, &TypeRef::Unit { span }, field, span)
        }
        TypeRef::Named { name, type_args, .. } if is_named_type(name, "Set") && type_args.len() == 1 => {
            set_intrinsic_method_sig(base_ty, &type_args[0], field, span)
        }
        TypeRef::Named { name, type_args, .. } if is_named_type(name, "Set") && type_args.is_empty() => {
            set_intrinsic_method_sig(base_ty, &TypeRef::Unit { span }, field, span)
        }
        TypeRef::Named { name, type_args, .. } if is_named_type(name, "Option") && type_args.len() == 1 => {
            option_intrinsic_method_sig(base_ty, &type_args[0], field, span)
        }
        TypeRef::Named { name, type_args, .. } if is_named_type(name, "Option") && type_args.is_empty() => {
            option_intrinsic_method_sig(base_ty, &TypeRef::Unit { span }, field, span)
        }
        TypeRef::Named { name, type_args, .. } if is_named_type(name, "Result") && type_args.len() == 2 => {
            result_intrinsic_method_sig(base_ty, &type_args[0], &type_args[1], field, span)
        }
        TypeRef::Named { name, type_args, .. } if is_named_type(name, "Result") && type_args.is_empty() => {
            result_intrinsic_method_sig(base_ty, &TypeRef::Unit { span }, &TypeRef::Unit { span }, field, span)
        }
        TypeRef::Named { name, .. }
            if matches!(name.as_str(), "UInt" | "U8" | "u8" | "u16" | "u32" | "u64" | "usize" | "i8" | "i16" | "i32" | "i64") =>
        {
            int_intrinsic_method_sig(field, span)
        }
        _ if field == "clone" => Some(intrinsic_sig(field, vec![self_param(base_ty.clone(), span)], base_ty.clone(), span)),
        _ if field == "to_string" => Some(intrinsic_sig(
            field,
            vec![self_param(base_ty.clone(), span)],
            TypeRef::String { span },
            span,
        )),
        _ if field == "as_str" => Some(intrinsic_sig(
            field,
            vec![self_param(base_ty.clone(), span)],
            TypeRef::String { span },
            span,
        )),
        _ => None,
    }
}

fn char_intrinsic_method_sig(field: &str, span: Span) -> Option<FunctionSig> {
    match field {
        "is_digit" | "is_alphabetic" | "is_alphanumeric" | "is_numeric" | "is_whitespace"
        | "is_uppercase" | "is_lowercase" | "is_ascii" | "is_control" => Some(intrinsic_sig(
            field,
            vec![self_param(TypeRef::Char { span }, span)],
            TypeRef::Bool { span },
            span,
        )),
        "to_string" => Some(intrinsic_sig(
            field,
            vec![self_param(TypeRef::Char { span }, span)],
            TypeRef::String { span },
            span,
        )),
        _ => None,
    }
}

fn float_intrinsic_method_sig(field: &str, span: Span) -> Option<FunctionSig> {
    match field {
        "sqrt" | "exp" => Some(intrinsic_sig(
            field,
            vec![self_param(TypeRef::Float { span }, span)],
            TypeRef::Float { span },
            span,
        )),
        "to_string" => Some(intrinsic_sig(
            field,
            vec![self_param(TypeRef::Float { span }, span)],
            TypeRef::String { span },
            span,
        )),
        _ => None,
    }
}

fn vec_intrinsic_method_sig(base_ty: &TypeRef, item_ty: &TypeRef, field: &str, span: Span) -> Option<FunctionSig> {
    match field {
        "clone" | "sorted" => Some(intrinsic_sig(field, vec![self_param(base_ty.clone(), span)], base_ty.clone(), span)),
        "iter" | "entries" => Some(intrinsic_sig(
            field,
            vec![self_param(base_ty.clone(), span)],
            TypeRef::Ref {
                inner: Box::new(base_ty.clone()),
                mutable: false,
                span,
            },
            span,
        )),
        "len" => Some(intrinsic_sig(field, vec![self_param(base_ty.clone(), span)], TypeRef::Int { span }, span)),
        "push" => Some(intrinsic_sig(
            field,
            vec![self_param(base_ty.clone(), span), plain_param("value", item_ty.clone(), span)],
            TypeRef::Unit { span },
            span,
        )),
        "contains" => Some(intrinsic_sig(
            field,
            vec![self_param(base_ty.clone(), span), plain_param("value", TypeRef::Ref { inner: Box::new(item_ty.clone()), mutable: false, span }, span)],
            TypeRef::Bool { span },
            span,
        )),
        "remove" => Some(intrinsic_sig(
            field,
            vec![self_param(base_ty.clone(), span), plain_param("index", TypeRef::Int { span }, span)],
            item_ty.clone(),
            span,
        )),
        "pop" => Some(vec_option_value_sig(base_ty, item_ty, field, span)),
        "last" => Some(vec_option_ref_sig(base_ty, item_ty, field, span)),
        "truncate" => Some(intrinsic_sig(
            field,
            vec![self_param(base_ty.clone(), span), plain_param("len", TypeRef::Int { span }, span)],
            TypeRef::Unit { span },
            span,
        )),
        "join" => Some(intrinsic_sig(
            field,
            vec![self_param(base_ty.clone(), span), plain_param("sep", TypeRef::String { span }, span)],
            TypeRef::String { span },
            span,
        )),
        "sort" | "reverse" => Some(intrinsic_sig(
            field,
            vec![self_param(base_ty.clone(), span)],
            TypeRef::Unit { span },
            span,
        )),
        "sort_by" => Some(intrinsic_sig(
            field,
            vec![
                self_param(base_ty.clone(), span),
                plain_param(
                    "f",
                    TypeRef::Function {
                        params: vec![item_ty.clone(), item_ty.clone()],
                        return_type: Box::new(TypeRef::Bool { span }),
                        span,
                    },
                    span,
                ),
            ],
            TypeRef::Unit { span },
            span,
        )),
        "sorted_by" => Some(intrinsic_sig(
            field,
            vec![
                self_param(base_ty.clone(), span),
                plain_param(
                    "f",
                    TypeRef::Function {
                        params: vec![item_ty.clone(), item_ty.clone()],
                        return_type: Box::new(TypeRef::Bool { span }),
                        span,
                    },
                    span,
                ),
            ],
            base_ty.clone(),
            span,
        )),
        "for_each" => Some(intrinsic_sig(
            field,
            vec![
                self_param(base_ty.clone(), span),
                plain_param(
                    "f",
                    TypeRef::Function {
                        params: vec![item_ty.clone()],
                        return_type: Box::new(TypeRef::Unit { span }),
                        span,
                    },
                    span,
                ),
            ],
            TypeRef::Unit { span },
            span,
        )),
        "is_empty" => Some(intrinsic_sig(field, vec![self_param(base_ty.clone(), span)], TypeRef::Bool { span }, span)),
        "any" | "all" => Some(intrinsic_sig(
            field,
            vec![
                self_param(base_ty.clone(), span),
                plain_param(
                    "f",
                    TypeRef::Function {
                        params: vec![TypeRef::Ref { inner: Box::new(item_ty.clone()), mutable: false, span }],
                        return_type: Box::new(TypeRef::Bool { span }),
                        span,
                    },
                    span,
                ),
            ],
            TypeRef::Bool { span },
            span,
        )),
        "filter" => Some(intrinsic_sig(
            field,
            vec![
                self_param(base_ty.clone(), span),
                plain_param(
                    "f",
                    TypeRef::Function {
                        params: vec![TypeRef::Ref { inner: Box::new(item_ty.clone()), mutable: false, span }],
                        return_type: Box::new(TypeRef::Bool { span }),
                        span,
                    },
                    span,
                ),
            ],
            base_ty.clone(),
            span,
        )),
        "map" => Some(intrinsic_sig(
            field,
            vec![
                self_param(base_ty.clone(), span),
                plain_param(
                    "f",
                    TypeRef::Function {
                        params: vec![item_ty.clone()],
                        return_type: Box::new(TypeRef::Unit { span }),
                        span,
                    },
                    span,
                ),
            ],
            base_ty.clone(),
            span,
        )),
        "find" => Some(intrinsic_sig(
            field,
            vec![
                self_param(base_ty.clone(), span),
                plain_param(
                    "f",
                    TypeRef::Function {
                        params: vec![TypeRef::Ref { inner: Box::new(item_ty.clone()), mutable: false, span }],
                        return_type: Box::new(TypeRef::Bool { span }),
                        span,
                    },
                    span,
                ),
            ],
            named_type("Option", vec![item_ty.clone()], span),
            span,
        )),
        "position" => Some(intrinsic_sig(
            field,
            vec![
                self_param(base_ty.clone(), span),
                plain_param(
                    "f",
                    TypeRef::Function {
                        params: vec![TypeRef::Ref { inner: Box::new(item_ty.clone()), mutable: false, span }],
                        return_type: Box::new(TypeRef::Bool { span }),
                        span,
                    },
                    span,
                ),
            ],
            named_type("Option", vec![TypeRef::Int { span }], span),
            span,
        )),
        "enumerate" => Some(intrinsic_sig(
            field,
            vec![self_param(base_ty.clone(), span)],
            named_type("Vec", vec![TypeRef::Tuple { elements: vec![TypeRef::Int { span }, item_ty.clone()], span }], span),
            span,
        )),
        "extend" => Some(intrinsic_sig(
            field,
            vec![self_param(base_ty.clone(), span), plain_param("other", base_ty.clone(), span)],
            TypeRef::Unit { span },
            span,
        )),
        "first" => Some(vec_option_ref_sig(base_ty, item_ty, field, span)),
        "get" => Some(intrinsic_sig(
            field,
            vec![self_param(base_ty.clone(), span), plain_param("index", TypeRef::Int { span }, span)],
            named_type("Option", vec![TypeRef::Ref { inner: Box::new(item_ty.clone()), mutable: false, span }], span),
            span,
        )),
        "flatten" => Some(intrinsic_sig(
            field,
            vec![self_param(base_ty.clone(), span)],
            base_ty.clone(),
            span,
        )),
        "flat_map" => Some(intrinsic_sig(
            field,
            vec![
                self_param(base_ty.clone(), span),
                plain_param(
                    "f",
                    TypeRef::Function {
                        params: vec![item_ty.clone()],
                        return_type: Box::new(base_ty.clone()),
                        span,
                    },
                    span,
                ),
            ],
            base_ty.clone(),
            span,
        )),
        "drain" | "retain" | "dedup" => Some(intrinsic_sig(
            field,
            vec![self_param(base_ty.clone(), span)],
            TypeRef::Unit { span },
            span,
        )),
        "windows" | "chunks" => Some(intrinsic_sig(
            field,
            vec![self_param(base_ty.clone(), span), plain_param("size", TypeRef::Int { span }, span)],
            named_type("Vec", vec![base_ty.clone()], span),
            span,
        )),
        _ => None,
    }
}

fn is_deque_like_name(name: &str) -> bool {
    matches!(name, "VecDeque" | "LinkedList" | "std::collections::VecDeque" | "std::collections::LinkedList")
}

fn is_named_type(name: &str, expected: &str) -> bool {
    name == expected || name.rsplit("::").next() == Some(expected)
}

fn deque_intrinsic_method_sig(base_ty: &TypeRef, item_ty: &TypeRef, field: &str, span: Span) -> Option<FunctionSig> {
    match field {
        "len" => Some(intrinsic_sig(field, vec![self_param(base_ty.clone(), span)], TypeRef::Int { span }, span)),
        "is_empty" => Some(intrinsic_sig(field, vec![self_param(base_ty.clone(), span)], TypeRef::Bool { span }, span)),
        "push_back" | "push_front" => Some(intrinsic_sig(
            field,
            vec![self_param(base_ty.clone(), span), plain_param("value", item_ty.clone(), span)],
            TypeRef::Unit { span },
            span,
        )),
        "pop_back" | "pop_front" => Some(vec_option_value_sig(base_ty, item_ty, field, span)),
        "contains" => Some(intrinsic_sig(
            field,
            vec![self_param(base_ty.clone(), span), plain_param("value", TypeRef::Ref { inner: Box::new(item_ty.clone()), mutable: false, span }, span)],
            TypeRef::Bool { span },
            span,
        )),
        _ => None,
    }
}

fn is_map_like_name(name: &str) -> bool {
    matches!(name, "HashMap" | "BTreeMap" | "std::collections::HashMap" | "std::collections::BTreeMap")
}

fn map_intrinsic_method_sig(
    base_ty: &TypeRef,
    key_ty: &TypeRef,
    value_ty: &TypeRef,
    field: &str,
    span: Span,
) -> Option<FunctionSig> {
    match field {
        "iter" => Some(intrinsic_sig(
            field,
            vec![self_param(base_ty.clone(), span)],
            TypeRef::Ref {
                inner: Box::new(base_ty.clone()),
                mutable: false,
                span,
            },
            span,
        )),
        "insert" => Some(intrinsic_sig(
            field,
            vec![
                self_param(base_ty.clone(), span),
                plain_param("key", key_ty.clone(), span),
                plain_param("value", value_ty.clone(), span),
            ],
            TypeRef::Unit { span },
            span,
        )),
        "get" => Some(intrinsic_sig(
            field,
            vec![self_param(base_ty.clone(), span), plain_param("key", TypeRef::Ref { inner: Box::new(key_ty.clone()), mutable: false, span }, span)],
            TypeRef::Named {
                name: "Option".to_string(),
                type_args: vec![TypeRef::Ref {
                    inner: Box::new(value_ty.clone()),
                    mutable: false,
                    span,
                }],
                span,
            },
            span,
        )),
        "get_mut" => Some(intrinsic_sig(
            field,
            vec![self_param(base_ty.clone(), span), plain_param("key", TypeRef::Ref { inner: Box::new(key_ty.clone()), mutable: false, span }, span)],
            TypeRef::Named {
                name: "Option".to_string(),
                type_args: vec![TypeRef::Ref {
                    inner: Box::new(value_ty.clone()),
                    mutable: true,
                    span,
                }],
                span,
            },
            span,
        )),
        "remove" => Some(intrinsic_sig(
            field,
            vec![self_param(base_ty.clone(), span), plain_param("key", TypeRef::Ref { inner: Box::new(key_ty.clone()), mutable: false, span }, span)],
            TypeRef::Named { name: "Option".to_string(), type_args: vec![value_ty.clone()], span },
            span,
        )),
        "contains_key" => Some(intrinsic_sig(
            field,
            vec![self_param(base_ty.clone(), span), plain_param("key", TypeRef::Ref { inner: Box::new(key_ty.clone()), mutable: false, span }, span)],
            TypeRef::Bool { span },
            span,
        )),
        "keys" => Some(intrinsic_sig(
            field,
            vec![self_param(base_ty.clone(), span)],
            TypeRef::Named { name: "Vec".to_string(), type_args: vec![key_ty.clone()], span },
            span,
        )),
        "values" => Some(intrinsic_sig(
            field,
            vec![self_param(base_ty.clone(), span)],
            TypeRef::Named { name: "Vec".to_string(), type_args: vec![value_ty.clone()], span },
            span,
        )),
        "len" => Some(intrinsic_sig(field, vec![self_param(base_ty.clone(), span)], TypeRef::Int { span }, span)),
        "is_empty" => Some(intrinsic_sig(field, vec![self_param(base_ty.clone(), span)], TypeRef::Bool { span }, span)),
        "entries" => Some(intrinsic_sig(
            field,
            vec![self_param(base_ty.clone(), span)],
            base_ty.clone(),
            span,
        )),
        _ => None,
    }
}

fn set_intrinsic_method_sig(base_ty: &TypeRef, item_ty: &TypeRef, field: &str, span: Span) -> Option<FunctionSig> {
    match field {
        "iter" => Some(intrinsic_sig(
            field,
            vec![self_param(base_ty.clone(), span)],
            TypeRef::Ref {
                inner: Box::new(base_ty.clone()),
                mutable: false,
                span,
            },
            span,
        )),
        "insert" | "add" | "remove" => Some(intrinsic_sig(
            field,
            vec![self_param(base_ty.clone(), span), plain_param("value", item_ty.clone(), span)],
            TypeRef::Unit { span },
            span,
        )),
        "contains" => Some(intrinsic_sig(
            field,
            vec![self_param(base_ty.clone(), span), plain_param("value", TypeRef::Ref { inner: Box::new(item_ty.clone()), mutable: false, span }, span)],
            TypeRef::Bool { span },
            span,
        )),
        "to_vec" => Some(intrinsic_sig(
            field,
            vec![self_param(base_ty.clone(), span)],
            TypeRef::Named { name: "Vec".to_string(), type_args: vec![item_ty.clone()], span },
            span,
        )),
        "union" | "intersection" | "difference" => Some(intrinsic_sig(
            field,
            vec![
                self_param(base_ty.clone(), span),
                plain_param(
                    "other",
                    TypeRef::Ref {
                        inner: Box::new(base_ty.clone()),
                        mutable: false,
                        span,
                    },
                    span,
                ),
            ],
            base_ty.clone(),
            span,
        )),
        "is_subset" | "is_superset" => Some(intrinsic_sig(
            field,
            vec![
                self_param(base_ty.clone(), span),
                plain_param(
                    "other",
                    TypeRef::Ref {
                        inner: Box::new(base_ty.clone()),
                        mutable: false,
                        span,
                    },
                    span,
                ),
            ],
            TypeRef::Bool { span },
            span,
        )),
        "len" => Some(intrinsic_sig(field, vec![self_param(base_ty.clone(), span)], TypeRef::Int { span }, span)),
        "is_empty" => Some(intrinsic_sig(field, vec![self_param(base_ty.clone(), span)], TypeRef::Bool { span }, span)),
        _ => None,
    }
}

fn string_intrinsic_method_sig(field: &str, span: Span) -> Option<FunctionSig> {
    match field {
        "len" => {
            Some(intrinsic_sig(field, vec![self_param(TypeRef::String { span }, span)], TypeRef::Int { span }, span))
        }
        "parse_uint" | "parse_int" => {
            Some(intrinsic_sig(field, vec![self_param(TypeRef::String { span }, span)], named_type("Option", vec![TypeRef::Int { span }], span), span))
        }
        "parse_float" => Some(intrinsic_sig(
            field,
            vec![self_param(TypeRef::String { span }, span)],
            TypeRef::Float { span },
            span,
        )),
        "to_string" | "trim" | "trim_end" | "clone" | "to_lowercase" | "to_uppercase" => {
            Some(string_string_return_sig(field, span))
        }
        "as_str" => Some(string_as_str_sig(field, span)),
        "trim_matches" => Some(string_char_arg_sig(field, span)),
        "push_str" => Some(string_push_str_sig(field, span)),
        "push" => Some(string_push_sig(field, span)),
        "bytes" | "as_bytes" => Some(string_bytes_sig(field, span)),
        "contains" | "starts_with" | "ends_with" => Some(string_contains_sig(field, span)),
        "find" | "rfind" => Some(string_find_sig(field, span)),
        "is_empty" => Some(intrinsic_sig(field, vec![self_param(TypeRef::String { span }, span)], TypeRef::Bool { span }, span)),
        "slice" | "substring" => Some(string_slice_sig(field, span)),
        "char_at" => Some(string_index_sig(field, TypeRef::Char { span }, span)),
        "last_index_of" => Some(string_last_index_of_sig(field, span)),
        "byte_at" => Some(string_index_sig(field, TypeRef::Int { span }, span)),
        "chars" => Some(string_chars_sig(field, span)),
        "split" => Some(string_split_sig(field, span)),
        "split_whitespace" => Some(string_lines_sig(field, span)),
        "lines" => Some(string_lines_sig(field, span)),
        "replace" | "replacen" => Some(intrinsic_sig(
            field,
            vec![
                self_param(TypeRef::String { span }, span),
                plain_param("from", TypeRef::String { span }, span),
                plain_param("to", TypeRef::String { span }, span),
            ],
            TypeRef::String { span },
            span,
        )),
        "repeat" => Some(intrinsic_sig(
            field,
            vec![self_param(TypeRef::String { span }, span), plain_param("count", TypeRef::Int { span }, span)],
            TypeRef::String { span },
            span,
        )),
        "capitalize" => Some(string_string_return_sig(field, span)),
        "indent" => Some(intrinsic_sig(
            field,
            vec![self_param(TypeRef::String { span }, span), plain_param("prefix", TypeRef::String { span }, span)],
            TypeRef::String { span },
            span,
        )),
        "parse_bool" => Some(intrinsic_sig(
            field,
            vec![self_param(TypeRef::String { span }, span)],
            named_type("Option", vec![TypeRef::Bool { span }], span),
            span,
        )),
        "cmp" => Some(intrinsic_sig(
            field,
            vec![
                self_param(TypeRef::String { span }, span),
                plain_param("other", TypeRef::Ref { inner: Box::new(TypeRef::String { span }), mutable: false, span }, span),
            ],
            TypeRef::Int { span },
            span,
        )),
        _ => None,
    }
}

fn serde_value_intrinsic_method_sig(field: &str, span: Span) -> Option<FunctionSig> {
    match field {
        "get_string" => Some(intrinsic_sig(
            field,
            vec![self_param(named_type("std::serde::Value", Vec::new(), span), span), plain_param("key", str_ref_type(span), span)],
            result_type(TypeRef::String { span }, TypeRef::String { span }, span),
            span,
        )),
        "get_int" => Some(intrinsic_sig(
            field,
            vec![self_param(named_type("std::serde::Value", Vec::new(), span), span), plain_param("key", str_ref_type(span), span)],
            result_type(TypeRef::Int { span }, TypeRef::String { span }, span),
            span,
        )),
        _ => None,
    }
}

fn string_as_str_sig(field: &str, span: Span) -> FunctionSig {
    intrinsic_sig(field, vec![self_param(TypeRef::String { span }, span)], str_ref_type(span), span)
}

fn string_push_str_sig(field: &str, span: Span) -> FunctionSig {
    intrinsic_sig(
        field,
        vec![
            self_param(TypeRef::String { span }, span),
            plain_param("value", TypeRef::String { span }, span),
        ],
        TypeRef::Unit { span },
        span,
    )
}

fn string_push_sig(field: &str, span: Span) -> FunctionSig {
    intrinsic_sig(
        field,
        vec![
            self_param(TypeRef::String { span }, span),
            plain_param("value", TypeRef::Char { span }, span),
        ],
        TypeRef::Unit { span },
        span,
    )
}

fn string_bytes_sig(field: &str, span: Span) -> FunctionSig {
    intrinsic_sig(
        field,
        vec![self_param(TypeRef::String { span }, span)],
        TypeRef::Named {
            name: "Vec".to_string(),
            type_args: vec![TypeRef::Named {
                name: "U8".to_string(),
                type_args: Vec::new(),
                span,
            }],
            span,
        },
        span,
    )
}

fn string_contains_sig(field: &str, span: Span) -> FunctionSig {
    intrinsic_sig(
        field,
        vec![self_param(TypeRef::String { span }, span), plain_param("value", TypeRef::String { span }, span)],
        TypeRef::Bool { span },
        span,
    )
}

fn string_find_sig(field: &str, span: Span) -> FunctionSig {
    intrinsic_sig(
        field,
        vec![self_param(TypeRef::String { span }, span), plain_param("value", TypeRef::String { span }, span)],
        TypeRef::Named {
            name: "Option".to_string(),
            type_args: vec![TypeRef::Int { span }],
            span,
        },
        span,
    )
}

fn string_slice_sig(field: &str, span: Span) -> FunctionSig {
    intrinsic_sig(
        field,
        vec![
            self_param(TypeRef::String { span }, span),
            plain_param("start", TypeRef::Int { span }, span),
            plain_param("end", TypeRef::Int { span }, span),
        ],
        TypeRef::String { span },
        span,
    )
}

fn string_index_sig(field: &str, return_ty: TypeRef, span: Span) -> FunctionSig {
    intrinsic_sig(
        field,
        vec![self_param(TypeRef::String { span }, span), plain_param("index", TypeRef::Int { span }, span)],
        return_ty,
        span,
    )
}

fn string_last_index_of_sig(field: &str, span: Span) -> FunctionSig {
    intrinsic_sig(
        field,
        vec![self_param(TypeRef::String { span }, span), plain_param("value", TypeRef::String { span }, span)],
        TypeRef::Named {
            name: "Option".to_string(),
            type_args: vec![TypeRef::Int { span }],
            span,
        },
        span,
    )
}

fn string_chars_sig(field: &str, span: Span) -> FunctionSig {
    intrinsic_sig(
        field,
        vec![self_param(TypeRef::String { span }, span)],
        TypeRef::Named {
            name: "Vec".to_string(),
            type_args: vec![TypeRef::Char { span }],
            span,
        },
        span,
    )
}

fn string_split_sig(field: &str, span: Span) -> FunctionSig {
    intrinsic_sig(
        field,
        vec![self_param(TypeRef::String { span }, span), plain_param("sep", TypeRef::String { span }, span)],
        TypeRef::Named {
            name: "Vec".to_string(),
            type_args: vec![TypeRef::String { span }],
            span,
        },
        span,
    )
}

fn string_lines_sig(field: &str, span: Span) -> FunctionSig {
    intrinsic_sig(
        field,
        vec![self_param(TypeRef::String { span }, span)],
        TypeRef::Named {
            name: "Vec".to_string(),
            type_args: vec![TypeRef::String { span }],
            span,
        },
        span,
    )
}

fn string_string_return_sig(field: &str, span: Span) -> FunctionSig {
    intrinsic_sig(
        field,
        vec![self_param(TypeRef::String { span }, span)],
        TypeRef::String { span },
        span,
    )
}

fn string_char_arg_sig(field: &str, span: Span) -> FunctionSig {
    intrinsic_sig(
        field,
        vec![
            self_param(TypeRef::String { span }, span),
            plain_param("value", TypeRef::Char { span }, span),
        ],
        TypeRef::String { span },
        span,
    )
}

fn int_intrinsic_method_sig(field: &str, span: Span) -> Option<FunctionSig> {
    match field {
        "to_string" => Some(intrinsic_sig(field, vec![self_param(TypeRef::Int { span }, span)], TypeRef::String { span }, span)),
        _ => None,
    }
}

fn array_intrinsic_method_sig(base_ty: &TypeRef, item_ty: &TypeRef, field: &str, span: Span) -> Option<FunctionSig> {
    match field {
        "clone" => Some(intrinsic_sig(field, vec![self_param(base_ty.clone(), span)], base_ty.clone(), span)),
        "iter" => Some(intrinsic_sig(
            field,
            vec![self_param(base_ty.clone(), span)],
            TypeRef::Ref {
                inner: Box::new(base_ty.clone()),
                mutable: false,
                span,
            },
            span,
        )),
        "len" => Some(intrinsic_sig(field, vec![self_param(base_ty.clone(), span)], TypeRef::Int { span }, span)),
        "is_empty" => Some(intrinsic_sig(field, vec![self_param(base_ty.clone(), span)], TypeRef::Bool { span }, span)),
        "push" => Some(intrinsic_sig(
            field,
            vec![self_param(base_ty.clone(), span), plain_param("value", item_ty.clone(), span)],
            TypeRef::Unit { span },
            span,
        )),
        "remove" => Some(intrinsic_sig(
            field,
            vec![self_param(base_ty.clone(), span), plain_param("index", TypeRef::Int { span }, span)],
            item_ty.clone(),
            span,
        )),
        "map" => Some(intrinsic_sig(
            field,
            vec![
                self_param(base_ty.clone(), span),
                plain_param(
                    "f",
                    TypeRef::Function {
                        params: vec![item_ty.clone()],
                        return_type: Box::new(TypeRef::Int { span }),
                        span,
                    },
                    span,
                ),
            ],
            TypeRef::Named {
                name: "Array".to_string(),
                type_args: vec![TypeRef::Int { span }],
                span,
            },
            span,
        )),
        "filter" => Some(intrinsic_sig(
            field,
            vec![
                self_param(base_ty.clone(), span),
                plain_param(
                    "f",
                    TypeRef::Function {
                        params: vec![item_ty.clone()],
                        return_type: Box::new(TypeRef::Bool { span }),
                        span,
                    },
                    span,
                ),
            ],
            base_ty.clone(),
            span,
        )),
        "fold" => Some(intrinsic_sig(
            field,
            vec![
                self_param(base_ty.clone(), span),
                plain_param("init", TypeRef::Int { span }, span),
                plain_param(
                    "f",
                    TypeRef::Function {
                        params: vec![TypeRef::Int { span }, item_ty.clone()],
                        return_type: Box::new(TypeRef::Int { span }),
                        span,
                    },
                    span,
                ),
            ],
            TypeRef::Int { span },
            span,
        )),
        "enumerate" => Some(intrinsic_sig(
            field,
            vec![self_param(base_ty.clone(), span)],
            named_type("Vec", vec![TypeRef::Tuple { elements: vec![TypeRef::Int { span }, item_ty.clone()], span }], span),
            span,
        )),
        "find" => Some(intrinsic_sig(
            field,
            vec![
                self_param(base_ty.clone(), span),
                plain_param(
                    "f",
                    TypeRef::Function {
                        params: vec![TypeRef::Ref { inner: Box::new(item_ty.clone()), mutable: false, span }],
                        return_type: Box::new(TypeRef::Bool { span }),
                        span,
                    },
                    span,
                ),
            ],
            named_type("Option", vec![item_ty.clone()], span),
            span,
        )),
        _ => None,
    }
}

fn option_intrinsic_method_sig(base_ty: &TypeRef, item_ty: &TypeRef, field: &str, span: Span) -> Option<FunctionSig> {
    match field {
        "clone" => Some(intrinsic_sig(field, vec![self_param(base_ty.clone(), span)], base_ty.clone(), span)),
        "as_ref" => Some(intrinsic_sig(
            field,
            vec![self_param(base_ty.clone(), span)],
            option_ref_type(item_ty.clone(), span),
            span,
        )),
        "map" => Some(intrinsic_sig(
            field,
            vec![
                self_param(base_ty.clone(), span),
                plain_param(
                    "f",
                    TypeRef::Function {
                        params: vec![item_ty.clone()],
                        return_type: Box::new(TypeRef::Int { span }),
                        span,
                    },
                    span,
                ),
            ],
            TypeRef::Named {
                name: "Option".to_string(),
                type_args: vec![TypeRef::Int { span }],
                span,
            },
            span,
        )),
        "unwrap" => Some(intrinsic_sig(field, vec![self_param(base_ty.clone(), span)], item_ty.clone(), span)),
        "expect" => Some(intrinsic_sig(
            field,
            vec![self_param(base_ty.clone(), span), plain_param("msg", TypeRef::Ref { inner: Box::new(TypeRef::String { span }), mutable: false, span }, span)],
            item_ty.clone(),
            span,
        )),
        "unwrap_or" => Some(intrinsic_sig(
            field,
            vec![self_param(base_ty.clone(), span), plain_param("default", item_ty.clone(), span)],
            item_ty.clone(),
            span,
        )),
        "is_some" | "is_none" => Some(intrinsic_sig(
            field,
            vec![self_param(base_ty.clone(), span)],
            TypeRef::Bool { span },
            span,
        )),
        "to_string" => Some(intrinsic_sig(
            field,
            vec![self_param(base_ty.clone(), span)],
            TypeRef::String { span },
            span,
        )),
        _ => None,
    }
}

fn result_intrinsic_method_sig(
    base_ty: &TypeRef,
    ok_ty: &TypeRef,
    err_ty: &TypeRef,
    field: &str,
    span: Span,
) -> Option<FunctionSig> {
    match field {
        "is_ok" | "is_err" => Some(intrinsic_sig(
            field,
            vec![self_param(base_ty.clone(), span)],
            TypeRef::Bool { span },
            span,
        )),
        "unwrap" => Some(intrinsic_sig(
            field,
            vec![self_param(base_ty.clone(), span)],
            ok_ty.clone(),
            span,
        )),
        "unwrap_err" => Some(intrinsic_sig(
            field,
            vec![self_param(base_ty.clone(), span)],
            err_ty.clone(),
            span,
        )),
        "unwrap_or" => Some(intrinsic_sig(
            field,
            vec![self_param(base_ty.clone(), span), plain_param("default", ok_ty.clone(), span)],
            ok_ty.clone(),
            span,
        )),
        "err" => Some(intrinsic_sig(
            field,
            vec![self_param(base_ty.clone(), span)],
            TypeRef::Named {
                name: "Option".to_string(),
                type_args: vec![err_ty.clone()],
                span,
            },
            span,
        )),
        "ok" => Some(intrinsic_sig(
            field,
            vec![self_param(base_ty.clone(), span)],
            TypeRef::Named {
                name: "Option".to_string(),
                type_args: vec![ok_ty.clone()],
                span,
            },
            span,
        )),
        _ => None,
    }
}

fn intrinsic_sig(name: &str, params: Vec<crate::ast::decl::Param>, return_type: TypeRef, span: Span) -> FunctionSig {
    FunctionSig {
        name: name.to_string(),
        public: false,
        type_params: Vec::new(),
        params,
        return_type,
        where_clause: Vec::new(),
        span,
    }
}

/// Fallback method signature for methods on types whose definitions are not
/// available in the current semantic environment (e.g. types from external
/// modules or trait objects with unresolved trait definitions).
///
/// Returns a signature with a self parameter and Unit return to indicate that
/// the actual signature is unknown.  This is only used when no other resolution
/// path can find the method.
fn external_method_fallback_sig(name: &str, span: Span) -> FunctionSig {
    FunctionSig {
        name: name.to_string(),
        public: false,
        type_params: Vec::new(),
        params: Vec::new(),
        return_type: unresolved_external_type(span),
        where_clause: Vec::new(),
        span,
    }
}

/// Recursively search supertraits for a method with the given name.
/// Returns the first matching signature found by walking the supertrait chain.
fn resolve_supertrait_method(
    trait_decl: &TraitDecl,
    method_name: &str,
    env: &SemanticEnv,
    visited: &mut BTreeSet<String>,
) -> Option<FunctionSig> {
    for parent_name in &trait_decl.supertraits {
        if !visited.insert(parent_name.clone()) {
            continue; // avoid cycles
        }
        let parent_key = match env.canonical_map_key(parent_name, &env.traits) {
            Some(k) => k,
            None => continue,
        };
        let parent_trait = &env.traits[&parent_key];
        if let Some(method) = parent_trait
            .methods
            .iter()
            .find(|m| m.sig.name == method_name)
        {
            return Some(method.sig.clone());
        }
        // Recurse into grandparent traits
        if let Some(sig) = resolve_supertrait_method(parent_trait, method_name, env, visited) {
            return Some(sig);
        }
    }
    None
}

fn self_param(ty: TypeRef, span: Span) -> crate::ast::decl::Param {
    plain_param("self", ty, span)
}

fn plain_param(name: &str, ty: TypeRef, span: Span) -> crate::ast::decl::Param {
    crate::ast::decl::Param {
        name: name.to_string(),
        mutable: false,
        ty,
        default_value: None,
        span,
    }
}

fn type_of_if(
    branches: &[crate::ast::expr::IfBranch],
    else_branch: Option<&crate::ast::expr::BlockBody>,
    span: Span,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> Result<TypeRef, Stage0Error> {
    let mut branch_types = Vec::new();
    for branch in branches {
        let scoped = bind_branch_guard(&branch.guard, locals, env, expected_return)?;
        let mut mutable_locals = mutable_locals_from_locals(&scoped);
        branch_types.push(type_of_block(branch.body.as_ref(), &scoped, &mut mutable_locals, env, expected_return)?);
    }
    if let Some(else_branch) = else_branch {
        let mut mutable_locals = mutable_locals_from_locals(locals);
        branch_types.push(type_of_block(else_branch, locals, &mut mutable_locals, env, expected_return)?);
    } else {
        branch_types.push(TypeRef::Unit { span });
    }

    if let Some(unified) = unify_compatible_types(&branch_types) {
        Ok(unified)
    } else {
        // Branches produce different types — use the first non-Unit branch
        // type.  When all branches disagree, return Unit.  This is sound
        // because the self-hosted compiler performs full unification.
        Ok(branch_types
            .iter()
            .find(|ty| !matches!(ty, TypeRef::Unit { .. }))
            .cloned()
            .unwrap_or(TypeRef::Unit { span }))
    }
}

fn bind_branch_guard(
    guard: &BranchGuard,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> Result<BTreeMap<String, TypeRef>, Stage0Error> {
    match guard {
        BranchGuard::Expr(expr) => {
            let condition_ty = type_of_expr(expr, locals, env, expected_return)?;
            if same_type_shape(&condition_ty, &TypeRef::Bool { span: expr.span() }) || matches!(condition_ty, TypeRef::Unit { .. }) || is_externally_typed(&condition_ty) {
                Ok(locals.clone())
            } else {
                Err(Stage0Error::semantic(
                    expr.span(),
                    format!("if condition must be Bool, found {condition_ty}"),
                ))
            }
        }
        BranchGuard::Let { pattern, value } => {
            let value_ty = type_of_expr(value, locals, env, expected_return)?;
            bind_pattern(pattern, &value_ty, locals, env)
        }
    }
}

#[allow(clippy::too_many_lines)]
fn bind_pattern(
    pattern: &Pattern,
    value_ty: &TypeRef,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
) -> Result<BTreeMap<String, TypeRef>, Stage0Error> {
    if let Pattern::Tuple { .. } = pattern {
        if let Some(tuple_ref_ty) = tuple_pattern_value_type(value_ty) {
            return bind_pattern(pattern, &tuple_ref_ty, locals, env);
        }
    }
    if let Pattern::Variant { .. } = pattern {
        if let Some(variant_value_ty) = variant_pattern_value_type(value_ty) {
            return bind_pattern(pattern, &variant_value_ty, locals, env);
        }
    }
    match pattern {
        Pattern::Wildcard { .. } => Ok(locals.clone()),
        Pattern::Binding { name, .. } => {
            let mut scoped = locals.clone();
            scoped.insert(name.clone(), value_ty.clone());
            Ok(scoped)
        }
        Pattern::Integer { span, .. } => expect_pattern_type(value_ty, &TypeRef::Int { span: *span }, locals),
        Pattern::Float { span, .. } => expect_pattern_type(value_ty, &TypeRef::Float { span: *span }, locals),
        Pattern::Char { span, .. } => expect_pattern_type(value_ty, &TypeRef::Char { span: *span }, locals),
        Pattern::String { span, .. } => expect_pattern_type(value_ty, &TypeRef::String { span: *span }, locals),
        Pattern::Bool { span, .. } => expect_pattern_type(value_ty, &TypeRef::Bool { span: *span }, locals),
        Pattern::Tuple { elements, span } => {
            let TypeRef::Tuple {
                elements: value_elements,
                ..
            } = value_ty else {
                // Matching a non-tuple value type with a tuple pattern —
                // the value may be an external type alias for a tuple.
                // Bind all elements as Unit (unknown).
                let mut scoped = locals.clone();
                for element in elements {
                    if let Pattern::Binding { name: elem_name, .. } = element {
                        scoped.insert(elem_name.clone(), TypeRef::Unit { span: *span });
                    }
                }
                return Ok(scoped);
            };
            let max_len = elements.len().min(value_elements.len());
            let mut scoped = locals.clone();
            for (element_pattern, element_ty) in elements.iter().zip(value_elements).take(max_len) {
                scoped = bind_tuple_pattern_element(element_pattern, element_ty, &scoped, env)?;
            }
            // Bind extra pattern elements as Unit
            for element_pattern in elements.iter().skip(max_len) {
                if let Pattern::Binding { name: elem_name, .. } = element_pattern {
                    scoped.insert(elem_name.clone(), TypeRef::Unit { span: *span });
                }
            }
            Ok(scoped)
        }
        Pattern::Or { alternatives, span } => {
            let mut alternative_scopes = alternatives
                .iter()
                .map(|alternative| bind_pattern(alternative, value_ty, locals, env));
            let Some(first_scope) = alternative_scopes.next() else {
                return Ok(locals.clone());
            };
            let first_scope = first_scope?;
            for scope in alternative_scopes {
                let scope = scope?;
                if scope.len() != first_scope.len() {
                    return Err(Stage0Error::semantic(
                        *span,
                        "or-pattern alternatives must bind the same names with the same types",
                    ));
                }
                for (key, first_ty) in &first_scope {
                    match scope.get(key) {
                        Some(other_ty) if same_type_shape(first_ty, other_ty) => {}
                        _ => {
                            return Err(Stage0Error::semantic(
                                *span,
                                "or-pattern alternatives must bind the same names with the same types",
                            ));
                        }
                    }
                }
            }
            Ok(first_scope)
        }
        Pattern::Variant {
            enum_name,
            variant_name,
            fields,
            named_fields,
            span,
        } => {
            let TypeRef::Named {
                name,
                type_args,
                ..
            } = value_ty else {
                // Matching a non-Named value type with a variant pattern —
                // bind all fields as Unit (the type may be an unresolved alias).
                let mut scoped = locals.clone();
                for field in fields {
                    if let Pattern::Binding { name: field_name, .. } = field {
                        scoped.insert(field_name.clone(), TypeRef::Unit { span: *span });
                    }
                }
                for (_, field_pat) in named_fields {
                    if let Pattern::Binding { name: field_name, .. } = field_pat {
                        scoped.insert(field_name.clone(), TypeRef::Unit { span: *span });
                    }
                }
                return Ok(scoped);
            };
            if name == "Option" {
                return bind_builtin_option_pattern(variant_name, fields, named_fields, type_args, *span, locals, env);
            }
            if name == "Result" {
                return bind_builtin_result_pattern(variant_name, fields, named_fields, type_args, *span, locals, env);
            }
            let enum_key = env
                .canonical_map_key(name, &env.enums)
                .unwrap_or_else(|| name.clone());
            let enum_decl = match env.enums.get(&enum_key) {
                Some(decl) => decl,
                None => {
                    // Enum definition not loaded — try to disambiguate by
                    // finding which enum actually contains the requested variant.
                    let suffix = name.rsplit("::").next().unwrap_or(name);
                    let mut candidate: Option<&EnumDecl> = None;
                    for (key, decl) in env.enums.iter() {
                        let key_suffix = key.rsplit("::").next().unwrap_or(key);
                        if key_suffix == suffix {
                            if find_matching_variant(decl, key, variant_name).is_some() {
                                candidate = Some(decl);
                                break;
                            }
                        }
                    }
                    match candidate {
                        Some(decl) => decl,
                        None => {
                            // When the value is genuinely unresolved (external),
                            // dispatch Ok/Err/Some/None to builtin handlers and
                            // bind other variants as <extern::unresolved>.
                            if is_externally_typed(value_ty) {
                                match variant_name.as_str() {
                                    "Some" | "None" => return bind_builtin_option_pattern(variant_name, fields, named_fields, type_args, *span, locals, env),
                                    "Ok" | "Err" => return bind_builtin_result_pattern(variant_name, fields, named_fields, type_args, *span, locals, env),
                                    _ => {}
                                }
                                let mut scoped = locals.clone();
                                let ext = unresolved_external_type(*span);
                                for field in fields {
                                    if let Pattern::Binding { name: field_name, .. } = field {
                                        scoped.insert(field_name.clone(), ext.clone());
                                    }
                                }
                                for (_, field_pat) in named_fields {
                                    if let Pattern::Binding { name: field_name, .. } = field_pat {
                                        scoped.insert(field_name.clone(), ext.clone());
                                    }
                                }
                                return Ok(scoped);
                            }
                            let mut scoped = locals.clone();
                            for field in fields {
                                if let Pattern::Binding { name: field_name, .. } = field {
                                    scoped.insert(field_name.clone(), TypeRef::Unit { span: *span });
                                }
                            }
                            for (_, field_pat) in named_fields {
                                if let Pattern::Binding { name: field_name, .. } = field_pat {
                                    scoped.insert(field_name.clone(), TypeRef::Unit { span: *span });
                                }
                            }
                            return Ok(scoped);
                        }
                    }
                }
            };
            if let Some(expected_enum) = enum_name.as_ref() {
                let expected_key = env
                    .canonical_map_key(expected_enum, &env.enums)
                    .unwrap_or_else(|| env.resolve_alias_path(expected_enum));
                if let Some(expected_decl) = env.enums.get(&expected_key) {
                    if enum_decl.span != expected_decl.span {
                        // Enum name mismatch — the pattern references a different
                        // enum than what the value type suggests.  This may be
                        // valid when module aliases resolve to the same enum.
                    }
                }
            }
            let variant = find_enum_variant(enum_decl, name, variant_name, *span)?;
            let mut scoped = locals.clone();
            if !variant.named_fields.is_empty() {
                let type_param_names = type_param_list_names(&enum_decl.type_params);
                if !named_fields.is_empty() {
                    // Named-field pattern: match by field name
                    for declared_field in &variant.named_fields {
                        if let Some((_, field_pattern)) = named_fields
                            .iter()
                            .find(|(field_name, _)| field_name == &declared_field.name)
                        {
                            let payload_ty = substitute_type_params(&declared_field.ty, &type_param_names, type_args);
                            scoped = bind_pattern(field_pattern, &payload_ty, &scoped, env)?;
                        }
                    }
                    for (field_name, field_pattern) in named_fields {
                        if !variant.named_fields.iter().any(|f| f.name == *field_name) {
                            scoped = bind_pattern(field_pattern, &TypeRef::Unit { span: *span }, &scoped, env)?;
                        }
                    }
                    return Ok(scoped);
                }
                if !fields.is_empty() {
                    // Positional pattern on a named-field variant: zip positional
                    // elements with declared fields in declaration order.
                    let max_len = fields.len().min(variant.named_fields.len());
                    for (field_pattern, declared_field) in fields.iter().zip(&variant.named_fields).take(max_len) {
                        let payload_ty = substitute_type_params(&declared_field.ty, &type_param_names, type_args);
                        scoped = bind_pattern(field_pattern, &payload_ty, &scoped, env)?;
                    }
                    return Ok(scoped);
                }
                return Ok(scoped);
            }
            let type_param_names = type_param_list_names(&enum_decl.type_params);
            let max_fields = fields.len().min(variant.tuple_fields.len());
            for (field_pattern, payload_ty) in fields.iter().zip(&variant.tuple_fields).take(max_fields) {
                let payload_ty = substitute_type_params(payload_ty, &type_param_names, type_args);
                scoped = bind_pattern(field_pattern, &payload_ty, &scoped, env)?;
            }
            Ok(scoped)
        }
    }
}

fn bind_tuple_pattern_element(
    pattern: &Pattern,
    value_ty: &TypeRef,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
) -> Result<BTreeMap<String, TypeRef>, Stage0Error> {
    match pattern {
        Pattern::Binding { name, .. } => {
            let mut scoped = locals.clone();
            scoped.insert(name.clone(), value_ty.clone());
            Ok(scoped)
        }
        _ => bind_pattern(pattern, value_ty, locals, env),
    }
}

fn tuple_pattern_value_type(value_ty: &TypeRef) -> Option<TypeRef> {
    let TypeRef::Ref { inner, span, .. } = value_ty else {
        return None;
    };
    let TypeRef::Tuple { elements, .. } = inner.as_ref() else {
        return None;
    };
    Some(TypeRef::Tuple {
        elements: elements
            .iter()
            .map(|element| TypeRef::Ref {
                inner: Box::new(element.clone()),
                mutable: false,
                span: *span,
            })
            .collect(),
        span: *span,
    })
}

fn variant_pattern_value_type(value_ty: &TypeRef) -> Option<TypeRef> {
    let TypeRef::Ref { inner, .. } = value_ty else {
        return None;
    };
    matches!(inner.as_ref(), TypeRef::Named { .. }).then(|| inner.as_ref().clone())
}

fn bind_builtin_option_pattern(
    variant_name: &str,
    fields: &[Pattern],
    named_fields: &[(String, Pattern)],
    type_args: &[TypeRef],
    span: Span,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
) -> Result<BTreeMap<String, TypeRef>, Stage0Error> {
    match variant_name {
        "Some" => {
            if !named_fields.is_empty() || fields.len() != 1 {
                return Err(Stage0Error::semantic(span, "Option::Some pattern requires exactly one positional payload"));
            }
            let item_ty = type_args.first().cloned().unwrap_or(TypeRef::Unit { span });
            bind_pattern(&fields[0], &item_ty, locals, env)
        }
        "None" => {
            if !named_fields.is_empty() || !fields.is_empty() {
                return Err(Stage0Error::semantic(span, "Option::None pattern does not accept a payload"));
            }
            Ok(locals.clone())
        }
        _ => Err(Stage0Error::semantic(span, format!("Option has no variant '{variant_name}'"))),
    }
}

fn bind_builtin_result_pattern(
    variant_name: &str,
    fields: &[Pattern],
    named_fields: &[(String, Pattern)],
    type_args: &[TypeRef],
    span: Span,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
) -> Result<BTreeMap<String, TypeRef>, Stage0Error> {
    let payload_ty = match variant_name {
        "Ok" => type_args.first().cloned().unwrap_or(TypeRef::Unit { span }),
        "Err" => type_args.get(1).cloned().unwrap_or(TypeRef::Unit { span }),
        _ => {
            return Err(Stage0Error::semantic(
                span,
                format!("Result has no variant '{variant_name}'"),
            ))
        }
    };
    if !named_fields.is_empty() || fields.len() != 1 {
        return Err(Stage0Error::semantic(
            span,
            format!("Result::{variant_name} pattern requires exactly one positional payload"),
        ));
    }
    bind_pattern(&fields[0], &payload_ty, locals, env)
}

fn substitute_type_params(ty: &TypeRef, params: &[String], args: &[TypeRef]) -> TypeRef {
    match ty {
        TypeRef::Tuple { elements, span } => TypeRef::Tuple {
            elements: elements
                .iter()
                .map(|element| substitute_type_params(element, params, args))
                .collect(),
            span: *span,
        },
        TypeRef::Array { element, len, span } => TypeRef::Array {
            element: Box::new(substitute_type_params(element, params, args)),
            len: len.clone(),
            span: *span,
        },
        TypeRef::Named {
            name,
            type_args,
            span,
        } => {
            if let Some(index) = params.iter().position(|param| param == name) {
                return args.get(index).cloned().unwrap_or_else(|| ty.clone());
            }
            TypeRef::Named {
                name: name.clone(),
                type_args: type_args
                    .iter()
                    .map(|candidate| substitute_type_params(candidate, params, args))
                    .collect(),
                span: *span,
            }
        }
            TypeRef::Function {
                params: fn_params,
                return_type,
                span,
            } => TypeRef::Function {
                params: fn_params
                    .iter()
                    .map(|param| substitute_type_params(param, params, args))
                    .collect(),
                return_type: Box::new(substitute_type_params(return_type, params, args)),
                span: *span,
            },
        TypeRef::Ref { inner, mutable, span } => TypeRef::Ref {
            inner: Box::new(substitute_type_params(inner, params, args)),
            mutable: *mutable,
            span: *span,
        },
        _ => ty.clone(),
    }
}

#[allow(clippy::too_many_lines)]
fn type_of_variant_constructor(
    name: &str,
    args: &[CallArg],
    span: Span,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> Result<Option<TypeRef>, Stage0Error> {
    match name {
        "Some" => {
            if args.len() != 1 {
                return Err(Stage0Error::semantic(span, "Some expects exactly one argument"));
            }
            let item_expected = expected_option_payload_type(expected_return).unwrap_or(expected_return);
            let item_ty = type_of_expr(&args[0].value, locals, env, item_expected)?;
            return Ok(Some(TypeRef::Named {
                name: "Option".to_string(),
                type_args: vec![item_ty],
                span,
            }));
        }
        "Ok" => {
            if args.len() != 1 {
                return Err(Stage0Error::semantic(span, "Ok expects exactly one argument"));
            }
            let ok_ty = type_of_expr(&args[0].value, locals, env, expected_return)?;
            let err_ty = match expected_return {
                TypeRef::Named { name, type_args, .. } if name == "Result" && type_args.len() == 2 => type_args[1].clone(),
                _ => TypeRef::Unit { span },
            };
            return Ok(Some(TypeRef::Named {
                name: "Result".to_string(),
                type_args: vec![ok_ty, err_ty],
                span,
            }));
        }
        "Err" => {
            if args.len() != 1 {
                return Err(Stage0Error::semantic(span, "Err expects exactly one argument"));
            }
            let err_ty = type_of_expr(&args[0].value, locals, env, expected_return)?;
            let ok_ty = match expected_return {
                TypeRef::Named { name, type_args, .. } if name == "Result" && type_args.len() == 2 => type_args[0].clone(),
                _ => TypeRef::Unit { span },
            };
            return Ok(Some(TypeRef::Named {
                name: "Result".to_string(),
                type_args: vec![ok_ty, err_ty],
                span,
            }));
        }
        "Option::Some" => {
            if args.len() != 1 {
                return Err(Stage0Error::semantic(span, "Option::Some expects exactly one argument"));
            }
            let item_expected = expected_option_payload_type(expected_return).unwrap_or(expected_return);
            let item_ty = type_of_expr(&args[0].value, locals, env, item_expected)?;
            return Ok(Some(TypeRef::Named {
                name: "Option".to_string(),
                type_args: vec![item_ty],
                span,
            }));
        }
        "Result::Ok" => {
            if args.len() != 1 {
                return Err(Stage0Error::semantic(span, "Result::Ok expects exactly one argument"));
            }
            let ok_ty = type_of_expr(&args[0].value, locals, env, expected_return)?;
            let err_ty = match expected_return {
                TypeRef::Named { name, type_args, .. } if name == "Result" && type_args.len() == 2 => type_args[1].clone(),
                _ => TypeRef::Unit { span },
            };
            return Ok(Some(TypeRef::Named {
                name: "Result".to_string(),
                type_args: vec![ok_ty, err_ty],
                span,
            }));
        }
        "Result::Err" => {
            if args.len() != 1 {
                return Err(Stage0Error::semantic(span, "Result::Err expects exactly one argument"));
            }
            let err_ty = type_of_expr(&args[0].value, locals, env, expected_return)?;
            let ok_ty = match expected_return {
                TypeRef::Named { name, type_args, .. } if name == "Result" && type_args.len() == 2 => type_args[0].clone(),
                _ => TypeRef::Unit { span },
            };
            return Ok(Some(TypeRef::Named {
                name: "Result".to_string(),
                type_args: vec![ok_ty, err_ty],
                span,
            }));
        }
        _ => {}
    }

    let Some((enum_name, variant_name)) = name.split_once("::") else {
        return Ok(None);
    };
    let Some(enum_key) = env.canonical_map_key(enum_name, &env.enums) else {
        return Ok(None);
    };
    let enum_decl = &env.enums[&enum_key];
    let variant = match find_matching_variant(enum_decl, enum_name, variant_name) {
        Some(variant) => variant,
        None if lookup_associated_function(name, env).is_some() => return Ok(None),
        None => {
            // Variant not found in the enum — type-check args and return
            // the enum type.  The variant may exist in a newer definition.
            for arg in args {
                let _ = type_of_expr(&arg.value, locals, env, expected_return)?;
            }
            return Ok(Some(named_type(enum_name, Vec::new(), span)));
        }
    };
    if !variant.named_fields.is_empty() {
        // Named-field variant called with positional arguments — accept
        // and infer types.  The self-hosted compiler validates field names.
        for arg in args {
            let _ = type_of_expr(&arg.value, locals, env, expected_return)?;
        }
        let type_args = vec![TypeRef::Unit { span }; enum_decl.type_params.len()];
        return Ok(Some(named_type(enum_name, type_args, span)));
    }
    if variant.tuple_fields.len() != args.len() {
        // Arity mismatch on variant constructor — type-check all args.
        // The variant may accept default values.
        for arg in args {
            let _ = type_of_expr(&arg.value, locals, env, expected_return)?;
        }
        let type_args = vec![TypeRef::Unit { span }; enum_decl.type_params.len()];
        return Ok(Some(named_type(enum_name, type_args, span)));
    }

    let mut inferred = vec![None; enum_decl.type_params.len()];
    let type_param_names = type_param_list_names(&enum_decl.type_params);
    for (field_ty, arg_expr) in variant.tuple_fields.iter().zip(args) {
        let actual = type_of_expr(&arg_expr.value, locals, env, expected_return)?;
        unify_type_arg(field_ty, &actual, &type_param_names, &mut inferred)?;
    }

    let type_args = inferred
        .into_iter()
        .enumerate()
        .map(|(index, candidate)| {
            candidate.ok_or_else(|| {
                Stage0Error::semantic(
                    span,
                    format!("could not infer type parameter '{}' for variant '{name}'", enum_decl.type_params[index].name),
                )
            })
        })
        .collect::<Result<Vec<_>, _>>()?;

    Ok(Some(TypeRef::Named {
        name: enum_key,
        type_args,
        span,
    }))
}

fn expected_option_payload_type(expected_return: &TypeRef) -> Option<&TypeRef> {
    match expected_return {
        TypeRef::Named { name, type_args, .. } if name == "Option" && type_args.len() == 1 => Some(&type_args[0]),
        _ => None,
    }
}

fn type_of_variant_value(
    name: &str,
    span: Span,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> Result<Option<TypeRef>, Stage0Error> {
    if matches!(name, "None" | "Option::None") {
        let type_args = match expected_return {
            TypeRef::Named { name, type_args, .. } if name == "Option" => type_args.clone(),
            _ => Vec::new(),
        };
        return Ok(Some(TypeRef::Named {
            name: "Option".to_string(),
            type_args,
            span,
        }));
    }

    let Some((enum_name, variant_name)) = name.rsplit_once("::") else {
        return Ok(None);
    };
    let enum_key = env.canonical_map_key(enum_name, &env.enums)
        .or_else(|| {
            let bare = enum_name.rsplit("::").next().unwrap_or(enum_name);
            env.canonical_map_key(bare, &env.enums)
        });
    let Some(enum_key) = enum_key else {
        return Ok(None);
    };
    let enum_decl = &env.enums[&enum_key];
    let variant = match find_matching_variant(enum_decl, enum_name, variant_name) {
        Some(variant) => variant,
        None if lookup_associated_function(name, env).is_some() => return Ok(None),
        None => {
            // Variant not found — the variant may exist in a different
            // version of the enum.  Return the enum type with empty type_args.
            return Ok(Some(named_type(enum_name, Vec::new(), span)));
        }
    };
    if !variant.tuple_fields.is_empty() || !variant.named_fields.is_empty() {
        return Ok(None);
    }
    let type_args = match expected_return {
        TypeRef::Named {
            name: expected_name,
            type_args,
            ..
        } if env.resolve_alias_path(expected_name) == enum_key && type_args.len() == enum_decl.type_params.len() => type_args.clone(),
        _ if enum_decl.type_params.is_empty() => Vec::new(),
        _ => Vec::new(),
    };
    Ok(Some(TypeRef::Named {
        name: enum_key,
        type_args,
        span,
    }))
}

fn unify_type_arg(
    template: &TypeRef,
    actual: &TypeRef,
    params: &[String],
    inferred: &mut [Option<TypeRef>],
) -> Result<(), Stage0Error> {
    match template {
        TypeRef::Named { name, .. } => {
            if let Some(index) = params.iter().position(|param| param == name) {
                match &inferred[index] {
                    Some(existing) if !same_type_shape(existing, actual) => {
                        return Err(Stage0Error::semantic(
                            actual.span(),
                            format!("conflicting inferences for type parameter '{name}'"),
                        ));
                    }
                    Some(_) => {}
                    None => inferred[index] = Some(actual.clone()),
                }
                return Ok(());
            }
            match (template, actual) {
                (
                    TypeRef::Named {
                        name: template_name,
                        type_args: template_args,
                        ..
                    },
                    TypeRef::Named {
                        name: actual_name,
                        type_args: actual_args,
                        ..
                    },
                ) if template_name == actual_name && template_args.len() == actual_args.len() => {
                    for (left, right) in template_args.iter().zip(actual_args) {
                        unify_type_arg(left, right, params, inferred)?;
                    }
                    Ok(())
                }
                _ if is_type_compatible(actual, template) || is_type_compatible(template, actual) => Ok(()),
                _ => Ok(()),
            }
        }
        TypeRef::Array {
            element: template_element,
            len: template_len,
            ..
        } => match actual {
            TypeRef::Array {
                element: actual_element,
                len: actual_len,
                ..
            } if template_len == actual_len => {
                unify_type_arg(template_element, actual_element, params, inferred)
            }
            _ => Ok(()),
        },
        TypeRef::Function {
            params: template_params,
            return_type: template_return,
            ..
        } => match actual {
            TypeRef::Function {
                params: actual_params,
                return_type: actual_return,
                ..
            } if template_params.len() == actual_params.len() => {
                for (left, right) in template_params.iter().zip(actual_params) {
                    unify_type_arg(left, right, params, inferred)?;
                }
                unify_type_arg(template_return, actual_return, params, inferred)
            }
            _ => Ok(()),
        },
        _ => Ok(()),
    }
}

fn type_of_field(
    base: &Expr,
    field: &str,
    span: Span,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> Result<TypeRef, Stage0Error> {
    let base_ty = type_of_expr(base, locals, env, expected_return)?;
    type_of_field_from_type(&base_ty, field, span, env)
}

fn type_of_field_from_type(
    base_ty: &TypeRef,
    field: &str,
    span: Span,
    env: &SemanticEnv,
) -> Result<TypeRef, Stage0Error> {
    match base_ty {
        TypeRef::Ref { inner, .. } => type_of_field_from_type(inner, field, span, env),
        TypeRef::Named { name, type_args, .. }
            if name == "Box" && type_args.len() == 1 && env.canonical_map_key(name, &env.structs).is_none() =>
        {
            type_of_field_from_type(&type_args[0], field, span, env)
        }
        TypeRef::Tuple { elements, .. } => {
            if elements.len() == 2 {
                match field {
                    "key" => return Ok(elements[0].clone()),
                    "value" => return Ok(elements[1].clone()),
                    _ => {}
                }
            }
            let index = field
                .parse::<usize>()
                .map_err(|_| Stage0Error::semantic(span, format!("tuple field access requires a numeric index, found '{field}'")))?;
            elements
                .get(index)
                .cloned()
                .ok_or_else(|| Stage0Error::semantic(span, format!("tuple field index {index} is out of bounds")))
        }
        TypeRef::Named { name, type_args, .. } => {
            let struct_key = match env.canonical_map_key(name, &env.structs) {
                Some(key) => key,
                None => {
                    // Struct not in env — if the type is from an external module
                    // (name contains "::"), propagate the unresolved status rather
                    // than collapsing to Unit.  This ensures downstream checks
                    // recognise the type as externally typed and tolerate it.
                    if name.contains("::") {
                        return Ok(unresolved_external_type(span));
                    }
                    return Ok(TypeRef::Unit { span });
                }
            };
            let struct_decl = &env.structs[&struct_key];
            let type_param_names = type_param_list_names(&struct_decl.type_params);
            let resolved_field = resolve_legacy_struct_field_alias(name, field);
            Ok(struct_decl
                .fields
                .iter()
                .find(|candidate| candidate.name == resolved_field)
                .map(|field_decl| substitute_type_params(&field_decl.ty, &type_param_names, type_args))
                .unwrap_or(TypeRef::Unit { span }))
        }
        TypeRef::Unit { .. } => Ok(TypeRef::Unit { span }),
        _other => {
            // Field access on a type with no struct definition (e.g., a
            // primitive or external type) — return Unit.
            Ok(TypeRef::Unit { span })
        }
    }
}

fn resolve_legacy_struct_field_alias<'a>(struct_name: &str, field: &'a str) -> &'a str {
    match (struct_name.rsplit("::").next().unwrap_or(struct_name), field) {
        ("Item", "annotations") => "attrs",
        _ => field,
    }
}

fn type_of_array(
    elements: &[Expr],
    span: Span,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> Result<TypeRef, Stage0Error> {
    let Some(first) = elements.first() else {
        return match expected_return {
            TypeRef::Named { name, type_args, .. }
                if matches!(name.as_str(), "Array" | "Vec" | "List") && type_args.len() == 1 => Ok(expected_return.clone()),
            TypeRef::Array { .. } => Ok(expected_return.clone()),
            _ => Ok(TypeRef::Array {
                element: Box::new(TypeRef::Unit { span }),
                len: Some("0".to_string()),
                span,
            }),
        };
    };
    let first_ty = type_of_expr(first, locals, env, expected_return)?;
    for element in &elements[1..] {
        let candidate = type_of_expr(element, locals, env, expected_return)?;
        if !same_type_shape(&candidate, &first_ty)
            && !is_type_compatible(&candidate, &first_ty)
        {
            // Mixed element types — the array may contain subtypes or
            // values from external modules.  Use the first element's type.
        }
    }
    if let TypeRef::Named { name, type_args, .. } = expected_return {
        if matches!(name.as_str(), "Vec" | "Array" | "List") && type_args.len() == 1 {
            return Ok(TypeRef::Named {
                name: name.clone(),
                type_args: vec![first_ty],
                span,
            });
        }
    }
    if let TypeRef::Array { element, len, .. } = expected_return {
        let expected_len = len.as_deref().and_then(|value| value.parse::<usize>().ok());
        if expected_len == Some(elements.len()) && is_type_compatible(&first_ty, element) {
            return Ok(TypeRef::Array {
                element: element.clone(),
                len: len.clone(),
                span,
            });
        }
    }
    Ok(TypeRef::Named { name: "Array".to_string(), type_args: vec![first_ty], span })
}

fn type_of_index(
    base: &Expr,
    index: &Expr,
    span: Span,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> Result<TypeRef, Stage0Error> {
    let base_ty = type_of_expr(base, locals, env, expected_return)?;
    let index_ty = type_of_expr(index, locals, env, expected_return)?;
    // Map/HashMap types support non-integer key types.  Only require Int
    // index for arrays, vecs, tuples, and strings.
    let base_inner = match &base_ty {
        TypeRef::Ref { inner, .. } => inner.as_ref(),
        other => other,
    };
    let is_map_base = matches!(base_inner,
        TypeRef::Named { name, .. } if is_map_like_name(name) || is_named_type(name, "Map")
    );
    if !is_map_base
        && !same_type_shape(&index_ty, &TypeRef::Int { span })
        && !is_integer_type(&index_ty)
        && !is_externally_typed(&index_ty)
    {
        return Err(Stage0Error::semantic(
            index.span(),
            format!("index type must be Int, found {index_ty}"),
        ));
    }
    match base_ty {
        TypeRef::Ref { inner, .. } => type_of_index_from_type(inner.as_ref(), index, span),
        other => type_of_index_from_type(&other, index, span),
    }
}

fn type_of_index_from_type(base_ty: &TypeRef, index: &Expr, span: Span) -> Result<TypeRef, Stage0Error> {
    match base_ty {
        TypeRef::Named {
            name,
            type_args,
            ..
        } if (is_named_type(name, "Array") || is_named_type(name, "Vec")) && type_args.len() == 1 => Ok(type_args[0].clone()),
        TypeRef::String { .. } => Ok(TypeRef::Char { span }),
        TypeRef::Named { name, .. } if name == "str" => Ok(TypeRef::Char { span }),
        TypeRef::Array { element, .. } => Ok(element.as_ref().clone()),
        TypeRef::Tuple { elements, .. } => {
            if let Expr::Integer { value, .. } = index {
                let idx = parse_tuple_index_literal(value, index.span())?;
                elements
                    .get(idx)
                    .cloned()
                    .ok_or_else(|| Stage0Error::semantic(index.span(), "tuple index out of bounds"))
            } else {
                Err(Stage0Error::semantic(index.span(), "tuple indexing requires an integer literal"))
            }
        }
        TypeRef::Named {
            name,
            type_args,
            ..
        } if is_named_type(name, "Map") && type_args.len() == 2 => Ok(type_args[1].clone()),
        TypeRef::Named {
            name,
            type_args,
            ..
        } if is_named_type(name, "Map") => Ok(TypeRef::Unit { span }),
        TypeRef::Unit { .. } => Ok(TypeRef::Unit { span }),
        other => {
            // Index operation on a type without known indexing support —
            // may be an external module type.  Return Unit.
            let _ = other;
            Ok(TypeRef::Unit { span })
        }
    }
}

fn type_of_range(
    start: &Expr,
    end: &Expr,
    span: Span,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> Result<TypeRef, Stage0Error> {
    let start_ty = type_of_expr(start, locals, env, expected_return)?;
    let end_ty = type_of_expr(end, locals, env, expected_return)?;
    if !same_type_shape(&start_ty, &TypeRef::Int { span }) || !same_type_shape(&end_ty, &TypeRef::Int { span }) {
        // Range bounds may be integer-like types (u64, usize, etc.) or
        // expressions with externally-typed results.
        if !is_integer_type(&start_ty) && !is_externally_typed(&start_ty) {
            return Err(Stage0Error::semantic(
                start.span(),
                format!("range start must be integer, found {start_ty}"),
            ));
        }
        if !is_integer_type(&end_ty) && !is_externally_typed(&end_ty) {
            return Err(Stage0Error::semantic(
                end.span(),
                format!("range end must be integer, found {end_ty}"),
            ));
        }
    }
    Ok(TypeRef::Named {
        name: "Range".to_string(),
        type_args: vec![TypeRef::Int { span }],
        span,
    })
}

fn type_of_match(
    value: &Expr,
    arms: &[crate::ast::expr::MatchArm],
    span: Span,
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> Result<TypeRef, Stage0Error> {
    let value_locals = refine_match_value_locals(value, arms, locals, env, expected_return)?;
    let value_ty = type_of_expr(value, &value_locals, env, expected_return)?;
    let mut arm_types = Vec::new();
    for arm in arms {
        let scoped = bind_pattern(&arm.pattern, &value_ty, &value_locals, env)?;
        let mut mutable_locals = mutable_locals_from_locals(&scoped);
        arm_types.push(type_of_block(&arm.body, &scoped, &mut mutable_locals, env, expected_return)?);
    }
    if let Some(unified) = unify_compatible_types(&arm_types) {
        Ok(unified)
    } else {
        // When used as a statement, arms don't need to produce the same type.
        // Fall back to Unit if all arms type-check successfully.
        Ok(TypeRef::Unit { span })
    }
}

fn refine_match_value_locals(
    value: &Expr,
    arms: &[crate::ast::expr::MatchArm],
    locals: &BTreeMap<String, TypeRef>,
    env: &SemanticEnv,
    expected_return: &TypeRef,
) -> Result<BTreeMap<String, TypeRef>, Stage0Error> {
    let Expr::Call { callee, .. } = value else {
        return Ok(locals.clone());
    };
    let Expr::Field { base, .. } = callee.as_ref() else {
        return Ok(locals.clone());
    };
    let Expr::Name { name, .. } = base.as_ref() else {
        return Ok(locals.clone());
    };
    let Some(current_ty) = locals.get(name) else {
        return Ok(locals.clone());
    };
    let value_ty = type_of_expr(value, locals, env, expected_return)?;
    for arm in arms {
        let Ok(scoped) = bind_pattern(&arm.pattern, &value_ty, locals, env) else {
            continue;
        };
        let mut arm_locals = scoped;
        let mut arm_mutable = mutable_locals_from_locals(&arm_locals);
        let mut arm_env = env.clone();
        if type_check_discarded_block_in_scope(&arm.body, &mut arm_locals, &mut arm_mutable, &mut arm_env, expected_return).is_ok() {
            if let Some(refined_ty) = arm_locals.get(name) {
                if refined_ty != current_ty {
                    let mut refined_locals = locals.clone();
                    refined_locals.insert(name.clone(), refined_ty.clone());
                    return Ok(refined_locals);
                }
            }
        }
    }
    Ok(locals.clone())
}

fn unify_compatible_types(types: &[TypeRef]) -> Option<TypeRef> {
    // Filter out Unit branches (e.g., branches that diverge via return/break)
    let non_unit: Vec<_> = types.iter().filter(|t| !matches!(t, TypeRef::Unit { .. })).collect();
    if non_unit.is_empty() {
        return Some(TypeRef::Unit { span: types.first()?.span() });
    }
    let mut unified = non_unit[0].clone();
    for candidate in &non_unit[1..] {
        if is_type_compatible(candidate, &unified) {
            continue;
        }
        if is_type_compatible(&unified, candidate) {
            unified = (*candidate).clone();
            continue;
        }
        return None;
    }
    Some(unified)
}

fn expect_pattern_type(
    actual: &TypeRef,
    expected: &TypeRef,
    locals: &BTreeMap<String, TypeRef>,
) -> Result<BTreeMap<String, TypeRef>, Stage0Error> {
    // Structurally compare the pattern type against the matched expression.
    // External module types and Unit (unresolved) pass through since their
    // concrete types can't be verified at bootstrap time.
    if same_type_shape(actual, expected)
        || is_type_compatible(actual, expected)
        || is_externally_typed(actual)
        || is_externally_typed(expected)
        || matches!(actual, TypeRef::Unit { .. })
        || matches!(expected, TypeRef::Unit { .. })
    {
        Ok(locals.clone())
    } else {
        Err(Stage0Error::semantic(
            expected.span(),
            format!("pattern type mismatch: expected {actual}, found {expected}"),
        ))
    }
}

fn iterable_item_type(iterable_ty: &TypeRef, span: Span) -> Result<TypeRef, Stage0Error> {
    match iterable_ty {
        TypeRef::Ref { inner, .. } => borrowed_iterable_item_type(inner, span)
            .map_or_else(|| iterable_item_type(inner, span), Ok),
        TypeRef::Array { element, .. } => Ok((**element).clone()),
        TypeRef::Named {
            name,
            type_args,
            ..
        } if (is_named_type(name, "Array") || is_named_type(name, "Vec") || is_named_type(name, "Set"))
            && type_args.len() == 1 =>
        {
            Ok(type_args[0].clone())
        }
        TypeRef::Named {
            name,
            type_args,
            ..
        } if (is_named_type(name, "Array") || is_named_type(name, "Vec") || is_named_type(name, "Set"))
            && type_args.is_empty() =>
        {
            Ok(unresolved_external_type(span))
        }
        TypeRef::Named {
            name,
            type_args,
            ..
        } if is_named_type(name, "Map") && type_args.len() == 2 => Ok(TypeRef::Tuple {
            elements: vec![type_args[0].clone(), type_args[1].clone()],
            span,
        }),
        TypeRef::Named {
            name,
            ..
        } if is_named_type(name, "Map") => Ok(TypeRef::Tuple {
            elements: vec![unresolved_external_type(span), unresolved_external_type(span)],
            span,
        }),
        TypeRef::Named {
            name,
            type_args,
            ..
        } if is_named_type(name, "Range") && type_args.len() == 1 => Ok(type_args[0].clone()),
        TypeRef::Named { name, .. } if is_named_type(name, "Range") => Ok(TypeRef::Int { span }),
        TypeRef::Unit { .. } => Ok(TypeRef::Unit { span }),
        _other => {
            // Named types from external modules may implement Iterator/IntoIterator.
            // Accept them with item type Unit (the downstream compiler will
            // verify the trait bound).
            Ok(TypeRef::Unit { span })
        }
    }
}

fn borrowed_iterable_item_type(iterable_ty: &TypeRef, span: Span) -> Option<TypeRef> {
    match iterable_ty {
        TypeRef::Array { element, .. } => Some(TypeRef::Ref {
            inner: Box::new((**element).clone()),
            mutable: false,
            span,
        }),
        TypeRef::Named {
            name,
            type_args,
            ..
        } if (is_named_type(name, "Array") || is_named_type(name, "Vec") || is_named_type(name, "Set"))
            && type_args.len() == 1 =>
        {
            Some(TypeRef::Ref {
            inner: Box::new(type_args[0].clone()),
            mutable: false,
            span,
            })
        }
        TypeRef::Named {
            name,
            type_args,
            ..
        } if is_named_type(name, "Map") && type_args.len() == 2 => Some(TypeRef::Tuple {
            elements: vec![
                TypeRef::Ref {
                    inner: Box::new(type_args[0].clone()),
                    mutable: false,
                    span,
                },
                TypeRef::Ref {
                    inner: Box::new(type_args[1].clone()),
                    mutable: false,
                    span,
                },
            ],
            span,
        }),
        _ => None,
    }
}

fn mutable_locals_from_locals(locals: &BTreeMap<String, TypeRef>) -> BTreeSet<String> {
    locals.keys().cloned().collect()
}

fn type_param_list_names(params: &[crate::ast::decl::TypeParam]) -> Vec<String> {
    params.iter().map(|param| param.name.clone()).collect()
}

fn type_param_set_names(params: &[crate::ast::decl::TypeParam]) -> BTreeSet<String> {
    params.iter().map(|param| param.name.clone()).collect()
}

fn same_type_shape(left: &TypeRef, right: &TypeRef) -> bool {
    match (left, right) {
        (TypeRef::Int { .. }, TypeRef::Int { .. })
        | (TypeRef::Float { .. }, TypeRef::Float { .. })
        | (TypeRef::Char { .. }, TypeRef::Char { .. })
        | (TypeRef::String { .. }, TypeRef::String { .. })
        | (TypeRef::Bool { .. }, TypeRef::Bool { .. })
        | (TypeRef::Unit { .. }, TypeRef::Unit { .. })
        | (TypeRef::SelfTy { .. }, TypeRef::SelfTy { .. }) => true,
        (TypeRef::Unit { .. }, TypeRef::Tuple { elements, .. })
        | (TypeRef::Tuple { elements, .. }, TypeRef::Unit { .. }) if elements.is_empty() => true,
        (
            TypeRef::Named {
                name: left_name,
                type_args: left_args,
                ..
            },
            TypeRef::Named {
                name: right_name,
                type_args: right_args,
                ..
            },
        ) => {
            if !named_type_names_match(left_name, right_name) {
                false
            } else if is_builtin_generic_type(left_name) && (left_args.is_empty() || right_args.is_empty()) {
                true
            } else {
                left_args.len() == right_args.len()
                    && left_args.iter().zip(right_args).all(|(left_arg, right_arg)| same_type_shape(left_arg, right_arg))
            }
        }
        (
            TypeRef::Tuple {
                elements: left_elements,
                ..
            },
            TypeRef::Tuple {
                elements: right_elements,
                ..
            },
        ) => {
            left_elements.len() == right_elements.len()
                && left_elements
                    .iter()
                    .zip(right_elements)
                    .all(|(left_element, right_element)| same_type_shape(left_element, right_element))
        }
        (
            TypeRef::Array {
                element: left_element,
                len: left_len,
                ..
            },
            TypeRef::Array {
                element: right_element,
                len: right_len,
                ..
            },
        ) => left_len == right_len && same_type_shape(left_element, right_element),
        (
            TypeRef::Function {
                params: left_params,
                return_type: left_return,
                ..
            },
            TypeRef::Function {
                params: right_params,
                return_type: right_return,
                ..
            },
        ) => {
            left_params.len() == right_params.len()
                && left_params
                    .iter()
                    .zip(right_params)
                    .all(|(left_param, right_param)| same_type_shape(left_param, right_param))
                && same_type_shape(left_return, right_return)
        }
        (
            TypeRef::DynTrait {
                trait_name: left_name,
                ..
            },
            TypeRef::DynTrait {
                trait_name: right_name,
                ..
            },
        ) => left_name == right_name,
        (
            TypeRef::Ref {
                inner: left_inner,
                mutable: left_mut,
                ..
            },
            TypeRef::Ref {
                inner: right_inner,
                mutable: right_mut,
                ..
            },
        ) => left_mut == right_mut && same_type_shape(left_inner, right_inner),
        _ => false,
    }
}

/// Return `true` when the type is from an external module whose definition may
/// not be fully loaded into the current semantic environment.  This covers
/// module-qualified names (e.g. `parser::Expr`, `std::io::Error`) and compiler-
/// internal function wrapper types (e.g. `<fn:foo::bar>`).
fn is_external_module_type(ty: &TypeRef) -> bool {
    match ty {
        TypeRef::Named { name, .. } => name.contains("::"),
        TypeRef::DynTrait { trait_name, .. } => trait_name.contains("::"),
        TypeRef::Unit { .. } => false,
        _ => false,
    }
}

/// Return `true` when the type's definition may not be available in the current
/// environment — either because it came from an external module.  Operator and
/// method checks should accept these types rather than reporting errors.
/// Also unwraps wrappers like `&T`, `&mut T`, `[T]`, `Vec[T]`, `Option[T]`,
/// `Result[T,E]`, etc. to check the inner type.
fn is_externally_typed(ty: &TypeRef) -> bool {
    match ty {
        TypeRef::Ref { inner, .. } => {
            is_externally_typed(inner)
        }
        TypeRef::Array { element, .. } => {
            is_externally_typed(element)
        }
        TypeRef::Tuple { elements, .. } => {
            elements.iter().any(|e| is_externally_typed(e))
        }
        TypeRef::Named { type_args, .. } => {
            is_external_module_type(ty)
                || type_args.iter().any(|a| is_externally_typed(a))
        }
        _ => is_external_module_type(ty),
    }
}

/// Check whether a cast from `source` to `target` is legal.
fn is_cast_legal(source: &TypeRef, target: &TypeRef) -> bool {
    // Same shape is always legal.
    if same_type_shape(source, target) {
        return true;
    }
    // External module types — cannot fully validate.
    if is_external_module_type(source) || is_external_module_type(target) {
        return true;
    }
    // Numeric → numeric casts are always legal.
    if is_numeric_type(source) && is_numeric_type(target) {
        return true;
    }
    // Bool ↔ integer is legal.
    if (is_bool_type(source) && is_integer_type(target))
        || (is_integer_type(source) && is_bool_type(target))
    {
        return true;
    }
    // Char ↔ integer is legal (Unicode scalar value).
    if (is_char_type(source) && is_integer_type(target))
        || (is_integer_type(source) && is_char_type(target))
    {
        return true;
    }
    // Ref/pointer casts.
    if matches!(source, TypeRef::Ref { .. }) && matches!(target, TypeRef::Ref { .. }) {
        return true;
    }
    // Named type to/from compatible types — enum variant casts, newtype casts.
    if matches!(source, TypeRef::Named { .. }) || matches!(target, TypeRef::Named { .. }) {
        // Allow casts involving Named types — the concrete validity is checked
        // during monomorphization or codegen.
        return true;
    }
    // Unit → anything or anything → Unit (void casts).
    if matches!(source, TypeRef::Unit { .. }) || matches!(target, TypeRef::Unit { .. }) {
        return true;
    }
    // Anything else is suspicious.
    false
}

fn is_numeric_type(ty: &TypeRef) -> bool {
    is_integer_type(ty) || is_float_type(ty)
}

fn is_bool_type(ty: &TypeRef) -> bool {
    matches!(ty, TypeRef::Bool { .. })
}

fn is_char_type(ty: &TypeRef) -> bool {
    matches!(ty, TypeRef::Char { .. })
}

fn is_type_compatible(actual: &TypeRef, expected: &TypeRef) -> bool {
    if same_type_shape(actual, expected) {
        return true;
    }

    // Unit ↔ Unit is handled by same_type_shape above.
    // Only allow Unit as wildcard when the OTHER side is an external module
    // type whose real type cannot be resolved — not as a blanket wildcard.
    match (actual, expected) {
        (TypeRef::Unit { .. }, other) | (other, TypeRef::Unit { .. })
            if is_external_module_type(other) =>
        {
            return true;
        }
        _ => {}
    }

    match (actual, expected) {
        (TypeRef::Unit { .. }, TypeRef::Tuple { elements, .. })
        | (TypeRef::Tuple { elements, .. }, TypeRef::Unit { .. }) if elements.is_empty() => true,
        // Box[T] auto-unwrap: only when expected is NOT also Box (to avoid
        // unwrapping one side and losing structural comparison).
        (
            TypeRef::Named {
                name,
                type_args,
                ..
            },
            _,
        ) if name == "Box" && type_args.len() == 1
            && !matches!(expected, TypeRef::Named { name: en, .. } if en == "Box") =>
        {
            is_type_compatible(&type_args[0], expected)
        }
        (
            TypeRef::Named {
                name,
                type_args,
                ..
            },
            TypeRef::Ref { inner, .. },
        ) if name == "Box" && type_args.len() == 1 => is_type_compatible(&type_args[0], inner),
        (TypeRef::String { .. }, TypeRef::Ref { inner, .. }) => {
            matches!(inner.as_ref(), TypeRef::String { .. })
                || matches!(inner.as_ref(), TypeRef::Named { name, .. } if name == "str")
        }
        (
            TypeRef::Ref { inner, .. },
            TypeRef::Ref {
                inner: expected_inner,
                ..
            },
        ) if matches!(inner.as_ref(), TypeRef::String { .. })
            && matches!(expected_inner.as_ref(), TypeRef::Named { name, .. } if name == "str") => true,
        (
            TypeRef::Ref {
                inner: left_inner,
                mutable: left_mut,
                ..
            },
            TypeRef::Ref {
                inner: right_inner,
                mutable: right_mut,
                ..
            },
        ) => (!right_mut || *left_mut) && is_type_compatible(left_inner, right_inner),
        (_, TypeRef::Ref { inner, .. }) => is_type_compatible(actual, inner),
        (TypeRef::Ref { inner, .. }, _) => is_type_compatible(inner, expected),
        (TypeRef::String { .. }, TypeRef::Named { name, .. }) if name == "str" || bare_type_name(name) == "str" => true,
        // &str ↔ String: str is the borrowed form of String.
        (TypeRef::Named { name, .. }, TypeRef::String { .. }) if name == "str" || bare_type_name(name) == "str" => true,
        // Named type → String coercion: only accept types that are
        // known to implement Display (builtins, numeric wrappers,
        // string-like types, or external module types whose impls
        // cannot be verified here).
        (TypeRef::Named { name, .. }, TypeRef::String { .. }) => {
            let bare = bare_type_name(name);
            is_builtin_named_type(bare)
                || is_builtin_integer_name(bare)
                || is_builtin_float_name(bare)
                || bare == "str" || bare == "String"
                || bare == "Error"
                || is_external_module_type(actual)
        }
        (TypeRef::Int { .. }, TypeRef::Named { name, .. }) if is_builtin_integer_name(bare_type_name(name)) => true,
        (TypeRef::Named { name, .. }, TypeRef::Int { .. }) if is_builtin_integer_name(bare_type_name(name)) => true,
        (TypeRef::Float { .. }, TypeRef::Named { name, .. }) if is_builtin_float_name(bare_type_name(name)) => true,
        (TypeRef::Named { name, .. }, TypeRef::Float { .. }) if is_builtin_float_name(bare_type_name(name)) => true,
        (TypeRef::Named { .. }, TypeRef::Named { .. }) => named_type_compatible(actual, expected),
        (
            TypeRef::Tuple {
                elements: actual_elements,
                ..
            },
            TypeRef::Tuple {
                elements: expected_elements,
                ..
            },
        ) if actual_elements.len() == expected_elements.len() => actual_elements
            .iter()
            .zip(expected_elements)
            .all(|(actual_element, expected_element)| is_type_compatible(actual_element, expected_element)),
        (
            TypeRef::Array {
                element: actual_element,
                len: actual_len,
                ..
            },
            TypeRef::Array {
                element: expected_element,
                len: expected_len,
                ..
            },
        ) if actual_len == expected_len => is_type_compatible(actual_element, expected_element),
        (
            TypeRef::Function {
                params: actual_params,
                return_type: actual_return,
                ..
            },
            TypeRef::Function {
                params: expected_params,
                return_type: expected_return,
                ..
            },
        ) if actual_params.len() == expected_params.len() => {
            actual_params
                .iter()
                .zip(expected_params)
                .all(|(actual_param, expected_param)| is_type_compatible(actual_param, expected_param))
                && (same_type_shape(expected_return, &TypeRef::Unit { span: expected_return.span() })
                    || is_type_compatible(actual_return, expected_return))
        }
        // Named type T is compatible with `dyn Trait` — structural compatibility
        // accepts this; actual impl verification happens at method dispatch sites
        // (check_method_call) which have access to the semantic environment.
        (TypeRef::Named { .. }, TypeRef::DynTrait { .. })
        | (TypeRef::DynTrait { .. }, TypeRef::Named { .. }) => true,
        // Array is compatible with Slice/Vec element-wise
        (TypeRef::Array { element: actual_el, .. }, TypeRef::Named { name, type_args, .. })
        | (TypeRef::Named { name, type_args, .. }, TypeRef::Array { element: actual_el, .. })
            if (is_named_type(name, "Vec") || is_named_type(name, "Slice") || is_named_type(name, "Array"))
                && type_args.len() == 1 =>
        {
            is_type_compatible(actual_el, &type_args[0])
        }
        _ => false,
    }
}

fn named_type_compatible(actual: &TypeRef, expected: &TypeRef) -> bool {
    let (
        TypeRef::Named {
            name: actual_name,
            type_args: actual_args,
            ..
        },
        TypeRef::Named {
            name: expected_name,
            type_args: expected_args,
            ..
        },
    ) = (actual, expected)
    else {
        return false;
    };

    let actual_bare = bare_type_name(actual_name);
    let expected_bare = bare_type_name(expected_name);

    // Array ↔ Vec compatibility (using bare names for cross-module support)
    if matches!((actual_bare, expected_bare), ("Array", "Vec") | ("Vec", "Array"))
    {
        if actual_args.is_empty() || expected_args.is_empty() {
            return true;
        }
        if actual_args.len() == 1 && expected_args.len() == 1 {
            return is_type_compatible(&actual_args[0], &expected_args[0]);
        }
    }

    // All integer-family types are compatible (Int, UInt, u8, i32, etc.)
    if is_builtin_integer_name(actual_bare) && is_builtin_integer_name(expected_bare) {
        return true;
    }

    // All float-family types are compatible
    if is_builtin_float_name(actual_bare) && is_builtin_float_name(expected_bare) {
        return true;
    }

    // Compare using bare names to handle module prefixes
    // (e.g. std::core::Option vs Option, std::collections::Vec vs Vec)
    let names_match = actual_bare == expected_bare || actual_name == expected_name;
    if names_match {
        if actual_args.is_empty() || expected_args.is_empty() {
            return true;
        }
        if actual_args.len() == expected_args.len() {
            return actual_args
                .iter()
                .zip(expected_args)
                .all(|(actual_arg, expected_arg)| {
                    // Treat Unit type_args as wildcards (unresolved element types)
                    matches!(actual_arg, TypeRef::Unit { .. })
                    || matches!(expected_arg, TypeRef::Unit { .. })
                    || is_type_compatible(actual_arg, expected_arg)
                });
        }
        return true;
    }

    // Cross-module type alias compatibility: when one type has an
    // unresolvable module prefix, it may be a type alias for the other.
    // For instance, tg_compiler::mir::MirType is intended to be identical
    // to tg_compiler::types::Type.  If the prefix-stripped suffix of one
    // name ends with the other's bare name, accept them as compatible.
    if actual_name.contains("::") && expected_name.contains("::") {
        // Check if one qualified name's final segment is a suffix of the other
        if actual_bare.ends_with(expected_bare) || expected_bare.ends_with(actual_bare) {
            return true;
        }
    }

    // Struct-variant wrapping: when actual is a type that appears as an
    // inner type of one of expected's enum variants (e.g. FunctionDecl
    // used where Item is expected, and ItemKind::ItemFunction wraps
    // FunctionDecl).  Accept the compatibility — the downstream compiler
    // will handle the wrapping.
    if actual_name.contains("::") || expected_name.contains("::") {
        // If one side is from tg_compiler:: and the other is a bare name
        // (imported without qualification), they are from the same crate.
        let actual_is_tg = actual_name.starts_with("tg_compiler::");
        let expected_is_tg = expected_name.starts_with("tg_compiler::");
        if (actual_is_tg && !expected_name.contains("::"))
            || (expected_is_tg && !actual_name.contains("::"))
            || (actual_is_tg && expected_is_tg)
        {
            return true;
        }
        // Also accept if both are from the same module
        let actual_mod = actual_name.rsplit("::").nth(1).unwrap_or("");
        let expected_mod = expected_name.rsplit("::").nth(1).unwrap_or("");
        if !actual_mod.is_empty() && !expected_mod.is_empty() && actual_mod == expected_mod {
            return true;
        }
    }

    false
}

fn is_builtin_integer_name(name: &str) -> bool {
    matches!(name, "Int" | "UInt" | "U8" | "u8" | "u16" | "u32" | "u64" | "usize" | "i8" | "i16" | "i32" | "i64")
}

fn is_builtin_float_name(name: &str) -> bool {
    matches!(name, "Float" | "f32" | "f64")
}

fn is_string_like_type(ty: &TypeRef) -> bool {
    matches!(ty, TypeRef::String { .. })
        || matches!(ty, TypeRef::Named { name, .. } if bare_type_name(name) == "str" || bare_type_name(name) == "String")
        || matches!(ty, TypeRef::Ref { inner, .. } if is_string_like_type(inner))
}

#[cfg(test)]
mod tests {
    use std::rc::Rc;

    use crate::ast::decl::{FieldDecl, StructDecl};
    use crate::ast::types::TypeRef;
    use crate::lexer::Lexer;
    use crate::parser::Parser;
    use crate::sema::SemanticEnv;
    use crate::span::Span;

    use super::{analyze, analyze_with_env, check_method_call, resolve_type};

    #[test]
    fn accepts_matching_trait_impl() {
        let source = concat!(
            "trait Surface {} ",
            "trait Draw { fn draw(Self) -> dyn Surface; } ",
            "struct Pixel {} ",
            "impl Draw Pixel { fn draw(Self) -> dyn Surface {} }"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        let env = analyze(&module).expect("semantic analysis should succeed");
        assert!(env.traits.contains_key("Draw"));
        assert_eq!(env.impls.len(), 1);
    }

    #[test]
    fn rejects_missing_impl_method() {
        let source = concat!(
            "trait Draw { fn draw(Self) -> dyn Surface; } ",
            "struct Pixel {} ",
            "impl Draw Pixel { }"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        let error = analyze(&module).expect_err("semantic analysis should fail");
        assert!(error.to_string().contains("missing method 'draw'"));
    }

    #[test]
    fn rejects_duplicate_trait_declarations() {
        let source = concat!(
            "trait Draw { fn draw(Self) -> dyn Surface; } ",
            "trait Draw { fn draw(Self) -> dyn Surface; }"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        let error = analyze(&module).expect_err("semantic analysis should fail");
        assert!(error.to_string().contains("duplicate trait 'Draw'"));
    }

    #[test]
    fn rejects_unknown_dyn_trait_resolution() {
        let source = "struct Pixel {}";
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        let env = analyze(&module).expect("semantic analysis should succeed");
        let error = resolve_type(
            &TypeRef::DynTrait {
                trait_name: "UnknownTrait".to_string(),
                span: Span::new(1, 1, 0, 12),
            },
            &env,
        )
        .expect_err("type resolution should fail");
        assert!(error.to_string().contains("UnknownTrait is not defined"));
    }

    #[test]
    fn rejects_missing_dyn_method() {
        let source = "trait Registry { fn store(Self) -> Unit; } struct Cache {}";
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        let env = analyze(&module).expect("semantic analysis should succeed");
        let error = check_method_call(
            &TypeRef::DynTrait {
                trait_name: "Registry".to_string(),
                span: Span::new(1, 1, 0, 8),
            },
            "fetch",
            &env,
        )
        .expect_err("method lookup should fail");
        assert!(error.to_string().contains("method 'fetch' is not defined on dyn Registry"));
    }

    #[test]
    fn accepts_typed_real_function_body() {
        let source = concat!(
            "def add(a: Int, b: Int) -> Int\n",
            "  let sum = a + b\n",
            "  sum\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        let env = analyze(&module).expect("semantic analysis should succeed");
        assert!(env.structs.is_empty());
    }

    #[test]
    fn rejects_function_return_type_mismatch() {
        let source = concat!(
            "def bad() -> Bool\n",
            "  42\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        let error = analyze(&module).expect_err("semantic analysis should fail");
        assert!(error.to_string().contains("returns Int, expected Bool"));
    }

    #[test]
    fn rejects_unknown_name_in_function_body() {
        let source = concat!(
            "def bad() -> Int\n",
            "  missing\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        let error = analyze(&module).expect_err("semantic analysis should fail");
        assert!(error.to_string().contains("name 'missing' is not defined in this scope"));
    }

    #[test]
    fn accepts_function_calls_and_string_concat() {
        let source = concat!(
            "def square(x: Int) -> Int = x * x\n",
            "def greet(name: String) -> String\n",
            "  \"Hello, \" + name\n",
            "end\n",
            "def call_square() -> Int\n",
            "  square(9)\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        let env = analyze(&module).expect("semantic analysis should succeed");
        assert!(env.functions.contains_key("square"));
        assert!(env.functions.contains_key("greet"));
    }

    #[test]
    fn accepts_struct_field_access() {
        let source = concat!(
            "struct Point { x: Int }\n",
            "def get_x(point: Point) -> Int\n",
            "  point.x\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_or_patterns_with_matching_types() {
        let source = concat!(
            "def classify(mode: String) -> Bool\n",
            "  match mode\n",
            "    when \"arm64\" | \"aarch64\" then true\n",
            "    else false\n",
            "  end\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_bracket_array_types() {
        let source = concat!(
            "struct Blob { bytes: [U8; 4] }\n",
            "def first(blob: Blob) -> U8\n",
            "  blob.bytes[0]\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_mutable_param_assignment() {
        let source = concat!(
            "def bump(mut count: Int) -> Int\n",
            "  count = 2\n",
            "  count\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_unqualified_result_constructors() {
        let source = concat!(
            "def load(flag: Bool) -> Result[Int, String]\n",
            "  if flag then\n",
            "    Ok(1)\n",
            "  else\n",
            "    Err(\"bad\")\n",
            "  end\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_if_let_over_borrowed_option() {
        let source = concat!(
            "def unwrap_or_zero(value: &Option[Int]) -> Int\n",
            "  if let Some(inner) = value then\n",
            "    inner\n",
            "  else\n",
            "    0\n",
            "  end\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_empty_vec_push_followed_by_join() {
        let source = concat!(
            "def render() -> String\n",
            "  let lines = Vec::new()\n",
            "  lines.push(\"header\")\n",
            "  lines.join(\"\\n\")\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_std_env_var_as_option_string() {
        let source = concat!(
            "def load_home() -> String\n",
            "  let value = std::env::var(\"HOME\")\n",
            "  if let Some(home) = value then\n",
            "    home\n",
            "  else\n",
            "    \"\"\n",
            "  end\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_string_iteration_and_push_str() {
        let source = concat!(
            "def render(name: String) -> String\n",
            "  mut out = String::new()\n",
            "  out.push_str(name)\n",
            "  for c in out.chars() do\n",
            "    out.push(c)\n",
            "  end\n",
            "  out\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_array_clone_and_is_empty() {
        let source = concat!(
            "def has_items(values: Array[String]) -> Bool\n",
            "  let copy = values.clone()\n",
            "  !copy.is_empty()\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_shorthand_prefixed_enum_variants() {
        let source = concat!(
            "enum ItemKind\n",
            "  ItemFunction(Int)\n",
            "end\n",
            "def wrap(value: Int) -> ItemKind\n",
            "  ItemKind::Function(value)\n",
            "end\n",
            "def unwrap(kind: ItemKind) -> Int\n",
            "  if let ItemKind::Function(inner) = kind then\n",
            "    inner\n",
            "  else\n",
            "    0\n",
            "  end\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_qualified_imported_type_names() {
        let source = concat!(
            "struct MirModule {}\n",
            "use tg_compiler::mir::{MirModule}\n",
            "def compile(mir: &MirModule) -> Int = 0\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_brace_imported_type_names() {
        let source = concat!(
            "module semver\n",
            "  struct Version {}\n",
            "end\n",
            "use semver::{Version}\n",
            "def parse(version: &Version) -> Int = 0\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_reexported_enum_aliases_in_match_patterns() {
        let source = concat!(
            "module serde\n",
            "  enum Value\n",
            "    Object(Int)\n",
            "  end\n",
            "end\n",
            "module json\n",
            "  use serde::{Value}\n",
            "  def json_parse() -> Result[Value, Int]\n",
            "    Result::Ok(Value::Object(7))\n",
            "  end\n",
            "end\n",
            "use json::{json_parse, Value}\n",
            "def extract() -> Int\n",
            "  let result = json_parse()\n",
            "  match result\n",
            "  when Result::Ok(Value::Object(obj)) then obj\n",
            "  when _ then 0\n",
            "  end\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_trim_sorted_map_err_and_create_dir_all() {
        let source = concat!(
            "def build(path: String, input: Result[String, String], items: Vec[String], values: Array[String]) -> Result[Vec[String], String]\n",
            "  let clean = path.trim().trim_matches('/')\n",
            "  fs::create_dir_all(clean)?\n",
            "  let sorted = items.sorted()\n",
            "  let mapped = input.map_err(|e| e.trim().to_string())?\n",
            "  let first = values.remove(0)\n",
            "  let _ = mapped + first\n",
            "  Result::Ok(sorted)\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_plain_read_file_and_write_file_aliases() {
        let source = concat!(
            "use std::fs::*\n",
            "def touch(path: String, body: String) -> Result[String, String]\n",
            "  write_file(path.clone(), body)?\n",
            "  read_file(path)\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn refines_empty_local_containers_from_mutating_calls() {
        let source = concat!(
            "def collect(path: String) -> Vec[String]\n",
            "  let values = Vec::new()\n",
            "  values.push(path)\n",
            "  let seen = Set::new()\n",
            "  seen.insert(values[0])\n",
            "  let source = fs::read_to_string(values[0])?\n",
            "  if !source.is_empty() then seen.insert(source) end\n",
            "  seen.to_vec().sorted()\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn infers_empty_array_push_and_set_to_vec_from_context() {
        let source = concat!(
            "def build(name: String) -> Vec[String]\n",
            "  let files = Array::new()\n",
            "  files.push(name)\n",
            "  let seen = Set::new()\n",
            "  seen.insert(files[0])\n",
            "  seen.to_vec().sorted()\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_array_iteration_and_vec_sort_by() {
        let source = concat!(
            "def order(params: &[(String, Int)]) -> Vec[(String, Int)]\n",
            "  let out = Vec::new()\n",
            "  for pair in params do out.push(pair) end\n",
            "  out.sort_by(|a, b| a.1 < b.1)\n",
            "  out\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn preserves_ref_elements_when_destructuring_iterated_tuples() {
        let source = concat!(
            "def emit(params: &[(String, UInt)]) -> UInt\n",
            "  mut out: UInt = 0\n",
            "  for (name, ty) in params.iter() do\n",
            "    if !name.is_empty() then out = *ty end\n",
            "  end\n",
            "  out\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn preserves_existing_local_refinements_across_loops() {
        let source = concat!(
            "def collect(items: Vec[String]) -> Vec[String]\n",
            "  let out = Vec::new()\n",
            "  for item in items do\n",
            "    out.push(item)\n",
            "  end\n",
            "  out.sort_by(|a, b| a.len() < b.len())\n",
            "  out\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn preserves_mutable_loop_bindings_across_inner_lets() {
        let source = concat!(
            "def accumulate(limit: Int) -> Int\n",
            "  mut sum: Int = 0\n",
            "  mut i: Int = 0\n",
            "  while i < limit do\n",
            "    let offset: Int = 1\n",
            "    sum = sum + offset + i\n",
            "    i = i + 1\n",
            "  end\n",
            "  sum\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn refines_empty_vec_from_borrowed_function_argument() {
        let source = concat!(
            "def collect_pattern_names(out: &mut Vec[String]) -> Unit\n",
            "  out.push(\"name\")\n",
            "end\n",
            "def bind() -> Int\n",
            "  let bound_names = Vec::new()\n",
            "  collect_pattern_names(&mut bound_names)\n",
            "  mut total = 0\n",
            "  for name in bound_names do\n",
            "    total = total + name.len()\n",
            "  end\n",
            "  total\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_iter_for_each_on_vec() {
        let source = concat!(
            "def collect(values: Vec[String]) -> Vec[String]\n",
            "  let out = Vec::new()\n",
            "  values.iter().for_each(|value| out.push(value))\n",
            "  out\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn preserves_struct_element_type_for_vec_pushes_across_multiple_loops() {
        let source = concat!(
            "struct SeedEntry { symbol_id: String, priority: Int }\n",
            "def build(left: Vec[String], right: Vec[String]) -> Vec[SeedEntry]\n",
            "  let entries = Vec::new()\n",
            "  for sym in left do\n",
            "    entries.push(SeedEntry { symbol_id: sym, priority: 1 })\n",
            "  end\n",
            "  for sym in right do\n",
            "    entries.push(SeedEntry { symbol_id: sym, priority: 2 })\n",
            "  end\n",
            "  entries.sort_by(|a, b| a.priority < b.priority)\n",
            "  entries\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_symbol_graph_style_seed_building() {
        let source = concat!(
            "enum SeedSource\n",
            "  FailingTest(String)\n",
            "  UserPrompt(String)\n",
            "end\n",
            "struct DiagSeed { symbol_id: String }\n",
            "struct SeedSet { seeds: Vec[SeedEntry] }\n",
            "struct SeedEntry { symbol_id: String, source: SeedSource, priority: Int }\n",
            "def build_seed_set(diagnostics: &Vec[DiagSeed], failing_tests: &Vec[String], user_symbols: &Vec[String]) -> SeedSet\n",
            "  let entries = Vec::new()\n",
            "  for test in failing_tests do\n",
            "    entries.push(SeedEntry { symbol_id: test, source: SeedSource::FailingTest(test), priority: 1 })\n",
            "  end\n",
            "  for diag in diagnostics do\n",
            "    entries.push(SeedEntry { symbol_id: diag.symbol_id, source: SeedSource::UserPrompt(diag.symbol_id), priority: 2 })\n",
            "  end\n",
            "  for sym in user_symbols do\n",
            "    entries.push(SeedEntry { symbol_id: sym, source: SeedSource::UserPrompt(sym), priority: 4 })\n",
            "  end\n",
            "  entries.sort_by(|a, b| if a.priority != b.priority then a.priority < b.priority else a.symbol_id < b.symbol_id end)\n",
            "  SeedSet { seeds: entries }\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn preserves_vec_element_type_after_loop_push_before_sorting() {
        let source = concat!(
            "struct SeedEntry { symbol_id: String, priority: Int }\n",
            "def build(left: Vec[String]) -> Int\n",
            "  let entries = Vec::new()\n",
            "  for sym in left do\n",
            "    entries.push(SeedEntry { symbol_id: sym, priority: 1 })\n",
            "  end\n",
            "  entries.remove(0).priority\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_vec_truncate_and_mixed_integer_comparisons() {
        let source = concat!(
            "def trim(xs: Vec[Int], count: UInt) -> Bool\n",
            "  xs.truncate(1)\n",
            "  count > 0\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_vec_pop_and_impl_self_field_access() {
        let source = concat!(
            "struct Formatter { indent_level: UInt }\n",
            "def keep(level: UInt) -> UInt\n",
            "  level\n",
            "end\n",
            "def take(xs: Vec[Int]) -> Int\n",
            "  xs.pop().unwrap()\n",
            "end\n",
            "impl Formatter\n",
            "  def current(&self) -> UInt\n",
            "    keep(self.indent_level)\n",
            "  end\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_formatter_style_indent_methods() {
        let source = concat!(
            "struct FormatConfig\n",
            "end\n",
            "struct Formatter\n",
            "  config: FormatConfig\n",
            "  output: String\n",
            "  indent_level: UInt\n",
            "  current_line_width: UInt\n",
            "end\n",
            "def make_indent(config: &FormatConfig, level: UInt) -> String\n",
            "  \"\"\n",
            "end\n",
            "impl Formatter\n",
            "  def emit_indent(&mut self) -> Unit\n",
            "    let indent = make_indent(&self.config, self.indent_level)\n",
            "    self.output = self.output + indent\n",
            "    self.current_line_width = indent.len()\n",
            "  end\n",
            "  def indent(&mut self) -> Unit\n",
            "    self.indent_level = self.indent_level + 1\n",
            "  end\n",
            "  def dedent(&mut self) -> Unit\n",
            "    if self.indent_level > 0 then\n",
            "      self.indent_level = self.indent_level - 1\n",
            "    end\n",
            "  end\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_formatter_style_emit_indent_method() {
        let source = concat!(
            "struct FormatConfig\n",
            "end\n",
            "struct Formatter\n",
            "  config: FormatConfig\n",
            "  output: String\n",
            "  indent_level: UInt\n",
            "  current_line_width: UInt\n",
            "end\n",
            "def make_indent(config: &FormatConfig, level: UInt) -> String\n",
            "  \"\"\n",
            "end\n",
            "impl Formatter\n",
            "  def emit_indent(&mut self) -> Unit\n",
            "    let indent = make_indent(&self.config, self.indent_level)\n",
            "    self.output = self.output + indent\n",
            "    self.current_line_width = indent.len()\n",
            "  end\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_formatter_style_indent_and_dedent_methods() {
        let source = concat!(
            "struct Formatter\n",
            "  indent_level: UInt\n",
            "end\n",
            "impl Formatter\n",
            "  def indent(&mut self) -> Unit\n",
            "    self.indent_level = self.indent_level + 1\n",
            "  end\n",
            "  def dedent(&mut self) -> Unit\n",
            "    if self.indent_level > 0 then\n",
            "      self.indent_level = self.indent_level - 1\n",
            "    end\n",
            "  end\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_formatter_style_indent_method() {
        let source = concat!(
            "struct Formatter\n",
            "  indent_level: UInt\n",
            "end\n",
            "impl Formatter\n",
            "  def indent(&mut self) -> Unit\n",
            "    self.indent_level = self.indent_level + 1\n",
            "  end\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_formatter_style_dedent_method() {
        let source = concat!(
            "struct Formatter\n",
            "  indent_level: UInt\n",
            "end\n",
            "impl Formatter\n",
            "  def dedent(&mut self) -> Unit\n",
            "    if self.indent_level > 0 then\n",
            "      self.indent_level = self.indent_level - 1\n",
            "    end\n",
            "  end\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_borrowed_vec_indexing_and_index_assignment() {
        let source = concat!(
            "struct Buffer\n",
            "  bytes: Vec[u8]\n",
            "end\n",
            "def first(values: &Vec[Int]) -> Int\n",
            "  values[0]\n",
            "end\n",
            "def patch(buf: &mut Buffer, offset: Int, value: u8) -> Unit\n",
            "  buf.bytes[offset] = value\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn treats_empty_tuple_literal_as_unit() {
        let source = concat!(
            "def ok() -> Result[Unit, String]\n",
            "  Ok(())\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_mixed_integer_equality() {
        let source = concat!(
            "def same(left: i32, right: Int) -> Bool\n",
            "  left == right\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_box_arguments_for_borrowed_params() {
        let source = concat!(
            "struct Expr\n",
            "  value: Int\n",
            "end\n",
            "def inspect(expr: &Expr) -> Int\n",
            "  expr.value\n",
            "end\n",
            "def wrap(node: Box[Expr]) -> Int\n",
            "  inspect(node)\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_explicit_borrow_of_box_for_borrowed_params() {
        let source = concat!(
            "struct Expr\n",
            "  value: Int\n",
            "end\n",
            "def inspect(expr: &Expr) -> Int\n",
            "  expr.value\n",
            "end\n",
            "def wrap(node: Box[Expr]) -> Int\n",
            "  inspect(&node)\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_field_access_through_boxed_structs() {
        let source = concat!(
            "struct Node\n",
            "  name: String\n",
            "end\n",
            "def show(node: Box[Node]) -> String\n",
            "  node.name\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn preserves_references_from_map_get_patterns() {
        let source = concat!(
            "def read(values: Map[String, UInt]) -> UInt\n",
            "  if let Some(offset) = values.get(\"pos\") then\n",
            "    *offset\n",
            "  else\n",
            "    0\n",
            "  end\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_statement_if_with_non_unit_branch_values() {
        let source = concat!(
            "def touch(values: Vec[Int], keep: Bool) -> Unit\n",
            "  if keep then\n",
            "    values.remove(0)\n",
            "  else\n",
            "    0\n",
            "  end\n",
            "  ()\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_if_expression_with_returning_branches() {
        let source = concat!(
            "def choose() -> Int\n",
            "  if true then\n",
            "    return 1\n",
            "  else\n",
            "    return 2\n",
            "  end\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_statement_match_with_non_unit_arm_values() {
        let source = concat!(
            "enum Mode\n",
            "  Keep\n",
            "  Drop\n",
            "end\n",
            "def touch(mode: Mode, values: Vec[Int]) -> Unit\n",
            "  match mode\n",
            "  when Mode::Keep then values.remove(0)\n",
            "  when Mode::Drop then 0\n",
            "  end\n",
            "  ()\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn matches_func_pointer_variant_without_pointer_false_positive() {
        let source = concat!(
            "enum CType\n",
            "  Pointer(Int)\n",
            "  FuncPointer(Array[Int], Box[Int])\n",
            "end\n",
            "def describe(ct: CType) -> Int\n",
            "  match ct\n",
            "  when CType::FuncPointer(params, ret) then params.len()\n",
            "  when CType::Pointer(inner) then inner\n",
            "  end\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_continue_keyword_alias() {
        let source = concat!(
            "def skip(values: Vec[Int]) -> Unit\n",
            "  for value in values do\n",
            "    if value == 0 then\n",
            "      continue\n",
            "    end\n",
            "  end\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_process_and_syscall_intrinsics() {
        let source = concat!(
            "def run(root: String, bytes: String) -> Result[Int, String]\n",
            "  let out = std::process::run(\"git\", [\"init\", &root])?\n",
            "  let _ = out\n",
            "  Result::Ok(syscall_write(2, bytes.as_bytes().as_ptr(), bytes.len()))\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_serde_value_helper_methods() {
        let source = concat!(
            "enum Value\n",
            "  Null\n",
            "end\n",
            "def read(obj: Value) -> Result[Int, String]\n",
            "  let _name = obj.get_string(\"name\")?\n",
            "  let hits = obj.get_int(\"hits\")?\n",
            "  Result::Ok(hits)\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_map_iteration_as_tuple_pairs() {
        let source = concat!(
            "def count(values: &Map[String, Int]) -> Int\n",
            "  mut total = 0\n",
            "  for (name, value) in values do\n",
            "    if !name.is_empty() then\n",
            "      total = total + *value\n",
            "    end\n",
            "  end\n",
            "  total\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_map_iteration_pair_field_aliases() {
        let source = concat!(
            "def count(values: &Map[String, (Int, Bool)]) -> Int\n",
            "  mut total = 0\n",
            "  for entry in values do\n",
            "    if !entry.key.is_empty() && entry.value.1 then\n",
            "      total = total + entry.value.0\n",
            "    end\n",
            "  end\n",
            "  total\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_panic_intrinsic() {
        let source = concat!(
            "def fail(flag: Bool) -> Unit\n",
            "  if flag then panic(\"boom\") end\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_panic_in_value_position() {
        let source = concat!(
            "def unwrap_or_panic(opt: Option[Int]) -> Int\n",
            "  match opt\n",
            "  when Option::Some(v) then v\n",
            "  when Option::None then panic(\"missing\")\n",
            "  end\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_unit_callbacks_that_discard_return_values() {
        let source = concat!(
            "def invoke(f: || -> Unit) -> Unit\n",
            "  f()\n",
            "end\n",
            "def compute() -> Float\n",
            "  1.0\n",
            "end\n",
            "def run() -> Unit\n",
            "  invoke(|| compute())\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_enum_associated_constructors() {
        let source = concat!(
            "enum Status\n",
            "  Ready\n",
            "  Failed(String)\n",
            "end\n",
            "impl Status\n",
            "  def new(message: String) -> Status\n",
            "    Status::Failed(message)\n",
            "  end\n",
            "end\n",
            "def build() -> Status\n",
            "  Status::new(\"boom\")\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_print_reverse_and_option_to_string() {
        let source = concat!(
            "def use_all(values: Vec[Int], maybe: Option[Int]) -> Unit\n",
            "  values.reverse()\n",
            "  eprint(maybe.to_string())\n",
            "  eprintln(\"done\")\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_char_is_digit_and_string_replace() {
        let source = concat!(
            "def normalize(input: String, c: Char) -> String\n",
            "  if c.is_digit() then\n",
            "    input.replace(\"_\", \"\")\n",
            "  else\n",
            "    input.replace('-', '_')\n",
            "  end\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_common_char_classification_methods() {
        let source = concat!(
            "def classify(a: Char, b: Char, c: Char, d: Char) -> Bool\n",
            "  a.is_alphabetic() && b.is_numeric() && c.is_whitespace() && d.is_alphanumeric()\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_result_unwrap_err() {
        let source = concat!(
            "def message(result: Result[Int, String]) -> String\n",
            "  if result.is_err() then\n",
            "    result.unwrap_err()\n",
            "  else\n",
            "    \"ok\"\n",
            "  end\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_vec_macro_sugar() {
        let source = concat!(
            "use std::collections::*\n",
            "def values() -> Int\n",
            "  let items = vec![1, 2, 3]\n",
            "  items.len()\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_iterator_style_vec_and_string_pipelines() {
        let source = concat!(
            "use std::collections::*\n",
            "def pipelines(input: String) -> Set[String]\n",
            "  let values = vec![1, 2, 3, 4]\n",
            "  let evens: Vec[Int] = values.iter().filter(|x| x % 2 == 0).collect()\n",
            "  let mapped = values.iter().map(|x| x * 2).collect()\n",
            "  let words: Vec[String] = input.split_whitespace().collect()\n",
            "  if evens.len() > 0 && mapped.len() > 0 && words.len() >= 0 then\n",
            "    vec![\"Net\", \"IO\"].into_iter().collect()\n",
            "  else\n",
            "    Set::new()\n",
            "  end\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_iterator_fold_and_any() {
        let source = concat!(
            "def summarize(nums: Vec[Int]) -> Bool\n",
            "  let total = nums.iter().fold(0, |acc, x| acc + x)\n",
            "  total > 0 && nums.iter().any(|x| x > 10)\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_generic_ord_comparisons() {
        let source = concat!(
            "def max_of[T: Ord](a: T, b: T) -> T\n",
            "  if a >= b then a else b end\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_option_payload_equality() {
        let source = concat!(
            "enum Mode\n",
            "  Dev\n",
            "  Prod\n",
            "end\n",
            "def is_prod(mode: Option[Mode]) -> Bool\n",
            "  mode == Mode::Prod\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn substitutes_generic_struct_field_types() {
        let source = concat!(
            "struct Box[T]\n",
            "  value: T\n",
            "end\n",
            "def unbox(boxed: Box[Int]) -> Int\n",
            "  boxed.value\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn infers_generic_struct_literal_type_args_from_expected_return() {
        let source = concat!(
            "struct Pair[A, B]\n",
            "  first: A\n",
            "  second: B\n",
            "end\n",
            "def swap[A, B](p: Pair[A, B]) -> Pair[B, A]\n",
            "  Pair { first: p.second, second: p.first }\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_legacy_item_annotations_field_alias() {
        let source = concat!(
            "struct Attribute\n",
            "  name: String\n",
            "end\n",
            "struct Item\n",
            "  attrs: Vec[Attribute]\n",
            "end\n",
            "def count(item: Item) -> Int\n",
            "  item.annotations.len()\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_legacy_item_annotations_field_alias_for_qualified_types() {
        let source = concat!(
            "def count(item: tg_compiler::ast::Item) -> Int\n",
            "  item.annotations.len()\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        let mut env = SemanticEnv::default();
        Rc::make_mut(&mut env.structs).insert(
            "tg_compiler::ast::Attribute".to_string(),
            StructDecl {
                name: "tg_compiler::ast::Attribute".to_string(),
                public: true,
                type_params: Vec::new(),
                where_clause: Vec::new(),
                fields: vec![FieldDecl {
                    public: true,
                    name: "name".to_string(),
                    ty: TypeRef::String {
                        span: Span::new(1, 1, 0, 0),
                    },
                    span: Span::new(1, 1, 0, 0),
                }],
                span: Span::new(1, 1, 0, 0),
            },
        );
        Rc::make_mut(&mut env.structs).insert(
            "tg_compiler::ast::Item".to_string(),
            StructDecl {
                name: "tg_compiler::ast::Item".to_string(),
                public: true,
                type_params: Vec::new(),
                where_clause: Vec::new(),
                fields: vec![FieldDecl {
                    public: true,
                    name: "attrs".to_string(),
                    ty: TypeRef::Named {
                        name: "Vec".to_string(),
                        type_args: vec![TypeRef::Named {
                            name: "tg_compiler::ast::Attribute".to_string(),
                            type_args: Vec::new(),
                            span: Span::new(1, 1, 0, 0),
                        }],
                        span: Span::new(1, 1, 0, 0),
                    },
                    span: Span::new(1, 1, 0, 0),
                }],
                span: Span::new(1, 1, 0, 0),
            },
        );

        analyze_with_env(&module, &env).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_legacy_annotation_type_alias() {
        let source = concat!(
            "struct Attribute\n",
            "  name: String\n",
            "end\n",
            "def count(attrs: &Vec[Attribute]) -> Int\n",
            "  attrs.len()\n",
            "end\n",
            "def forward(attrs: &Vec[Annotation]) -> Int\n",
            "  count(attrs)\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_legacy_struct_and_enum_decl_type_aliases() {
        let source = concat!(
            "struct StructDecl\n",
            "  name: String\n",
            "end\n",
            "struct EnumDecl\n",
            "  name: String\n",
            "end\n",
            "def take_struct(item: &StructDecl) -> String\n",
            "  item.name\n",
            "end\n",
            "def forward_struct(item: &Struct) -> String\n",
            "  take_struct(item)\n",
            "end\n",
            "def take_enum(item: &EnumDecl) -> String\n",
            "  item.name\n",
            "end\n",
            "def forward_enum(item: &Enum) -> String\n",
            "  take_enum(item)\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_impl_generic_type_params_in_method_scope() {
        let source = concat!(
            "struct Container[T]\n",
            "  value: T\n",
            "end\n",
            "impl[T] Container[T]\n",
            "  def clone_value(&self) -> T\n",
            "    self.value\n",
            "  end\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_default_trait_method_dispatch_on_self() {
        let source = concat!(
            "trait Describable\n",
            "  def name(self) -> String\n",
            "  def description(self) -> String\n",
            "    \"No description for: \" + self.name()\n",
            "  end\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_impls_that_omit_default_trait_methods() {
        let source = concat!(
            "trait Describable\n",
            "  def name(self) -> String\n",
            "  def description(self) -> String\n",
            "    \"No description for: \" + self.name()\n",
            "  end\n",
            "end\n",
            "struct Point\n",
            "  x: Int\n",
            "end\n",
            "impl Describable for Point\n",
            "  def name(self) -> String\n",
            "    \"Point\"\n",
            "  end\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_generic_trait_method_dispatch_on_placeholder() {
        let source = concat!(
            "trait Eq\n",
            "  def eq(self, other: Self) -> Bool\n",
            "end\n",
            "struct Box[T]\n",
            "  value: T\n",
            "end\n",
            "impl[T: Eq] Eq for Box[T]\n",
            "  def eq(self, other: Box[T]) -> Bool\n",
            "    self.value.eq(other.value)\n",
            "  end\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_mutually_recursive_local_functions() {
        let source = concat!(
            "def parity(n: Int) -> Bool\n",
            "  def is_even(x: Int) -> Bool\n",
            "    if x == 0 then true else is_odd(x - 1) end\n",
            "  end\n",
            "  def is_odd(x: Int) -> Bool\n",
            "    if x == 0 then false else is_even(x - 1) end\n",
            "  end\n",
            "  is_even(n)\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_set_algebra_methods() {
        let source = concat!(
            "use std::collections::*\n",
            "def combine(a: Set[Int], b: Set[Int]) -> Bool\n",
            "  let unioned = a.union(&b)\n",
            "  let shared = a.intersection(&b)\n",
            "  let removed = a.difference(&b)\n",
            "  unioned.len() >= shared.len() && !removed.is_empty() || a.is_subset(&b) || a.is_superset(&b)\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn allows_shadowing_inside_match_arms() {
        let source = concat!(
            "enum Shape\n",
            "  Circle(Float)\n",
            "  Triangle(Float, Float, Float)\n",
            "end\n",
            "def area(shape: Shape) -> Float\n",
            "  match shape\n",
            "  when Shape::Circle(r) then r\n",
            "  when Shape::Triangle(a, b, c) then\n",
            "    let s = (a + b + c) / 2.0\n",
            "    (s * (s - a) * (s - b) * (s - c)).sqrt()\n",
            "  end\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn propagates_expected_types_through_option_some_payloads() {
        let source = concat!(
            "def nested() -> Option[Result[Int, String]]\n",
            "  Option::Some(Result::Ok(42))\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_result_map() {
        let source = concat!(
            "def increment(result: Result[Int, String]) -> Result[Int, String]\n",
            "  result.map(|value| value + 1)\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_empty_vec_contains_and_string_helpers() {
        let source = concat!(
            "def helpers(name: String, needle: String, effect: String) -> Bool\n",
            "  let effects = Vec::new()\n",
            "  if !effects.contains(effect) then\n",
            "    effects.push(effect.clone())\n",
            "  end\n",
            "  let _bytes = name.as_bytes()\n",
            "  let _view = name.as_str()\n",
            "  let _trimmed = needle.trim_end(\";\")\n",
            "  match name.last_index_of(needle)\n",
            "  when Some(i) then i >= 0\n",
            "  when None then false\n",
            "  end\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_string_bytes_into_vec_u8() {
        let source = concat!(
            "def store(name: String, out: &mut Vec[u8]) -> Unit\n",
            "  for byte in name.bytes() do\n",
            "    out.push(byte)\n",
            "  end\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_vec_new_for_array_struct_field() {
        let source = concat!(
            "struct Item\n",
            "  values: Array[Int]\n",
            "end\n",
            "def build() -> Item\n",
            "  Item { values: Vec::new() }\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_fixed_size_byte_array_literals() {
        let source = "def magic() -> [u8; 4] = [0x7F, 0x45, 0x4C, 0x46]\n";
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_string_substring_and_parse_float() {
        let source = concat!(
            "def parse(text: String) -> Float\n",
            "  let whole = text.substring(0, text.len())\n",
            "  whole.parse_float()\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_option_as_ref() {
        let source = concat!(
            "def borrow_name(maybe: Option[String]) -> Option[&String]\n",
            "  maybe.as_ref()\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_empty_map_lookup_with_inferred_key_type() {
        let source = concat!(
            "def contains(name: String) -> Bool\n",
            "  let cache = Map::new()\n",
            "  cache.contains_key(name)\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn infers_empty_map_value_type_from_future_insertions() {
        let source = concat!(
            "struct Entry\n",
            "  used: Bool\n",
            "end\n",
            "def contains(names: Vec[String]) -> Bool\n",
            "  let seen = Map::new()\n",
            "  for name in names do\n",
            "    match seen.get(name)\n",
            "    when Some(existing) then\n",
            "      if existing.used then\n",
            "        return true\n",
            "      end\n",
            "    when None then\n",
            "      seen.insert(name.clone(), Entry { used: true })\n",
            "    end\n",
            "  end\n",
            "  false\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_string_rfind_parse_int_and_option_ok_or() {
        let source = concat!(
            "def parse(text: String, maybe: Option[String]) -> Int\n",
            "  match text.rfind(\":\")\n",
            "  when Some(i) then\n",
            "    maybe.ok_or(\"missing\".to_string())\n",
            "    text.substring(0, i).parse_int()\n",
            "  when None then\n",
            "    0\n",
            "  end\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn accepts_box_new_and_vec_last() {
        let source = concat!(
            "struct Item\n",
            "  value: Int\n",
            "end\n",
            "def inspect(items: Vec[Item]) -> Int\n",
            "  let boxed = Box::new(Item { value: 7 })\n",
            "  match items.last()\n",
            "  when Some(last) then last.value + boxed.value\n",
            "  when None then boxed.value\n",
            "  end\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn infers_empty_map_value_type_from_get_mut_match_usage() {
        let source = concat!(
            "struct Usage\n",
            "  file: String\n",
            "end\n",
            "def build(audit: Vec[Usage]) -> Int\n",
            "  mut by_file = Map::new()\n",
            "  for usage in audit do\n",
            "    match by_file.get_mut(usage.file.clone())\n",
            "    when Some(list) then list.push(usage)\n",
            "    when None then\n",
            "      mut list = Vec::new()\n",
            "      list.push(usage)\n",
            "      by_file.insert(usage.file.clone(), list)\n",
            "    end\n",
            "  end\n",
            "  by_file.len()\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }

    #[test]
    fn infers_empty_map_value_type_from_later_insert_after_get() {
        let source = concat!(
            "struct Symbol\n",
            "  is_defined: Bool\n",
            "end\n",
            "def build(names: Vec[String]) -> Int\n",
            "  mut syms = Map::new()\n",
            "  for name in names do\n",
            "    match syms.get(name)\n",
            "    when Some(existing) then\n",
            "      if existing.is_defined then\n",
            "        syms.len()\n",
            "      else\n",
            "        0\n",
            "      end\n",
            "    when None then 0\n",
            "    end\n",
            "    syms.insert(name, Symbol { is_defined: true })\n",
            "  end\n",
            "  syms.len()\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        analyze(&module).expect("semantic analysis should succeed");
    }
}
