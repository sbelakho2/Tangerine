use crate::span::Span;
use std::fmt;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum TypeRef {
    Int { span: Span },
    Float { span: Span },
    Char { span: Span },
    String { span: Span },
    Bool { span: Span },
    Unit { span: Span },
    Tuple {
        elements: Vec<TypeRef>,
        span: Span,
    },
    Array {
        element: Box<TypeRef>,
        len: Option<String>,
        span: Span,
    },
    Named {
        name: String,
        type_args: Vec<TypeRef>,
        span: Span,
    },
    Function {
        params: Vec<TypeRef>,
        return_type: Box<TypeRef>,
        span: Span,
    },
    SelfTy { span: Span },
    DynTrait { trait_name: String, span: Span },
    Ref {
        inner: Box<TypeRef>,
        mutable: bool,
        span: Span,
    },
}

impl TypeRef {
    #[must_use]
    pub fn span(&self) -> Span {
        match self {
            Self::Int { span }
            | Self::Float { span }
            | Self::Char { span }
            | Self::String { span }
            | Self::Bool { span }
            | Self::Unit { span }
            | Self::Tuple { span, .. }
            | Self::Array { span, .. }
            | Self::Named { span, .. }
            | Self::Function { span, .. }
            | Self::SelfTy { span }
            | Self::DynTrait { span, .. }
            | Self::Ref { span, .. } => *span,
        }
    }
}

impl fmt::Display for TypeRef {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Int { .. } => write!(f, "Int"),
            Self::Float { .. } => write!(f, "Float"),
            Self::Char { .. } => write!(f, "Char"),
            Self::String { .. } => write!(f, "String"),
            Self::Bool { .. } => write!(f, "Bool"),
            Self::Unit { .. } => write!(f, "Unit"),
            Self::Tuple { elements, .. } => {
                let rendered = elements
                    .iter()
                    .map(ToString::to_string)
                    .collect::<Vec<_>>()
                    .join(", ");
                write!(f, "({rendered})")
            }
            Self::Array { element, len, .. } => match len {
                Some(len) => write!(f, "[{element}; {len}]"),
                None => write!(f, "[{element}]"),
            },
            Self::Named {
                name,
                type_args,
                ..
            } => {
                if type_args.is_empty() {
                    write!(f, "{name}")
                } else {
                    let rendered = type_args
                        .iter()
                        .map(ToString::to_string)
                        .collect::<Vec<_>>()
                        .join(", ");
                    write!(f, "{name}[{rendered}]")
                }
            }
            Self::Function {
                params,
                return_type,
                ..
            } => {
                let rendered = params
                    .iter()
                    .map(ToString::to_string)
                    .collect::<Vec<_>>()
                    .join(", ");
                write!(f, "fn({rendered}) -> {return_type}")
            }
            Self::SelfTy { .. } => write!(f, "Self"),
            Self::DynTrait { trait_name, .. } => write!(f, "dyn {trait_name}"),
            Self::Ref { inner, mutable, .. } => {
                if *mutable {
                    write!(f, "&mut {inner}")
                } else {
                    write!(f, "&{inner}")
                }
            }
        }
    }
}
