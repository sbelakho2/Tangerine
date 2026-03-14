#![deny(clippy::all, clippy::pedantic, warnings)]

use std::sync::atomic::{AtomicUsize, Ordering};

pub static ALLOC_CURRENT: AtomicUsize = AtomicUsize::new(0);
pub static ALLOC_PEAK: AtomicUsize = AtomicUsize::new(0);

/// Return current live allocation in KB.
pub fn alloc_current_kb() -> usize {
    ALLOC_CURRENT.load(Ordering::Relaxed) / 1024
}

/// Return peak allocation in KB.
pub fn alloc_peak_kb() -> usize {
    ALLOC_PEAK.load(Ordering::Relaxed) / 1024
}

pub mod ast;
pub mod codegen;
pub mod driver;
pub mod error;
pub mod lexer;
pub mod parser;
pub mod sema;
pub mod span;
