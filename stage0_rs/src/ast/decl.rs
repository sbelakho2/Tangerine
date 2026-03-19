use crate::span::Span;

use super::expr::FunctionBody;
use super::types::TypeRef;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Module {
    pub decls: Vec<Decl>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Decl {
    Meta(MetaDecl),
    Module(ModuleDecl),
    Struct(StructDecl),
    Enum(EnumDecl),
    Trait(TraitDecl),
    Impl(ImplDecl),
    Function(FunctionDecl),
    TypeAlias(TypeAliasDecl),
    Const(ConstDecl),
    Global(GlobalDecl),
    Extern(ExternBlockDecl),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TypeParam {
    pub name: String,
    pub bounds: Vec<String>,
    pub span: Span,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WherePredicate {
    pub ty: TypeRef,
    pub bounds: Vec<String>,
    pub span: Span,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ModuleDecl {
    pub name: String,
    pub public: bool,
    pub decls: Vec<Decl>,
    pub span: Span,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MetaDecl {
    pub kind: MetaKind,
    pub detail: String,
    pub span: Span,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum MetaKind {
    Annotation,
    Use,
    Edition,
    Rationale,
    Capability,
    Test,
    Macro,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StructDecl {
    pub name: String,
    pub public: bool,
    pub type_params: Vec<TypeParam>,
    pub where_clause: Vec<WherePredicate>,
    pub fields: Vec<FieldDecl>,
    pub span: Span,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct EnumDecl {
    pub name: String,
    pub public: bool,
    pub type_params: Vec<TypeParam>,
    pub where_clause: Vec<WherePredicate>,
    pub variants: Vec<VariantDecl>,
    pub span: Span,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct VariantDecl {
    pub name: String,
    pub tuple_fields: Vec<TypeRef>,
    pub named_fields: Vec<FieldDecl>,
    pub span: Span,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FieldDecl {
    pub public: bool,
    pub name: String,
    pub ty: TypeRef,
    pub span: Span,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TraitDecl {
    pub name: String,
    pub public: bool,
    pub type_params: Vec<TypeParam>,
    pub supertraits: Vec<String>,
    pub where_clause: Vec<WherePredicate>,
    pub methods: Vec<FunctionDecl>,
    pub associated_types: Vec<TypeAliasDecl>,
    pub span: Span,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ImplDecl {
    pub type_params: Vec<TypeParam>,
    pub trait_name: String,
    pub trait_type: Option<TypeRef>,
    pub target_type: String,
    pub for_type: TypeRef,
    pub where_clause: Vec<WherePredicate>,
    pub methods: Vec<MethodBody>,
    pub associated_types: Vec<TypeAliasDecl>,
    pub consts: Vec<ConstDecl>,
    pub span: Span,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FunctionSig {
    pub name: String,
    pub public: bool,
    pub type_params: Vec<TypeParam>,
    pub params: Vec<Param>,
    pub return_type: TypeRef,
    pub where_clause: Vec<WherePredicate>,
    pub span: Span,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FunctionDecl {
    pub sig: FunctionSig,
    pub clauses: Vec<FunctionClause>,
    pub body: FunctionBody,
    pub span: Span,
}

pub type MethodBody = FunctionDecl;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum FunctionClause {
    Requires(RequiresClause),
    Budget(BudgetClause),
    Contract(ContractClause),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RequiresClause {
    pub capabilities: Vec<String>,
    pub span: Span,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BudgetClause {
    pub entries: Vec<BudgetEntry>,
    pub span: Span,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BudgetEntry {
    pub metric: String,
    pub operator: BudgetOp,
    pub limit: String,
    pub span: Span,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum BudgetOp {
    Lt,
    LtEq,
    Gt,
    GtEq,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ContractClause {
    pub kind: ContractKind,
    pub condition: super::expr::Expr,
    pub message: Option<String>,
    pub span: Span,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ContractKind {
    Pre,
    Post,
    Invariant,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Param {
    pub name: String,
    pub mutable: bool,
    pub ty: TypeRef,
    pub default_value: Option<super::expr::Expr>,
    pub span: Span,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TypeAliasDecl {
    pub name: String,
    pub public: bool,
    pub target: Option<TypeRef>,
    pub span: Span,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ConstDecl {
    pub name: String,
    pub public: bool,
    pub ty: Option<TypeRef>,
    pub value: super::expr::Expr,
    pub span: Span,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct GlobalDecl {
    pub name: String,
    pub public: bool,
    pub mutable: bool,
    pub ty: Option<TypeRef>,
    pub value: super::expr::Expr,
    pub span: Span,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ExternBlockDecl {
    pub abi: Option<String>,
    pub functions: Vec<FunctionSig>,
    pub structs: Vec<StructDecl>,
    pub span: Span,
}
