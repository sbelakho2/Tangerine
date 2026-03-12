use std::fmt;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Span {
    pub line: usize,
    pub col: usize,
    pub start: usize,
    pub end: usize,
}

impl Span {
    #[must_use]
    /// Create a new source span.
    ///
    /// # Panics
    /// Panics if `start > end`.
    pub fn new(line: usize, col: usize, start: usize, end: usize) -> Self {
        assert!(start <= end, "span start must not exceed end");
        Self {
            line,
            col,
            start,
            end,
        }
    }
}

impl fmt::Display for Span {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}:{} ({}..{})", self.line, self.col, self.start, self.end)
    }
}

#[cfg(test)]
mod tests {
    use super::Span;

    #[test]
    fn span_formats_as_expected() {
        let span = Span::new(1, 1, 0, 5);
        assert_eq!(span.to_string(), "1:1 (0..5)");
    }

    #[test]
    #[should_panic(expected = "span start must not exceed end")]
    fn invalid_span_panics() {
        let _ = Span::new(1, 1, 10, 5);
    }
}
