use miette::Diagnostic;
use thiserror::Error;

use crate::span::Span;

#[derive(Debug, Error, Diagnostic, Clone, Eq, PartialEq)]
pub enum Stage0Error {
    #[error("lex error at {span}: {message}")]
    Lex { span: Span, message: String },
    #[error("parse error at {span}: {message}")]
    Parse { span: Span, message: String },
    #[error("semantic error at {span}: {message}")]
    Semantic { span: Span, message: String },
    #[error("codegen error at {span}: {message}")]
    Codegen { span: Span, message: String },
}

impl Stage0Error {
    #[must_use]
    pub fn lex(span: Span, message: impl Into<String>) -> Self {
        Self::Lex {
            span,
            message: message.into(),
        }
    }

    #[must_use]
    pub fn parse(span: Span, message: impl Into<String>) -> Self {
        Self::Parse {
            span,
            message: message.into(),
        }
    }

    #[must_use]
    pub fn semantic(span: Span, message: impl Into<String>) -> Self {
        Self::Semantic {
            span,
            message: message.into(),
        }
    }

    #[must_use]
    pub fn codegen(span: Span, message: impl Into<String>) -> Self {
        Self::Codegen {
            span,
            message: message.into(),
        }
    }
}
