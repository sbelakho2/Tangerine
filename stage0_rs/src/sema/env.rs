use std::collections::{BTreeMap, BTreeSet};
use std::rc::Rc;

use crate::ast::decl::{ConstDecl, Decl, EnumDecl, FunctionDecl, FunctionSig, GlobalDecl, ImplDecl, MetaKind, Module, Param, StructDecl, TraitDecl, TypeAliasDecl};
use crate::ast::expr::{BlockBody, Expr, FunctionBody};
use crate::ast::types::TypeRef;
use crate::error::Stage0Error;
use crate::sema::is_builtin_named_type;
use crate::span::Span;

/// The semantic environment used during type-checking.
///
/// Large, rarely-mutated declaration maps are wrapped in `Rc` so that
/// `env.clone()` (which happens for every nested scope) is nearly free —
/// it only increments reference counts instead of deep-copying thousands
/// of declarations.  The few mutation sites use `Rc::make_mut` for
/// copy-on-write semantics.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct SemanticEnv {
    pub structs: Rc<BTreeMap<String, StructDecl>>,
    pub enums: Rc<BTreeMap<String, EnumDecl>>,
    pub traits: Rc<BTreeMap<String, TraitDecl>>,
    pub functions: Rc<BTreeMap<String, FunctionSig>>,
    pub type_aliases: Rc<BTreeMap<String, TypeRef>>,
    pub consts: Rc<BTreeMap<String, TypeRef>>,
    pub globals: Rc<BTreeMap<String, GlobalInfo>>,
    pub aliases: Rc<BTreeMap<String, String>>,
    pub impls: Rc<Vec<ImplInfo>>,
    pub active_trait: Option<String>,
    /// The return type of the enclosing function.  Used by `Stmt::Return`
    /// so that inner expression contexts (e.g. a let-binding annotation)
    /// do not override the function-level expectation.
    pub fn_return_type: Option<TypeRef>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct GlobalInfo {
    pub ty: TypeRef,
    pub mutable: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ImplInfo {
    pub trait_name: String,
    pub for_type: String,
    pub for_type_ref: TypeRef,
    pub methods: BTreeMap<String, FunctionSig>,
    pub associated_types: BTreeMap<String, TypeRef>,
    pub span: Span,
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

fn compact_trait_decl(decl: &TraitDecl) -> TraitDecl {
    TraitDecl {
        name: decl.name.clone(),
        public: decl.public,
        type_params: decl.type_params.clone(),
        supertraits: decl.supertraits.clone(),
        where_clause: decl.where_clause.clone(),
        methods: decl
            .methods
            .iter()
            .map(|method| FunctionDecl {
                sig: method.sig.clone(),
                clauses: method.clauses.clone(),
                body: compact_function_body(&method.body),
                span: method.span,
            })
            .collect(),
        associated_types: decl.associated_types.clone(),
        span: decl.span,
    }
}

impl SemanticEnv {
    /// Collect declarations into a semantic environment without validating cross-reference integrity.
    ///
    /// # Errors
    /// Returns `Stage0Error` on duplicate declarations or invalid impl targets discovered during collection.
    pub fn collect(module: &Module) -> Result<Self, Stage0Error> {
        let mut env = Self::default();
        collect_decl_scope(&module.decls, None, &mut env)?;
        Ok(env)
    }

    /// Build the global semantic environment from parsed declarations.
    ///
    /// # Errors
    /// Returns `Stage0Error` on duplicate declarations, invalid impl targets,
    /// unknown trait references, unknown structs, or incompatible method signatures.
    pub fn build(module: &Module) -> Result<Self, Stage0Error> {
        let env = Self::collect(module)?;
        env.validate_references()?;
        Ok(env)
    }

    #[must_use]
    pub fn resolve_alias_path(&self, name: &str) -> String {
        let mut resolved = name.to_string();
        let mut visited = BTreeSet::new();
        while visited.insert(resolved.clone()) {
            let Some(next) = resolve_alias_prefix(&resolved, &self.aliases) else {
                break;
            };
            if next == resolved {
                break;
            }
            // Detect growing-prefix cycles: if the new string simply prepends
            // a prefix onto the old string (e.g. "X" → "X::X"), stop.
            if next.starts_with(&resolved) && next[resolved.len()..].starts_with("::") {
                resolved = next;
                break;
            }
            resolved = next;
        }
        resolved
    }

    #[must_use]
    pub fn canonical_map_key<T>(&self, name: &str, map: &BTreeMap<String, T>) -> Option<String> {
        let aliased = self.resolve_alias_path(name);
        if map.contains_key(&aliased) {
            return Some(aliased);
        }
        if map.contains_key(name) {
            return Some(name.to_string());
        }
        if let Some(key) = fallback_map_key(name, map) {
            return Some(key);
        }
        fallback_map_key(&aliased, map)
    }

    #[must_use]
    pub fn resolve_type_alias(&self, name: &str) -> Option<TypeRef> {
        let aliased = self.resolve_alias_path(name);
        self.type_aliases
            .get(&aliased)
            .cloned()
            .or_else(|| self.type_aliases.get(name).cloned())
            .or_else(|| {
                fallback_map_key(name, &self.type_aliases)
                    .and_then(|key| self.type_aliases.get(&key).cloned())
            })
            .or_else(|| {
                fallback_map_key(&aliased, &self.type_aliases)
                    .and_then(|key| self.type_aliases.get(&key).cloned())
            })
            .or_else(|| legacy_type_alias(name))
            .or_else(|| legacy_type_alias(&aliased))
    }

    fn validate_references(&self) -> Result<(), Stage0Error> {
        for impl_info in self.impls.iter() {
            let for_type = self.resolve_alias_path(&impl_info.for_type);
            if self.canonical_map_key(&for_type, &self.structs).is_none()
                && self.canonical_map_key(&for_type, &self.enums).is_none()
                && self.resolve_type_alias(&for_type).is_none()
            {
                return Err(Stage0Error::semantic(
                    impl_info.span,
                    format!("unknown type '{}'", impl_info.for_type),
                ));
            }

            if impl_info.trait_name.is_empty() || is_builtin_trait(&impl_info.trait_name) {
                continue;
            }

            let Some(trait_key) = self.canonical_map_key(&impl_info.trait_name, &self.traits) else {
                return Err(Stage0Error::semantic(
                    impl_info.span,
                    format!("unknown trait '{}'", impl_info.trait_name),
                ));
            };

            let trait_decl = &self.traits[&trait_key];

            for trait_method in &trait_decl.methods {
                let name = &trait_method.sig.name;
                let Some(impl_method) = impl_info.methods.get(name) else {
                    if matches!(trait_method.body, FunctionBody::Declaration { .. }) {
                        return Err(Stage0Error::semantic(
                            impl_info.span,
                            format!("impl for '{}' missing method '{}'", impl_info.trait_name, name),
                        ));
                    }
                    continue;
                };
                let actual = substitute_self_type_in_sig(impl_method, &impl_info.for_type_ref);
                let expected = substitute_self_type_in_sig(
                    &substitute_associated_types_in_sig(&trait_method.sig, &impl_info.associated_types),
                    &impl_info.for_type_ref,
                );
                if !signatures_match(&actual, &expected) {
                    return Err(Stage0Error::semantic(
                        impl_method.span,
                        format!("signature mismatch for method '{name}'"),
                    ));
                }
            }

            for associated_type in &trait_decl.associated_types {
                let _ = impl_info.associated_types.get(&associated_type.name).ok_or_else(|| {
                    Stage0Error::semantic(
                        impl_info.span,
                        format!("impl for '{}' missing associated type '{}'", impl_info.trait_name, associated_type.name),
                    )
                })?;
            }
        }
        Ok(())
    }
}

fn resolve_alias_prefix(name: &str, aliases: &BTreeMap<String, String>) -> Option<String> {
    let mut best_match: Option<(&String, &String)> = None;
    for (alias, target) in aliases {
        // Skip self-referencing aliases for prefix matching: if the target
        // starts with "alias::", applying this to a prefix match would produce
        // infinite expansion (e.g. alias "X" → "X::Y" applied to "X::Z"
        // gives "X::Y::Z" which still has prefix "X").
        let is_prefix_match = name != alias
            && name.strip_prefix(alias.as_str()).is_some_and(|suffix| suffix.starts_with("::"));
        let is_self_referencing = target.starts_with(alias.as_str())
            && target[alias.len()..].starts_with("::");
        if is_prefix_match && is_self_referencing {
            continue;
        }
        if name == alias || is_prefix_match {
            let should_replace = best_match
                .as_ref()
                .is_none_or(|(current_alias, _)| alias.len() > current_alias.len());
            if should_replace {
                best_match = Some((alias, target));
            }
        }
    }
    let (alias, target) = best_match?;
    if name == alias {
        Some(target.clone())
    } else {
        Some(format!("{target}{}", &name[alias.len()..]))
    }
}

fn legacy_type_alias(name: &str) -> Option<TypeRef> {
    let alias = name.rsplit("::").next().unwrap_or(name);
    match alias {
        "Annotation" => Some(TypeRef::Named {
            name: "Attribute".to_string(),
            type_args: Vec::new(),
            span: Span::new(0, 0, 0, 0),
        }),
        "Struct" => Some(TypeRef::Named {
            name: "StructDecl".to_string(),
            type_args: Vec::new(),
            span: Span::new(0, 0, 0, 0),
        }),
        "Enum" => Some(TypeRef::Named {
            name: "EnumDecl".to_string(),
            type_args: Vec::new(),
            span: Span::new(0, 0, 0, 0),
        }),
        _ => None,
    }
}

fn fallback_map_key<T>(name: &str, map: &BTreeMap<String, T>) -> Option<String> {
    let suffix = name.rsplit("::").next().unwrap_or(name);
    if suffix != name && map.contains_key(suffix) {
        return Some(suffix.to_string());
    }
    let mut matches = map
        .keys()
        .filter(|key| key.rsplit("::").next().is_some_and(|segment| segment == suffix))
        .cloned();
    let candidate = matches.next()?;
    if matches.next().is_none() {
        Some(candidate)
    } else {
        None
    }
}

fn collect_decl_scope(
    decls: &[Decl],
    module_prefix: Option<&str>,
    env: &mut SemanticEnv,
) -> Result<(), Stage0Error> {
    let local_type_names = decls
        .iter()
        .filter_map(|decl| match decl {
            Decl::Struct(struct_decl) => Some(struct_decl.name.clone()),
            Decl::Enum(enum_decl) => Some(enum_decl.name.clone()),
            Decl::Trait(trait_decl) => Some(trait_decl.name.clone()),
            Decl::TypeAlias(alias_decl) => Some(alias_decl.name.clone()),
            _ => None,
        })
        .collect::<BTreeSet<_>>();
    for decl in decls {
        if let Decl::Meta(meta) = decl {
            if meta.kind == MetaKind::Use {
                for (alias, target) in parse_use_aliases(&meta.detail) {
                    let _ = Rc::make_mut(&mut env.aliases).insert(alias, target);
                }
            }
        }
    }

    for decl in decls {
        match decl {
            Decl::Struct(struct_decl) => {
                validate_struct_decl(struct_decl)?;
                insert_unique_struct(Rc::make_mut(&mut env.structs), struct_decl)?;
                insert_qualified_struct(Rc::make_mut(&mut env.structs), struct_decl, module_prefix, &local_type_names);
            }
            Decl::Enum(enum_decl) => {
                validate_enum_decl(enum_decl)?;
                insert_unique_enum(Rc::make_mut(&mut env.enums), enum_decl)?;
                insert_qualified_enum(Rc::make_mut(&mut env.enums), enum_decl, module_prefix, &local_type_names);
            }
            Decl::Trait(trait_decl) => {
                validate_trait_methods(trait_decl)?;
                insert_unique_trait(Rc::make_mut(&mut env.traits), trait_decl)?;
                insert_qualified_trait(Rc::make_mut(&mut env.traits), trait_decl, module_prefix, &local_type_names);
            }
            Decl::Impl(impl_decl) => {
                let _ = named_type(&impl_decl.for_type)?;
                Rc::make_mut(&mut env.impls).push(build_impl_info(impl_decl)?);
            }
            Decl::Function(function_decl) => {
                insert_unique_function(Rc::make_mut(&mut env.functions), &function_decl.sig)?;
                insert_qualified_function(Rc::make_mut(&mut env.functions), &function_decl.sig, module_prefix, &local_type_names);
            }
            Decl::TypeAlias(alias_decl) => insert_type_alias(Rc::make_mut(&mut env.type_aliases), alias_decl, module_prefix, &local_type_names)?,
            Decl::Const(const_decl) => {
                insert_unique_const(Rc::make_mut(&mut env.consts), const_decl)?;
                insert_qualified_const(Rc::make_mut(&mut env.consts), const_decl, module_prefix, &local_type_names);
            }
            Decl::Global(global_decl) => {
                insert_unique_global(Rc::make_mut(&mut env.globals), global_decl)?;
                insert_qualified_global(Rc::make_mut(&mut env.globals), global_decl, module_prefix, &local_type_names);
            }
            Decl::Extern(extern_decl) => {
                for function in &extern_decl.functions {
                    insert_unique_function(Rc::make_mut(&mut env.functions), function)?;
                    insert_qualified_function(Rc::make_mut(&mut env.functions), function, module_prefix, &local_type_names);
                }
            }
            Decl::Module(module_decl) => {
                collect_decl_scope(&module_decl.decls, Some(&module_decl.name), env)?;
            }
            Decl::Meta(_) => {}
        }
    }
    Ok(())
}

fn parse_use_aliases(detail: &str) -> Vec<(String, String)> {
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

fn qualified_name(prefix: Option<&str>, name: &str) -> Option<String> {
    prefix.map(|prefix| format!("{prefix}::{name}"))
}

fn qualify_named_symbol(name: &str, prefix: &str, local_type_names: &BTreeSet<String>) -> String {
    if name.contains("::") || is_builtin_named_type(name) || !local_type_names.contains(name) {
        name.to_string()
    } else {
        format!("{prefix}::{name}")
    }
}

fn qualify_type_ref(ty: &TypeRef, prefix: &str, local_type_names: &BTreeSet<String>) -> TypeRef {
    match ty {
        TypeRef::Tuple { elements, span } => TypeRef::Tuple {
            elements: elements
                .iter()
                .map(|element| qualify_type_ref(element, prefix, local_type_names))
                .collect(),
            span: *span,
        },
        TypeRef::Array { element, len, span } => TypeRef::Array {
            element: Box::new(qualify_type_ref(element, prefix, local_type_names)),
            len: len.clone(),
            span: *span,
        },
        TypeRef::Named { name, type_args, span } => TypeRef::Named {
            name: qualify_named_symbol(name, prefix, local_type_names),
            type_args: type_args
                .iter()
                .map(|arg| qualify_type_ref(arg, prefix, local_type_names))
                .collect(),
            span: *span,
        },
        TypeRef::Function {
            params,
            return_type,
            span,
        } => TypeRef::Function {
            params: params
                .iter()
                .map(|param| qualify_type_ref(param, prefix, local_type_names))
                .collect(),
            return_type: Box::new(qualify_type_ref(return_type, prefix, local_type_names)),
            span: *span,
        },
        TypeRef::DynTrait { trait_name, span } => TypeRef::DynTrait {
            trait_name: qualify_named_symbol(trait_name, prefix, local_type_names),
            span: *span,
        },
        TypeRef::Ref { inner, mutable, span } => TypeRef::Ref {
            inner: Box::new(qualify_type_ref(inner, prefix, local_type_names)),
            mutable: *mutable,
            span: *span,
        },
        _ => ty.clone(),
    }
}

fn qualify_type_params(type_params: &[crate::ast::decl::TypeParam], prefix: &str, local_type_names: &BTreeSet<String>) -> Vec<crate::ast::decl::TypeParam> {
    type_params
        .iter()
        .map(|param| crate::ast::decl::TypeParam {
            name: param.name.clone(),
            bounds: param
                .bounds
                .iter()
                .map(|bound| qualify_named_symbol(bound, prefix, local_type_names))
                .collect(),
            span: param.span,
        })
        .collect()
}

fn qualify_where_clause(
    predicates: &[crate::ast::decl::WherePredicate],
    prefix: &str,
    local_type_names: &BTreeSet<String>,
) -> Vec<crate::ast::decl::WherePredicate> {
    predicates
        .iter()
        .map(|predicate| crate::ast::decl::WherePredicate {
            ty: qualify_type_ref(&predicate.ty, prefix, local_type_names),
            bounds: predicate
                .bounds
                .iter()
                .map(|bound| qualify_named_symbol(bound, prefix, local_type_names))
                .collect(),
            span: predicate.span,
        })
        .collect()
}

fn qualify_fields(fields: &[crate::ast::decl::FieldDecl], prefix: &str, local_type_names: &BTreeSet<String>) -> Vec<crate::ast::decl::FieldDecl> {
    fields
        .iter()
        .map(|field| crate::ast::decl::FieldDecl {
            public: field.public,
            name: field.name.clone(),
            ty: qualify_type_ref(&field.ty, prefix, local_type_names),
            span: field.span,
        })
        .collect()
}

fn qualify_function_sig(sig: &FunctionSig, prefix: &str, local_type_names: &BTreeSet<String>) -> FunctionSig {
    FunctionSig {
        name: sig.name.clone(),
        public: sig.public,
        type_params: qualify_type_params(&sig.type_params, prefix, local_type_names),
        params: sig
            .params
            .iter()
            .map(|param| Param {
                name: param.name.clone(),
                mutable: param.mutable,
                ty: qualify_type_ref(&param.ty, prefix, local_type_names),
                default_value: param.default_value.clone(),
                span: param.span,
            })
            .collect(),
        return_type: qualify_type_ref(&sig.return_type, prefix, local_type_names),
        where_clause: qualify_where_clause(&sig.where_clause, prefix, local_type_names),
        span: sig.span,
    }
}

fn insert_qualified_struct(
    table: &mut BTreeMap<String, StructDecl>,
    decl: &StructDecl,
    prefix: Option<&str>,
    local_type_names: &BTreeSet<String>,
) {
    if let Some(name) = qualified_name(prefix, &decl.name) {
        let mut qualified = decl.clone();
        qualified.name.clone_from(&name);
        if let Some(prefix) = prefix {
            qualified.type_params = qualify_type_params(&qualified.type_params, prefix, local_type_names);
            qualified.where_clause = qualify_where_clause(&qualified.where_clause, prefix, local_type_names);
            qualified.fields = qualify_fields(&qualified.fields, prefix, local_type_names);
        }
        let _ = table.insert(name, qualified);
    }
}

fn insert_qualified_enum(
    table: &mut BTreeMap<String, EnumDecl>,
    decl: &EnumDecl,
    prefix: Option<&str>,
    local_type_names: &BTreeSet<String>,
) {
    if let Some(name) = qualified_name(prefix, &decl.name) {
        let mut qualified = decl.clone();
        qualified.name.clone_from(&name);
        if let Some(prefix) = prefix {
            qualified.type_params = qualify_type_params(&qualified.type_params, prefix, local_type_names);
            qualified.where_clause = qualify_where_clause(&qualified.where_clause, prefix, local_type_names);
            qualified.variants = qualified
                .variants
                .iter()
                .map(|variant| crate::ast::decl::VariantDecl {
                    name: variant.name.clone(),
                    tuple_fields: variant
                        .tuple_fields
                        .iter()
                        .map(|field| qualify_type_ref(field, prefix, local_type_names))
                        .collect(),
                    named_fields: qualify_fields(&variant.named_fields, prefix, local_type_names),
                    span: variant.span,
                })
                .collect();
        }
        let _ = table.insert(name, qualified);
    }
}

fn insert_qualified_trait(
    table: &mut BTreeMap<String, TraitDecl>,
    decl: &TraitDecl,
    prefix: Option<&str>,
    local_type_names: &BTreeSet<String>,
) {
    if let Some(name) = qualified_name(prefix, &decl.name) {
        let mut qualified = compact_trait_decl(decl);
        qualified.name.clone_from(&name);
        if let Some(prefix) = prefix {
            qualified.type_params = qualify_type_params(&qualified.type_params, prefix, local_type_names);
            qualified.supertraits = qualified
                .supertraits
                .iter()
                .map(|trait_name| qualify_named_symbol(trait_name, prefix, local_type_names))
                .collect();
            qualified.where_clause = qualify_where_clause(&qualified.where_clause, prefix, local_type_names);
            qualified.methods = qualified
                .methods
                .iter()
                .map(|method| crate::ast::decl::FunctionDecl {
                    sig: qualify_function_sig(&method.sig, prefix, local_type_names),
                    clauses: method.clauses.clone(),
                    body: compact_function_body(&method.body),
                    span: method.span,
                })
                .collect();
            qualified.associated_types = qualified
                .associated_types
                .iter()
                .map(|assoc| TypeAliasDecl {
                    name: assoc.name.clone(),
                    public: assoc.public,
                    target: assoc.target.as_ref().map(|target| qualify_type_ref(target, prefix, local_type_names)),
                    span: assoc.span,
                })
                .collect();
        }
        let _ = table.insert(name, qualified);
    }
}

fn insert_qualified_function(
    table: &mut BTreeMap<String, FunctionSig>,
    sig: &FunctionSig,
    prefix: Option<&str>,
    local_type_names: &BTreeSet<String>,
) {
    if let Some(name) = qualified_name(prefix, &sig.name) {
        let mut qualified = if let Some(prefix) = prefix {
            qualify_function_sig(sig, prefix, local_type_names)
        } else {
            sig.clone()
        };
        qualified.name.clone_from(&name);
        let _ = table.insert(name, qualified);
    }
}

fn insert_type_alias(
    table: &mut BTreeMap<String, TypeRef>,
    decl: &TypeAliasDecl,
    prefix: Option<&str>,
    local_type_names: &BTreeSet<String>,
) -> Result<(), Stage0Error> {
    let Some(target) = decl.target.clone() else {
        return Ok(());
    };
    if table.insert(decl.name.clone(), target.clone()).is_some() {
        return Err(Stage0Error::semantic(
            decl.span,
            format!("duplicate type alias '{}'", decl.name),
        ));
    }
    if let Some(name) = qualified_name(prefix, &decl.name) {
        let qualified_target = if let Some(prefix) = prefix {
            qualify_type_ref(&target, prefix, local_type_names)
        } else {
            target
        };
        let _ = table.insert(name, qualified_target);
    }
    Ok(())
}

fn insert_qualified_const(
    table: &mut BTreeMap<String, TypeRef>,
    decl: &ConstDecl,
    prefix: Option<&str>,
    local_type_names: &BTreeSet<String>,
) {
    if let Some(name) = qualified_name(prefix, &decl.name) {
        let target = decl.ty.clone().unwrap_or(TypeRef::Unit { span: decl.span });
        let qualified_target = if let Some(prefix) = prefix {
            qualify_type_ref(&target, prefix, local_type_names)
        } else {
            target
        };
        let _ = table.insert(name, qualified_target);
    }
}

fn insert_qualified_global(
    table: &mut BTreeMap<String, GlobalInfo>,
    decl: &GlobalDecl,
    prefix: Option<&str>,
    local_type_names: &BTreeSet<String>,
) {
    if let Some(name) = qualified_name(prefix, &decl.name) {
        let ty = decl.ty.clone().unwrap_or(TypeRef::Unit { span: decl.span });
        let qualified_ty = if let Some(prefix) = prefix {
            qualify_type_ref(&ty, prefix, local_type_names)
        } else {
            ty
        };
        let _ = table.insert(
            name,
            GlobalInfo {
                ty: qualified_ty,
                mutable: decl.mutable,
            },
        );
    }
}

fn is_builtin_trait(name: &str) -> bool {
    matches!(name, "Display" | "Debug" | "Clone" | "Default")
}

fn named_type(ty: &TypeRef) -> Result<String, Stage0Error> {
    match ty {
        TypeRef::Named { name, .. } => Ok(name.clone()),
        TypeRef::Int { .. } => Ok("i64".to_string()),
        TypeRef::Float { .. } => Ok("f64".to_string()),
        TypeRef::Char { .. } => Ok("char".to_string()),
        TypeRef::String { .. } => Ok("String".to_string()),
        TypeRef::Bool { .. } => Ok("bool".to_string()),
        TypeRef::Unit { .. } => Ok("()".to_string()),
        TypeRef::Tuple { .. } | TypeRef::Array { .. } | TypeRef::Function { .. } => {
            Err(Stage0Error::semantic(ty.span(), "impl target must be a named type"))
        }
        _ => Err(Stage0Error::semantic(ty.span(), "impl target must be a named type")),
    }
}

fn insert_unique_enum(
    table: &mut BTreeMap<String, EnumDecl>,
    decl: &EnumDecl,
) -> Result<(), Stage0Error> {
    if table.insert(decl.name.clone(), decl.clone()).is_some() {
        return Err(Stage0Error::semantic(
            decl.span,
            format!("duplicate enum '{}'", decl.name),
        ));
    }
    Ok(())
}

fn insert_unique_struct(
    table: &mut BTreeMap<String, StructDecl>,
    decl: &StructDecl,
) -> Result<(), Stage0Error> {
    if table.insert(decl.name.clone(), decl.clone()).is_some() {
        return Err(Stage0Error::semantic(
            decl.span,
            format!("duplicate struct '{}'", decl.name),
        ));
    }
    Ok(())
}

fn insert_unique_trait(
    table: &mut BTreeMap<String, TraitDecl>,
    decl: &TraitDecl,
) -> Result<(), Stage0Error> {
    if table.insert(decl.name.clone(), compact_trait_decl(decl)).is_some() {
        return Err(Stage0Error::semantic(
            decl.span,
            format!("duplicate trait '{}'", decl.name),
        ));
    }
    Ok(())
}

fn validate_trait_methods(decl: &TraitDecl) -> Result<(), Stage0Error> {
    let mut methods = BTreeMap::<String, Span>::new();
    for method in &decl.methods {
        validate_function_sig(&method.sig)?;
        if methods.insert(method.sig.name.clone(), method.sig.span).is_some() {
            return Err(Stage0Error::semantic(
                method.sig.span,
                format!("duplicate trait method '{}'", method.sig.name),
            ));
        }
    }
    Ok(())
}

pub(crate) fn validate_struct_decl(decl: &StructDecl) -> Result<(), Stage0Error> {
    let type_params = type_param_names(&decl.type_params);
    for field in &decl.fields {
        validate_type_params(&field.ty, &type_params, field.span)?;
    }
    for predicate in &decl.where_clause {
        validate_type_params(&predicate.ty, &type_params, predicate.span)?;
    }
    Ok(())
}

pub(crate) fn validate_enum_decl(decl: &EnumDecl) -> Result<(), Stage0Error> {
    let type_params = type_param_names(&decl.type_params);
    let mut variants = BTreeMap::<String, Span>::new();
    for variant in &decl.variants {
        if variants.insert(variant.name.clone(), variant.span).is_some() {
            return Err(Stage0Error::semantic(
                variant.span,
                format!("duplicate enum variant '{}::{}'", decl.name, variant.name),
            ));
        }
        for field in &variant.tuple_fields {
            validate_type_params(field, &type_params, variant.span)?;
        }
        for field in &variant.named_fields {
            validate_type_params(&field.ty, &type_params, field.span)?;
        }
    }
    for predicate in &decl.where_clause {
        validate_type_params(&predicate.ty, &type_params, predicate.span)?;
    }
    Ok(())
}

fn validate_type_params(
    ty: &TypeRef,
    type_params: &BTreeSet<String>,
    _span: Span,
) -> Result<(), Stage0Error> {
    match ty {
        TypeRef::Tuple { elements, .. } => {
            for element in elements {
                validate_type_params(element, type_params, element.span())?;
            }
            Ok(())
        }
        TypeRef::Array { element, .. } => validate_type_params(element, type_params, element.span()),
        TypeRef::Named { name, type_args, .. } => {
            if !type_params.contains(name) {
                for arg in type_args {
                    validate_type_params(arg, type_params, arg.span())?;
                }
            }
            Ok(())
        }
        TypeRef::Function {
            params,
            return_type,
            ..
        } => {
            for param in params {
                validate_type_params(param, type_params, param.span())?;
            }
            validate_type_params(return_type, type_params, return_type.span())
        }
        TypeRef::Ref { inner, .. } => validate_type_params(inner, type_params, inner.span()),
        TypeRef::Int { .. }
        | TypeRef::Float { .. }
        | TypeRef::Char { .. }
        | TypeRef::String { .. }
        | TypeRef::Bool { .. }
        | TypeRef::Unit { .. }
        | TypeRef::SelfTy { .. }
        | TypeRef::DynTrait { .. } => Ok(()),
    }
}

pub(crate) fn build_impl_info(decl: &ImplDecl) -> Result<ImplInfo, Stage0Error> {
    let mut methods = BTreeMap::new();
    let mut associated_types = BTreeMap::new();
    for method in &decl.methods {
        if methods.insert(method.sig.name.clone(), method.sig.clone()).is_some() {
            return Err(Stage0Error::semantic(
                method.sig.span,
                format!("duplicate impl method '{}'", method.sig.name),
            ));
        }
    }
    for alias in &decl.associated_types {
        let Some(target) = alias.target.clone() else {
            return Err(Stage0Error::semantic(alias.span, format!("impl associated type '{}' requires a target", alias.name)));
        };
        if associated_types.insert(alias.name.clone(), target).is_some() {
            return Err(Stage0Error::semantic(alias.span, format!("duplicate impl associated type '{}'", alias.name)));
        }
    }
    Ok(ImplInfo {
        trait_name: decl.trait_name.clone(),
        for_type: decl.target_type.clone(),
        for_type_ref: decl.for_type.clone(),
        methods,
        associated_types,
        span: decl.span,
    })
}

fn insert_unique_function(
    table: &mut BTreeMap<String, FunctionSig>,
    sig: &FunctionSig,
) -> Result<(), Stage0Error> {
    validate_function_sig(sig)?;
    if table.insert(sig.name.clone(), sig.clone()).is_some() {
        return Err(Stage0Error::semantic(
            sig.span,
            format!("duplicate function '{}'", sig.name),
        ));
    }
    Ok(())
}

fn insert_unique_const(
    table: &mut BTreeMap<String, TypeRef>,
    decl: &ConstDecl,
) -> Result<(), Stage0Error> {
    let inferred = decl.ty.clone().unwrap_or_else(|| infer_const_type(&decl.value));
    if table.insert(decl.name.clone(), inferred).is_some() {
        return Err(Stage0Error::semantic(
            decl.span,
            format!("duplicate const '{}'", decl.name),
        ));
    }
    Ok(())
}

fn insert_unique_global(
    table: &mut BTreeMap<String, GlobalInfo>,
    decl: &GlobalDecl,
) -> Result<(), Stage0Error> {
    let ty = decl.ty.clone().unwrap_or_else(|| infer_const_type(&decl.value));
    let info = GlobalInfo {
        ty,
        mutable: decl.mutable,
    };
    if table.insert(decl.name.clone(), info).is_some() {
        return Err(Stage0Error::semantic(
            decl.span,
            format!("duplicate global '{}'", decl.name),
        ));
    }
    Ok(())
}

fn infer_const_type(expr: &Expr) -> TypeRef {
    match expr {
        Expr::Integer { span, .. } => TypeRef::Int { span: *span },
        Expr::Float { span, .. } => TypeRef::Float { span: *span },
        Expr::Char { span, .. } => TypeRef::Char { span: *span },
        Expr::String { span, .. } => TypeRef::String { span: *span },
        Expr::Bool { span, .. } => TypeRef::Bool { span: *span },
        Expr::Block { .. } => TypeRef::Unit { span: expr.span() },
        _ => TypeRef::Unit { span: expr.span() },
    }
}

fn signatures_match(left: &FunctionSig, right: &FunctionSig) -> bool {
    left.type_params == right.type_params
        && params_match(&left.params, &right.params)
        && types_match(&left.return_type, &right.return_type)
}

fn validate_function_sig(sig: &FunctionSig) -> Result<(), Stage0Error> {
    let type_params = type_param_names(&sig.type_params);
    for param in &sig.params {
        validate_type_params(&param.ty, &type_params, param.span)?;
    }
    validate_type_params(&sig.return_type, &type_params, sig.return_type.span())
}

fn substitute_associated_types_in_sig(
    sig: &FunctionSig,
    associated_types: &BTreeMap<String, TypeRef>,
) -> FunctionSig {
    FunctionSig {
        name: sig.name.clone(),
        public: sig.public,
        type_params: sig.type_params.clone(),
        params: sig
            .params
            .iter()
            .map(|param| Param {
                name: param.name.clone(),
                mutable: param.mutable,
                ty: substitute_associated_type(&param.ty, associated_types),
                default_value: param.default_value.clone(),
                span: param.span,
            })
            .collect(),
        return_type: substitute_associated_type(&sig.return_type, associated_types),
        where_clause: sig.where_clause.clone(),
        span: sig.span,
    }
}

fn substitute_self_type_in_sig(sig: &FunctionSig, self_ty: &TypeRef) -> FunctionSig {
    FunctionSig {
        name: sig.name.clone(),
        public: sig.public,
        type_params: sig.type_params.clone(),
        params: sig
            .params
            .iter()
            .map(|param| Param {
                name: param.name.clone(),
                mutable: param.mutable,
                ty: substitute_self_type(&param.ty, self_ty),
                default_value: param.default_value.clone(),
                span: param.span,
            })
            .collect(),
        return_type: substitute_self_type(&sig.return_type, self_ty),
        where_clause: sig.where_clause.clone(),
        span: sig.span,
    }
}

fn substitute_self_type(ty: &TypeRef, self_ty: &TypeRef) -> TypeRef {
    match ty {
        TypeRef::SelfTy { .. } => self_ty.clone(),
        TypeRef::Tuple { elements, span } => TypeRef::Tuple {
            elements: elements.iter().map(|element| substitute_self_type(element, self_ty)).collect(),
            span: *span,
        },
        TypeRef::Array { element, len, span } => TypeRef::Array {
            element: Box::new(substitute_self_type(element, self_ty)),
            len: len.clone(),
            span: *span,
        },
        TypeRef::Named { name, type_args, span } => TypeRef::Named {
            name: name.clone(),
            type_args: type_args.iter().map(|arg| substitute_self_type(arg, self_ty)).collect(),
            span: *span,
        },
        TypeRef::Function { params, return_type, span } => TypeRef::Function {
            params: params.iter().map(|param| substitute_self_type(param, self_ty)).collect(),
            return_type: Box::new(substitute_self_type(return_type, self_ty)),
            span: *span,
        },
        TypeRef::Ref { inner, mutable, span } => TypeRef::Ref {
            inner: Box::new(substitute_self_type(inner, self_ty)),
            mutable: *mutable,
            span: *span,
        },
        _ => ty.clone(),
    }
}

fn substitute_associated_type(ty: &TypeRef, associated_types: &BTreeMap<String, TypeRef>) -> TypeRef {
    match ty {
        TypeRef::Named {
            name,
            type_args,
            span,
        } => {
            if let Some(associated_name) = name.strip_prefix("Self::") {
                if let Some(replacement) = associated_types.get(associated_name) {
                    return replacement.clone();
                }
            }
            TypeRef::Named {
                name: name.clone(),
                type_args: type_args
                    .iter()
                    .map(|arg| substitute_associated_type(arg, associated_types))
                    .collect(),
                span: *span,
            }
        }
        TypeRef::Tuple { elements, span } => TypeRef::Tuple {
            elements: elements
                .iter()
                .map(|element| substitute_associated_type(element, associated_types))
                .collect(),
            span: *span,
        },
        TypeRef::Array { element, len, span } => TypeRef::Array {
            element: Box::new(substitute_associated_type(element, associated_types)),
            len: len.clone(),
            span: *span,
        },
        TypeRef::Function {
            params,
            return_type,
            span,
        } => TypeRef::Function {
            params: params
                .iter()
                .map(|param| substitute_associated_type(param, associated_types))
                .collect(),
            return_type: Box::new(substitute_associated_type(return_type, associated_types)),
            span: *span,
        },
        TypeRef::Ref { inner, mutable, span } => TypeRef::Ref {
            inner: Box::new(substitute_associated_type(inner, associated_types)),
            mutable: *mutable,
            span: *span,
        },
        _ => ty.clone(),
    }
}

fn type_param_names(params: &[crate::ast::decl::TypeParam]) -> BTreeSet<String> {
    params.iter().map(|param| param.name.clone()).collect()
}

fn params_match(left: &[Param], right: &[Param]) -> bool {
    left.len() == right.len()
        && left.iter().zip(right).all(|(left_param, right_param)| {
            left_param.name == right_param.name && types_match(&left_param.ty, &right_param.ty)
        })
}

fn types_match(left: &TypeRef, right: &TypeRef) -> bool {
    match (left, right) {
        (TypeRef::Int { .. }, TypeRef::Int { .. })
        | (TypeRef::Float { .. }, TypeRef::Float { .. })
        | (TypeRef::Char { .. }, TypeRef::Char { .. })
        | (TypeRef::String { .. }, TypeRef::String { .. })
        | (TypeRef::Bool { .. }, TypeRef::Bool { .. })
        | (TypeRef::Unit { .. }, TypeRef::Unit { .. })
        | (TypeRef::SelfTy { .. }, TypeRef::SelfTy { .. }) => true,
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
            left_name == right_name
                && left_args.len() == right_args.len()
                && left_args.iter().zip(right_args).all(|(left_arg, right_arg)| types_match(left_arg, right_arg))
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
                    .all(|(left_element, right_element)| types_match(left_element, right_element))
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
        ) => left_len == right_len && types_match(left_element, right_element),
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
                    .all(|(left_param, right_param)| types_match(left_param, right_param))
                && types_match(left_return, right_return)
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
        ) => left_mut == right_mut && types_match(left_inner, right_inner),
        _ => false,
    }
}
