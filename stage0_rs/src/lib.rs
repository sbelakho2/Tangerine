#![deny(clippy::all, clippy::pedantic, warnings)]

pub mod ast;
pub mod codegen;
pub mod driver;
pub mod error;
pub mod lexer;
pub mod parser;
pub mod sema;
pub mod span;
