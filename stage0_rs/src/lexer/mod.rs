pub mod token;

use token::{Token, TokenKind};

use crate::error::Stage0Error;
use crate::span::Span;

/// Lex Tangerine source while discarding trivia tokens from the returned stream.
///
/// # Errors
/// Returns `Stage0Error` when the lexer encounters unsupported source text.
pub fn lex(input: &str) -> Result<Vec<Token>, Stage0Error> {
    let mut tokens = Lexer::new(input).lex_all()?;
    if matches!(tokens.last().map(|token| &token.kind), Some(TokenKind::Eof)) {
        let _ = tokens.pop();
    }
    Ok(tokens)
}

/// Lex Tangerine source and preserve whitespace/comment trivia tokens.
///
/// # Errors
/// Returns `Stage0Error` when the lexer encounters unsupported source text.
pub fn lex_preserving_trivia(input: &str) -> Result<Vec<Token>, Stage0Error> {
    Lexer::new(input).lex_all_with_trivia(false)
}

#[derive(Debug)]
pub struct Lexer<'src> {
    source: &'src str,
    index: usize,
    line: usize,
    col: usize,
}

impl<'src> Lexer<'src> {
    #[must_use]
    pub fn new(source: &'src str) -> Self {
        Self {
            source,
            index: 0,
            line: 1,
            col: 1,
        }
    }

    /// Lex the full input while dropping trivia tokens and appending EOF.
    ///
    /// # Errors
    /// Returns `Stage0Error` when unsupported source text is encountered.
    pub fn lex_all(self) -> Result<Vec<Token>, Stage0Error> {
        self.lex_all_with_trivia(true)
    }

    /// Lex the full input with optional trivia preservation and EOF insertion.
    ///
    /// # Errors
    /// Returns `Stage0Error` when unsupported source text is encountered.
    pub fn lex_all_with_trivia(mut self, append_eof: bool) -> Result<Vec<Token>, Stage0Error> {
        let mut tokens = Vec::new();
        while let Some(ch) = self.peek_char() {
            if ch == '\n' {
                tokens.push(self.single(TokenKind::Newline));
                continue;
            }

            if ch.is_whitespace() {
                tokens.push(self.lex_whitespace());
                continue;
            }

            if ch == '/' && self.peek_second_char() == Some('/') {
                tokens.push(self.lex_comment());
                continue;
            }

            if ch == '#' {
                if self.peek_second_char() == Some('|') {
                    tokens.push(self.lex_block_comment()?);
                } else {
                    tokens.push(self.lex_comment());
                }
                continue;
            }

            let token = match ch {
                'a'..='z' | 'A'..='Z' | '_' => self.lex_ident_or_keyword(),
                '0'..='9' => self.lex_number()?,
                '"' => self.lex_string()?,
                '\'' => {
                    if self.should_lex_apostrophe_ident() {
                        self.lex_apostrophe_ident()
                    } else {
                        self.lex_char()?
                    }
                }
                '@' => self.single(TokenKind::At),
                '(' => self.single(TokenKind::LParen),
                ')' => self.single(TokenKind::RParen),
                '[' => self.single(TokenKind::LBracket),
                ']' => self.single(TokenKind::RBracket),
                '{' => self.single(TokenKind::LBrace),
                '}' => self.single(TokenKind::RBrace),
                ':' => self.lex_colon_or_path_sep(),
                ',' => self.single(TokenKind::Comma),
                '.' => self.lex_dot_or_range(),
                ';' => self.single(TokenKind::Semi),
                '=' => self.lex_equals_family(),
                '!' => self.lex_bang_family(),
                '<' => self.lex_lt_family(),
                '>' => self.lex_gt_family(),
                '&' => self.lex_amp_family(),
                '|' => self.lex_pipe_family(),
                '^' => self.single(TokenKind::Caret),
                '~' => self.single(TokenKind::Tilde),
                '+' => self.lex_plus_family(),
                '%' => self.lex_percent_family(),
                '*' => self.lex_star_family(),
                '?' => self.single(TokenKind::Question),
                '/' => self.lex_slash_family(),
                '-' => self.lex_minus_family(),
                _ => {
                    let span = Span::new(self.line, self.col, self.index, self.index + ch.len_utf8());
                    return Err(Stage0Error::lex(span, format!("unexpected character '{ch}'")));
                }
            };
            tokens.push(token);
        }

        if append_eof {
            tokens.push(Token::new(
                TokenKind::Eof,
                "",
                Span::new(self.line, self.col, self.index, self.index),
            ));
        }

        tokens.retain(|token| !matches!(token.kind, TokenKind::Whitespace | TokenKind::Comment) || !append_eof);
        Ok(tokens)
    }

    fn single(&mut self, kind: TokenKind) -> Token {
        let start = self.mark();
        let ch = self.bump_char().expect("character already checked");
        Token::new(kind, ch.to_string(), self.span_from(start))
    }

    fn lex_minus_family(&mut self) -> Token {
        let start = self.mark();
        let first = self.bump_char().expect("character already checked");
        match self.peek_char() {
            Some('>') => {
                let second = self.bump_char().expect("peeked char must exist");
                Token::new(TokenKind::Arrow, format!("{first}{second}"), self.span_from(start))
            }
            Some('=') => {
                let second = self.bump_char().expect("peeked char must exist");
                Token::new(TokenKind::MinusEq, format!("{first}{second}"), self.span_from(start))
            }
            _ => Token::new(TokenKind::Minus, first.to_string(), self.span_from(start)),
        }
    }

    fn lex_colon_or_path_sep(&mut self) -> Token {
        let start = self.mark();
        let first = self.bump_char().expect("character already checked");
        if self.peek_char() == Some(':') {
            let second = self.bump_char().expect("peeked char must exist");
            Token::new(TokenKind::ColonColon, format!("{first}{second}"), self.span_from(start))
        } else {
            Token::new(TokenKind::Colon, first.to_string(), self.span_from(start))
        }
    }

    fn lex_dot_or_range(&mut self) -> Token {
        let start = self.mark();
        let first = self.bump_char().expect("character already checked");
        if self.peek_char() == Some('.') {
            let second = self.bump_char().expect("peeked char must exist");
            if self.peek_char() == Some('=') {
                let third = self.bump_char().expect("peeked char must exist");
                Token::new(TokenKind::DotDotEq, format!("{first}{second}{third}"), self.span_from(start))
            } else {
                Token::new(TokenKind::DotDot, format!("{first}{second}"), self.span_from(start))
            }
        } else {
            Token::new(TokenKind::Dot, first.to_string(), self.span_from(start))
        }
    }

    fn lex_equals_family(&mut self) -> Token {
        let start = self.mark();
        let first = self.bump_char().expect("character already checked");
        if self.peek_char() == Some('=') {
            let second = self.bump_char().expect("peeked char must exist");
            Token::new(TokenKind::EqEq, format!("{first}{second}"), self.span_from(start))
        } else if self.peek_char() == Some('>') {
            let second = self.bump_char().expect("peeked char must exist");
            Token::new(TokenKind::FatArrow, format!("{first}{second}"), self.span_from(start))
        } else {
            Token::new(TokenKind::Eq, first.to_string(), self.span_from(start))
        }
    }

    fn lex_bang_family(&mut self) -> Token {
        let start = self.mark();
        let first = self.bump_char().expect("character already checked");
        if self.peek_char() == Some('=') {
            let second = self.bump_char().expect("peeked char must exist");
            Token::new(TokenKind::BangEq, format!("{first}{second}"), self.span_from(start))
        } else {
            Token::new(TokenKind::Bang, first.to_string(), self.span_from(start))
        }
    }

    fn lex_lt_family(&mut self) -> Token {
        let start = self.mark();
        let first = self.bump_char().expect("character already checked");
        if self.peek_char() == Some('=') {
            let second = self.bump_char().expect("peeked char must exist");
            Token::new(TokenKind::LtEq, format!("{first}{second}"), self.span_from(start))
        } else if self.peek_char() == Some('<') {
            let second = self.bump_char().expect("peeked char must exist");
            Token::new(TokenKind::Shl, format!("{first}{second}"), self.span_from(start))
        } else {
            Token::new(TokenKind::Lt, first.to_string(), self.span_from(start))
        }
    }

    fn lex_gt_family(&mut self) -> Token {
        let start = self.mark();
        let first = self.bump_char().expect("character already checked");
        if self.peek_char() == Some('=') {
            let second = self.bump_char().expect("peeked char must exist");
            Token::new(TokenKind::GtEq, format!("{first}{second}"), self.span_from(start))
        } else if self.peek_char() == Some('>') {
            let second = self.bump_char().expect("peeked char must exist");
            Token::new(TokenKind::Shr, format!("{first}{second}"), self.span_from(start))
        } else {
            Token::new(TokenKind::Gt, first.to_string(), self.span_from(start))
        }
    }

    fn lex_amp_family(&mut self) -> Token {
        let start = self.mark();
        let first = self.bump_char().expect("character already checked");
        if self.peek_char() == Some('&') {
            let second = self.bump_char().expect("peeked char must exist");
            Token::new(TokenKind::AmpAmp, format!("{first}{second}"), self.span_from(start))
        } else {
            Token::new(TokenKind::Amp, first.to_string(), self.span_from(start))
        }
    }

    fn lex_pipe_family(&mut self) -> Token {
        let start = self.mark();
        let first = self.bump_char().expect("character already checked");
        if self.peek_char() == Some('|') {
            let second = self.bump_char().expect("peeked char must exist");
            Token::new(TokenKind::PipePipe, format!("{first}{second}"), self.span_from(start))
        } else {
            Token::new(TokenKind::Pipe, first.to_string(), self.span_from(start))
        }
    }

    fn lex_plus_family(&mut self) -> Token {
        let start = self.mark();
        let first = self.bump_char().expect("character already checked");
        if self.peek_char() == Some('=') {
            let second = self.bump_char().expect("peeked char must exist");
            Token::new(TokenKind::PlusEq, format!("{first}{second}"), self.span_from(start))
        } else {
            Token::new(TokenKind::Plus, first.to_string(), self.span_from(start))
        }
    }

    fn lex_star_family(&mut self) -> Token {
        let start = self.mark();
        let first = self.bump_char().expect("character already checked");
        if self.peek_char() == Some('=') {
            let second = self.bump_char().expect("peeked char must exist");
            Token::new(TokenKind::StarEq, format!("{first}{second}"), self.span_from(start))
        } else {
            Token::new(TokenKind::Star, first.to_string(), self.span_from(start))
        }
    }

    fn lex_percent_family(&mut self) -> Token {
        let start = self.mark();
        let first = self.bump_char().expect("character already checked");
        if self.peek_char() == Some('=') {
            let second = self.bump_char().expect("peeked char must exist");
            Token::new(TokenKind::PercentEq, format!("{first}{second}"), self.span_from(start))
        } else {
            Token::new(TokenKind::Percent, first.to_string(), self.span_from(start))
        }
    }

    fn lex_ident_or_keyword(&mut self) -> Token {
        let start = self.mark();
        while matches!(self.peek_char(), Some('a'..='z' | 'A'..='Z' | '0'..='9' | '_')) {
            let _ = self.bump_char();
        }
        let lexeme = self.slice(start.index, self.index);
        let kind = match lexeme {
            "use" => TokenKind::KeywordUse,
            "edition" => TokenKind::KeywordEdition,
            "rationale" => TokenKind::KeywordRationale,
            "cap" => TokenKind::KeywordCap,
            "def" => TokenKind::KeywordDef,
            "fn" => TokenKind::KeywordFn,
            "if" => TokenKind::KeywordIf,
            "then" => TokenKind::KeywordThen,
            "else" => TokenKind::KeywordElse,
            "elsif" => TokenKind::KeywordElsif,
            "while" => TokenKind::KeywordWhile,
            "struct" => TokenKind::KeywordStruct,
            "enum" => TokenKind::KeywordEnum,
            "match" => TokenKind::KeywordMatch,
            "when" => TokenKind::KeywordWhen,
            "trait" => TokenKind::KeywordTrait,
            "impl" => TokenKind::KeywordImpl,
            "for" => TokenKind::KeywordFor,
            "in" => TokenKind::KeywordIn,
            "do" => TokenKind::KeywordDo,
            "let" => TokenKind::KeywordLet,
            "mut" => TokenKind::KeywordMut,
            "return" => TokenKind::KeywordReturn,
            "break" => TokenKind::KeywordBreak,
            "next" | "continue" => TokenKind::KeywordNext,
            "pub" => TokenKind::KeywordPub,
            "module" => TokenKind::KeywordModule,
            "mod" => TokenKind::KeywordMod,
            "const" => TokenKind::KeywordConst,
            "type" => TokenKind::KeywordType,
            "extern" => TokenKind::KeywordExtern,
            "where" => TokenKind::KeywordWhere,
            "as" => TokenKind::KeywordAs,
            "super" => TokenKind::KeywordSuper,
            "crate" => TokenKind::KeywordCrate,
            "yield" => TokenKind::KeywordYield,
            "async" => TokenKind::KeywordAsync,
            "await" => TokenKind::KeywordAwait,
            "requires" => TokenKind::KeywordRequires,
            "effect" => TokenKind::KeywordEffect,
            "implies" => TokenKind::KeywordImplies,
            "handle" => TokenKind::KeywordHandle,
            "with" => TokenKind::KeywordWith,
            "budget" => TokenKind::KeywordBudget,
            "pre" => TokenKind::KeywordPre,
            "post" => TokenKind::KeywordPost,
            "invariant" => TokenKind::KeywordInvariant,
            "guard" => TokenKind::KeywordGuard,
            "try" => TokenKind::KeywordTry,
            "catch" => TokenKind::KeywordCatch,
            "finally" => TokenKind::KeywordFinally,
            "macro" => TokenKind::KeywordMacro,
            "comptime" => TokenKind::KeywordComptime,
            "loop" => TokenKind::KeywordLoop,
            "pure" => TokenKind::KeywordPure,
            "inline" => TokenKind::KeywordInline,
            "unless" => TokenKind::KeywordUnless,
            "until" => TokenKind::KeywordUntil,
            "unsafe" => TokenKind::KeywordUnsafe,
            "end" => TokenKind::KeywordEnd,
            "true" => TokenKind::KeywordTrue,
            "false" => TokenKind::KeywordFalse,
            "self" => TokenKind::KeywordSelfValue,
            "Self" => TokenKind::KeywordSelfTy,
            "dyn" => TokenKind::KeywordDyn,
            _ => TokenKind::Ident(lexeme.to_string()),
        };
        Token::new(kind, lexeme, self.span_from(start))
    }

    fn should_lex_apostrophe_ident(&self) -> bool {
        matches!(self.peek_second_char(), Some('a'..='z' | 'A'..='Z' | '_'))
            && matches!(self.peek_third_char(), Some('a'..='z' | 'A'..='Z' | '0'..='9' | '_'))
    }

    fn lex_apostrophe_ident(&mut self) -> Token {
        let start = self.mark();
        let _ = self.bump_char();
        while matches!(self.peek_char(), Some('a'..='z' | 'A'..='Z' | '0'..='9' | '_')) {
            let _ = self.bump_char();
        }
        let lexeme = self.slice(start.index, self.index);
        Token::new(TokenKind::Ident(lexeme.to_string()), lexeme, self.span_from(start))
    }

    fn lex_string(&mut self) -> Result<Token, Stage0Error> {
        let start = self.mark();
        let _ = self.bump_char();
        let mut value = String::new();
        loop {
            let ch = self.peek_char().ok_or_else(|| {
                Stage0Error::lex(self.span_from(start), "unterminated string literal")
            })?;
            match ch {
                '"' => {
                    let _ = self.bump_char();
                    break;
                }
                '\\' => {
                    let _ = self.bump_char();
                    let escaped = self.peek_char().ok_or_else(|| {
                        Stage0Error::lex(self.span_from(start), "unterminated escape sequence")
                    })?;
                    let _ = self.bump_char();
                    value.push(self.lex_escape_char(start, escaped)?);
                }
                '\n' => {
                    let _ = self.bump_char();
                    value.push('\n');
                }
                other => {
                    let _ = self.bump_char();
                    value.push(other);
                }
            }
        }
        let lexeme = self.slice(start.index, self.index);
        Ok(Token::new(TokenKind::String(value), lexeme, self.span_from(start)))
    }

    fn lex_char(&mut self) -> Result<Token, Stage0Error> {
        let start = self.mark();
        let _ = self.bump_char();
        let value = match self.peek_char().ok_or_else(|| {
            Stage0Error::lex(self.span_from(start), "unterminated char literal")
        })? {
            '\\' => {
                let _ = self.bump_char();
                let escaped = self.peek_char().ok_or_else(|| {
                    Stage0Error::lex(self.span_from(start), "unterminated escape sequence")
                })?;
                let _ = self.bump_char();
                self.lex_escape_char(start, escaped)?
            }
            '\n' => {
                return Err(Stage0Error::lex(self.span_from(start), "char literal cannot span multiple lines"));
            }
            ch => {
                let _ = self.bump_char();
                ch
            }
        };
        if self.peek_char() != Some('\'') {
            return Err(Stage0Error::lex(self.span_from(start), "unterminated char literal"));
        }
        let _ = self.bump_char();
        let lexeme = self.slice(start.index, self.index);
        Ok(Token::new(TokenKind::Char(value), lexeme, self.span_from(start)))
    }

    fn lex_number(&mut self) -> Result<Token, Stage0Error> {
        let start = self.mark();
        if self.peek_char() == Some('0') {
            match self.peek_second_char() {
                Some('x' | 'X') => {
                    let _ = self.bump_char();
                    let _ = self.bump_char();
                    self.consume_prefixed_digits(is_hex_digit);
                    self.ensure_prefixed_digits(start, 2, "hex")?;
                    let lexeme = self.slice(start.index, self.index);
                    return Ok(Token::new(TokenKind::Integer(lexeme.to_string()), lexeme, self.span_from(start)));
                }
                Some('b' | 'B') => {
                    let _ = self.bump_char();
                    let _ = self.bump_char();
                    self.consume_prefixed_digits(|ch| matches!(ch, '0' | '1'));
                    self.ensure_prefixed_digits(start, 2, "binary")?;
                    let lexeme = self.slice(start.index, self.index);
                    return Ok(Token::new(TokenKind::Integer(lexeme.to_string()), lexeme, self.span_from(start)));
                }
                Some('o' | 'O') => {
                    let _ = self.bump_char();
                    let _ = self.bump_char();
                    self.consume_prefixed_digits(|ch| matches!(ch, '0'..='7'));
                    self.ensure_prefixed_digits(start, 2, "octal")?;
                    let lexeme = self.slice(start.index, self.index);
                    return Ok(Token::new(TokenKind::Integer(lexeme.to_string()), lexeme, self.span_from(start)));
                }
                _ => {}
            }
        }

        self.consume_decimal_digits();
        let is_float = self.peek_char() == Some('.')
            && self.peek_second_char().is_some_and(|ch| ch.is_ascii_digit());
        if is_float {
            let _ = self.bump_char();
            self.consume_decimal_digits();
            if matches!(self.peek_char(), Some('e' | 'E')) {
                let _ = self.bump_char();
                if matches!(self.peek_char(), Some('+' | '-')) {
                    let _ = self.bump_char();
                }
                if !matches!(self.peek_char(), Some(ch) if ch.is_ascii_digit()) {
                    return Err(Stage0Error::lex(self.span_from(start), "float exponent must contain digits"));
                }
                self.consume_decimal_digits();
            }
            let lexeme = self.slice(start.index, self.index);
            return Ok(Token::new(TokenKind::Float(lexeme.to_string()), lexeme, self.span_from(start)));
        }

        let lexeme = self.slice(start.index, self.index);
        Ok(Token::new(TokenKind::Integer(lexeme.to_string()), lexeme, self.span_from(start)))
    }

    fn lex_whitespace(&mut self) -> Token {
        let start = self.mark();
        while matches!(self.peek_char(), Some(ch) if ch.is_whitespace() && ch != '\n') {
            let _ = self.bump_char();
        }
        let lexeme = self.slice(start.index, self.index);
        Token::new(TokenKind::Whitespace, lexeme, self.span_from(start))
    }

    fn lex_comment(&mut self) -> Token {
        let start = self.mark();
        let first = self.bump_char().expect("comment must start with a marker");
        if first == '/' {
            let _ = self.bump_char();
        }
        while matches!(self.peek_char(), Some(ch) if ch != '\n') {
            let _ = self.bump_char();
        }
        let lexeme = self.slice(start.index, self.index);
        Token::new(TokenKind::Comment, lexeme, self.span_from(start))
    }

    fn lex_block_comment(&mut self) -> Result<Token, Stage0Error> {
        let start = self.mark();
        let _ = self.bump_char();
        let _ = self.bump_char();
        let mut depth = 1usize;
        while let Some(ch) = self.peek_char() {
            if ch == '#' && self.peek_second_char() == Some('|') {
                let _ = self.bump_char();
                let _ = self.bump_char();
                depth += 1;
                continue;
            }
            if ch == '|' && self.peek_second_char() == Some('#') {
                let _ = self.bump_char();
                let _ = self.bump_char();
                depth -= 1;
                if depth == 0 {
                    let lexeme = self.slice(start.index, self.index);
                    return Ok(Token::new(TokenKind::Comment, lexeme, self.span_from(start)));
                }
                continue;
            }
            let _ = self.bump_char();
        }
        Err(Stage0Error::lex(self.span_from(start), "unterminated block comment"))
    }

    fn lex_slash_family(&mut self) -> Token {
        let start = self.mark();
        let first = self.bump_char().expect("character already checked");
        if self.peek_char() == Some('=') {
            let second = self.bump_char().expect("peeked char must exist");
            Token::new(TokenKind::SlashEq, format!("{first}{second}"), self.span_from(start))
        } else {
            Token::new(TokenKind::Slash, first.to_string(), self.span_from(start))
        }
    }

    fn lex_escape_char(&mut self, start: Marker, escaped: char) -> Result<char, Stage0Error> {
        match escaped {
            'n' => Ok('\n'),
            'r' => Ok('\r'),
            't' => Ok('\t'),
            '0' => Ok('\0'),
            '"' => Ok('"'),
            '\'' => Ok('\''),
            '\\' => Ok('\\'),
            'x' => self.lex_hex_escape(start),
            'u' => self.lex_unicode_escape(start),
            other => Err(Stage0Error::lex(
                self.span_from(start),
                format!("unsupported escape sequence \\{other}"),
            )),
        }
    }

    fn lex_hex_escape(&mut self, start: Marker) -> Result<char, Stage0Error> {
        let first = self.bump_char().ok_or_else(|| Stage0Error::lex(self.span_from(start), "unterminated hex escape"))?;
        let second = self.bump_char().ok_or_else(|| Stage0Error::lex(self.span_from(start), "unterminated hex escape"))?;
        if !is_hex_digit(first) || !is_hex_digit(second) {
            return Err(Stage0Error::lex(self.span_from(start), "hex escape must use two hex digits"));
        }
        let value = u32::from_str_radix(&format!("{first}{second}"), 16)
            .map_err(|_| Stage0Error::lex(self.span_from(start), "invalid hex escape value"))?;
        char::from_u32(value).ok_or_else(|| Stage0Error::lex(self.span_from(start), "invalid hex escape scalar value"))
    }

    fn lex_unicode_escape(&mut self, start: Marker) -> Result<char, Stage0Error> {
        if self.peek_char() != Some('{') {
            let mut digits = String::new();
            for _ in 0..4 {
                let ch = self.bump_char().ok_or_else(|| {
                    Stage0Error::lex(self.span_from(start), "unterminated unicode escape")
                })?;
                if !is_hex_digit(ch) {
                    return Err(Stage0Error::lex(self.span_from(start), "unicode escape must use hex digits"));
                }
                digits.push(ch);
            }
            let value = u32::from_str_radix(&digits, 16)
                .map_err(|_| Stage0Error::lex(self.span_from(start), "invalid unicode escape value"))?;
            return char::from_u32(value)
                .ok_or_else(|| Stage0Error::lex(self.span_from(start), "invalid unicode scalar value"));
        }
        let _ = self.bump_char();
        let mut digits = String::new();
        while let Some(ch) = self.peek_char() {
            if ch == '}' {
                let _ = self.bump_char();
                break;
            }
            if !is_hex_digit(ch) {
                return Err(Stage0Error::lex(self.span_from(start), "unicode escape must use hex digits"));
            }
            digits.push(ch);
            let _ = self.bump_char();
        }
        if digits.is_empty() {
            return Err(Stage0Error::lex(self.span_from(start), "unicode escape cannot be empty"));
        }
        let value = u32::from_str_radix(&digits, 16)
            .map_err(|_| Stage0Error::lex(self.span_from(start), "invalid unicode escape value"))?;
        char::from_u32(value).ok_or_else(|| Stage0Error::lex(self.span_from(start), "invalid unicode scalar value"))
    }

    fn consume_decimal_digits(&mut self) {
        while matches!(self.peek_char(), Some(ch) if ch.is_ascii_digit() || ch == '_') {
            let _ = self.bump_char();
        }
    }

    fn consume_prefixed_digits<F>(&mut self, predicate: F)
    where
        F: Fn(char) -> bool,
    {
        while matches!(self.peek_char(), Some(ch) if predicate(ch) || ch == '_') {
            let _ = self.bump_char();
        }
    }

    fn ensure_prefixed_digits(
        &self,
        start: Marker,
        prefix_len: usize,
        label: &str,
    ) -> Result<(), Stage0Error> {
        let digits = &self.source[start.index + prefix_len..self.index];
        if digits.chars().any(|ch| ch != '_') {
            Ok(())
        } else {
            Err(Stage0Error::lex(
                self.span_from(start),
                format!("{label} integer literal must contain at least one digit"),
            ))
        }
    }

    fn peek_char(&self) -> Option<char> {
        self.source[self.index..]
            .char_indices()
            .next()
            .map(|(_, ch)| ch)
    }

    fn peek_second_char(&self) -> Option<char> {
        let mut chars = self.source[self.index..].char_indices();
        let _ = chars.next();
        chars.next().map(|(_, ch)| ch)
    }

    fn peek_third_char(&self) -> Option<char> {
        let mut chars = self.source[self.index..].char_indices();
        let _ = chars.next();
        let _ = chars.next();
        chars.next().map(|(_, ch)| ch)
    }

    fn bump_char(&mut self) -> Option<char> {
        let ch = self.peek_char()?;
        self.index += ch.len_utf8();
        if ch == '\n' {
            self.line += 1;
            self.col = 1;
        } else {
            self.col += 1;
        }
        Some(ch)
    }

    fn slice(&self, start: usize, end: usize) -> &'src str {
        &self.source[start..end]
    }

    fn mark(&self) -> Marker {
        Marker {
            index: self.index,
            line: self.line,
            col: self.col,
        }
    }

    fn span_from(&self, start: Marker) -> Span {
        Span::new(start.line, start.col, start.index, self.index)
    }
}

fn is_hex_digit(ch: char) -> bool {
    ch.is_ascii_hexdigit()
}

#[derive(Clone, Copy, Debug)]
struct Marker {
    index: usize,
    line: usize,
    col: usize,
}

#[cfg(test)]
mod tests {
    use super::token::TokenKind;
    use super::{lex, lex_preserving_trivia, Lexer};

    #[test]
    fn public_lex_on_empty_input_returns_no_tokens() {
        let tokens = lex("").expect("lex should succeed");
        assert!(tokens.is_empty());
    }

    #[test]
    fn lexes_trait_signature_and_struct() {
        let source = "trait Draw { fn draw(Self) -> dyn Surface; } struct Pixel {}";
        let tokens = Lexer::new(source).lex_all().expect("lex should succeed");
        let kinds: Vec<TokenKind> = tokens.into_iter().map(|token| token.kind).collect();
        assert_eq!(
            kinds,
            vec![
                TokenKind::KeywordTrait,
                TokenKind::Ident("Draw".to_string()),
                TokenKind::LBrace,
                TokenKind::KeywordFn,
                TokenKind::Ident("draw".to_string()),
                TokenKind::LParen,
                TokenKind::KeywordSelfTy,
                TokenKind::RParen,
                TokenKind::Arrow,
                TokenKind::KeywordDyn,
                TokenKind::Ident("Surface".to_string()),
                TokenKind::Semi,
                TokenKind::RBrace,
                TokenKind::KeywordStruct,
                TokenKind::Ident("Pixel".to_string()),
                TokenKind::LBrace,
                TokenKind::RBrace,
                TokenKind::Eof,
            ]
        );
    }

    #[test]
    fn rejects_unknown_character() {
        let error = Lexer::new("$").lex_all().expect_err("lex should fail");
        assert!(error.to_string().contains("unexpected character '$'"));
    }

    #[test]
    fn lexes_extended_keyword_and_operator_surface() {
        let source = "pub module mod const type extern while match when return break next continue where as super crate yield async await effect implies handle with budget pre post invariant guard try catch finally macro comptime loop pure inline unless until self += -= *= /= %= => ..= << >> / ? ^ ~";
        let tokens = Lexer::new(source).lex_all().expect("lex should succeed");
        let kinds: Vec<TokenKind> = tokens.into_iter().map(|token| token.kind).collect();
        assert_eq!(
            kinds,
            vec![
                TokenKind::KeywordPub,
                TokenKind::KeywordModule,
                TokenKind::KeywordMod,
                TokenKind::KeywordConst,
                TokenKind::KeywordType,
                TokenKind::KeywordExtern,
                TokenKind::KeywordWhile,
                TokenKind::KeywordMatch,
                TokenKind::KeywordWhen,
                TokenKind::KeywordReturn,
                TokenKind::KeywordBreak,
                TokenKind::KeywordNext,
                TokenKind::KeywordNext,
                TokenKind::KeywordWhere,
                TokenKind::KeywordAs,
                TokenKind::KeywordSuper,
                TokenKind::KeywordCrate,
                TokenKind::KeywordYield,
                TokenKind::KeywordAsync,
                TokenKind::KeywordAwait,
                TokenKind::KeywordEffect,
                TokenKind::KeywordImplies,
                TokenKind::KeywordHandle,
                TokenKind::KeywordWith,
                TokenKind::KeywordBudget,
                TokenKind::KeywordPre,
                TokenKind::KeywordPost,
                TokenKind::KeywordInvariant,
                TokenKind::KeywordGuard,
                TokenKind::KeywordTry,
                TokenKind::KeywordCatch,
                TokenKind::KeywordFinally,
                TokenKind::KeywordMacro,
                TokenKind::KeywordComptime,
                TokenKind::KeywordLoop,
                TokenKind::KeywordPure,
                TokenKind::KeywordInline,
                TokenKind::KeywordUnless,
                TokenKind::KeywordUntil,
                TokenKind::KeywordSelfValue,
                TokenKind::PlusEq,
                TokenKind::MinusEq,
                TokenKind::StarEq,
                TokenKind::SlashEq,
                TokenKind::PercentEq,
                TokenKind::FatArrow,
                TokenKind::DotDotEq,
                TokenKind::Shl,
                TokenKind::Shr,
                TokenKind::Slash,
                TokenKind::Question,
                TokenKind::Caret,
                TokenKind::Tilde,
                TokenKind::Eof,
            ]
        );
    }

    #[test]
    fn preserves_comment_and_whitespace_trivia() {
        let tokens = lex_preserving_trivia("# comment\n  ").expect("lex should succeed");
        let kinds: Vec<TokenKind> = tokens.into_iter().map(|token| token.kind).collect();
        assert_eq!(kinds, vec![TokenKind::Comment, TokenKind::Newline, TokenKind::Whitespace]);
    }

    #[test]
    fn reversible_lex_preserves_original_source() {
        let source = "def constant() -> Int\n  42\nend\n";
        let tokens = lex_preserving_trivia(source).expect("lex should succeed");
        let round_trip = tokens.into_iter().map(|token| token.lexeme).collect::<String>();
        assert_eq!(round_trip, source);
    }

    #[test]
    fn lexes_string_and_metadata_tokens() {
        let source = "@test\nuse std::core\nedition \"2026\"\n";
        let tokens = Lexer::new(source).lex_all().expect("lex should succeed");
        let kinds: Vec<TokenKind> = tokens.into_iter().map(|token| token.kind).collect();
        assert_eq!(
            kinds,
            vec![
                TokenKind::At,
                TokenKind::Ident("test".to_string()),
                TokenKind::Newline,
                TokenKind::KeywordUse,
                TokenKind::Ident("std".to_string()),
                TokenKind::ColonColon,
                TokenKind::Ident("core".to_string()),
                TokenKind::Newline,
                TokenKind::KeywordEdition,
                TokenKind::String("2026".to_string()),
                TokenKind::Newline,
                TokenKind::Eof,
            ]
        );
    }

    #[test]
    fn lexes_prefixed_numbers_floats_chars_and_nested_block_comments() {
        let source = "0xFF 0b1010 0o77 3.14 6.02e23 '\\n' #| outer #| inner |# done |#";
        let tokens = lex_preserving_trivia(source).expect("lex should succeed");
        let kinds: Vec<TokenKind> = tokens.into_iter().map(|token| token.kind).collect();
        assert_eq!(
            kinds,
            vec![
                TokenKind::Integer("0xFF".to_string()),
                TokenKind::Whitespace,
                TokenKind::Integer("0b1010".to_string()),
                TokenKind::Whitespace,
                TokenKind::Integer("0o77".to_string()),
                TokenKind::Whitespace,
                TokenKind::Float("3.14".to_string()),
                TokenKind::Whitespace,
                TokenKind::Float("6.02e23".to_string()),
                TokenKind::Whitespace,
                TokenKind::Char('\n'),
                TokenKind::Whitespace,
                TokenKind::Comment,
            ]
        );
    }

    #[test]
    fn lexes_apostrophe_prefixed_lifetime_bounds_as_identifiers() {
        let source = "def register[F: Format + 'static](f: F) -> Unit";
        let tokens = Lexer::new(source).lex_all().expect("lex should succeed");
        let kinds: Vec<TokenKind> = tokens.into_iter().map(|token| token.kind).collect();
        assert!(kinds.contains(&TokenKind::Ident("'static".to_string())));
        assert!(!kinds.contains(&TokenKind::Char('s')));
    }

    #[test]
    fn rejects_invalid_prefixed_and_exponent_numbers() {
        let hex_error = Lexer::new("0x").lex_all().expect_err("hex literal should fail");
        assert!(hex_error.to_string().contains("hex integer literal must contain at least one digit"));

        let float_error = Lexer::new("1.0e").lex_all().expect_err("float exponent should fail");
        assert!(float_error.to_string().contains("float exponent must contain digits"));
    }
}
