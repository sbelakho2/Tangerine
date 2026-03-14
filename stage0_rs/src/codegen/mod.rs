use crate::ast::decl::{ConstDecl, Decl, EnumDecl, ExternBlockDecl, FunctionSig, GlobalDecl, MetaKind, Module, StructDecl, TraitDecl, TypeAliasDecl};
use crate::ast::expr::{BinaryOp, BlockBody, Expr, FunctionBody, Pattern, Stmt, UnaryOp};
use crate::ast::types::TypeRef;
use crate::error::Stage0Error;
use crate::sema::SemanticEnv;
use crate::span::Span;
use std::collections::{BTreeMap as OrderedMap, BTreeSet as OrderedSet};
use std::env;
use std::fmt::Write;
use std::path::Path;
use std::process::Command;

struct CodegenState {
    recursive_inline_types: OrderedSet<String>,
    enum_types: OrderedSet<String>,
    variant_owners: OrderedMap<String, String>,
    string_returning_functions: OrderedSet<String>,
    function_params: OrderedMap<String, Vec<TypeRef>>,
    mutable_trait_methods: OrderedSet<String>,
    emit_span_type: bool,
    emit_span_merge: bool,
    local_names: OrderedSet<String>,
    support_use_paths: Vec<String>,
    support_modules: SupportModuleTree,
}

#[derive(Default)]
struct SupportModuleTree {
    children: OrderedMap<String, SupportModuleTree>,
    items: Vec<SupportItem>,
    impls: Vec<SupportImpl>,
}

enum SupportItem {
    Struct(StructDecl),
    Enum(EnumDecl),
    Trait(TraitDecl),
    Function(FunctionSig),
    TypeAlias(String, TypeRef),
    Const(String, TypeRef),
    Global(String, TypeRef, bool),
}

struct SupportImpl {
    trait_name: String,
    type_params: Vec<String>,
    for_type: TypeRef,
    methods: Vec<FunctionSig>,
    associated_types: Vec<(String, TypeRef)>,
}

#[derive(Default)]
struct SupportReferences {
    items: OrderedSet<String>,
    use_paths: OrderedSet<String>,
}

/// Emit a Rust source file for the parsed Tangerine module.
///
/// # Errors
/// Returns `Stage0Error` if any Tangerine type in the module cannot be lowered
/// to Rust source without loss of semantic information.
pub fn emit_rust(module: &Module, env: &SemanticEnv) -> Result<String, Stage0Error> {
    let state = build_codegen_state(module, env);
    emit_module(module, &state, true)
}

fn emit_module(module: &Module, state: &CodegenState, include_prelude: bool) -> Result<String, Stage0Error> {
    let mut out = String::new();
    if include_prelude {
        emit_prelude(&mut out, state);
        emit_support_modules(&mut out, state)?;
        emit_use_metadata(&mut out, module, state);
    }

    for decl in &module.decls {
        emit_decl(&mut out, decl, state)?;
    }

    Ok(out)
}

fn emit_prelude(out: &mut String, state: &CodegenState) {
    out.push_str("#![allow(dead_code)]\n\n");
    out.push_str("use std::collections::{BTreeMap, BTreeSet};\n");
    // Don't import Display unconditionally - handle it in trait bounds instead
    out.push_str("type Array<T> = Vec<T>;\n");
    out.push_str("type Map<K, V> = BTreeMap<K, V>;\n");
    out.push_str("type Set<T> = BTreeSet<T>;\n\n");
    if state.emit_span_type {
        out.push_str("#[derive(Clone, Copy, Default)]\n");
        out.push_str("pub struct Span { pub line: i64, pub col: i64, pub start: i64, pub end_pos: i64 }\n");
    }
    if state.emit_span_merge {
        out.push_str("pub fn span_merge(left: Span, right: Span) -> Span { Span { line: left.line, col: left.col, start: left.start, end_pos: right.end_pos } }\n");
    }
    if state.emit_span_type || state.emit_span_merge {
        out.push('\n');
    }
}

fn emit_support_modules(out: &mut String, state: &CodegenState) -> Result<(), Stage0Error> {
    for item in &state.support_modules.items {
        emit_support_item(out, item, state, 0)?;
    }
    for support_impl in &state.support_modules.impls {
        emit_support_impl(out, support_impl, state, 0)?;
    }
    if !state.support_modules.items.is_empty() {
        out.push('\n');
    }
    for (name, module) in &state.support_modules.children {
        emit_support_module(out, name, module, state, 0)?;
    }
    if !state.support_modules.children.is_empty() {
        out.push('\n');
    }
    Ok(())
}

fn emit_decl(out: &mut String, decl: &Decl, state: &CodegenState) -> Result<(), Stage0Error> {
    match decl {
        Decl::Meta(_) => {}
        Decl::Module(module_decl) => emit_module_decl(out, module_decl, state)?,
        Decl::Struct(struct_decl) => {
            out.push_str(&gen_struct(struct_decl, state)?);
            out.push('\n');
        }
        Decl::Enum(enum_decl) => {
            out.push_str(&gen_enum(enum_decl, state)?);
            out.push('\n');
        }
        Decl::Trait(trait_decl) => {
            out.push_str(&gen_trait(trait_decl, state)?);
            out.push('\n');
        }
        Decl::Impl(impl_decl) => emit_impl_decl(out, impl_decl, state)?,
        Decl::Function(function_decl) => emit_function_decl(out, function_decl, state)?,
        Decl::TypeAlias(alias_decl) => {
            out.push_str(&gen_type_alias(alias_decl)?);
            out.push('\n');
        }
        Decl::Const(const_decl) => {
            out.push_str(&gen_const(const_decl)?);
            out.push('\n');
        }
        Decl::Global(global_decl) => {
            out.push_str(&gen_global(global_decl)?);
            out.push('\n');
        }
        Decl::Extern(extern_decl) => {
            out.push_str(&gen_extern_block(extern_decl)?);
            out.push('\n');
        }
    }
    Ok(())
}

fn emit_module_decl(out: &mut String, module_decl: &crate::ast::decl::ModuleDecl, state: &CodegenState) -> Result<(), Stage0Error> {
    let nested = emit_module(
        &Module {
            decls: module_decl.decls.clone(),
        },
        state,
        false,
    )?;
    let segments: Vec<&str> = module_decl.name.split("::").collect();
    for (level, segment) in segments.iter().enumerate() {
        writeln!(out, "{}pub mod {} {{", indent(level), segment).expect("writing to String must succeed");
        writeln!(out, "{}use super::*;", indent(level + 1)).expect("writing to String must succeed");
    }
    for line in nested.lines() {
        writeln!(out, "{}{}", indent(segments.len()), line).expect("writing to String must succeed");
    }
    for level in (0..segments.len()).rev() {
        writeln!(out, "{}}}", indent(level)).expect("writing to String must succeed");
    }
    out.push('\n');
    Ok(())
}

fn emit_impl_decl(out: &mut String, impl_decl: &crate::ast::decl::ImplDecl, state: &CodegenState) -> Result<(), Stage0Error> {
    let type_params = format_type_params(&impl_decl.type_params);
    let where_clause = format_where_clause(&impl_decl.where_clause)?;
    if impl_decl.trait_name.is_empty() {
        writeln!(out, "impl{type_params} {}{where_clause} {{", format_type(&impl_decl.for_type)?)
            .expect("writing to String must succeed");
    } else {
        writeln!(
            out,
            "impl{type_params} {} for {}{where_clause} {{",
            impl_decl.trait_name,
            format_type(&impl_decl.for_type)?
        )
        .expect("writing to String must succeed");
    }
    for associated_type in &impl_decl.associated_types {
        let target = associated_type
            .target
            .as_ref()
            .map(format_type)
            .transpose()?
            .unwrap_or_else(|| "()".to_string());
        writeln!(out, "    type {} = {target};", associated_type.name)
            .expect("writing to String must succeed");
    }
    for method in &impl_decl.methods {
        out.push_str("    fn ");
        out.push_str(&method.sig.name);
        out.push_str(&format_type_params(&method.sig.type_params));
        out.push('(');
        out.push_str(&format_params_with_body(
            &method.sig.params,
            Some(&method.body),
            Some(impl_decl.trait_name.as_str()),
            &method.sig.name,
            state,
        )?);
        out.push_str(") -> ");
        out.push_str(&format_type(&method.sig.return_type)?);
        out.push_str(&format_where_clause(&method.sig.where_clause)?);
        out.push(' ');
        out.push_str(&emit_function_body(
            &method.body,
            1,
            is_unit_type(&method.sig.return_type),
            Some(&method.sig.return_type),
            state,
        )?);
        out.push('\n');
    }
    out.push_str("}\n\n");
    Ok(())
}

fn emit_function_decl(
    out: &mut String,
    function_decl: &crate::ast::decl::FunctionDecl,
    state: &CodegenState,
) -> Result<(), Stage0Error> {
    write!(
        out,
        "pub fn {}{}({}) -> {}{} ",
        function_decl.sig.name,
        format_type_params(&function_decl.sig.type_params),
        format_params_with_body(
            &function_decl.sig.params,
            Some(&function_decl.body),
            None,
            &function_decl.sig.name,
            state,
        )?,
        format_type(&function_decl.sig.return_type)?,
        format_where_clause(&function_decl.sig.where_clause)?
    )
    .expect("writing to String must succeed");
    out.push_str(&emit_function_body(
        &function_decl.body,
        0,
        is_unit_type(&function_decl.sig.return_type),
        Some(&function_decl.sig.return_type),
        state,
    )?);
    out.push_str("\n\n");
    Ok(())
}

/// Emit a Rust struct declaration.
///
/// # Errors
/// Returns `Stage0Error` if any struct field type cannot be represented in Rust.
fn gen_struct(decl: &StructDecl, state: &CodegenState) -> Result<String, Stage0Error> {
    let mut out = String::new();
    out.push_str("#[derive(Clone)]\n");
    writeln!(
        out,
        "{}struct {}{}{} {{",
        visibility_prefix(decl.public),
        decl.name,
        format_type_params(&decl.type_params),
        format_where_clause(&decl.where_clause)?
    )
        .expect("writing to String must succeed");
    for field in &decl.fields {
        writeln!(
            out,
            "    {}{}: {},",
            visibility_prefix(field.public),
            field.name,
            format_struct_field_type(&field.ty, state, false)?
        )
            .expect("writing to String must succeed");
    }
    out.push_str("}\n");
    Ok(out)
}

/// Emit a Rust enum declaration.
///
/// # Errors
/// Returns `Stage0Error` if any enum payload type cannot be represented in Rust.
fn gen_enum(decl: &EnumDecl, state: &CodegenState) -> Result<String, Stage0Error> {
    let mut out = String::new();
    if decl
        .variants
        .iter()
        .all(|variant| variant.tuple_fields.is_empty() && variant.named_fields.is_empty())
    {
        out.push_str("#[derive(Clone, Copy)]\n");
    } else {
        out.push_str("#[derive(Clone)]\n");
    }
    writeln!(
        out,
        "{}enum {}{}{} {{",
        visibility_prefix(decl.public),
        decl.name,
        format_type_params(&decl.type_params),
        format_where_clause(&decl.where_clause)?
    )
        .expect("writing to String must succeed");
    for variant in &decl.variants {
        if variant.tuple_fields.is_empty() && variant.named_fields.is_empty() {
            writeln!(out, "    {},", variant.name).expect("writing to String must succeed");
        } else if !variant.named_fields.is_empty() {
            let payload = variant
                .named_fields
                .iter()
                .map(|field| format_storage_type(&field.ty, state, false).map(|ty| format!("{}: {ty}", field.name)))
                .collect::<Result<Vec<_>, _>>()?
                .join(", ");
            writeln!(out, "    {} {{ {} }},", variant.name, payload)
                .expect("writing to String must succeed");
        } else {
            let payload = variant
                .tuple_fields
                .iter()
                .map(|ty| format_storage_type(ty, state, false))
                .collect::<Result<Vec<_>, _>>()?
                .join(", ");
            writeln!(out, "    {}({}),", variant.name, payload).expect("writing to String must succeed");
        }
    }
    out.push_str("}\n");
    Ok(out)
}

/// Emit a Rust trait declaration.
///
/// # Errors
/// Returns `Stage0Error` if any method signature cannot be lowered exactly.
fn gen_trait(decl: &TraitDecl, state: &CodegenState) -> Result<String, Stage0Error> {
    let mut out = format!(
        "{}trait {}{}{}{} {{\n",
        visibility_prefix(decl.public),
        decl.name,
        format_type_params(&decl.type_params),
        format_supertraits(&decl.supertraits),
        format_where_clause(&decl.where_clause)?
    );
    for associated_type in &decl.associated_types {
        match associated_type.target.as_ref() {
            Some(target) => {
                writeln!(out, "    type {} = {};", associated_type.name, format_type(target)?)
                    .expect("writing to String must succeed");
            }
            None => {
                writeln!(out, "    type {};", associated_type.name)
                    .expect("writing to String must succeed");
            }
        }
    }
    for method in &decl.methods {
        out.push_str("    fn ");
        out.push_str(&method.sig.name);
        out.push_str(&format_type_params(&method.sig.type_params));
        out.push('(');
        out.push_str(&format_params_with_body(
            &method.sig.params,
            Some(&method.body),
            Some(decl.name.as_str()),
            &method.sig.name,
            state,
        )?);
        out.push_str(") -> ");
        out.push_str(&format_type(&method.sig.return_type)?);
        out.push_str(&format_where_clause(&method.sig.where_clause)?);
        match &method.body {
            FunctionBody::Declaration { .. } => out.push_str(";\n"),
            _ => {
                out.push(' ');
                out.push_str(&emit_function_body(
                    &method.body,
                    1,
                    is_unit_type(&method.sig.return_type),
                    Some(&method.sig.return_type),
                    state,
                )?);
                out.push('\n');
            }
        }
    }
    out.push_str("}\n");
    Ok(out)
}

fn gen_type_alias(decl: &TypeAliasDecl) -> Result<String, Stage0Error> {
    let target = decl
        .target
        .as_ref()
        .map(format_type)
        .transpose()?
        .unwrap_or_else(|| "()".to_string());
    Ok(format!("{}type {} = {};\n", visibility_prefix(decl.public), decl.name, target))
}

fn gen_const(decl: &ConstDecl) -> Result<String, Stage0Error> {
    let ty = decl
        .ty
        .as_ref()
        .map(format_type)
        .transpose()?
        .unwrap_or_else(|| "()".to_string());
    Ok(format!(
        "{}const {}: {} = {};\n",
        visibility_prefix(decl.public),
        decl.name,
        ty,
        format_const_expr(&decl.value)?
    ))
}

fn gen_global(decl: &GlobalDecl) -> Result<String, Stage0Error> {
    let ty = decl
        .ty
        .as_ref()
        .map(format_type)
        .transpose()?
        .unwrap_or_else(|| "()".to_string());
    let qualifier = if decl.mutable { "static mut" } else { "static" };
    Ok(format!(
        "{}{} {}: {} = {};\n",
        visibility_prefix(decl.public),
        qualifier,
        decl.name,
        ty,
        format_const_expr(&decl.value)?
    ))
}

fn gen_extern_block(decl: &ExternBlockDecl) -> Result<String, Stage0Error> {
    let mut out = String::new();
    if let Some(abi) = &decl.abi {
            writeln!(out, "extern \"{abi}\" {{").expect("writing to String must succeed");
    } else {
        out.push_str("extern {\n");
    }
    for function in &decl.functions {
        writeln!(
            out,
            "    fn {}({}) -> {};",
            function.name,
            format_params(&function.params)?,
            format_type(&function.return_type)?
        )
        .expect("writing to String must succeed");
    }
    out.push_str("}\n");
    Ok(out)
}

fn format_const_expr(expr: &Expr) -> Result<String, Stage0Error> {
    match expr {
        Expr::Integer { value, .. } | Expr::Float { value, .. } => Ok(value.clone()),
        Expr::Char { value, .. } => Ok(format!("'{}'", escape_char_literal(*value))),
        Expr::String { value, .. } => Ok(format!("\"{}\".to_string()", escape_string_literal(value))),
        Expr::Bool { value, .. } => Ok(value.to_string()),
        Expr::Name { name, .. } => Ok(name.clone()),
        other => Err(Stage0Error::codegen(
            other.span(),
            format!("const lowering is unsupported for expression {other:?}"),
        )),
    }
}

fn emit_support_module(
    out: &mut String,
    name: &str,
    module: &SupportModuleTree,
    state: &CodegenState,
    indent_level: usize,
) -> Result<(), Stage0Error> {
    writeln!(out, "{}pub mod {} {{", indent(indent_level), name).expect("writing to String must succeed");
    writeln!(out, "{}use super::*;", indent(indent_level + 1)).expect("writing to String must succeed");
    for (child_name, child) in &module.children {
        emit_support_module(out, child_name, child, state, indent_level + 1)?;
    }
    for item in &module.items {
        emit_support_item(out, item, state, indent_level + 1)?;
    }
    for support_impl in &module.impls {
        emit_support_impl(out, support_impl, state, indent_level + 1)?;
    }
    writeln!(out, "{}}}", indent(indent_level)).expect("writing to String must succeed");
    Ok(())
}

fn emit_support_item(
    out: &mut String,
    item: &SupportItem,
    state: &CodegenState,
    indent_level: usize,
) -> Result<(), Stage0Error> {
    match item {
        SupportItem::Struct(decl) => emit_support_struct(out, decl, state, indent_level)?,
        SupportItem::Enum(decl) => emit_support_enum(out, decl, state, indent_level)?,
        SupportItem::Trait(decl) => emit_support_trait(out, decl, state, indent_level)?,
        SupportItem::Function(sig) => emit_support_function(out, sig, indent_level)?,
        SupportItem::TypeAlias(name, ty) => emit_support_type_alias(out, name, ty, indent_level)?,
        SupportItem::Const(name, ty) => emit_support_const(out, name, ty, indent_level)?,
        SupportItem::Global(name, ty, mutable) => emit_support_global(out, name, ty, *mutable, indent_level)?,
    }
    Ok(())
}

fn emit_support_struct(
    out: &mut String,
    decl: &StructDecl,
    state: &CodegenState,
    indent_level: usize,
) -> Result<(), Stage0Error> {
    writeln!(out, "{}#[derive(Clone)]", indent(indent_level)).expect("writing to String must succeed");
    writeln!(
        out,
        "{}pub struct {}{}{} {{",
        indent(indent_level),
        leaf_name(&decl.name),
        format_type_params(&decl.type_params),
        format_where_clause(&decl.where_clause)?
    )
    .expect("writing to String must succeed");
    for field in &decl.fields {
        writeln!(
            out,
            "{}pub {}: {},",
            indent(indent_level + 1),
            field.name,
            format_struct_field_type(&field.ty, state, false)?
        )
        .expect("writing to String must succeed");
    }
    writeln!(out, "{}}}", indent(indent_level)).expect("writing to String must succeed");
    Ok(())
}

fn emit_support_enum(
    out: &mut String,
    decl: &EnumDecl,
    state: &CodegenState,
    indent_level: usize,
) -> Result<(), Stage0Error> {
    if decl
        .variants
        .iter()
        .all(|variant| variant.tuple_fields.is_empty() && variant.named_fields.is_empty())
    {
        writeln!(out, "{}#[derive(Clone, Copy)]", indent(indent_level)).expect("writing to String must succeed");
    } else {
        writeln!(out, "{}#[derive(Clone)]", indent(indent_level)).expect("writing to String must succeed");
    }
    writeln!(
        out,
        "{}pub enum {}{}{} {{",
        indent(indent_level),
        leaf_name(&decl.name),
        format_type_params(&decl.type_params),
        format_where_clause(&decl.where_clause)?
    )
    .expect("writing to String must succeed");
    for variant in &decl.variants {
        if variant.tuple_fields.is_empty() && variant.named_fields.is_empty() {
            writeln!(out, "{}{},", indent(indent_level + 1), variant.name)
                .expect("writing to String must succeed");
        } else if !variant.named_fields.is_empty() {
            let payload = variant
                .named_fields
                .iter()
                .map(|field| format_struct_field_type(&field.ty, state, false).map(|ty| format!("{}: {ty}", field.name)))
                .collect::<Result<Vec<_>, _>>()?
                .join(", ");
            writeln!(out, "{}{} {{ {} }},", indent(indent_level + 1), variant.name, payload)
                .expect("writing to String must succeed");
        } else {
            let payload = variant
                .tuple_fields
                .iter()
                .map(|ty| format_storage_type(ty, state, false))
                .collect::<Result<Vec<_>, _>>()?
                .join(", ");
            writeln!(out, "{}{}({}),", indent(indent_level + 1), variant.name, payload)
                .expect("writing to String must succeed");
        }
    }
    writeln!(out, "{}}}", indent(indent_level)).expect("writing to String must succeed");
    Ok(())
}

fn emit_support_trait(
    out: &mut String,
    decl: &TraitDecl,
    state: &CodegenState,
    indent_level: usize,
) -> Result<(), Stage0Error> {
    let header = format!(
        "{}pub trait {}{}{}{} {{",
        indent(indent_level),
        leaf_name(&decl.name),
        format_type_params(&decl.type_params),
        format_supertraits(&decl.supertraits),
        format_where_clause(&decl.where_clause)?
    );
    writeln!(out, "{header}").expect("writing to String must succeed");
    for associated_type in &decl.associated_types {
        match associated_type.target.as_ref() {
            Some(target) => {
                writeln!(
                    out,
                    "{}type {} = {};",
                    indent(indent_level + 1),
                    associated_type.name,
                    format_type(target)?
                )
                .expect("writing to String must succeed");
            }
            None => {
                writeln!(out, "{}type {};", indent(indent_level + 1), associated_type.name)
                    .expect("writing to String must succeed");
            }
        }
    }
    for method in &decl.methods {
        writeln!(
            out,
            "{}fn {}{}({}) -> {}{};",
            indent(indent_level + 1),
            leaf_name(&method.sig.name),
            format_type_params(&method.sig.type_params),
            format_params(&method.sig.params)?,
            format_type(&method.sig.return_type)?,
            format_where_clause(&method.sig.where_clause)?
        )
        .expect("writing to String must succeed");
    }
    writeln!(out, "{}}}", indent(indent_level)).expect("writing to String must succeed");
    let _ = state;
    Ok(())
}

fn emit_support_function(out: &mut String, sig: &FunctionSig, indent_level: usize) -> Result<(), Stage0Error> {
    let fn_name = leaf_name(&sig.name);
    writeln!(
        out,
        "{}pub fn {}{}({}) -> {}{} {{ todo!(\"support function '{}' not yet linked\") }}",
        indent(indent_level),
        fn_name,
        format_type_params(&sig.type_params),
        format_params(&sig.params)?,
        format_type(&sig.return_type)?,
        format_where_clause(&sig.where_clause)?,
        fn_name
    )
    .expect("writing to String must succeed");
    Ok(())
}

fn emit_support_const(out: &mut String, name: &str, ty: &TypeRef, indent_level: usize) -> Result<(), Stage0Error> {
    writeln!(
        out,
        "{}pub const {}: {} = {};",
        indent(indent_level),
        leaf_name(name),
        format_support_value_type(ty)?,
        format_support_value_initializer(ty)?
    )
    .expect("writing to String must succeed");
    Ok(())
}

fn emit_support_global(
    out: &mut String,
    name: &str,
    ty: &TypeRef,
    mutable: bool,
    indent_level: usize,
) -> Result<(), Stage0Error> {
    let qualifier = if mutable { "pub static mut" } else { "pub static" };
    writeln!(
        out,
        "{}{} {}: {} = {};",
        indent(indent_level),
        qualifier,
        leaf_name(name),
        format_support_value_type(ty)?,
        format_support_value_initializer(ty)?
    )
    .expect("writing to String must succeed");
    Ok(())
}

fn emit_support_impl(
    out: &mut String,
    support_impl: &SupportImpl,
    _state: &CodegenState,
    indent_level: usize,
) -> Result<(), Stage0Error> {
    let impl_type_params = format_support_impl_type_params(&support_impl.type_params);
    if support_impl.trait_name.is_empty() {
        writeln!(
            out,
            "{}impl{} {} {{",
            indent(indent_level),
            impl_type_params,
            format_type(&support_impl.for_type)?
        )
        .expect("writing to String must succeed");
    } else {
        writeln!(
            out,
            "{}impl{} {} for {} {{",
            indent(indent_level),
            impl_type_params,
            qualify_rust_path(&support_impl.trait_name),
            format_type(&support_impl.for_type)?
        )
        .expect("writing to String must succeed");
    }
    for (name, ty) in &support_impl.associated_types {
        writeln!(
            out,
            "{}type {} = {};",
            indent(indent_level + 1),
            name,
            format_type(ty)?
        )
        .expect("writing to String must succeed");
    }
    for method in &support_impl.methods {
        let visibility = if support_impl.trait_name.is_empty() {
            visibility_prefix(method.public)
        } else {
            ""
        };
        writeln!(
            out,
            "{}{}fn {}{}({}) -> {}{} {{ unimplemented!() }}",
            indent(indent_level + 1),
            visibility,
            leaf_name(&method.name),
            format_type_params(&method.type_params),
            format_params(&method.params)?,
            format_type(&method.return_type)?,
            format_where_clause(&method.where_clause)?
        )
        .expect("writing to String must succeed");
    }
    writeln!(out, "{}}}", indent(indent_level)).expect("writing to String must succeed");
    Ok(())
}

fn emit_support_type_alias(
    out: &mut String,
    name: &str,
    ty: &TypeRef,
    indent_level: usize,
) -> Result<(), Stage0Error> {
    writeln!(
        out,
        "{}pub type {} = {};",
        indent(indent_level),
        leaf_name(name),
        format_type(ty)?
    )
    .expect("writing to String must succeed");
    Ok(())
}

fn emit_use_metadata(out: &mut String, module: &Module, state: &CodegenState) {
    let mut paths = OrderedSet::new();
    for decl in &module.decls {
        if let Decl::Meta(meta) = decl {
            if meta.kind == MetaKind::Use {
                for path in rewrite_use_paths(&meta.detail, &state.local_names) {
                    paths.insert(path);
                }
            }
        }
    }
    paths.extend(state.support_use_paths.iter().cloned());
    let emitted = !paths.is_empty();
    for path in paths {
        writeln!(out, "use {path};").expect("writing to String must succeed");
    }
    if emitted {
        out.push('\n');
    }
}

fn rewrite_use_paths(detail: &str, local_names: &OrderedSet<String>) -> Vec<String> {
    let trimmed = detail.trim();
    if trimmed.is_empty() {
        return Vec::new();
    }

    if let Some((prefix, inner)) = split_braced_use(trimmed) {
        let mut paths = Vec::new();
        for item in split_top_level_items(inner) {
            let item = item.trim();
            if item.is_empty() {
                continue;
            }
            let combined = join_use_prefix(prefix, item);
            paths.extend(rewrite_use_paths(&combined, local_names));
        }
        return paths;
    }

    let (base, alias) = split_use_alias(trimmed);
    let imported_name = alias.unwrap_or_else(|| leaf_name(base));
    if local_names.contains(imported_name) || is_generated_prelude_name(imported_name) {
        return Vec::new();
    }

    rewrite_simple_use_path(base)
        .into_iter()
        .map(|path| match alias {
            Some(alias) => format!("{path} as {alias}"),
            None => path,
        })
        .collect()
}

fn is_generated_prelude_name(name: &str) -> bool {
    matches!(name, "Array" | "Map" | "Set" | "Span" | "span_merge")
}

fn split_use_alias(detail: &str) -> (&str, Option<&str>) {
    if let Some((base, alias)) = detail.split_once(" as ") {
        (base.trim(), Some(alias.trim()))
    } else {
        (detail.trim(), None)
    }
}

fn rewrite_simple_use_path(path: &str) -> Vec<String> {
    match path {
        "std::core::Option" | "std::core::Result" | "std::core::Vec" | "std::core::String" | "std::core::Bool" | "std::core::UInt"
        | "std::core::Int" | "std::core::Float" | "std::core::panic" | "std::collections::Vec" | "std::collections::Map"
        | "std::collections::Set" | "std::collections::Array" | "std::io::print" | "std::io::println" | "std::io::eprint"
        | "std::io::eprintln" => Vec::new(),
        "std::core::Display" => vec!["std::fmt::Display".to_string()],
        "std::core::catch_unwind" => vec!["std::panic::catch_unwind".to_string()],
        "std::collections::VecDeque" | "std::collections::LinkedList" | "std::collections::BTreeMap" | "std::collections::BTreeSet" => {
            vec![path.to_string()]
        }
        _ if path.starts_with("std::") => vec![format!("crate::{}", &path["std::".len()..])],
        _ if path.starts_with("crate::") => vec![path.to_string()],
        _ => vec![format!("crate::{path}")],
    }
}

fn leaf_name(name: &str) -> &str {
    name.rsplit("::").next().unwrap_or(name)
}

fn collect_support_modules(module: &Module, env: &SemanticEnv, local_names: &OrderedSet<String>) -> SupportModuleTree {
    let mut root = SupportModuleTree::default();
    let included = collect_included_support_names(module, env, local_names);
    for (name, decl) in env.structs.iter() {
        if included.contains(name) {
            insert_support_item(&mut root, name, SupportItem::Struct(decl.clone()));
        }
    }
    for (name, decl) in env.enums.iter() {
        if included.contains(name) {
            insert_support_item(&mut root, name, SupportItem::Enum(decl.clone()));
        }
    }
    for (name, decl) in env.traits.iter() {
        if included.contains(name) {
            insert_support_item(&mut root, name, SupportItem::Trait(decl.clone()));
        }
    }
    for (name, sig) in env.functions.iter() {
        if included.contains(name) {
            insert_support_item(&mut root, name, SupportItem::Function(sig.clone()));
        }
    }
    for (name, ty) in env.type_aliases.iter() {
        if included.contains(name) {
            insert_support_item(&mut root, name, SupportItem::TypeAlias(name.clone(), ty.clone()));
        }
    }
    for (name, ty) in env.consts.iter() {
        if included.contains(name) {
            insert_support_item(&mut root, name, SupportItem::Const(name.clone(), ty.clone()));
        }
    }
    for (name, global) in env.globals.iter() {
        if included.contains(name) {
            insert_support_item(
                &mut root,
                name,
                SupportItem::Global(name.clone(), global.ty.clone(), global.mutable),
            );
        }
    }
    let mut inserted_impls = OrderedSet::new();
    for impl_info in env.impls.iter() {
        let canonical_for_type = canonical_type_name_from_type_ref(&impl_info.for_type_ref).unwrap_or_else(|| env.resolve_alias_path(&impl_info.for_type));
        if !included.contains(&canonical_for_type) {
            continue;
        }
        let key = format!("{} for {}", impl_info.trait_name, canonical_for_type);
        if !inserted_impls.insert(key) {
            continue;
        }
        insert_support_impl(
            &mut root,
            &canonical_for_type,
            build_support_impl(impl_info, env),
        );
    }
    root
}

fn collect_included_support_names(module: &Module, env: &SemanticEnv, local_names: &OrderedSet<String>) -> OrderedSet<String> {
    let mut included = OrderedSet::new();
    let mut queue = collect_support_references(module, env, local_names).items.into_iter().collect::<Vec<_>>();

    while let Some(name) = queue.pop() {
        let Some(name) = canonical_support_name(env, &name) else {
            continue;
        };
        if !included.insert(name.clone()) {
            continue;
        }

        if let Some(decl) = env.structs.get(&name) {
            for field in &decl.fields {
                queue_type_dependencies(&field.ty, env, &mut queue);
            }
        }
        if let Some(decl) = env.enums.get(&name) {
            for variant in &decl.variants {
                for field in &variant.tuple_fields {
                    queue_type_dependencies(field, env, &mut queue);
                }
                for field in &variant.named_fields {
                    queue_type_dependencies(&field.ty, env, &mut queue);
                }
            }
        }
        if let Some(decl) = env.traits.get(&name) {
            for supertrait in &decl.supertraits {
                queue.push(supertrait.clone());
            }
            for assoc in &decl.associated_types {
                if let Some(target) = &assoc.target {
                    queue_type_dependencies(target, env, &mut queue);
                }
            }
            for method in &decl.methods {
                for param in &method.sig.params {
                    queue_type_dependencies(&param.ty, env, &mut queue);
                }
                queue_type_dependencies(&method.sig.return_type, env, &mut queue);
            }
        }
        if let Some(sig) = env.functions.get(&name) {
            for param in &sig.params {
                queue_type_dependencies(&param.ty, env, &mut queue);
            }
            queue_type_dependencies(&sig.return_type, env, &mut queue);
        }
        if let Some(ty) = env.type_aliases.get(&name) {
            queue_type_dependencies(ty, env, &mut queue);
        }
        if let Some(ty) = env.consts.get(&name) {
            queue_type_dependencies(ty, env, &mut queue);
        }
        if let Some(global) = env.globals.get(&name) {
            queue_type_dependencies(&global.ty, env, &mut queue);
        }
        queue_impl_dependencies(&name, env, &mut queue);
    }

    included
}

fn collect_support_references(
    module: &Module,
    env: &SemanticEnv,
    local_names: &OrderedSet<String>,
) -> SupportReferences {
    let mut refs = SupportReferences::default();
    let mut scopes = vec![local_names.clone()];
    walk_module_support_refs(module, env, &mut refs, &mut scopes);
    refs
}

fn walk_module_support_refs(
    module: &Module,
    env: &SemanticEnv,
    refs: &mut SupportReferences,
    scopes: &mut Vec<OrderedSet<String>>,
) {
    for decl in &module.decls {
        walk_decl_support_refs(decl, env, refs, scopes);
    }
}

fn walk_decl_support_refs(
    decl: &Decl,
    env: &SemanticEnv,
    refs: &mut SupportReferences,
    scopes: &mut Vec<OrderedSet<String>>,
) {
    match decl {
        Decl::Meta(meta) if meta.kind == MetaKind::Use => {
            collect_use_targets(&meta.detail, env, &mut refs.items.iter().cloned().collect::<Vec<_>>());
            for target in collect_use_targets_to_vec(&meta.detail, env) {
                refs.items.insert(target);
            }
        }
        Decl::Module(module_decl) => {
            if let Some(scope) = scopes.last_mut() {
                scope.insert(module_decl.name.split("::").next().unwrap_or(&module_decl.name).to_string());
            }
            scopes.push(OrderedSet::new());
            for child in &module_decl.decls {
                walk_decl_support_refs(child, env, refs, scopes);
            }
            scopes.pop();
        }
        Decl::Struct(struct_decl) => {
            for field in &struct_decl.fields {
                walk_type_support_refs(&field.ty, env, refs);
            }
            for predicate in &struct_decl.where_clause {
                walk_where_predicate_support_refs(predicate, env, refs);
            }
        }
        Decl::Enum(enum_decl) => {
            for variant in &enum_decl.variants {
                for field in &variant.tuple_fields {
                    walk_type_support_refs(field, env, refs);
                }
                for field in &variant.named_fields {
                    walk_type_support_refs(&field.ty, env, refs);
                }
            }
            for predicate in &enum_decl.where_clause {
                walk_where_predicate_support_refs(predicate, env, refs);
            }
        }
        Decl::Trait(trait_decl) => {
            for supertrait in &trait_decl.supertraits {
                record_support_ref(supertrait, env, refs, scopes, true);
            }
            for associated_type in &trait_decl.associated_types {
                if let Some(target) = &associated_type.target {
                    walk_type_support_refs(target, env, refs);
                }
            }
            for method in &trait_decl.methods {
                walk_function_support_refs(method, env, refs, scopes);
            }
            for predicate in &trait_decl.where_clause {
                walk_where_predicate_support_refs(predicate, env, refs);
            }
        }
        Decl::Impl(impl_decl) => {
            walk_type_support_refs(&impl_decl.for_type, env, refs);
            if !impl_decl.trait_name.is_empty() {
                record_support_ref(&impl_decl.trait_name, env, refs, scopes, true);
            }
            for associated_type in &impl_decl.associated_types {
                if let Some(target) = &associated_type.target {
                    walk_type_support_refs(target, env, refs);
                }
            }
            for method in &impl_decl.methods {
                walk_function_support_refs(method, env, refs, scopes);
            }
            for predicate in &impl_decl.where_clause {
                walk_where_predicate_support_refs(predicate, env, refs);
            }
        }
        Decl::Function(function_decl) => walk_function_support_refs(function_decl, env, refs, scopes),
        Decl::TypeAlias(type_alias_decl) => {
            if let Some(target) = &type_alias_decl.target {
                walk_type_support_refs(target, env, refs);
            }
        }
        Decl::Const(const_decl) => {
            if let Some(ty) = &const_decl.ty {
                walk_type_support_refs(ty, env, refs);
            }
            walk_expr_support_refs(&const_decl.value, env, refs, scopes);
        }
        Decl::Global(global_decl) => {
            if let Some(ty) = &global_decl.ty {
                walk_type_support_refs(ty, env, refs);
            }
            walk_expr_support_refs(&global_decl.value, env, refs, scopes);
        }
        Decl::Extern(extern_decl) => {
            for function in &extern_decl.functions {
                walk_sig_support_refs(function, env, refs, scopes);
            }
        }
        Decl::Meta(_) => {}
    }
}

fn walk_function_support_refs(
    function_decl: &crate::ast::decl::FunctionDecl,
    env: &SemanticEnv,
    refs: &mut SupportReferences,
    scopes: &mut Vec<OrderedSet<String>>,
) {
    walk_sig_support_refs(&function_decl.sig, env, refs, scopes);
    let mut fn_scope = OrderedSet::new();
    for param in &function_decl.sig.params {
        fn_scope.insert(param.name.clone());
    }
    scopes.push(fn_scope);
    match &function_decl.body {
        FunctionBody::Declaration { .. } => {}
        FunctionBody::Block(block) => walk_block_support_refs(block, env, refs, scopes),
    }
    scopes.pop();
}

fn walk_sig_support_refs(
    sig: &FunctionSig,
    env: &SemanticEnv,
    refs: &mut SupportReferences,
    scopes: &mut Vec<OrderedSet<String>>,
) {
    for param in &sig.params {
        walk_type_support_refs(&param.ty, env, refs);
        if let Some(default_value) = &param.default_value {
            walk_expr_support_refs(default_value, env, refs, scopes);
        }
    }
    walk_type_support_refs(&sig.return_type, env, refs);
    for predicate in &sig.where_clause {
        walk_where_predicate_support_refs(predicate, env, refs);
    }
}

fn walk_where_predicate_support_refs(
    predicate: &crate::ast::decl::WherePredicate,
    env: &SemanticEnv,
    refs: &mut SupportReferences,
) {
    walk_type_support_refs(&predicate.ty, env, refs);
    for bound in &predicate.bounds {
        record_support_ref(bound, env, refs, &mut Vec::new(), true);
    }
}

fn walk_block_support_refs(
    block: &BlockBody,
    env: &SemanticEnv,
    refs: &mut SupportReferences,
    scopes: &mut Vec<OrderedSet<String>>,
) {
    scopes.push(OrderedSet::new());
    for stmt in &block.stmts {
        walk_stmt_support_refs(stmt, env, refs, scopes);
    }
    if let Some(tail) = &block.tail {
        walk_expr_support_refs(tail, env, refs, scopes);
    }
    scopes.pop();
}

fn walk_stmt_support_refs(
    stmt: &Stmt,
    env: &SemanticEnv,
    refs: &mut SupportReferences,
    scopes: &mut Vec<OrderedSet<String>>,
) {
    match stmt {
        Stmt::Requires { .. } | Stmt::Break { .. } | Stmt::Next { .. } => {}
        Stmt::While { condition, body, .. } => {
            walk_expr_support_refs(condition, env, refs, scopes);
            walk_block_support_refs(body, env, refs, scopes);
        }
        Stmt::Loop { body, .. } => walk_block_support_refs(body, env, refs, scopes),
        Stmt::For { pattern, iterable, body, .. } => {
            walk_expr_support_refs(iterable, env, refs, scopes);
            let bound_names = collect_pattern_names(pattern);
            scopes.push(bound_names.into_iter().collect());
            walk_block_support_refs(body, env, refs, scopes);
            scopes.pop();
        }
        Stmt::Return { value, .. } => {
            if let Some(value) = value {
                walk_expr_support_refs(value, env, refs, scopes);
            }
        }
        Stmt::Let {
            pattern,
            value,
            inferred_type,
            ..
        } => {
            if let Some(ty) = inferred_type {
                walk_type_support_refs(ty, env, refs);
            }
            walk_expr_support_refs(value, env, refs, scopes);
            if let Some(scope) = scopes.last_mut() {
                scope.extend(collect_pattern_names(pattern));
            }
        }
        Stmt::Assign { target, value, .. } => {
            walk_expr_support_refs(target, env, refs, scopes);
            walk_expr_support_refs(value, env, refs, scopes);
        }
        Stmt::Expr { expr, .. } => walk_expr_support_refs(expr, env, refs, scopes),
        Stmt::Decl { decl, .. } => walk_decl_support_refs(decl, env, refs, scopes),
        Stmt::Use { path, .. } => {
            for target in collect_use_targets_to_vec(path, env) {
                refs.items.insert(target);
            }
        }
        Stmt::Meta { decl, .. } if decl.kind == MetaKind::Use => {
            for target in collect_use_targets_to_vec(&decl.detail, env) {
                refs.items.insert(target);
            }
        }
        Stmt::Meta { .. } => {}
        Stmt::Function { decl, .. } => {
            if let Some(scope) = scopes.last_mut() {
                scope.insert(decl.sig.name.clone());
            }
            walk_function_support_refs(decl, env, refs, scopes);
        }
    }
}

fn walk_expr_support_refs(
    expr: &Expr,
    env: &SemanticEnv,
    refs: &mut SupportReferences,
    scopes: &mut Vec<OrderedSet<String>>,
) {
    match expr {
        Expr::Integer { .. } | Expr::Float { .. } | Expr::Char { .. } | Expr::String { .. } | Expr::Bool { .. } => {}
        Expr::Name { name, .. } => record_support_ref(name, env, refs, scopes, false),
        Expr::Array { elements, .. } | Expr::Tuple { elements, .. } => {
            for element in elements {
                walk_expr_support_refs(element, env, refs, scopes);
            }
        }
        Expr::StructLiteral { name, fields, .. } => {
            record_support_ref(name, env, refs, scopes, true);
            for (_, value) in fields {
                walk_expr_support_refs(value, env, refs, scopes);
            }
        }
        Expr::Block { block, .. } | Expr::UnsafeBlock { block, .. } => walk_block_support_refs(block, env, refs, scopes),
        Expr::If { branches, else_branch, .. } => {
            for branch in branches {
                match &branch.guard {
                    crate::ast::expr::BranchGuard::Expr(expr) => walk_expr_support_refs(expr, env, refs, scopes),
                    crate::ast::expr::BranchGuard::Let { pattern, value } => {
                        walk_expr_support_refs(value, env, refs, scopes);
                        walk_pattern_support_refs(pattern, env, refs, scopes);
                    }
                }
                walk_block_support_refs(branch.body.as_ref(), env, refs, scopes);
            }
            if let Some(else_branch) = else_branch {
                walk_block_support_refs(else_branch, env, refs, scopes);
            }
        }
        Expr::Call { callee, args, .. } => {
            walk_expr_support_refs(callee, env, refs, scopes);
            for arg in args {
                walk_expr_support_refs(&arg.value, env, refs, scopes);
            }
        }
        Expr::Index { base, index, .. } => {
            walk_expr_support_refs(base, env, refs, scopes);
            walk_expr_support_refs(index, env, refs, scopes);
        }
        Expr::Range { start, end, .. } => {
            walk_expr_support_refs(start, env, refs, scopes);
            walk_expr_support_refs(end, env, refs, scopes);
        }
        Expr::Match { value, arms, .. } => {
            walk_expr_support_refs(value, env, refs, scopes);
            for arm in arms {
                walk_pattern_support_refs(&arm.pattern, env, refs, scopes);
                walk_block_support_refs(&arm.body, env, refs, scopes);
            }
        }
        Expr::Cast { expr, ty, .. } => {
            walk_expr_support_refs(expr, env, refs, scopes);
            walk_type_support_refs(ty, env, refs);
        }
        Expr::Try { expr, .. } => walk_expr_support_refs(expr, env, refs, scopes),
        Expr::Closure { closure, .. } => {
            let mut closure_scope = OrderedSet::new();
            closure_scope.extend(closure.params.iter().cloned());
            scopes.push(closure_scope);
            walk_block_support_refs(&closure.body, env, refs, scopes);
            scopes.pop();
        }
        Expr::Unary { expr, .. } => walk_expr_support_refs(expr, env, refs, scopes),
        Expr::Field { base, .. } => walk_expr_support_refs(base, env, refs, scopes),
        Expr::Binary { left, right, .. } => {
            walk_expr_support_refs(left, env, refs, scopes);
            walk_expr_support_refs(right, env, refs, scopes);
        }
    }
}

fn walk_pattern_support_refs(
    pattern: &Pattern,
    env: &SemanticEnv,
    refs: &mut SupportReferences,
    scopes: &mut Vec<OrderedSet<String>>,
) {
    match pattern {
        Pattern::Tuple { elements, .. } | Pattern::Or { alternatives: elements, .. } => {
            for element in elements {
                walk_pattern_support_refs(element, env, refs, scopes);
            }
        }
        Pattern::Variant {
            enum_name,
            variant_name,
            fields,
            named_fields,
            ..
        } => {
            if let Some(enum_name) = enum_name {
                record_support_ref(enum_name, env, refs, scopes, true);
            } else {
                record_support_ref(variant_name, env, refs, scopes, true);
            }
            for field in fields {
                walk_pattern_support_refs(field, env, refs, scopes);
            }
            for (_, pattern) in named_fields {
                walk_pattern_support_refs(pattern, env, refs, scopes);
            }
        }
        Pattern::Binding { name, .. } => {
            if let Some(scope) = scopes.last_mut() {
                scope.insert(name.clone());
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

fn walk_type_support_refs(ty: &TypeRef, env: &SemanticEnv, refs: &mut SupportReferences) {
    match ty {
        TypeRef::Tuple { elements, .. } => {
            for element in elements {
                walk_type_support_refs(element, env, refs);
            }
        }
        TypeRef::Array { element, .. } => walk_type_support_refs(element, env, refs),
        TypeRef::Named { name, type_args, .. } => {
            if let Some(canonical) = canonical_support_name(env, name) {
                refs.items.insert(canonical.clone());
            }
            for type_arg in type_args {
                walk_type_support_refs(type_arg, env, refs);
            }
        }
        TypeRef::Function {
            params,
            return_type,
            ..
        } => {
            for param in params {
                walk_type_support_refs(param, env, refs);
            }
            walk_type_support_refs(return_type, env, refs);
        }
        TypeRef::DynTrait { trait_name, .. } => {
            if let Some(canonical) = canonical_support_name(env, trait_name) {
                refs.items.insert(canonical);
            }
        }
        TypeRef::Ref { inner, .. } => walk_type_support_refs(inner, env, refs),
        TypeRef::Int { .. }
        | TypeRef::Float { .. }
        | TypeRef::Char { .. }
        | TypeRef::String { .. }
        | TypeRef::Bool { .. }
        | TypeRef::Unit { .. }
        | TypeRef::SelfTy { .. } => {}
    }
}

fn record_support_ref(
    raw_name: &str,
    env: &SemanticEnv,
    refs: &mut SupportReferences,
    scopes: &mut Vec<OrderedSet<String>>,
    type_context: bool,
) {
    if raw_name.is_empty() {
        return;
    }
    if !raw_name.contains("::") && scopes.iter().rev().any(|scope| scope.contains(raw_name)) {
        return;
    }
    if let Some(canonical) = canonical_support_name(env, raw_name) {
        refs.items.insert(canonical.clone());
        if !raw_name.contains("::") || type_context {
            if let Some(use_path) = support_auto_use_path(raw_name, &canonical) {
                refs.use_paths.insert(use_path);
            }
        }
        return;
    }
    if let Some(owner) = canonical_support_owner_name(env, raw_name) {
        refs.items.insert(owner.clone());
        if !raw_name.starts_with("std::") && !raw_name.starts_with("tg_compiler::") && !raw_name.starts_with("crate::") {
            if let Some(use_path) = support_auto_use_path(raw_name, &owner) {
                refs.use_paths.insert(use_path);
            }
        }
    }
}

fn support_auto_use_path(raw_name: &str, canonical: &str) -> Option<String> {
    if raw_name.starts_with("std::") || raw_name.starts_with("tg_compiler::") || raw_name.starts_with("crate::") {
        return None;
    }
    rewrite_simple_use_path(canonical).into_iter().next()
}

fn canonical_support_owner_name(env: &SemanticEnv, name: &str) -> Option<String> {
    let mut current = name;
    while let Some((prefix, _)) = current.rsplit_once("::") {
        if let Some(canonical) = canonical_support_name(env, prefix) {
            return Some(canonical);
        }
        current = prefix;
    }
    None
}

fn collect_use_targets_to_vec(detail: &str, env: &SemanticEnv) -> Vec<String> {
    let mut queue = Vec::new();
    collect_use_targets(detail, env, &mut queue);
    queue
}

fn collect_use_targets(detail: &str, env: &SemanticEnv, queue: &mut Vec<String>) {
    let trimmed = detail.trim();
    if trimmed.is_empty() {
        return;
    }

    if let Some((prefix, inner)) = split_braced_use(trimmed) {
        for item in split_top_level_items(inner) {
            let item = item.trim();
            if item.is_empty() {
                continue;
            }
            if let Some((nested_prefix, nested_inner)) = split_braced_use(item) {
                let combined_prefix = join_use_prefix(prefix, nested_prefix);
                collect_use_targets(&format!("{}{{{}}}", combined_prefix, nested_inner), env, queue);
                continue;
            }
            let target = item.split(" as ").next().unwrap_or(item).trim();
            if target == "*" {
                queue.extend(collect_module_members(prefix, env).into_iter().filter(|name| !skip_support_symbol(name)));
            } else {
                let joined = join_use_prefix(prefix, target);
                if !skip_support_symbol(&joined) {
                    queue.push(joined);
                }
            }
        }
        return;
    }

    let target = trimmed.split(" as ").next().unwrap_or(trimmed).trim();
    if target.is_empty() || skip_support_symbol(target) {
        return;
    }
    if has_exact_support_symbol(env, target) {
        queue.push(target.to_string());
    } else {
        queue.extend(collect_module_members(target, env).into_iter().filter(|name| !skip_support_symbol(name)));
    }
}

fn skip_support_symbol(name: &str) -> bool {
    matches!(
        leaf_name(name),
        "Option"
            | "Result"
            | "Vec"
            | "String"
            | "Bool"
            | "UInt"
            | "Int"
            | "Float"
            | "panic"
            | "Map"
            | "Set"
            | "Array"
            | "print"
            | "println"
            | "eprint"
            | "eprintln"
    )
}

fn split_braced_use(detail: &str) -> Option<(&str, &str)> {
    let mut depth = 0usize;
    let mut start = None;
    for (index, ch) in detail.char_indices() {
        match ch {
            '{' => {
                if depth == 0 {
                    start = Some(index);
                }
                depth += 1;
            }
            '}' => {
                depth = depth.saturating_sub(1);
                if depth == 0 {
                    let brace_start = start?;
                    let prefix = detail[..brace_start].trim().trim_end_matches("::").trim();
                    let inner = detail[brace_start + 1..index].trim();
                    return Some((prefix, inner));
                }
            }
            _ => {}
        }
    }
    None
}

fn split_top_level_items(detail: &str) -> Vec<&str> {
    let mut items = Vec::new();
    let mut start = 0usize;
    let mut depth = 0usize;
    for (index, ch) in detail.char_indices() {
        match ch {
            '{' => depth += 1,
            '}' => depth = depth.saturating_sub(1),
            ',' if depth == 0 => {
                items.push(detail[start..index].trim());
                start = index + 1;
            }
            _ => {}
        }
    }
    items.push(detail[start..].trim());
    items
}

fn join_use_prefix(prefix: &str, suffix: &str) -> String {
    if prefix.is_empty() {
        suffix.to_string()
    } else if suffix.is_empty() {
        prefix.to_string()
    } else {
        format!("{prefix}::{suffix}")
    }
}

fn collect_module_members(prefix: &str, env: &SemanticEnv) -> Vec<String> {
    let module_prefix = format!("{prefix}::");
    let mut members = OrderedSet::new();
    members.extend(env.structs.keys().filter(|name| name.starts_with(&module_prefix)).cloned());
    members.extend(env.enums.keys().filter(|name| name.starts_with(&module_prefix)).cloned());
    members.extend(env.traits.keys().filter(|name| name.starts_with(&module_prefix)).cloned());
    members.extend(env.functions.keys().filter(|name| name.starts_with(&module_prefix)).cloned());
    members.extend(env.type_aliases.keys().filter(|name| name.starts_with(&module_prefix)).cloned());
    members.into_iter().collect()
}

fn has_exact_support_symbol(env: &SemanticEnv, name: &str) -> bool {
    env.structs.contains_key(name)
        || env.enums.contains_key(name)
        || env.traits.contains_key(name)
        || env.functions.contains_key(name)
        || env.type_aliases.contains_key(name)
}

fn canonical_support_name(env: &SemanticEnv, name: &str) -> Option<String> {
    if skip_support_symbol(name) {
        return None;
    }
    if has_exact_support_symbol(env, name) && name.contains("::") {
        return Some(name.to_string());
    }

    let resolved = env.resolve_alias_path(name);
    if has_exact_support_symbol(env, &resolved) && resolved.contains("::") {
        return Some(resolved);
    }

    let suffix = format!("::{}", resolved.rsplit("::").next().unwrap_or(&resolved));
    if let Some(found) = env.structs.keys().filter(|candidate| candidate.ends_with(&suffix)).min().cloned() {
        return Some(found);
    }
    if let Some(found) = env.enums.keys().filter(|candidate| candidate.ends_with(&suffix)).min().cloned() {
        return Some(found);
    }
    if let Some(found) = env.traits.keys().filter(|candidate| candidate.ends_with(&suffix)).min().cloned() {
        return Some(found);
    }
    if let Some(found) = env.functions.keys().filter(|candidate| candidate.ends_with(&suffix)).min().cloned() {
        return Some(found);
    }
    if let Some(found) = env.type_aliases.keys().filter(|candidate| candidate.ends_with(&suffix)).min().cloned() {
        return Some(found);
    }

    None
}

fn queue_type_dependencies(ty: &TypeRef, env: &SemanticEnv, queue: &mut Vec<String>) {
    match ty {
        TypeRef::Tuple { elements, .. } => {
            for element in elements {
                queue_type_dependencies(element, env, queue);
            }
        }
        TypeRef::Array { element, .. } => queue_type_dependencies(element, env, queue),
        TypeRef::Named { name, type_args, .. } => {
            if let Some(name) = canonical_support_name(env, name) {
                if !skip_support_symbol(&name) {
                    queue.push(name);
                }
            }
            for type_arg in type_args {
                queue_type_dependencies(type_arg, env, queue);
            }
        }
        TypeRef::Function { params, return_type, .. } => {
            for param in params {
                queue_type_dependencies(param, env, queue);
            }
            queue_type_dependencies(return_type, env, queue);
        }
        TypeRef::DynTrait { trait_name, .. } => {
            if let Some(name) = canonical_support_name(env, trait_name) {
                if !skip_support_symbol(&name) {
                    queue.push(name);
                }
            }
        }
        TypeRef::Ref { inner, .. } => queue_type_dependencies(inner, env, queue),
        TypeRef::Int { .. }
        | TypeRef::Float { .. }
        | TypeRef::Char { .. }
        | TypeRef::String { .. }
        | TypeRef::Bool { .. }
        | TypeRef::Unit { .. }
        | TypeRef::SelfTy { .. } => {}
    }
}

fn insert_support_item(root: &mut SupportModuleTree, qualified_name: &str, item: SupportItem) {
    let mut segments = qualified_name.split("::").collect::<Vec<_>>();
    if segments.len() < 2 {
        root.items.push(item);
        return;
    }
    if segments.first() == Some(&"std") {
        segments.remove(0);
        if segments.len() < 2 {
            root.items.push(item);
            return;
        }
    }
    let _ = segments.pop();
    let mut node = root;
    for segment in segments {
        node = node.children.entry(segment.to_string()).or_default();
    }
    node.items.push(item);
}

fn insert_support_impl(root: &mut SupportModuleTree, qualified_name: &str, support_impl: SupportImpl) {
    let mut segments = qualified_name.split("::").collect::<Vec<_>>();
    if segments.is_empty() {
        root.impls.push(support_impl);
        return;
    }
    if segments.first() == Some(&"std") {
        segments.remove(0);
    }
    let _ = segments.pop();
    let mut node = root;
    for segment in segments {
        node = node.children.entry(segment.to_string()).or_default();
    }
    node.impls.push(support_impl);
}

fn queue_impl_dependencies(type_name: &str, env: &SemanticEnv, queue: &mut Vec<String>) {
    for impl_info in env.impls.iter() {
        let canonical_for_type = canonical_type_name_from_type_ref(&impl_info.for_type_ref)
            .unwrap_or_else(|| env.resolve_alias_path(&impl_info.for_type));
        if canonical_for_type != type_name {
            continue;
        }
        if !impl_info.trait_name.is_empty() {
            queue.push(impl_info.trait_name.clone());
        }
        for ty in impl_info.associated_types.values() {
            queue_type_dependencies(ty, env, queue);
        }
        for sig in impl_info.methods.values() {
            for param in &sig.params {
                queue_type_dependencies(&param.ty, env, queue);
            }
            queue_type_dependencies(&sig.return_type, env, queue);
        }
    }
}

fn build_support_impl(impl_info: &crate::sema::env::ImplInfo, env: &SemanticEnv) -> SupportImpl {
    let mut type_params = OrderedSet::new();
    collect_support_impl_type_params(&impl_info.for_type_ref, env, &mut type_params);
    for ty in impl_info.associated_types.values() {
        collect_support_impl_type_params(ty, env, &mut type_params);
    }
    for sig in impl_info.methods.values() {
        for param in &sig.params {
            collect_support_impl_type_params(&param.ty, env, &mut type_params);
        }
        collect_support_impl_type_params(&sig.return_type, env, &mut type_params);
    }
    SupportImpl {
        trait_name: impl_info.trait_name.clone(),
        type_params: type_params.into_iter().collect(),
        for_type: impl_info.for_type_ref.clone(),
        methods: impl_info.methods.values().cloned().collect(),
        associated_types: impl_info
            .associated_types
            .iter()
            .map(|(name, ty)| (name.clone(), ty.clone()))
            .collect(),
    }
}

fn collect_support_impl_type_params(ty: &TypeRef, env: &SemanticEnv, params: &mut OrderedSet<String>) {
    match ty {
        TypeRef::Named { name, type_args, .. } => {
            if !name.contains("::")
                && !is_builtin_named_support_name(name)
                && env.canonical_map_key(name, &env.structs).is_none()
                && env.canonical_map_key(name, &env.enums).is_none()
                && env.canonical_map_key(name, &env.traits).is_none()
                && env.resolve_type_alias(name).is_none()
            {
                params.insert(name.clone());
            }
            for type_arg in type_args {
                collect_support_impl_type_params(type_arg, env, params);
            }
        }
        TypeRef::Tuple { elements, .. } => {
            for element in elements {
                collect_support_impl_type_params(element, env, params);
            }
        }
        TypeRef::Array { element, .. } | TypeRef::Ref { inner: element, .. } => {
            collect_support_impl_type_params(element, env, params);
        }
        TypeRef::Function {
            params: fn_params,
            return_type,
            ..
        } => {
            for param in fn_params {
                collect_support_impl_type_params(param, env, params);
            }
            collect_support_impl_type_params(return_type, env, params);
        }
        TypeRef::DynTrait { trait_name, .. } => {
            if !trait_name.contains("::") && env.canonical_map_key(trait_name, &env.traits).is_none() {
                params.insert(trait_name.clone());
            }
        }
        TypeRef::Int { .. }
        | TypeRef::Float { .. }
        | TypeRef::Char { .. }
        | TypeRef::String { .. }
        | TypeRef::Bool { .. }
        | TypeRef::Unit { .. }
        | TypeRef::SelfTy { .. } => {}
    }
}

fn is_builtin_named_support_name(name: &str) -> bool {
    matches!(name, "Option" | "Result" | "Vec" | "List" | "Map" | "Set" | "Array" | "Range" | "Box" | "String" | "Bool" | "UInt" | "U8" | "Int" | "Float" | "str")
        || matches!(name, "u8" | "u16" | "u32" | "u64" | "usize" | "i8" | "i16" | "i32" | "i64" | "f32" | "f64")
}

fn canonical_type_name_from_type_ref(ty: &TypeRef) -> Option<String> {
    match ty {
        TypeRef::Named { name, .. } => Some(name.clone()),
        _ => None,
    }
}

fn collect_pattern_names(pattern: &Pattern) -> Vec<String> {
    let mut names = Vec::new();
    collect_pattern_names_into(pattern, &mut names);
    names
}

fn collect_pattern_names_into(pattern: &Pattern, names: &mut Vec<String>) {
    match pattern {
        Pattern::Binding { name, .. } => names.push(name.clone()),
        Pattern::Tuple { elements, .. } | Pattern::Or { alternatives: elements, .. } => {
            for element in elements {
                collect_pattern_names_into(element, names);
            }
        }
        Pattern::Variant {
            fields,
            named_fields,
            ..
        } => {
            for field in fields {
                collect_pattern_names_into(field, names);
            }
            for (_, pattern) in named_fields {
                collect_pattern_names_into(pattern, names);
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

fn format_support_impl_type_params(type_params: &[String]) -> String {
    if type_params.is_empty() {
        String::new()
    } else {
        format!("<{}>", type_params.join(", "))
    }
}

fn format_support_value_type(ty: &TypeRef) -> Result<String, Stage0Error> {
    match ty {
        TypeRef::String { .. } => Ok("&'static str".to_string()),
        _ => format_type(ty),
    }
}

fn format_support_value_initializer(ty: &TypeRef) -> Result<String, Stage0Error> {
    match ty {
        TypeRef::Int { .. } => Ok("0".to_string()),
        TypeRef::Named { name, .. }
            if matches!(name.as_str(), "UInt" | "U8" | "u8" | "u16" | "u32" | "u64" | "usize" | "i8" | "i16" | "i32" | "i64") =>
        {
            Ok("0".to_string())
        }
        TypeRef::Float { .. } => Ok("0.0".to_string()),
        TypeRef::Named { name, .. } if matches!(name.as_str(), "Float" | "f32" | "f64") => Ok("0.0".to_string()),
        TypeRef::Char { .. } => Ok("'\\0'".to_string()),
        TypeRef::String { .. } => Ok("\"\"".to_string()),
        TypeRef::Bool { .. } => Ok("false".to_string()),
        TypeRef::Unit { .. } => Ok("()".to_string()),
        _ => Ok("panic!(\"support stub\")".to_string()),
    }
}
fn emit_function_body(
    body: &FunctionBody,
    indent_level: usize,
    tail_is_stmt: bool,
    expected_tail_type: Option<&TypeRef>,
    state: &CodegenState,
) -> Result<String, Stage0Error> {
    match body {
        FunctionBody::Declaration { span } => Err(Stage0Error::codegen(
            *span,
            "cannot emit a declaration-only function body".to_string(),
        )),
        FunctionBody::Block(block) => emit_block(block, indent_level, tail_is_stmt, expected_tail_type, state),
    }
}

fn emit_block(
    block: &BlockBody,
    indent_level: usize,
    tail_is_stmt: bool,
    expected_tail_type: Option<&TypeRef>,
    state: &CodegenState,
) -> Result<String, Stage0Error> {
    let mut out = String::new();
    out.push_str("{\n");
    for stmt in &block.stmts {
        writeln!(out, "{}{}", indent(indent_level + 1), emit_stmt(stmt, indent_level + 1, state)?)
            .expect("writing to String must succeed");
    }
    if let Some(tail) = &block.tail {
        let suffix = if tail_is_stmt { ";" } else { "" };
        // For tail expressions in methods (non-unit return), we need to handle self.field specially
        let tail_expr = match expected_tail_type {
            Some(ty) if !is_unit_type(ty) => emit_return_expr(tail, state)?,
            _ => emit_expr_for_expected_type(tail, expected_tail_type, state)?,
        };
        writeln!(
            out,
            "{}{}{}",
            indent(indent_level + 1),
            tail_expr,
            suffix
        )
            .expect("writing to String must succeed");
    }
    write!(out, "{}}}", indent(indent_level)).expect("writing to String must succeed");
    Ok(out)
}

fn emit_stmt(stmt: &Stmt, indent_level: usize, state: &CodegenState) -> Result<String, Stage0Error> {
    match stmt {
        Stmt::Let {
            pattern,
            mutable,
            value,
            ..
        } => Ok(format!(
            "let {}{} = {};",
            if *mutable { "mut " } else { "" },
            emit_pattern(pattern)?,
            emit_expr(value, state)?
        )),
        Stmt::Expr { expr, .. } => Ok(format!("{};", emit_expr(expr, state)?)),
        Stmt::Return { value, .. } => Ok(match value {
            Some(value) => {
                let expr_str = emit_return_expr(value, state)?;
                format!("return {};", expr_str)
            }
            None => "return;".to_string(),
        }),
        Stmt::Assign { target, value, .. } => Ok(format!("{} = {};", emit_assign_target(target, state)?, emit_expr(value, state)?)),
        Stmt::While { condition, body, .. } => Ok(format!("while {} {}", emit_expr(condition, state)?, emit_block(body, indent_level, false, None, state)?)),
        Stmt::Loop { body, .. } => Ok(format!("loop {}", emit_block(body, indent_level, false, None, state)?)),
        Stmt::For {
            pattern,
            iterable,
            body,
            ..
        } => Ok(format!(
            "for {} in {} {}",
            emit_pattern(pattern)?,
            emit_iterable_expr(iterable, state)?,
            emit_block(body, indent_level, false, None, state)?
        )),
        Stmt::Break { .. } => Ok("break;".to_string()),
        Stmt::Next { .. } => Ok("continue;".to_string()),
        Stmt::Use { .. } | Stmt::Meta { .. } | Stmt::Requires { .. } => Ok(String::new()),
        Stmt::Function { decl, .. } => Ok(format!(
            "fn {}{}({}) -> {}{} {}",
            decl.sig.name,
            format_type_params(&decl.sig.type_params),
            format_params_with_body(&decl.sig.params, Some(&decl.body), None, &decl.sig.name, state)?,
            format_type(&decl.sig.return_type)?,
            format_where_clause(&decl.sig.where_clause)?,
            emit_function_body(
                &decl.body,
                indent_level,
                is_unit_type(&decl.sig.return_type),
                Some(&decl.sig.return_type),
                state,
            )?
        )),
        Stmt::Decl { .. } => Err(Stage0Error::codegen(
            stmt.span(),
            "nested declaration lowering is not implemented".to_string(),
        )),
    }
}

fn emit_pattern(pattern: &Pattern) -> Result<String, Stage0Error> {
    emit_pattern_with_state(pattern, None)
}

fn emit_pattern_with_state(pattern: &Pattern, state: Option<&CodegenState>) -> Result<String, Stage0Error> {
    match pattern {
        Pattern::Wildcard { .. } => Ok("_".to_string()),
        Pattern::Binding { name, .. } => Ok(name.clone()),
        Pattern::Integer { value, .. } | Pattern::Float { value, .. } => Ok(value.clone()),
        Pattern::Char { value, .. } => Ok(format!("'{}'", escape_char_literal(*value))),
        Pattern::String { value, .. } => Ok(format!("\"{}\"", escape_string_literal(value))),
        Pattern::Bool { value, .. } => Ok(value.to_string()),
        Pattern::Tuple { elements, .. } => Ok(format!(
            "({})",
            elements
                .iter()
                .map(|element| emit_pattern_with_state(element, state))
                .collect::<Result<Vec<_>, _>>()?
                .join(", ")
        )),
        Pattern::Or { alternatives, .. } => Ok(alternatives
            .iter()
            .map(|alternative| emit_pattern_with_state(alternative, state))
            .collect::<Result<Vec<_>, _>>()?
            .join(" | ")),
        Pattern::Variant {
            enum_name,
            variant_name,
            fields,
            named_fields,
            ..
        } => {
            let resolved_enum_name = enum_name.clone().or_else(|| {
                state.and_then(|codegen_state| codegen_state.variant_owners.get(variant_name).cloned())
            });
            let prefix = resolved_enum_name
                .as_ref()
                .map_or_else(|| variant_name.clone(), |name| format!("{name}::{variant_name}"));
            if !named_fields.is_empty() {
                let fields = named_fields
                    .iter()
                    .map(|(name, pattern)| Ok(format!("{name}: {}", emit_pattern_with_state(pattern, state)?)))
                    .collect::<Result<Vec<_>, Stage0Error>>()?
                    .join(", ");
                Ok(format!("{prefix} {{ {fields} }}"))
            } else if !fields.is_empty() {
                Ok(format!(
                    "{prefix}({})",
                    fields
                        .iter()
                        .map(|field| emit_pattern_with_state(field, state))
                        .collect::<Result<Vec<_>, _>>()?
                        .join(", ")
                ))
            } else {
                Ok(prefix)
            }
        }
    }
}

fn emit_expr(expr: &Expr, state: &CodegenState) -> Result<String, Stage0Error> {
    match expr {
        Expr::Integer { value, .. } | Expr::Float { value, .. } => Ok(value.clone()),
        Expr::Char { value, .. } => Ok(format!("'{}'", escape_char_literal(*value))),
        Expr::String { value, .. } => Ok(format!("\"{}\".to_string()", escape_string_literal(value))),
        Expr::Bool { value, .. } => Ok(value.to_string()),
        Expr::Name { name, .. } => Ok(name.clone()),
        Expr::Array { elements, .. } => Ok(format!(
            "vec![{}]",
            elements.iter().map(|element| emit_expr(element, state)).collect::<Result<Vec<_>, _>>()?.join(", ")
        )),
        Expr::Tuple { elements, .. } => Ok(format!(
            "({})",
            elements.iter().map(|element| emit_expr(element, state)).collect::<Result<Vec<_>, _>>()?.join(", ")
        )),
        Expr::StructLiteral { name, fields, .. } => Ok(format!(
            "{name} {{ {} }}",
            fields
                .iter()
                .map(|(field, value)| Ok(format!("{field}: {}", emit_expr(value, state)?)))
                .collect::<Result<Vec<_>, Stage0Error>>()?
                .join(", ")
        )),
        Expr::Block { block, .. } => emit_block(block.as_ref(), 0, false, None, state),
        Expr::Call { callee, args, .. } => emit_call_expr(callee, args, state),
        Expr::Index { base, index, .. } => {
            let base_expr = emit_expr(base, state)?;
            // Check if base is a boxed type that needs dereferencing
            if is_boxed_type(base, state)? {
                Ok(format!("(*{})[({}) as usize].clone()", base_expr, emit_expr(index, state)?))
            } else {
                Ok(format!("{}[({}) as usize].clone()", base_expr, emit_expr(index, state)?))
            }
        }
        Expr::Range {
            start,
            end,
            inclusive,
            ..
        } => Ok(format!(
            "{}{}{}",
            emit_expr(start, state)?,
            if *inclusive { "..=" } else { ".." },
            emit_expr(end, state)?
        )),
        Expr::Cast { expr, ty, .. } => Ok(format!("(({}) as {})", emit_expr(expr, state)?, format_type(ty)?)),
        Expr::Try { expr, .. } => Ok(format!("{}?", emit_expr(expr, state)?)),
        Expr::Closure { closure, .. } => Ok(format!(
            "move |{}| {}",
            closure.params.join(", "),
            emit_block(&closure.body, 0, false, None, state)?
        )),
        Expr::Unary { op, expr, .. } => {
            let expr_str = emit_expr(expr, state)?;
            match op {
                UnaryOp::Deref => {
                    // Check if we're dereferencing a primitive type (like i64) and handle specially
                    if is_primitive_type(expr)? {
                        Ok(expr_str)
                    } else {
                        Ok(format!("*{expr_str}"))
                    }
                }
                _ => Ok(format!("{}{expr_str}", emit_unary_op(op))),
            }
        }
        Expr::Field { base, field, .. } => {
            let base_expr = emit_expr(base, state)?;
            // Check if base is a boxed type that needs dereferencing
            if is_boxed_type(base, state)? {
                Ok(format!("(*{}).{}", base_expr, field))
            } else {
                Ok(format!("{}.{}", base_expr, field))
            }
        }
        Expr::Binary {
            left,
            op: BinaryOp::Add,
            right,
            ..
        } => {
            if is_stringy_expr(left, state) || is_stringy_expr(right, state) {
                Ok(format!(
                    "format!(\"{{}}{{}}\", {}, {})",
                    emit_concat_expr(left, state)?,
                    emit_concat_expr(right, state)?
                ))
            } else {
                Ok(format!("{} + {}", emit_expr(left, state)?, emit_expr(right, state)?))
            }
        }
        Expr::Binary { left, op, right, .. } => Ok(format!("{} {} {}", emit_expr(left, state)?, emit_binary_op(op), emit_expr(right, state)?)),
        Expr::If {
            branches,
            else_branch,
            ..
        } => {
            let mut out = String::new();
            for (index, branch) in branches.iter().enumerate() {
                let prefix = if index == 0 { "if" } else { "else if" };
                write!(out, "{prefix} {} {}", emit_branch_guard(&branch.guard, state)?, emit_block(branch.body.as_ref(), 0, false, None, state)?)
                    .expect("writing to String must succeed");
                if index + 1 < branches.len() || else_branch.is_some() {
                    out.push(' ');
                }
            }
            if let Some(else_branch) = else_branch {
                write!(out, "else {}", emit_block(else_branch, 0, false, None, state)?).expect("writing to String must succeed");
            }
            Ok(out)
        }
        Expr::UnsafeBlock { block, .. } => Ok(format!("unsafe {}", emit_block(block.as_ref(), 0, false, None, state)?)),
        Expr::Match { value, arms, .. } => {
            let arms = arms
                .iter()
                .map(|arm| Ok(format!("{} => {}", emit_pattern_with_state(&arm.pattern, Some(state))?, emit_block(&arm.body, 0, false, None, state)?)))
                .collect::<Result<Vec<_>, Stage0Error>>()?
                .join(", ");
            Ok(format!("match {} {{ {} }}", emit_expr(value, state)?, arms))
        }
    }
}

fn emit_call_expr(callee: &Expr, args: &[crate::ast::expr::CallArg], state: &CodegenState) -> Result<String, Stage0Error> {
    if let Some(lowered) = emit_named_call_expr(callee, args, state)? {
        return Ok(lowered);
    }
    if let Some(lowered) = emit_field_call_expr(callee, args, state)? {
        return Ok(lowered);
    }
    let param_types = match callee {
        Expr::Name { name, .. } => state.function_params.get(name),
        _ => None,
    };
    // Check if this is a method call (callee is a field expression)
    let is_method_call = matches!(callee, Expr::Field { .. });
    // Get the method name if it's a method call
    let method_name = match callee {
        Expr::Field { field, .. } => Some(field.as_str()),
        _ => None,
    };
    // Trait methods that expect &self and &other need the argument passed by reference
    // For method calls, args only contains non-self arguments, so all args need &
    let trait_methods_requiring_ref = ["eq", "ne", "cmp", "partial_cmp", "lt", "le", "gt", "ge"];
    let needs_ref = is_method_call && method_name.is_some_and(|m| trait_methods_requiring_ref.contains(&m));
    Ok(format!(
        "{}({})",
        emit_callee_expr(callee, state)?,
        args.iter()
            .enumerate()
            .map(|(index, arg)| {
                let emitted = emit_call_arg_expr(&arg.value, param_types.and_then(|params| params.get(index)), state)?;
                // For trait methods like eq, cmp, etc., pass all arguments by reference
                // (method calls only have non-self args in the args array)
                if needs_ref {
                    Ok(format!("&{}", emitted))
                } else {
                    Ok(emitted)
                }
            })
            .collect::<Result<Vec<_>, _>>()?
            .join(", ")
    ))
}

fn emit_named_call_expr(
    callee: &Expr,
    args: &[crate::ast::expr::CallArg],
    state: &CodegenState,
) -> Result<Option<String>, Stage0Error> {
    let Expr::Name { name, .. } = callee else {
        return Ok(None);
    };
    let lowered = match (name.as_str(), args) {
        ("assert", [arg]) | ("std::test::assert", [arg]) => {
            format!("assert!({})", emit_expr(&arg.value, state)?)
        }
        ("assert_true", [arg]) | ("std::test::assert_true", [arg]) => {
            format!("assert!({})", emit_expr(&arg.value, state)?)
        }
        ("assert_false", [arg]) | ("std::test::assert_false", [arg]) => {
            format!("assert!(!({}))", emit_expr(&arg.value, state)?)
        }
        ("assert_eq", [left, right]) | ("std::test::assert_eq", [left, right]) => {
            format!("assert_eq!({}, {})", emit_expr(&left.value, state)?, emit_expr(&right.value, state)?)
        }
        ("panic", [arg]) => format!("panic!({})", emit_expr(&arg.value, state)?),
        ("print", [arg]) | ("std::io::print", [arg]) => {
            format!("print!(\"{{}}\", {})", emit_expr(&arg.value, state)?)
        }
        ("println", [arg]) | ("std::io::println", [arg]) => {
            format!("println!(\"{{}}\", {})", emit_expr(&arg.value, state)?)
        }
        ("eprint", [arg]) | ("std::io::eprint", [arg]) => {
            format!("eprint!(\"{{}}\", {})", emit_expr(&arg.value, state)?)
        }
        ("eprintln", [arg]) | ("std::io::eprintln", [arg]) => {
            format!("eprintln!(\"{{}}\", {})", emit_expr(&arg.value, state)?)
        }
        ("Map::new", []) | ("HashMap::new", []) | ("BTreeMap::new", []) | ("std::collections::Map::new", []) => {
            "BTreeMap::<(), ()>::new()".to_string()
        }
        ("VecDeque::new", []) | ("std::collections::VecDeque::new", []) => {
            "std::collections::VecDeque::<()>::new()".to_string()
        }
        ("LinkedList::new", []) | ("std::collections::LinkedList::new", []) => {
            "std::collections::LinkedList::<()>::new()".to_string()
        }
        ("Vec::new", []) => "Vec::<i64>::new()".to_string(),
        ("Option::None", []) => "Option::<()>::None".to_string(),
        ("Option::Some", [arg]) => format!("Option::Some({})", emit_expr(&arg.value, state)?),
        ("Result::Ok", [arg]) => format!("Result::<_, ()>::Ok({})", emit_expr(&arg.value, state)?),
        ("Result::Err", [arg]) => format!("Result::<(), _>::Err({})", emit_expr(&arg.value, state)?),
        ("__intrinsic_int_to_float", [arg]) => format!("(({}) as f64)", emit_expr(&arg.value, state)?),
        ("__intrinsic_float_to_int", [arg]) => format!("(({}) as i64)", emit_expr(&arg.value, state)?),
        ("__intrinsic_pow", [left, right]) => {
            format!("({}).powf({})", emit_expr(&left.value, state)?, emit_expr(&right.value, state)?)
        }
        ("__intrinsic_exp", [arg]) => format!("({}).exp()", emit_expr(&arg.value, state)?),
        ("__intrinsic_sqrt", [arg]) => format!("({}).sqrt()", emit_expr(&arg.value, state)?),
        ("std::env::var", [arg]) => format!("std::env::var({}).ok()", emit_expr(&arg.value, state)?),
        ("read_file", [arg]) | ("fs::read_file", [arg]) | ("std::fs::read_file", [arg]) => {
            format!("std::fs::read_to_string({}).map_err(|e| e.to_string())", emit_expr(&arg.value, state)?)
        }
        ("write_file", [path, data]) | ("fs::write_file", [path, data]) | ("std::fs::write_file", [path, data]) => {
            format!(
                "std::fs::write({}, {}).map_err(|e| e.to_string())",
                emit_expr(&path.value, state)?,
                emit_expr(&data.value, state)?
            )
        }
        ("emit32_le", [buffer, value]) => format!(
            "emit32_le({}, {})",
            emit_expr(&buffer.value, state)?,
            emit_expr_as_unsigned(&value.value, "u32", state)?
        ),
        ("emit16_le", [buffer, value]) => format!(
            "emit16_le({}, {})",
            emit_expr(&buffer.value, state)?,
            emit_expr_as_unsigned(&value.value, "u16", state)?
        ),
        _ => return Ok(None),
    };
    Ok(Some(lowered))
}

fn emit_field_call_expr(
    callee: &Expr,
    args: &[crate::ast::expr::CallArg],
    state: &CodegenState,
) -> Result<Option<String>, Stage0Error> {
    let Expr::Field { base, field, .. } = callee else {
        return Ok(None);
    };
    let base_expr = emit_expr(base, state)?;
    let lowered = match (field.as_str(), args) {
        ("char_at", [arg]) => format!(
            "{}.chars().nth(({}) as usize).unwrap()",
            base_expr,
            emit_expr(&arg.value, state)?
        ),
        ("len", []) => format!("({}.len() as i64)", base_expr),
        ("trim", []) => format!("{}.trim().to_string()", base_expr),
        ("trim_end", []) => format!("{}.trim_end().to_string()", base_expr),
        ("trim_end", [arg]) => format!(
            "{}.trim_end_matches({})",
            base_expr,
            emit_expr(&arg.value, state)?
        ),
        ("get", [arg]) => {
            // For Map::get - use & for key
            let key = emit_expr(&arg.value, state)?;
            format!("{}.get(&{})", base_expr, key)
        }
        ("split", [arg]) => format!(
            "{}.split({}).map(str::to_string).collect::<Vec<_>>()",
            base_expr,
            emit_expr(&arg.value, state)?
        ),
        ("split_whitespace", []) => format!(
            "{}.split_whitespace().map(str::to_string).collect::<Vec<_>>()",
            base_expr
        ),
        ("map", [arg]) => format!(
            "({}).into_iter().map({}).collect::<Vec<_>>()",
            base_expr,
            emit_expr(&arg.value, state)?
        ),
        ("filter", [arg]) => format!(
            "({}).into_iter().filter({}).collect::<Vec<_>>()",
            base_expr,
            emit_filter_predicate_expr(&arg.value, state)?
        ),
        ("fold", [init, arg]) => format!(
            "({}).into_iter().fold({}, {})",
            base_expr,
            emit_expr(&init.value, state)?,
            emit_expr(&arg.value, state)?
        ),
        ("any", [arg]) => format!(
            "({}).into_iter().any({})",
            base_expr,
            emit_expr(&arg.value, state)?
        ),
        ("count", []) => format!("(({}).into_iter().count() as i64)", base_expr),
        ("union", [arg]) => format!(
            "{}.union(&{}).cloned().collect::<BTreeSet<_>>()",
            base_expr,
            emit_expr(&arg.value, state)?
        ),
        ("intersection", [arg]) => format!(
            "{}.intersection(&{}).cloned().collect::<BTreeSet<_>>()",
            base_expr,
            emit_expr(&arg.value, state)?
        ),
        ("difference", [arg]) => format!(
            "{}.difference(&{}).cloned().collect::<BTreeSet<_>>()",
            base_expr,
            emit_expr(&arg.value, state)?
        ),
        ("is_subset", [arg]) => format!("{}.is_subset(&{})", base_expr, emit_expr(&arg.value, state)?),
        ("is_superset", [arg]) => format!("{}.is_superset(&{})", base_expr, emit_expr(&arg.value, state)?),
        ("is_empty", []) => format!("{}.is_empty()", base_expr),
        ("collect", []) => format!("({})", base_expr),
        ("into_iter", []) => format!("({})", base_expr),
        ("find", [arg]) => format!(
            "{}.find(&{}).map(|index| (index as i64))",
            base_expr,
            emit_expr(&arg.value, state)?
        ),
        ("replace", [from, to]) => format!(
            "{}.replace(&{}, &{}.to_string())",
            base_expr,
            emit_expr(&from.value, state)?,
            emit_expr(&to.value, state)?
        ),
        ("sqrt", []) => format!("({}).sqrt()", base_expr),
        ("exp", []) => format!("({}).exp()", base_expr),
        ("to_string", []) => format!("({}).to_string()", base_expr),
        ("unwrap_err", []) => format!("{}.unwrap_err()", base_expr),
        ("is_digit", []) => format!("{}.is_ascii_digit()", base_expr),
        ("is_alphabetic", []) => format!("{}.is_alphabetic()", base_expr),
        ("is_alphanumeric", []) => format!("{}.is_alphanumeric()", base_expr),
        ("is_numeric", []) => format!("{}.is_numeric()", base_expr),
        ("is_whitespace", []) => format!("{}.is_whitespace()", base_expr),
        ("lines", []) => format!("{}.lines().map(str::to_string).collect::<Vec<_>>()", base_expr),
        // Map methods that need & for keys
        ("contains_key", [arg]) => format!(
            "{}.contains_key(&{})",
            base_expr,
            emit_expr(&arg.value, state)?
        ),
        ("remove", [arg]) => format!(
            "{}.remove(&{})",
            base_expr,
            emit_expr(&arg.value, state)?
        ),
        ("insert", [key, value]) => format!(
            "{}.insert({}, {})",
            base_expr,
            emit_expr(&key.value, state)?,
            emit_expr(&value.value, state)?
        ),
        // String methods that need & for the argument
        ("contains" | "starts_with" | "ends_with", [arg]) => format!(
            "{}.{}({})",
            base_expr,
            field,
            emit_expr(&arg.value, state)?
        ),
        // Push method for Vec - takes ownership
        ("push", [arg]) => format!(
            "{}.push({})",
            base_expr,
            emit_expr(&arg.value, state)?
        ),
        // Clone method for owned values
        ("clone", []) => {
            // Check if base is a boxed type that needs dereferencing
            if is_boxed_type(base, state)? {
                format!("(*{}).clone()", base_expr)
            } else {
                format!("{}.clone()", base_expr)
            }
        }
        _ => return Ok(None),
    };
    Ok(Some(lowered))
}

fn emit_callee_expr(expr: &Expr, state: &CodegenState) -> Result<String, Stage0Error> {
    match expr {
        Expr::Field { base, field, .. } => Ok(format!("{}.{}", emit_expr(base, state)?, field)),
        Expr::Index { base, index, .. } => Ok(format!("{}[({}) as usize]", emit_expr(base, state)?, emit_expr(index, state)?)),
        _ => emit_expr(expr, state),
    }
}

fn emit_expr_for_expected_type(expr: &Expr, expected_type: Option<&TypeRef>, state: &CodegenState) -> Result<String, Stage0Error> {
    match expected_type {
        Some(TypeRef::Ref { .. }) => emit_expr(expr, state),
        Some(TypeRef::Function { .. }) if matches!(expr, Expr::Closure { .. }) => {
            Ok(format!("Box::new({})", emit_move_closure_expr(expr, state)?))
        }
        Some(TypeRef::Function { .. }) if matches!(expr, Expr::Name { .. } | Expr::Field { .. }) => {
            Ok(format!("Box::new({})", emit_expr(expr, state)?))
        }
        Some(TypeRef::Named { name, .. }) if name == "Option" || name == "Result" || name == "Vec" || name == "BTreeMap" => {
            // Add explicit type annotations for generic types
            match expr {
                Expr::Call { callee, args, .. } => {
                    if let Expr::Name { name: callee_name, .. } = callee.as_ref() {
                        match callee_name.as_str() {
                            "Option::None" => Ok("Option::<()>::None".to_string()),
                            "Result::Ok" if args.len() == 1 => {
                                Ok(format!("Result::<_, ()>::Ok({})", emit_expr(&args[0].value, state)?))
                            }
                            "Result::Err" if args.len() == 1 => {
                                Ok(format!("Result::<(), _>::Err({})", emit_expr(&args[0].value, state)?))
                            }
                            "Vec::new" => Ok("Vec::<()>::new()".to_string()),
                            "BTreeMap::new" => Ok("BTreeMap::<(), ()>::new()".to_string()),
                            _ => emit_expr(expr, state),
                        }
                    } else {
                        emit_expr(expr, state)
                    }
                }
                _ => emit_expr(expr, state),
            }
        }
        _ => emit_expr(expr, state),
    }
}

fn emit_call_arg_expr(expr: &Expr, param_type: Option<&TypeRef>, state: &CodegenState) -> Result<String, Stage0Error> {
    // Check if we need to box closures when passed to functions expecting Fn
    match param_type {
        Some(TypeRef::Function { .. }) if matches!(expr, Expr::Closure { .. }) => {
            Ok(format!("Box::new({})", emit_move_closure_expr(expr, state)?))
        }
        Some(TypeRef::Function { .. }) if matches!(expr, Expr::Name { .. } | Expr::Field { .. }) => {
            Ok(format!("Box::new({})", emit_expr(expr, state)?))
        }
        _ => emit_expr_for_expected_type(expr, param_type, state),
    }
}


fn emit_move_closure_expr(expr: &Expr, state: &CodegenState) -> Result<String, Stage0Error> {
    match expr {
        Expr::Closure { closure, .. } => Ok(format!(
            "move |{}| {}",
            closure.params.join(", "),
            emit_block(&closure.body, 0, false, None, state)?
        )),
        _ => emit_expr(expr, state),
    }
}

fn emit_filter_predicate_expr(expr: &Expr, state: &CodegenState) -> Result<String, Stage0Error> {
    match expr {
        Expr::Closure { closure, .. } if closure.params.len() == 1 => {
            let param = &closure.params[0];
            let mut out = String::new();
            write!(out, "|{param}| {{ let {param} = {param}.clone(); ").expect("writing to String must succeed");
            for stmt in &closure.body.stmts {
                write!(out, "{} ", emit_stmt(stmt, 0, state)?).expect("writing to String must succeed");
            }
            if let Some(tail) = &closure.body.tail {
                write!(out, "{} ", emit_expr(tail, state)?).expect("writing to String must succeed");
            }
            out.push('}');
            Ok(out)
        }
        _ => emit_expr(expr, state),
    }
}

/// Emit a return expression, adding .clone() for self.field accesses.
/// Also handles boxing of closures when needed.
fn emit_return_expr(expr: &Expr, state: &CodegenState) -> Result<String, Stage0Error> {
    // For closures being returned, we need to box them with move
    if matches!(expr, Expr::Closure { .. }) {
        return Ok(format!("Box::new({})", emit_move_closure_expr(expr, state)?));
    }
    match expr {
        Expr::Field { base, field, .. } => {
            if let Expr::Name { name, .. } = base.as_ref() {
                if name == "self" {
                    return Ok(format!("self.{field}.clone()"));
                }
            }
            emit_expr(expr, state)
        }
        Expr::Name { name, .. } if name == "self" => Ok("self.clone()".to_string()),
        _ => emit_expr(expr, state),
    }
}

fn emit_expr_as_unsigned(expr: &Expr, target: &str, state: &CodegenState) -> Result<String, Stage0Error> {
    match expr {
        Expr::Binary { left, op, right, .. }
            if matches!(
                op,
                BinaryOp::BitOr
                    | BinaryOp::BitXor
                    | BinaryOp::BitAnd
                    | BinaryOp::Shl
                    | BinaryOp::Shr
                    | BinaryOp::Add
                    | BinaryOp::Sub
                    | BinaryOp::Mul
                    | BinaryOp::Div
                    | BinaryOp::Mod
            ) =>
        {
            Ok(format!(
                "(({} {} {}) as {target})",
                emit_expr_as_unsigned(left, target, state)?,
                emit_binary_op(op),
                emit_expr_as_unsigned(right, target, state)?
            ))
        }
        Expr::Unary { op, expr, .. } if matches!(op, UnaryOp::Neg | UnaryOp::BitNot | UnaryOp::Deref) => Ok(format!(
            "(({}{}) as {target})",
            emit_unary_op(op),
            emit_expr_as_unsigned(expr, target, state)?
        )),
        Expr::Cast { expr, .. } => Ok(format!("(({}) as {target})", emit_expr(expr, state)?)),
        _ => Ok(format!("(({}) as {target})", emit_expr(expr, state)?)),
    }
}

fn emit_assign_target(expr: &Expr, state: &CodegenState) -> Result<String, Stage0Error> {
    match expr {
        Expr::Index { base, index, .. } => Ok(format!("{}[({}) as usize]", emit_expr(base, state)?, emit_expr(index, state)?)),
        Expr::Field { base, field, .. } => Ok(format!("{}.{}", emit_expr(base, state)?, field)),
        Expr::Unary { op: UnaryOp::Deref, expr, .. } => Ok(format!("*{}", emit_expr(expr, state)?)),
        _ => emit_expr(expr, state),
    }
}

fn emit_iterable_expr(expr: &Expr, state: &CodegenState) -> Result<String, Stage0Error> {
    match expr {
        Expr::Range { .. }
        | Expr::Unary {
            op: UnaryOp::Borrow | UnaryOp::BorrowMut,
            ..
        } => emit_expr(expr, state),
        Expr::Call { callee, .. }
            if matches!(callee.as_ref(), Expr::Field { field, .. } if field == "iter") =>
        {
            emit_expr(expr, state)
        }
        _ => Ok(format!("({}).clone()", emit_expr(expr, state)?)),
    }
}

fn emit_branch_guard(guard: &crate::ast::expr::BranchGuard, state: &CodegenState) -> Result<String, Stage0Error> {
    match guard {
        crate::ast::expr::BranchGuard::Expr(expr) => emit_expr(expr, state),
        crate::ast::expr::BranchGuard::Let { pattern, value } => {
            Ok(format!("let {} = {}", emit_pattern(pattern)?, emit_expr(value, state)?))
        }
    }
}

fn emit_binary_op(op: &BinaryOp) -> &'static str {
    match op {
        BinaryOp::Or => "||",
        BinaryOp::And => "&&",
        BinaryOp::BitOr => "|",
        BinaryOp::BitXor => "^",
        BinaryOp::BitAnd => "&",
        BinaryOp::Shl => "<<",
        BinaryOp::Shr => ">>",
        BinaryOp::Add => "+",
        BinaryOp::Sub => "-",
        BinaryOp::Mul => "*",
        BinaryOp::Div => "/",
        BinaryOp::Mod => "%",
        BinaryOp::Eq => "==",
        BinaryOp::NotEq => "!=",
        BinaryOp::Lt => "<",
        BinaryOp::LtEq => "<=",
        BinaryOp::Gt => ">",
        BinaryOp::GtEq => ">=",
    }
}

fn emit_unary_op(op: &UnaryOp) -> &'static str {
    match op {
        UnaryOp::Not => "!",
        UnaryOp::BitNot => "~",
        UnaryOp::Neg => "-",
        UnaryOp::Deref => "*",
        UnaryOp::Borrow => "&",
        UnaryOp::BorrowMut => "&mut ",
    }
}

fn indent(level: usize) -> String {
    "    ".repeat(level)
}

#[must_use]
pub fn gen_dyn_ref(trait_name: &str) -> String {
    format!("Box<dyn {trait_name}>")
}

#[must_use]
pub fn rustc_check_command(path: &Path) -> Command {
    let mut command = Command::new(rustc_executable());
    command.arg("--crate-type=lib");
    command.arg("--emit=metadata");
    command.arg("-o");
    command.arg(metadata_output_path(path));
    command.arg(path);
    command
}

/// Run `rustc` in metadata-only mode against the provided source file.
///
/// # Errors
/// Returns `Stage0Error` if `rustc` cannot be launched or if the input file
/// fails Rust compilation.
pub fn rustc_check(path: &Path) -> Result<(), Stage0Error> {
    let output = rustc_check_command(path).output().map_err(|error| {
        Stage0Error::codegen(
            Span::new(1, 1, 0, 0),
            format!("failed to execute rustc metadata check: {error}"),
        )
    })?;
    if output.status.success() {
        Ok(())
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        Err(Stage0Error::codegen(
            Span::new(1, 1, 0, 0),
            format!("rustc metadata check failed for {}: {stderr}", path.display()),
        ))
    }
}

fn metadata_output_path(path: &Path) -> String {
    path.with_extension("rmeta").to_string_lossy().into_owned()
}

fn rustc_executable() -> String {
    if let Ok(rustc) = env::var("RUSTC") {
        return rustc;
    }

    if let Ok(home) = env::var("HOME") {
        let candidate = Path::new(&home).join(".cargo/bin/rustc");
        if candidate.is_file() {
            return candidate.to_string_lossy().into_owned();
        }
    }

    "rustc".to_string()
}

fn format_params(params: &[crate::ast::decl::Param]) -> Result<String, Stage0Error> {
    format_params_with_body(params, None, None, "", &CodegenState::empty())
}

fn format_params_with_body(
    params: &[crate::ast::decl::Param],
    body: Option<&FunctionBody>,
    trait_name: Option<&str>,
    method_name: &str,
    state: &CodegenState,
) -> Result<String, Stage0Error> {
    let mutable_self = trait_name
        .filter(|name| !name.is_empty())
        .is_some_and(|name| state.mutable_trait_methods.contains(&trait_method_key(name, method_name)))
        || body.is_some_and(function_body_mutates_self);
    params
        .iter()
        .map(|param| {
            Ok(if param.name == "self" {
                match &param.ty {
                    TypeRef::Ref { mutable: true, .. } => "&mut self".to_string(),
                    TypeRef::Ref { .. } => "&self".to_string(),
                    _ if param.mutable || mutable_self => "&mut self".to_string(),
                    _ => "&self".to_string(),
                }
            } else {
                format!("{}: {}", param.name, format_type(&param.ty)?)
            })
        })
        .collect::<Result<Vec<_>, _>>()
        .map(|parts| parts.join(", "))
}

fn function_body_mutates_self(body: &FunctionBody) -> bool {
    match body {
        FunctionBody::Declaration { .. } => false,
        FunctionBody::Block(block) => {
            block.stmts.iter().any(stmt_mutates_self) || block.tail.as_ref().is_some_and(expr_mutates_self)
        }
    }
}

fn stmt_mutates_self(stmt: &Stmt) -> bool {
    match stmt {
        Stmt::Assign { target, .. } => expr_roots_in_self(target),
        Stmt::While { body, .. } | Stmt::Loop { body, .. } | Stmt::For { body, .. } => {
            body.stmts.iter().any(stmt_mutates_self) || body.tail.as_ref().is_some_and(expr_mutates_self)
        }
        Stmt::Expr { expr, .. } => expr_mutates_self(expr),
        Stmt::Function { decl, .. } => function_body_mutates_self(&decl.body),
        Stmt::Decl { .. }
        | Stmt::Let { .. }
        | Stmt::Return { .. }
        | Stmt::Break { .. }
        | Stmt::Next { .. }
        | Stmt::Use { .. }
        | Stmt::Meta { .. }
        | Stmt::Requires { .. } => false,
    }
}

fn expr_mutates_self(expr: &Expr) -> bool {
    match expr {
        Expr::Block { block, .. } | Expr::UnsafeBlock { block, .. } => {
            block.stmts.iter().any(stmt_mutates_self) || block.tail.as_ref().is_some_and(expr_mutates_self)
        }
        Expr::If {
            branches,
            else_branch,
            ..
        } => {
            branches.iter().any(|branch| {
                branch.body.stmts.iter().any(stmt_mutates_self)
                    || branch.body.tail.as_ref().is_some_and(expr_mutates_self)
            }) || else_branch.as_ref().is_some_and(|block| {
                block.stmts.iter().any(stmt_mutates_self) || block.tail.as_ref().is_some_and(expr_mutates_self)
            })
        }
        Expr::Match { arms, .. } => arms.iter().any(|arm| {
            arm.body.stmts.iter().any(stmt_mutates_self) || arm.body.tail.as_ref().is_some_and(expr_mutates_self)
        }),
        _ => false,
    }
}

fn expr_roots_in_self(expr: &Expr) -> bool {
    match expr {
        Expr::Name { name, .. } => name == "self",
        Expr::Field { base, .. } | Expr::Index { base, .. } => expr_roots_in_self(base),
        Expr::Unary {
            op: UnaryOp::Deref,
            expr,
            ..
        } => expr_roots_in_self(expr),
        _ => false,
    }
}

fn format_type_params(type_params: &[crate::ast::decl::TypeParam]) -> String {
    if type_params.is_empty() {
        String::new()
    } else {
        format!(
            "<{}>",
            type_params
                .iter()
                .map(|param| {
                    if param.bounds.is_empty() {
                        param.name.clone()
                    } else {
                        let bounds = param
                            .bounds
                            .iter()
                            .map(|s| qualify_rust_path(&qualify_std_trait(s.as_str())))
                            .collect::<Vec<_>>()
                            .join(" + ");
                        format!("{}: {}", param.name, bounds)
                    }
                })
                .collect::<Vec<_>>()
                .join(", ")
        )
    }
}

/// Qualify standard library traits to avoid conflicts with user-defined traits.
fn qualify_std_trait(name: &str) -> String {
    match name {
        "Display" => "std::fmt::Display".to_string(),
        "Clone" => "std::clone::Clone".to_string(),
        "Copy" => "std::marker::Copy".to_string(),
        "Ord" => "std::cmp::Ord".to_string(),
        "PartialOrd" => "std::cmp::PartialOrd".to_string(),
        "Eq" => "std::cmp::Eq".to_string(),
        "PartialEq" => "std::cmp::PartialEq".to_string(),
        "Hash" => "std::hash::Hash".to_string(),
        "Default" => "std::default::Default".to_string(),
        "Iterator" => "std::iter::Iterator".to_string(),
        "IntoIterator" => "std::iter::IntoIterator".to_string(),
        "From" => "std::convert::From".to_string(),
        "Into" => "std::convert::Into".to_string(),
        "AsRef" => "std::convert::AsRef".to_string(),
        "AsMut" => "std::convert::AsMut".to_string(),
        "Drop" => "std::ops::Drop".to_string(),
        "Send" => "std::marker::Send".to_string(),
        "Sync" => "std::marker::Sync".to_string(),
        "Sized" => "std::marker::Sized".to_string(),
        "Unpin" => "std::marker::Unpin".to_string(),
        "Fn" => "std::ops::Fn".to_string(),
        "FnMut" => "std::ops::FnMut".to_string(),
        "FnOnce" => "std::ops::FnOnce".to_string(),
        _ => name.to_string(),
    }
}

fn format_supertraits(supertraits: &[String]) -> String {
    if supertraits.is_empty() {
        String::new()
    } else {
        format!(": {}", supertraits.iter().map(|s| qualify_rust_path(&qualify_std_trait(s))).collect::<Vec<_>>().join(" + "))
    }
}

fn qualify_rust_path(name: &str) -> String {
    let is_real_rust_std = matches!(
        name,
        n if n.starts_with("std::ops::")
            || n.starts_with("std::fmt::")
            || n.starts_with("std::cmp::")
            || n.starts_with("std::hash::")
            || n.starts_with("std::default::")
            || n.starts_with("std::iter::")
            || n.starts_with("std::collections::VecDeque")
            || n.starts_with("std::collections::LinkedList")
            || n.starts_with("std::collections::BTreeMap")
            || n.starts_with("std::collections::BTreeSet")
            || n.starts_with("std::convert::")
            || n.starts_with("std::marker::")
            || n.starts_with("std::clone::")
    );
    let rewritten = match name {
        "std::core::Option" => "Option".to_string(),
        "std::core::Result" => "Result".to_string(),
        "std::core::Vec" => "Vec".to_string(),
        "std::core::String" => "String".to_string(),
        "std::core::Bool" => "bool".to_string(),
        "std::core::UInt" => "u64".to_string(),
        "std::core::Int" => "i64".to_string(),
        "std::core::Float" => "f64".to_string(),
        "std::collections::Vec" => "Vec".to_string(),
        "std::collections::Map" => "Map".to_string(),
        "std::collections::Set" => "Set".to_string(),
        "std::collections::Array" => "Array".to_string(),
        _ if name.starts_with("std::") && !is_real_rust_std => {
            format!("crate::{}", &name["std::".len()..])
        }
        _ => name.to_string(),
    };
    if rewritten.contains("::") && !is_real_rust_std && !rewritten.starts_with("core::") && !rewritten.starts_with("crate::") {
        format!("crate::{rewritten}")
    } else {
        rewritten
    }
}

fn format_where_clause(predicates: &[crate::ast::decl::WherePredicate]) -> Result<String, Stage0Error> {
    if predicates.is_empty() {
        Ok(String::new())
    } else {
        Ok(format!(
            " where {}",
            predicates
                .iter()
                .map(|predicate| {
                    let bounds = predicate
                        .bounds
                        .iter()
                        .map(|s| qualify_rust_path(&qualify_std_trait(s.as_str())))
                        .collect::<Vec<_>>()
                        .join(" + ");
                    Ok(format!("{}: {}", format_type(&predicate.ty)?, bounds))
                })
                .collect::<Result<Vec<_>, Stage0Error>>()?
                .join(", ")
        ))
    }
}

fn format_type(ty: &TypeRef) -> Result<String, Stage0Error> {
    match ty {
        TypeRef::Int { .. } => Ok("i64".to_string()),
        TypeRef::Float { .. } => Ok("f64".to_string()),
        TypeRef::Char { .. } => Ok("char".to_string()),
        TypeRef::String { .. } => Ok("String".to_string()),
        TypeRef::Bool { .. } => Ok("bool".to_string()),
        TypeRef::Unit { .. } => Ok("()".to_string()),
        TypeRef::Tuple { elements, .. } => Ok(format!(
            "({})",
            elements
                .iter()
                .map(format_type)
                .collect::<Result<Vec<_>, _>>()?
                .join(", ")
        )),
        TypeRef::Array { element, len, .. } => match len {
            Some(len) => Ok(format!("[{}; {len}]", format_type(element)?)),
            None => Ok(format!("[{}]", format_type(element)?)),
        },
        TypeRef::Named { name, .. } if name == "UInt" => Ok("u64".to_string()),
        TypeRef::Named { name, .. } if name == "U8" => Ok("u8".to_string()),
        TypeRef::Named { name, .. } if name == "str" => Ok("str".to_string()),
        TypeRef::Named { name, .. }
            if matches!(name.as_str(), "u8" | "u16" | "u32" | "u64" | "usize" | "i8" | "i16" | "i32" | "i64" | "f32" | "f64") =>
        {
            Ok(name.clone())
        }
        TypeRef::Named { name, type_args, .. } => {
            let rust_name = match name.as_str() {
                "Array" => "Array",
                "List" => "Vec",
                "Map" => "Map",
                "Set" => "Set",
                "Range" => "std::ops::Range",
                other => other,
            };
            let rust_name = qualify_rust_path(rust_name);
            if type_args.is_empty() {
                Ok(rust_name)
            } else {
                Ok(format!(
                    "{}<{}>",
                    rust_name,
                    type_args.iter().map(format_type).collect::<Result<Vec<_>, _>>()?.join(", ")
                ))
            }
        }
        TypeRef::Function {
            params,
            return_type,
            ..
        } => Ok(format!(
            "Box<dyn Fn({}) -> {}>",
            params
                .iter()
                .map(format_type)
                .collect::<Result<Vec<_>, _>>()?
                .join(", "),
            format_type(return_type)?
        )),
        TypeRef::SelfTy { .. } => Ok("Self".to_string()),
        TypeRef::DynTrait { trait_name, .. } => Ok(gen_dyn_ref(trait_name)),
        TypeRef::Ref { inner, mutable, .. } => {
            if *mutable {
                Ok(format!("&mut {}", format_type(inner)?))
            } else {
                Ok(format!("&{}", format_type(inner)?))
            }
        }
    }
}

fn format_storage_type(ty: &TypeRef, state: &CodegenState, indirect: bool) -> Result<String, Stage0Error> {
    match ty {
        TypeRef::Int { .. } => Ok("i64".to_string()),
        TypeRef::Float { .. } => Ok("f64".to_string()),
        TypeRef::Char { .. } => Ok("char".to_string()),
        TypeRef::String { .. } => Ok("String".to_string()),
        TypeRef::Bool { .. } => Ok("bool".to_string()),
        TypeRef::Unit { .. } => Ok("()".to_string()),
        TypeRef::Tuple { elements, .. } => Ok(format!(
            "({})",
            elements
                .iter()
                .map(|element| format_storage_type(element, state, false))
                .collect::<Result<Vec<_>, _>>()?
                .join(", ")
        )),
        TypeRef::Array { element, len, .. } => match len {
            Some(len) => Ok(format!("[{}; {len}]", format_storage_type(element, state, false)?)),
            None => Ok(format!("[{}]", format_storage_type(element, state, false)?)),
        },
        TypeRef::Named { name, .. } if name == "UInt" => Ok("u64".to_string()),
        TypeRef::Named { name, .. } if name == "U8" => Ok("u8".to_string()),
        TypeRef::Named { name, .. } if name == "str" => Ok("str".to_string()),
        TypeRef::Named { name, .. }
            if matches!(name.as_str(), "u8" | "u16" | "u32" | "u64" | "usize" | "i8" | "i16" | "i32" | "i64" | "f32" | "f64") =>
        {
            Ok(name.clone())
        }
        TypeRef::Named { name, type_args, .. } => {
            let rust_name = match name.as_str() {
                "Array" => "Array",
                "List" => "Vec",
                "Map" => "Map",
                "Set" => "Set",
                "Range" => "std::ops::Range",
                other => other,
            };
            let rust_name = qualify_rust_path(rust_name);
            let arg_indirect = is_indirect_storage_container(name);
            let rendered = if type_args.is_empty() {
                rust_name
            } else {
                format!(
                    "{}<{}>",
                    rust_name,
                    type_args
                        .iter()
                        .map(|type_arg| format_storage_type(type_arg, state, arg_indirect))
                        .collect::<Result<Vec<_>, _>>()?
                        .join(", ")
                )
            };
            if !indirect && state.recursive_inline_types.contains(name) {
                Ok(format!("Box<{rendered}>"))
            } else {
                Ok(rendered)
            }
        }
        TypeRef::Function {
            params,
            return_type,
            ..
        } => Ok(format!(
            "Box<dyn Fn({}) -> {}>",
            params
                .iter()
                .map(|param| format_storage_type(param, state, true))
                .collect::<Result<Vec<_>, _>>()?
                .join(", "),
            format_storage_type(return_type, state, true)?
        )),
        TypeRef::SelfTy { .. } => Ok("Self".to_string()),
        TypeRef::DynTrait { trait_name, .. } => Ok(gen_dyn_ref(trait_name)),
        TypeRef::Ref { inner, mutable, .. } => {
            if *mutable {
                Ok(format!("&mut {}", format_storage_type(inner, state, true)?))
            } else {
                Ok(format!("&{}", format_storage_type(inner, state, true)?))
            }
        }
    }
}

fn is_stringy_expr(expr: &Expr, state: &CodegenState) -> bool {
    match expr {
        Expr::String { .. } => true,
        Expr::Call { callee, .. } => match callee.as_ref() {
            Expr::Field { field, .. } => field == "to_string",
            Expr::Name { name, .. } => state.string_returning_functions.contains(name),
            _ => false,
        },
        Expr::Binary {
            left,
            op: BinaryOp::Add,
            right,
            ..
        } => {
            is_stringy_expr(left, state) || is_stringy_expr(right, state)
        }
        _ => false,
    }
}

fn emit_concat_expr(expr: &Expr, state: &CodegenState) -> Result<String, Stage0Error> {
    emit_expr(expr, state)
}

struct CodegenMetadata {
    edges: OrderedMap<String, OrderedSet<String>>,
    enum_types: OrderedSet<String>,
    variant_owners: OrderedMap<String, String>,
    string_returning_functions: OrderedSet<String>,
    function_params: OrderedMap<String, Vec<TypeRef>>,
    mutable_trait_methods: OrderedSet<String>,
    emit_span_type: bool,
    emit_span_merge: bool,
}

impl Default for CodegenMetadata {
    fn default() -> Self {
        Self {
            edges: OrderedMap::new(),
            enum_types: OrderedSet::new(),
            variant_owners: OrderedMap::new(),
            string_returning_functions: OrderedSet::new(),
            function_params: OrderedMap::new(),
            mutable_trait_methods: OrderedSet::new(),
            emit_span_type: true,
            emit_span_merge: true,
        }
    }
}

impl CodegenState {
    fn empty() -> Self {
        Self {
            recursive_inline_types: OrderedSet::new(),
            enum_types: OrderedSet::new(),
            variant_owners: OrderedMap::new(),
            string_returning_functions: OrderedSet::new(),
            function_params: OrderedMap::new(),
            mutable_trait_methods: OrderedSet::new(),
            emit_span_type: true,
            emit_span_merge: true,
            local_names: OrderedSet::new(),
            support_use_paths: Vec::new(),
            support_modules: SupportModuleTree::default(),
        }
    }
}

fn build_codegen_state(module: &Module, env: &SemanticEnv) -> CodegenState {
    let mut metadata = CodegenMetadata::default();
    collect_codegen_metadata(&module.decls, &mut metadata);
    collect_support_metadata(env, &mut metadata);
    let local_names = collect_local_decl_names(&module.decls);
    let support_refs = collect_support_references(module, env, &local_names);
    CodegenState {
        recursive_inline_types: find_recursive_inline_types(&metadata.edges),
        enum_types: metadata.enum_types,
        variant_owners: metadata.variant_owners,
        string_returning_functions: metadata.string_returning_functions,
        function_params: metadata.function_params,
        mutable_trait_methods: metadata.mutable_trait_methods,
        emit_span_type: metadata.emit_span_type,
        emit_span_merge: metadata.emit_span_merge,
        local_names: local_names.clone(),
        support_use_paths: support_refs.use_paths.into_iter().collect(),
        support_modules: collect_support_modules(module, env, &local_names),
    }
}

fn collect_local_decl_names(decls: &[Decl]) -> OrderedSet<String> {
    let mut names = OrderedSet::new();
    for decl in decls {
        match decl {
            Decl::Struct(decl) => {
                names.insert(leaf_name(&decl.name).to_string());
            }
            Decl::Enum(decl) => {
                names.insert(leaf_name(&decl.name).to_string());
            }
            Decl::Trait(decl) => {
                names.insert(leaf_name(&decl.name).to_string());
            }
            Decl::Function(decl) => {
                names.insert(leaf_name(&decl.sig.name).to_string());
            }
            Decl::TypeAlias(decl) => {
                names.insert(leaf_name(&decl.name).to_string());
            }
            Decl::Const(decl) => {
                names.insert(decl.name.clone());
            }
            Decl::Global(decl) => {
                names.insert(decl.name.clone());
            }
            Decl::Module(decl) => {
                names.insert(decl.name.split("::").next().unwrap_or(&decl.name).to_string());
            }
            Decl::Impl(_) | Decl::Extern(_) | Decl::Meta(_) => {}
        }
    }
    names
}

fn collect_support_metadata(env: &SemanticEnv, metadata: &mut CodegenMetadata) {
    for decl in env.structs.values() {
        let entry = metadata.edges.entry(decl.name.clone()).or_default();
        for field in &decl.fields {
            collect_inline_type_edges(&field.ty, false, entry);
        }
    }
    for decl in env.enums.values() {
        metadata.enum_types.insert(decl.name.clone());
        let entry = metadata.edges.entry(decl.name.clone()).or_default();
        for variant in &decl.variants {
            metadata
                .variant_owners
                .entry(variant.name.clone())
                .or_insert_with(|| decl.name.clone());
            for field in &variant.tuple_fields {
                collect_inline_type_edges(field, false, entry);
            }
            for field in &variant.named_fields {
                collect_inline_type_edges(&field.ty, false, entry);
            }
        }
    }
    for sig in env.functions.values() {
        if matches!(sig.return_type, TypeRef::String { .. }) {
            metadata.string_returning_functions.insert(sig.name.clone());
        }
        metadata
            .function_params
            .entry(sig.name.clone())
            .or_insert_with(|| sig.params.iter().map(|param| param.ty.clone()).collect());
    }
}
fn collect_codegen_metadata(decls: &[Decl], metadata: &mut CodegenMetadata) {
    for decl in decls {
        match decl {
            Decl::Struct(struct_decl) => {
                if struct_decl.name == "Span" {
                    metadata.emit_span_type = false;
                }
                let entry = metadata.edges.entry(struct_decl.name.clone()).or_default();
                for field in &struct_decl.fields {
                    collect_inline_type_edges(&field.ty, false, entry);
                }
            }
            Decl::Enum(enum_decl) => {
                metadata.enum_types.insert(enum_decl.name.clone());
                let entry = metadata.edges.entry(enum_decl.name.clone()).or_default();
                for variant in &enum_decl.variants {
                    metadata
                        .variant_owners
                        .entry(variant.name.clone())
                        .or_insert_with(|| enum_decl.name.clone());
                }
                for variant in &enum_decl.variants {
                    for field in &variant.tuple_fields {
                        collect_inline_type_edges(field, false, entry);
                    }
                    for field in &variant.named_fields {
                        collect_inline_type_edges(&field.ty, false, entry);
                    }
                }
            }
            Decl::Function(function_decl) => {
                if function_decl.sig.name == "span_merge" {
                    metadata.emit_span_merge = false;
                }
                if matches!(function_decl.sig.return_type, TypeRef::String { .. }) {
                    metadata
                        .string_returning_functions
                        .insert(function_decl.sig.name.clone());
                }
                metadata.function_params.insert(
                    function_decl.sig.name.clone(),
                    function_decl.sig.params.iter().map(|param| param.ty.clone()).collect(),
                );
            }
            Decl::Trait(trait_decl) => {
                for method in &trait_decl.methods {
                    if function_uses_mut_self(method) {
                        metadata
                            .mutable_trait_methods
                            .insert(trait_method_key(&trait_decl.name, &method.sig.name));
                    }
                }
            }
            Decl::Impl(impl_decl) => {
                if !impl_decl.trait_name.is_empty() {
                    for method in &impl_decl.methods {
                        if function_uses_mut_self(method) {
                            metadata
                                .mutable_trait_methods
                                .insert(trait_method_key(&impl_decl.trait_name, &method.sig.name));
                        }
                    }
                }
            }
            Decl::Module(module_decl) => {
                collect_codegen_metadata(&module_decl.decls, metadata);
            }
            _ => {}
        }
    }
}

fn trait_method_key(trait_name: &str, method_name: &str) -> String {
    format!("{trait_name}::{method_name}")
}

fn function_uses_mut_self(function: &crate::ast::decl::FunctionDecl) -> bool {
    function
        .sig
        .params
        .iter()
        .find(|param| param.name == "self")
        .is_some_and(|param| {
            param.mutable
                || matches!(param.ty, TypeRef::Ref { mutable: true, .. })
                || function_body_mutates_self(&function.body)
        })
}

fn collect_inline_type_edges(ty: &TypeRef, indirect: bool, edges: &mut OrderedSet<String>) {
    match ty {
        TypeRef::Tuple { elements, .. } => {
            for element in elements {
                collect_inline_type_edges(element, false, edges);
            }
        }
        TypeRef::Array { element, .. } => collect_inline_type_edges(element, false, edges),
        TypeRef::Named { name, type_args, .. } => {
            if !indirect {
                edges.insert(name.clone());
            }
            let child_indirect = is_indirect_storage_container(name);
            for type_arg in type_args {
                collect_inline_type_edges(type_arg, child_indirect, edges);
            }
        }
        TypeRef::Function {
            params,
            return_type,
            ..
        } => {
            for param in params {
                collect_inline_type_edges(param, true, edges);
            }
            collect_inline_type_edges(return_type, true, edges);
        }
        TypeRef::Ref { inner, .. } => collect_inline_type_edges(inner, true, edges),
        TypeRef::Int { .. }
        | TypeRef::Float { .. }
        | TypeRef::Char { .. }
        | TypeRef::String { .. }
        | TypeRef::Bool { .. }
        | TypeRef::Unit { .. }
        | TypeRef::SelfTy { .. }
        | TypeRef::DynTrait { .. } => {}
    }
}

fn find_recursive_inline_types(edges: &OrderedMap<String, OrderedSet<String>>) -> OrderedSet<String> {
    edges
        .keys()
        .filter(|name| reaches_type(name, name, edges, &mut OrderedSet::new(), false))
        .cloned()
        .collect()
}

fn reaches_type(
    current: &str,
    target: &str,
    edges: &OrderedMap<String, OrderedSet<String>>,
    visited: &mut OrderedSet<String>,
    started: bool,
) -> bool {
    if started && current == target {
        return true;
    }
    if !visited.insert(current.to_string()) {
        return false;
    }
    let result = edges
        .get(current)
        .is_some_and(|next_set| next_set.iter().any(|next| reaches_type(next, target, edges, visited, true)));
    visited.remove(current);
    result
}

fn is_indirect_storage_container(name: &str) -> bool {
    matches!(name, "Array" | "Vec" | "Map" | "Set" | "Box")
}

fn is_boxed_type(expr: &Expr, state: &CodegenState) -> Result<bool, Stage0Error> {
    match expr {
        Expr::Field { base, .. } => is_boxed_type(base, state),
        Expr::Name { name, .. } => {
            Ok(state.recursive_inline_types.contains(name) && !state.enum_types.contains(name))
        }
        _ => Ok(false),
    }
}

fn is_primitive_type(expr: &Expr) -> Result<bool, Stage0Error> {
    match expr {
        Expr::Name { name, .. } => {
            Ok(matches!(name.as_str(), "i64" | "u64" | "i32" | "u32" | "i16" | "u16" | "i8" | "u8" | "f64" | "f32" | "bool" | "char"))
        }
        Expr::Field { base, .. } => is_primitive_type(base),
        _ => Ok(false),
    }
}

fn format_struct_field_type(ty: &TypeRef, state: &CodegenState, indirect: bool) -> Result<String, Stage0Error> {
    match ty {
        TypeRef::Tuple { elements, .. } => Ok(format!(
            "({})",
            elements
                .iter()
                .map(|element| format_struct_field_type(element, state, false))
                .collect::<Result<Vec<_>, _>>()?
                .join(", ")
        )),
        TypeRef::Array { element, len, .. } => match len {
            Some(len) => Ok(format!("[{}; {len}]", format_struct_field_type(element, state, false)?)),
            None => Ok(format!("[{}]", format_struct_field_type(element, state, false)?)),
        },
        TypeRef::Named { name, type_args, .. }
            if !indirect && state.recursive_inline_types.contains(name) && state.enum_types.contains(name) =>
        {
            let rust_name = match name.as_str() {
                "Array" => "Array",
                "List" => "Vec",
                "Map" => "Map",
                "Set" => "Set",
                "Range" => "std::ops::Range",
                other => other,
            };
            let rust_name = qualify_rust_path(rust_name);
            if type_args.is_empty() {
                Ok(rust_name)
            } else {
                let arg_indirect = is_indirect_storage_container(name);
                Ok(format!(
                    "{}<{}>",
                    rust_name,
                    type_args
                        .iter()
                        .map(|type_arg| format_struct_field_type(type_arg, state, arg_indirect))
                        .collect::<Result<Vec<_>, _>>()?
                        .join(", ")
                ))
            }
        }
        TypeRef::Named { name, type_args, .. } if !type_args.is_empty() => {
            let rust_name = match name.as_str() {
                "Array" => "Array",
                "List" => "Vec",
                "Map" => "Map",
                "Set" => "Set",
                "Range" => "std::ops::Range",
                other => other,
            };
            let rust_name = qualify_rust_path(rust_name);
            let arg_indirect = is_indirect_storage_container(name);
            let rendered = format!(
                "{}<{}>",
                rust_name,
                type_args
                    .iter()
                    .map(|type_arg| format_struct_field_type(type_arg, state, arg_indirect))
                    .collect::<Result<Vec<_>, _>>()?
                    .join(", ")
            );
            if !indirect && state.recursive_inline_types.contains(name) && !state.enum_types.contains(name) {
                Ok(format!("Box<{rendered}>"))
            } else {
                Ok(rendered)
            }
        }
        TypeRef::Named { name, .. }
            if !indirect && state.recursive_inline_types.contains(name) && !state.enum_types.contains(name) =>
        {
            Ok(format!("Box<{}>", format_storage_type(ty, state, true)?))
        }
        TypeRef::Function {
            params,
            return_type,
            ..
        } => Ok(format!(
            "Box<dyn Fn({}) -> {}>",
            params
                .iter()
                .map(|param| format_struct_field_type(param, state, true))
                .collect::<Result<Vec<_>, _>>()?
                .join(", "),
            format_struct_field_type(return_type, state, true)?
        )),
        TypeRef::Ref { inner, mutable, .. } => {
            if *mutable {
                Ok(format!("&mut {}", format_struct_field_type(inner, state, true)?))
            } else {
                Ok(format!("&{}", format_struct_field_type(inner, state, true)?))
            }
        }
        _ => format_storage_type(ty, state, indirect),
    }
}

fn is_unit_type(ty: &TypeRef) -> bool {
    matches!(ty, TypeRef::Unit { .. })
}

fn escape_char_literal(value: char) -> String {
    value.escape_default().to_string()
}

fn escape_string_literal(value: &str) -> String {
    value.chars().flat_map(char::escape_default).collect()
}

fn visibility_prefix(public: bool) -> &'static str {
    if public {
        "pub "
    } else {
        ""
    }
}

#[cfg(test)]
mod tests {
    use std::env;
    use std::fs;
    use std::path::Path;
    use std::time::{SystemTime, UNIX_EPOCH};

    use crate::ast::decl::Decl;
    use crate::driver::analyze_module_from_path;
    use crate::lexer::Lexer;
    use crate::parser::Parser;
    use crate::sema::{analyze, SemanticEnv};

    use super::{build_codegen_state, emit_rust, gen_dyn_ref, gen_struct, gen_trait, rustc_check, rustc_check_command};

    #[test]
    fn emits_trait_and_impl_tokens() {
        let source = concat!(
            "pub trait Draw { fn draw(Self) -> Int; } ",
            "struct Pixel { pub id: Int } ",
            "impl Draw Pixel { fn draw(Self) -> Int = self.id }"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        let env = analyze(&module).expect("semantic analysis should succeed");
        let rust = emit_rust(&module, &env).expect("codegen should succeed");
        assert!(rust.contains("pub trait Draw"));
        assert!(rust.contains("impl Draw for Pixel"));
        assert!(rust.contains("pub id: i64"));
        assert!(rust.contains("fn draw(&self) -> i64"));
    }

    #[test]
    fn emits_exact_struct_and_trait_shapes() {
        let source = concat!(
            "trait Surface {} ",
            "pub trait Draw { fn draw(Self) -> dyn Surface; } ",
            "pub struct Pixel { pub id: Int }"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        let trait_decl = match &module.decls[1] {
            Decl::Trait(decl) => decl,
            other => panic!("expected trait, got {other:?}"),
        };
        let struct_decl = match &module.decls[2] {
            Decl::Struct(decl) => decl,
            other => panic!("expected struct, got {other:?}"),
        };
        let state = build_codegen_state(&module, &SemanticEnv::default());
        assert_eq!(
            gen_trait(trait_decl, &state).expect("trait codegen should succeed"),
            "pub trait Draw {\n    fn draw(&self) -> Box<dyn Surface>;\n}\n"
        );
        assert_eq!(
            gen_struct(struct_decl, &state).expect("struct codegen should succeed"),
            "#[derive(Clone)]\npub struct Pixel {\n    pub id: i64,\n}\n"
        );
        assert_eq!(gen_dyn_ref("Registry"), "Box<dyn Registry>");
    }

    #[test]
    fn emits_mut_self_and_copy_enum_shapes() {
        let source = concat!(
            "enum X64\n",
            "  Rax\n",
            "  Rbx\n",
            "end\n",
            "struct Buf {}\n",
            "impl Buf\n",
            "  fn fill(&mut self) -> Unit = ()\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        let env = analyze(&module).expect("semantic analysis should succeed");
        let rust = emit_rust(&module, &env).expect("codegen should succeed");
        assert!(rust.contains("#[derive(Clone, Copy)]"));
        assert!(rust.contains("fn fill(&mut self) -> ()"));
    }

    #[test]
    fn rustc_checks_emit32_le_with_mixed_integer_bitfields() {
        let source = concat!(
            "struct CodeBuffer {}\n",
            "def emit32_le(b: &mut CodeBuffer, v: u32) -> Unit = ()\n",
            "def a64_code(r: Int) -> u32 = 0u32\n",
            "def encode(b: &mut CodeBuffer, r1: Int, r2: Int, base: Int, imm7: Int) -> Unit\n",
            "  emit32_le(b, 0xA9800000 | imm7 << 15 | a64_code(r2) << 10 | a64_code(base) << 5 | a64_code(r1))\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        let semantic_env = analyze(&module).expect("semantic analysis should succeed");
        let rust = emit_rust(&module, &semantic_env).expect("codegen should succeed");

        let temp_dir = env::temp_dir();
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock should be monotonic")
            .as_nanos();
        let path = temp_dir.join(format!("stage0_emit32_mixed_{unique}.rs"));
        fs::write(&path, rust).expect("should write temp rust file");
        rustc_check(&path).expect("rustc metadata check should succeed");
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn rustc_checks_parenthesized_casts_and_rvalue_indexing() {
        let source = concat!(
            "struct Holder { values: Vec[String] }\n",
            "def read(words: Vec[String], imm: u32) -> String\n",
            "  let lo = (imm & 0xFFFF) as u16\n",
            "  let _ = lo\n",
            "  words[0]\n",
            "end\n",
            "def patch(holder: &mut Holder, idx: Int, value: String) -> Unit\n",
            "  holder.values[idx] = value\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        let env = analyze(&module).expect("semantic analysis should succeed");
        let rust = emit_rust(&module, &env).expect("codegen should succeed");

        let temp_dir = env::temp_dir();
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock should be monotonic")
            .as_nanos();
        let path = temp_dir.join(format!("stage0_cast_index_{unique}.rs"));
        fs::write(&path, rust).expect("should write temp rust file");
        rustc_check(&path).expect("rustc metadata check should succeed");
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn rustc_checks_generic_types_fixture() {
        let repo_root = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("stage0_rs should live directly under the repo root");
        let source = fs::read_to_string(repo_root.join("golden/types_01.tg"))
            .expect("types_01 fixture should be readable");
        let module = Parser::new(Lexer::new(&source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        let env = analyze(&module).expect("semantic analysis should succeed");
        let rust = emit_rust(&module, &env).expect("codegen should succeed");

        let temp_dir = env::temp_dir();
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock should be monotonic")
            .as_nanos();
        let path = temp_dir.join(format!("stage0_types_fixture_{unique}.rs"));
        fs::write(&path, rust).expect("should write temp rust file");
        rustc_check(&path).expect("rustc metadata check should succeed");
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn rustc_checks_frontend_05_fixture() {
        let repo_root = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("stage0_rs should live directly under the repo root");
        let source = fs::read_to_string(repo_root.join("golden/frontend_05.tg"))
            .expect("frontend_05 fixture should be readable");
        let module = Parser::new(Lexer::new(&source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        let env = analyze(&module).expect("semantic analysis should succeed");
        let rust = emit_rust(&module, &env).expect("codegen should succeed");

        let temp_dir = env::temp_dir();
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock should be monotonic")
            .as_nanos();
        let path = temp_dir.join(format!("stage0_frontend_05_fixture_{unique}.rs"));
        fs::write(&path, rust).expect("should write temp rust file");
        rustc_check(&path).expect("rustc metadata check should succeed");
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn rustc_checks_assert_macros_and_boxed_function_args() {
        let source = concat!(
            "def assert_true(value: Bool) -> Unit = ()\n",
            "def assert_false(value: Bool) -> Unit = ()\n",
            "def assert_eq[T](left: T, right: T) -> Unit = ()\n",
            "def apply(f: fn(Int) -> Int, x: Int) -> Int\n",
            "  f(x)\n",
            "end\n",
            "def run() -> Unit\n",
            "  let double = |x| x * 2\n",
            "  assert_true(apply(double, 5) == 10)\n",
            "  assert_false(apply(double, 3) == 8)\n",
            "  assert_eq(apply(double, 6), 12)\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        let env = analyze(&module).expect("semantic analysis should succeed");
        let rust = emit_rust(&module, &env).expect("codegen should succeed");

        assert!(rust.contains("assert!(apply(Box::new(double), 5) == 10);"));
        assert!(rust.contains("assert!(!(apply(Box::new(double), 3) == 8));"));
        assert!(rust.contains("assert_eq!(apply(Box::new(double), 6), 12);"));

        let temp_dir = env::temp_dir();
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock should be monotonic")
            .as_nanos();
        let path = temp_dir.join(format!("stage0_assert_boxed_fn_{unique}.rs"));
        fs::write(&path, rust).expect("should write temp rust file");
        rustc_check(&path).expect("rustc metadata check should succeed");
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn emits_recursive_storage_boxes_and_nested_modules() {
        let source = concat!(
            "module tg_compiler::debugger\n",
            "struct Node { next: Option[Node] }\n",
            "end\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        let env = analyze(&module).expect("semantic analysis should succeed");
        let rust = emit_rust(&module, &env).expect("codegen should succeed");

        assert!(rust.contains("pub mod tg_compiler {"));
        assert!(rust.contains("pub mod debugger {"));
        assert!(rust.contains("next: Option<Box<Node>>"));
    }

    #[test]
    fn preserves_local_span_helpers_and_escapes_newlines() {
        let source = concat!(
            "struct Span { start: Int, end_pos: Int }\n",
            "def span_merge(a: Span, b: Span) -> Span = a\n",
            "const LF: Char = '\\n'\n"
        );
        let module = Parser::new(Lexer::new(source).lex_all().expect("lex should succeed"))
            .parse_module()
            .expect("parse should succeed");
        let env = analyze(&module).expect("semantic analysis should succeed");
        let rust = emit_rust(&module, &env).expect("codegen should succeed");

        assert_eq!(rust.matches("struct Span").count(), 1);
        assert_eq!(rust.matches("fn span_merge").count(), 1);
        assert!(rust.contains("const LF: char = '\\n';"));
    }

    #[test]
    fn emits_std_support_modules_for_driver_fixture() {
        let repo_root = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("stage0_rs should live directly under the repo root");
        let driver_path = repo_root.join("tg_compiler/driver.tg");

        let (module, env) = analyze_module_from_path(&driver_path)
            .expect("driver fixture should analyze successfully");
        let local_names = super::collect_local_decl_names(&module.decls);
        let included = super::collect_included_support_names(&module, &env, &local_names);
        assert!(
            included.contains("std::bench::BenchCase") || included.contains("bench::BenchCase"),
            "included support names missing bench::BenchCase: {included:?}"
        );
        assert!(
            included.contains("std::env::args") || included.contains("env::args"),
            "included support names missing env::args: {included:?}"
        );
        assert!(
            included.contains("std::semver::Version") || included.contains("semver::Version"),
            "included support names missing semver::Version: {included:?}"
        );

        let state = build_codegen_state(&module, &env);
        assert!(
            state.support_modules.children.contains_key("bench"),
            "support module tree missing bench child: {:?}",
            state.support_modules.children.keys().collect::<Vec<_>>()
        );
        assert!(
            state.support_modules.children.contains_key("env"),
            "support module tree missing env child: {:?}",
            state.support_modules.children.keys().collect::<Vec<_>>()
        );
        assert!(
            state.support_modules.children.contains_key("semver"),
            "support module tree missing semver child: {:?}",
            state.support_modules.children.keys().collect::<Vec<_>>()
        );

        let rust = emit_rust(&module, &env).expect("codegen should succeed");

        assert!(rust.contains("use crate::env::args;"));
        assert!(rust.contains("use crate::bench::BenchCase;"));
        assert!(rust.contains("pub mod env {"), "missing env support module");
        assert!(rust.contains("pub mod bench {"), "missing bench support module");
        assert!(rust.contains("pub mod semver {"), "missing semver support module");
    }

    #[test]
    fn builds_rustc_check_command() {
        let command = rustc_check_command(Path::new("generated.rs"));
        let program = command.get_program().to_string_lossy().into_owned();
        let args: Vec<String> = command
            .get_args()
            .map(|arg| arg.to_string_lossy().into_owned())
            .collect();
        assert!(program.ends_with("rustc"));
        assert_eq!(
            args,
            vec![
                "--crate-type=lib".to_string(),
                "--emit=metadata".to_string(),
                "-o".to_string(),
                "generated.rmeta".to_string(),
                "generated.rs".to_string(),
            ]
        );
    }

    #[test]
    fn rustc_check_accepts_valid_rust_and_rejects_invalid_rust() {
        let temp_dir = env::temp_dir().join(unique_test_dir_name());
        fs::create_dir_all(&temp_dir).expect("temp dir should be created");

        let valid_file = temp_dir.join("valid.rs");
        let invalid_file = temp_dir.join("invalid.rs");
        fs::write(&valid_file, "pub fn ok() {}\n").expect("valid rust file should be written");
        fs::write(&invalid_file, "fn main( {\n").expect("invalid rust file should be written");

        rustc_check(&valid_file).expect("valid rust should pass rustc --check");
        let error = rustc_check(&invalid_file).expect_err("invalid rust should fail rustc --check");
        assert!(error.to_string().contains("rustc metadata check failed"));

        fs::remove_file(&valid_file).expect("valid rust file should be removed");
        fs::remove_file(&invalid_file).expect("invalid rust file should be removed");
        let valid_meta = valid_file.with_extension("rmeta");
        if valid_meta.exists() {
            fs::remove_file(valid_meta).expect("valid metadata file should be removed");
        }
        let invalid_meta = invalid_file.with_extension("rmeta");
        if invalid_meta.exists() {
            fs::remove_file(invalid_meta).expect("invalid metadata file should be removed");
        }
        fs::remove_dir(&temp_dir).expect("temp dir should be removed");
    }

    fn unique_test_dir_name() -> String {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system time should be after unix epoch")
            .as_nanos();
        format!("stage0_rs_codegen_test_{nanos}")
    }
}
