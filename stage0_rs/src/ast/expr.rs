use crate::span::Span;

use super::decl::{Decl, FunctionDecl, MetaDecl};
use super::types::TypeRef;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum BinaryOp {
    Or,
    And,
    BitOr,
    BitXor,
    BitAnd,
    Shl,
    Shr,
    Add,
    Sub,
    Mul,
    Div,
    Mod,
    Eq,
    NotEq,
    Lt,
    LtEq,
    Gt,
    GtEq,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum UnaryOp {
    Not,
    BitNot,
    Neg,
    Deref,
    Borrow,
    BorrowMut,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Pattern {
    Wildcard {
        span: Span,
    },
    Binding {
        name: String,
        span: Span,
    },
    Integer {
        value: String,
        span: Span,
    },
    Float {
        value: String,
        span: Span,
    },
    Char {
        value: char,
        span: Span,
    },
    String {
        value: String,
        span: Span,
    },
    Bool {
        value: bool,
        span: Span,
    },
    Tuple {
        elements: Vec<Pattern>,
        span: Span,
    },
    Or {
        alternatives: Vec<Pattern>,
        span: Span,
    },
    Variant {
        enum_name: Option<String>,
        variant_name: String,
        fields: Vec<Pattern>,
        named_fields: Vec<(String, Pattern)>,
        span: Span,
    },
}

impl Pattern {
    #[must_use]
    pub fn span(&self) -> Span {
        match self {
            Self::Wildcard { span }
            | Self::Binding { span, .. }
            | Self::Integer { span, .. }
            | Self::Float { span, .. }
            | Self::Char { span, .. }
            | Self::String { span, .. }
            | Self::Bool { span, .. }
            | Self::Tuple { span, .. }
            | Self::Or { span, .. }
            | Self::Variant { span, .. } => *span,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MatchArm {
    pub pattern: Pattern,
    pub body: BlockBody,
    pub span: Span,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ClosureExpr {
    pub params: Vec<String>,
    pub body: BlockBody,
    pub span: Span,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CallArg {
    pub label: Option<String>,
    pub value: Expr,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum BranchGuard {
    Expr(Expr),
    Let { pattern: Pattern, value: Expr },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct IfBranch {
    pub guard: BranchGuard,
    pub body: Box<BlockBody>,
    pub span: Span,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Expr {
    Integer { value: String, span: Span },
    Float { value: String, span: Span },
    Char { value: char, span: Span },
    String { value: String, span: Span },
    Bool { value: bool, span: Span },
    Name { name: String, span: Span },
    Array {
        elements: Vec<Expr>,
        span: Span,
    },
    Tuple {
        elements: Vec<Expr>,
        span: Span,
    },
    StructLiteral {
        name: String,
        fields: Vec<(String, Expr)>,
        span: Span,
    },
    Block {
        block: Box<BlockBody>,
        span: Span,
    },
    UnsafeBlock {
        reason: String,
        block: Box<BlockBody>,
        span: Span,
    },
    If {
        branches: Vec<IfBranch>,
        else_branch: Option<Box<BlockBody>>,
        span: Span,
    },
    Call {
        callee: Box<Expr>,
        args: Vec<CallArg>,
        span: Span,
    },
    Index {
        base: Box<Expr>,
        index: Box<Expr>,
        span: Span,
    },
    Range {
        start: Box<Expr>,
        end: Box<Expr>,
        inclusive: bool,
        span: Span,
    },
    Match {
        value: Box<Expr>,
        arms: Vec<MatchArm>,
        span: Span,
    },
    Cast {
        expr: Box<Expr>,
        ty: TypeRef,
        span: Span,
    },
    Try {
        expr: Box<Expr>,
        span: Span,
    },
    Closure {
        closure: Box<ClosureExpr>,
        span: Span,
    },
    Unary {
        op: UnaryOp,
        expr: Box<Expr>,
        span: Span,
    },
    Field {
        base: Box<Expr>,
        field: String,
        span: Span,
    },
    Binary {
        left: Box<Expr>,
        op: BinaryOp,
        right: Box<Expr>,
        span: Span,
    },
}

impl Expr {
    #[must_use]
    pub fn span(&self) -> Span {
        match self {
            Self::Integer { span, .. }
            | Self::Float { span, .. }
            | Self::Char { span, .. }
            | Self::String { span, .. }
            | Self::Bool { span, .. }
            | Self::Name { span, .. }
            | Self::Array { span, .. }
            | Self::Tuple { span, .. }
            | Self::StructLiteral { span, .. }
            | Self::Block { span, .. }
            | Self::UnsafeBlock { span, .. }
            | Self::If { span, .. }
            | Self::Call { span, .. }
            | Self::Index { span, .. }
            | Self::Range { span, .. }
            | Self::Match { span, .. }
            | Self::Cast { span, .. }
            | Self::Try { span, .. }
            | Self::Closure { span, .. }
            | Self::Unary { span, .. }
            | Self::Field { span, .. }
            | Self::Binary { span, .. } => *span,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Stmt {
    Requires {
        capability: String,
        span: Span,
    },
    While {
        condition: Expr,
        body: BlockBody,
        span: Span,
    },
    Loop {
        body: BlockBody,
        span: Span,
    },
    For {
        pattern: Pattern,
        iterable: Expr,
        body: BlockBody,
        span: Span,
    },
    Return {
        value: Option<Expr>,
        span: Span,
    },
    Break {
        span: Span,
    },
    Next {
        span: Span,
    },
    Assign {
        target: Expr,
        value: Expr,
        span: Span,
    },
    Use {
        path: String,
        span: Span,
    },
    Meta {
        decl: MetaDecl,
        span: Span,
    },
    Function {
        decl: FunctionDecl,
        span: Span,
    },
    Decl {
        decl: Box<Decl>,
        span: Span,
    },
    Let {
        pattern: Pattern,
        mutable: bool,
        value: Expr,
        inferred_type: Option<TypeRef>,
        span: Span,
    },
    Expr { expr: Expr, span: Span },
}

impl Stmt {
    #[must_use]
    pub fn span(&self) -> Span {
        match self {
            Self::Requires { span, .. }
            | Self::While { span, .. }
            | Self::Loop { span, .. }
            | Self::For { span, .. }
            | Self::Return { span, .. }
            | Self::Break { span }
            | Self::Next { span }
            | Self::Assign { span, .. }
            | Self::Use { span, .. }
            | Self::Meta { span, .. }
            | Self::Function { span, .. }
            | Self::Decl { span, .. }
            | Self::Let { span, .. }
            | Self::Expr { span, .. } => *span,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum FunctionBody {
    Declaration { span: Span },
    Block(BlockBody),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BlockBody {
    pub stmts: Vec<Stmt>,
    pub tail: Option<Expr>,
    pub span: Span,
}