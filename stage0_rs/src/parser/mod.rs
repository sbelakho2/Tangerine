use crate::ast::decl::{
    BudgetClause, BudgetEntry, BudgetOp, ConstDecl, ContractClause, ContractKind, Decl, EnumDecl,
    ExternBlockDecl, FieldDecl, FunctionClause, FunctionDecl, FunctionSig, ImplDecl, MetaDecl,
    MetaKind, Module, ModuleDecl, Param, RequiresClause, StructDecl, TraitDecl, TypeAliasDecl,
    TypeParam, VariantDecl, WherePredicate,
};
use crate::ast::expr::{
    BinaryOp, BlockBody, BranchGuard, CallArg, ClosureExpr, Expr, FunctionBody, IfBranch, MatchArm,
    Pattern, Stmt, UnaryOp,
};
use crate::ast::types::TypeRef;
use crate::error::Stage0Error;
use crate::lexer::token::{Token, TokenKind};
use crate::span::Span;

#[derive(Debug)]
pub struct Parser {
    tokens: Vec<Token>,
    cursor: usize,
}

impl Parser {
    #[must_use]
    pub fn new(tokens: Vec<Token>) -> Self {
        let has_eof = matches!(tokens.last().map(|token| &token.kind), Some(TokenKind::Eof));
        let mut tokens = tokens;
        if !has_eof {
            let span = tokens
                .last()
                .map_or_else(|| Span::new(1, 1, 0, 0), |token| token.span);
            tokens.push(Token {
                kind: TokenKind::Eof,
                lexeme: String::new(),
                span,
            });
        }
        Self { tokens, cursor: 0 }
    }

    #[must_use]
    pub fn peek(&self) -> &Token {
        &self.tokens[self.cursor]
    }

    #[must_use]
    pub fn advance(&mut self) -> Token {
        let token = self.tokens[self.cursor].clone();
        if !matches!(token.kind, TokenKind::Eof) {
            self.cursor += 1;
        }
        token
    }

    /// Parse the full token stream into a Tangerine module.
    ///
    /// # Errors
    /// Returns `Stage0Error` when the token stream does not match the expected
    /// top-level Tangerine grammar.
    pub fn parse_module(&mut self) -> Result<Module, Stage0Error> {
        let mut decls = Vec::new();
        self.skip_newlines();
        while !self.at_eof() {
            if self.match_kind(&TokenKind::KeywordEnd) {
                self.skip_newlines();
                continue;
            }
            decls.push(self.parse_decl()?);
            self.skip_newlines();
        }
        Ok(Module { decls })
    }

    fn parse_decl(&mut self) -> Result<Decl, Stage0Error> {
        self.skip_newlines();
        let public = self.match_kind(&TokenKind::KeywordPub);
        if public {
            self.skip_newlines();
        }
        match self.peek_kind() {
            TokenKind::KeywordModule | TokenKind::KeywordMod => self.parse_module_decl(public).map(Decl::Module),
            TokenKind::At => self.parse_annotation().map(Decl::Meta),
            TokenKind::KeywordUse => self.parse_use_decl().map(Decl::Meta),
            TokenKind::KeywordEdition => self.parse_edition_decl().map(Decl::Meta),
            TokenKind::KeywordRationale => self.parse_rationale_decl().map(Decl::Meta),
            TokenKind::KeywordCap => self.parse_cap_decl().map(Decl::Meta),
            TokenKind::KeywordStruct => self.parse_struct(public).map(Decl::Struct),
            TokenKind::KeywordEnum => self.parse_enum(public).map(Decl::Enum),
            TokenKind::KeywordTrait => self.parse_trait(public).map(Decl::Trait),
            TokenKind::KeywordImpl => self.parse_impl().map(Decl::Impl),
            TokenKind::KeywordFn | TokenKind::KeywordDef => self.parse_function_decl(public).map(Decl::Function),
            TokenKind::KeywordType => self.parse_type_alias(public).map(Decl::TypeAlias),
            TokenKind::KeywordConst => self.parse_const_decl(public).map(Decl::Const),
            TokenKind::KeywordMut => self.parse_global_decl(public).map(Decl::Global),
            TokenKind::KeywordExtern => self.parse_extern_decl().map(Decl::Extern),
            other => Err(Stage0Error::parse(
                self.peek().span,
                format!("unexpected token at top level: {other:?}"),
            )),
        }
    }

    fn parse_module_decl(&mut self, public: bool) -> Result<ModuleDecl, Stage0Error> {
        let start = if self.match_kind(&TokenKind::KeywordModule) {
            self.last_consumed_span(self.peek().span)
        } else {
            self.expect(&TokenKind::KeywordMod)?.span
        };
        let name = self.parse_type_name()?;
        self.skip_newlines();
        let mut decls = Vec::new();
        while !self.check(&TokenKind::KeywordEnd) {
            decls.push(self.parse_decl()?);
            self.skip_newlines();
        }
        let end = self.expect(&TokenKind::KeywordEnd)?.span;
        Ok(ModuleDecl {
            name,
            public,
            decls,
            span: merge_spans(start, end),
        })
    }

    fn parse_struct(&mut self, public: bool) -> Result<StructDecl, Stage0Error> {
        let start = self.expect(&TokenKind::KeywordStruct)?.span;
        let name = self.expect_ident()?;
        let type_params = self.parse_optional_type_params()?;
        let where_clause = self.parse_optional_where_clause()?;
        let (fields, end) = if self.match_kind(&TokenKind::LBrace) {
            self.skip_newlines();
            let mut fields = Vec::new();
            while !self.check(&TokenKind::RBrace) {
                fields.push(self.parse_field_decl()?);
                if !self.match_kind(&TokenKind::Comma) {
                    break;
                }
                self.skip_newlines();
            }
            (fields, self.expect(&TokenKind::RBrace)?.span)
        } else {
            self.skip_newlines();
            let mut fields = Vec::new();
            while !self.check(&TokenKind::KeywordEnd) {
                fields.push(self.parse_field_decl()?);
                self.skip_newlines();
            }
            (fields, self.expect(&TokenKind::KeywordEnd)?.span)
        };
        Ok(StructDecl {
            name,
            public,
            type_params,
            where_clause,
            fields,
            span: merge_spans(start, end),
        })
    }

    fn parse_enum(&mut self, public: bool) -> Result<EnumDecl, Stage0Error> {
        let start = self.expect(&TokenKind::KeywordEnum)?.span;
        let name = self.expect_ident()?;
        let type_params = self.parse_optional_type_params()?;
        let where_clause = self.parse_optional_where_clause()?;
        self.skip_newlines();
        let mut variants = Vec::new();
        while !self.check(&TokenKind::KeywordEnd) {
            self.skip_newlines();
            if self.check(&TokenKind::KeywordEnd) {
                break;
            }
            variants.push(self.parse_variant_decl()?);
            let _ = self.match_kind(&TokenKind::Semi);
            self.skip_newlines();
        }
        let end = self.expect(&TokenKind::KeywordEnd)?.span;
        Ok(EnumDecl {
            name,
            public,
            type_params,
            where_clause,
            variants,
            span: merge_spans(start, end),
        })
    }

    fn parse_trait(&mut self, public: bool) -> Result<TraitDecl, Stage0Error> {
        let start = self.expect(&TokenKind::KeywordTrait)?.span;
        let name = self.expect_ident()?;
        let type_params = self.parse_optional_type_params()?;
        let supertraits = if self.match_kind(&TokenKind::Colon) {
            self.parse_bound_list()?
        } else {
            Vec::new()
        };
        let where_clause = self.parse_optional_where_clause()?;
        let mut methods = Vec::new();
        let mut associated_types = Vec::new();
        let end = if self.match_kind(&TokenKind::LBrace) {
            self.skip_newlines();
            while !self.check(&TokenKind::RBrace) {
                let item_public = self.match_kind(&TokenKind::KeywordPub);
                if self.check(&TokenKind::KeywordType) {
                    associated_types.push(self.parse_type_alias(item_public)?);
                } else {
                    methods.push(self.parse_trait_method(item_public)?);
                }
                let _ = self.match_kind(&TokenKind::Semi);
                self.skip_newlines();
            }
            self.expect(&TokenKind::RBrace)?.span
        } else {
            self.skip_newlines();
            while !self.check(&TokenKind::KeywordEnd) {
                let item_public = self.match_kind(&TokenKind::KeywordPub);
                if self.check(&TokenKind::KeywordType) {
                    associated_types.push(self.parse_type_alias(item_public)?);
                } else {
                    methods.push(self.parse_trait_method(item_public)?);
                }
                self.skip_newlines();
            }
            self.expect(&TokenKind::KeywordEnd)?.span
        };
        Ok(TraitDecl {
            name,
            public,
            type_params,
            supertraits,
            where_clause,
            methods,
            associated_types,
            span: merge_spans(start, end),
        })
    }

    fn parse_trait_method(&mut self, public: bool) -> Result<FunctionDecl, Stage0Error> {
        let sig = self.parse_signature(public)?;
        self.skip_newlines();
        let body = if self.check(&TokenKind::KeywordDef)
            || self.check(&TokenKind::KeywordType)
            || self.check(&TokenKind::KeywordEnd)
            || self.check(&TokenKind::Semi)
            || self.check(&TokenKind::RBrace)
        {
            FunctionBody::Declaration { span: sig.span }
        } else if self.match_kind(&TokenKind::Eq) {
            self.parse_inline_expr_body(sig.span)?
        } else {
            self.parse_end_terminated_body(sig.span)?
        };
        Ok(FunctionDecl {
            span: merge_spans(sig.span, function_body_span(&body)),
            sig,
            clauses: Vec::new(),
            body,
        })
    }

    fn parse_impl(&mut self) -> Result<ImplDecl, Stage0Error> {
        let start = self.expect(&TokenKind::KeywordImpl)?.span;
        let type_params = self.parse_optional_type_params()?;
        let first_type = self.parse_type()?;
        let is_trait_impl = self.match_kind(&TokenKind::KeywordFor)
            || matches!(
            self.peek_kind(),
            TokenKind::Ident(_) | TokenKind::KeywordSelfTy | TokenKind::KeywordDyn | TokenKind::LParen
        );
        let (trait_name, for_type) = if is_trait_impl {
            (target_type_name(&first_type)?, self.parse_type()?)
        } else {
            (String::new(), first_type)
        };
        let target_type = target_type_name(&for_type)?;
        let where_clause = self.parse_optional_where_clause()?;
        let mut methods = Vec::new();
        let mut associated_types = Vec::new();
        let end = if self.match_kind(&TokenKind::LBrace) {
            self.skip_newlines();
            while !self.check(&TokenKind::RBrace) {
                let item_public = self.match_kind(&TokenKind::KeywordPub);
                if self.check(&TokenKind::KeywordType) {
                    associated_types.push(self.parse_type_alias(item_public)?);
                } else {
                    methods.push(self.parse_function_decl(item_public)?);
                }
                self.skip_newlines();
            }
            self.expect(&TokenKind::RBrace)?.span
        } else {
            self.skip_newlines();
            while !self.check(&TokenKind::KeywordEnd) {
                let item_public = self.match_kind(&TokenKind::KeywordPub);
                if self.check(&TokenKind::KeywordType) {
                    associated_types.push(self.parse_type_alias(item_public)?);
                } else {
                    methods.push(self.parse_function_decl(item_public)?);
                }
                self.skip_newlines();
            }
            self.expect(&TokenKind::KeywordEnd)?.span
        };
        Ok(ImplDecl {
            type_params,
            trait_name,
            target_type,
            for_type,
            where_clause,
            methods,
            associated_types,
            span: merge_spans(start, end),
        })
    }

    fn parse_function_decl(&mut self, public: bool) -> Result<FunctionDecl, Stage0Error> {
        let sig = self.parse_signature(public)?;
        self.skip_newlines();
        let clauses = self.parse_function_clauses()?;
        let body = if self.match_kind(&TokenKind::Eq) {
            self.parse_inline_expr_body(sig.span)?
        } else if self.match_kind(&TokenKind::LBrace) {
            self.parse_braced_body(sig.span)?
        } else {
            self.parse_end_terminated_body(sig.span)?
        };
        Ok(FunctionDecl {
            sig: sig.clone(),
            clauses,
            span: merge_spans(sig.span, function_body_span(&body)),
            body,
        })
    }

    fn parse_function_clauses(&mut self) -> Result<Vec<FunctionClause>, Stage0Error> {
        let mut clauses = Vec::new();
        loop {
            let clause = match self.peek_kind() {
                TokenKind::KeywordRequires => Some(FunctionClause::Requires(self.parse_requires_clause()?)),
                TokenKind::KeywordBudget => Some(FunctionClause::Budget(self.parse_budget_clause()?)),
                TokenKind::KeywordPre => Some(FunctionClause::Contract(self.parse_contract_clause(ContractKind::Pre)?)),
                TokenKind::KeywordPost => Some(FunctionClause::Contract(self.parse_contract_clause(ContractKind::Post)?)),
                TokenKind::KeywordInvariant => {
                    Some(FunctionClause::Contract(self.parse_contract_clause(ContractKind::Invariant)?))
                }
                _ => None,
            };
            let Some(clause) = clause else { break };
            clauses.push(clause);
            self.skip_newlines();
        }
        Ok(clauses)
    }

    fn parse_requires_clause(&mut self) -> Result<RequiresClause, Stage0Error> {
        let start = self.expect(&TokenKind::KeywordRequires)?.span;
        let mut capabilities = vec![self.expect_ident()?];
        while self.match_kind(&TokenKind::Comma) {
            capabilities.push(self.expect_ident()?);
        }
        Ok(RequiresClause {
            capabilities,
            span: merge_spans(start, self.last_consumed_span(start)),
        })
    }

    fn parse_budget_clause(&mut self) -> Result<BudgetClause, Stage0Error> {
        let start = self.expect(&TokenKind::KeywordBudget)?.span;
        let mut entries = Vec::new();
        loop {
            let metric = self.expect_ident()?;
            let operator = match self.bump().kind {
                TokenKind::Lt => BudgetOp::Lt,
                TokenKind::LtEq => BudgetOp::LtEq,
                TokenKind::Gt => BudgetOp::Gt,
                TokenKind::GtEq => BudgetOp::GtEq,
                other => {
                    return Err(Stage0Error::parse(
                        self.peek().span,
                        format!("expected budget comparison operator, found {other:?}"),
                    ));
                }
            };
            let value_token = self.bump();
            let limit = match value_token.kind {
                TokenKind::String(value) | TokenKind::Integer(value) | TokenKind::Float(value) => value,
                other => {
                    return Err(Stage0Error::parse(
                        value_token.span,
                        format!("expected budget limit literal, found {other:?}"),
                    ));
                }
            };
            entries.push(BudgetEntry {
                metric,
                operator,
                limit,
                span: merge_spans(start, value_token.span),
            });
            if !self.match_kind(&TokenKind::Comma) {
                break;
            }
        }
        Ok(BudgetClause {
            entries,
            span: merge_spans(start, self.last_consumed_span(start)),
        })
    }

    fn parse_contract_clause(&mut self, kind: ContractKind) -> Result<ContractClause, Stage0Error> {
        let start = match kind {
            ContractKind::Pre => self.expect(&TokenKind::KeywordPre)?.span,
            ContractKind::Post => self.expect(&TokenKind::KeywordPost)?.span,
            ContractKind::Invariant => self.expect(&TokenKind::KeywordInvariant)?.span,
        };
        let condition = self.parse_expr()?;
        let message = if self.match_kind(&TokenKind::Comma) {
            match self.bump().kind {
                TokenKind::String(value) => Some(value),
                other => {
                    return Err(Stage0Error::parse(
                        self.peek().span,
                        format!("expected contract message string, found {other:?}"),
                    ));
                }
            }
        } else {
            None
        };
        Ok(ContractClause {
            kind,
            span: merge_spans(start, condition.span()),
            condition,
            message,
        })
    }

    fn parse_inline_expr_body(&mut self, start: Span) -> Result<FunctionBody, Stage0Error> {
        let expr = self.parse_expr()?;
        Ok(FunctionBody::Block(BlockBody {
            stmts: Vec::new(),
            tail: Some(expr.clone()),
            span: merge_spans(start, expr.span()),
        }))
    }

    fn parse_braced_body(&mut self, start: Span) -> Result<FunctionBody, Stage0Error> {
        self.skip_newlines();
        if self.check(&TokenKind::RBrace) {
            let end = self.expect(&TokenKind::RBrace)?.span;
            return Ok(FunctionBody::Declaration {
                span: merge_spans(start, end),
            });
        }

        let mut block = self.parse_block_body(&TokenKind::RBrace)?;
        let end = self.expect(&TokenKind::RBrace)?.span;
        block.span = merge_spans(start, end);
        Ok(FunctionBody::Block(block))
    }

    fn parse_end_terminated_body(&mut self, start: Span) -> Result<FunctionBody, Stage0Error> {
        self.skip_newlines();
        let mut block = self.parse_block_body(&TokenKind::KeywordEnd)?;
        self.skip_newlines();
        let end = self.expect(&TokenKind::KeywordEnd)?.span;
        block.span = merge_spans(start, end);
        Ok(FunctionBody::Block(block))
    }

    #[allow(clippy::too_many_lines)]
    fn parse_block_body(&mut self, terminator: &TokenKind) -> Result<BlockBody, Stage0Error> {
        self.skip_newlines();
        let start = self.peek().span;
        let mut stmts = Vec::new();
        let mut tail = None;

        loop {
            self.skip_newlines();
            if self.check(terminator) {
                break;
            }
            if self.at_eof() {
                return Err(Stage0Error::parse(start, format!("expected {terminator:?} before EOF")));
            }

            if let Some(stmt) = self.try_parse_nested_decl_stmt()? {
                stmts.push(stmt);
                self.consume_stmt_separator(terminator)?;
                self.skip_newlines();
                continue;
            }

            if self.check(&TokenKind::KeywordRequires) {
                let requires_span = self.expect(&TokenKind::KeywordRequires)?.span;
                let capability = self.expect_ident()?;
                stmts.push(Stmt::Requires {
                    capability,
                    span: merge_spans(requires_span, self.last_consumed_span(requires_span)),
                });
                self.consume_stmt_separator(terminator)?;
                self.skip_newlines();
                continue;
            }

            if self.check(&TokenKind::KeywordExtern) {
                let decl = self.parse_extern_decl()?;
                let span = decl.span;
                stmts.push(Stmt::Decl {
                    decl: Box::new(Decl::Extern(decl)),
                    span,
                });
                self.consume_stmt_separator(terminator)?;
                self.skip_newlines();
                continue;
            }

            if self.check(&TokenKind::KeywordWhile) || self.check(&TokenKind::KeywordUntil) {
                let stmt = self.parse_while_stmt()?;
                stmts.push(stmt);
                self.consume_stmt_separator(terminator)?;
                self.skip_newlines();
                continue;
            }

            if self.check(&TokenKind::KeywordLoop) {
                let stmt = self.parse_loop_stmt()?;
                stmts.push(stmt);
                self.consume_stmt_separator(terminator)?;
                self.skip_newlines();
                continue;
            }

            if self.check(&TokenKind::KeywordFor) {
                let stmt = self.parse_for_stmt()?;
                stmts.push(stmt);
                self.consume_stmt_separator(terminator)?;
                self.skip_newlines();
                continue;
            }

            if self.check(&TokenKind::KeywordReturn) {
                let stmt = self.parse_return_stmt(terminator)?;
                stmts.push(stmt);
                self.consume_stmt_separator(terminator)?;
                self.skip_newlines();
                continue;
            }

            if self.check(&TokenKind::KeywordBreak) {
                let stmt = self.parse_break_stmt()?;
                stmts.push(stmt);
                self.consume_stmt_separator(terminator)?;
                self.skip_newlines();
                continue;
            }

            if self.check(&TokenKind::KeywordNext) {
                let stmt = self.parse_next_stmt()?;
                stmts.push(stmt);
                self.consume_stmt_separator(terminator)?;
                self.skip_newlines();
                continue;
            }

            if self.check(&TokenKind::KeywordLet)
                || self.check(&TokenKind::KeywordMut)
                || matches!(self.peek_kind(), TokenKind::Ident(name) if name == "var")
            {
                let stmt = self.parse_binding_stmt()?;
                stmts.push(stmt);
                self.consume_stmt_separator(terminator)?;
                self.skip_newlines();
                continue;
            }

            if self.check(&TokenKind::KeywordUse) {
                let meta = self.parse_use_decl()?;
                stmts.push(Stmt::Use {
                    path: meta.detail,
                    span: meta.span,
                });
                self.consume_stmt_separator(terminator)?;
                self.skip_newlines();
                continue;
            }

            if self.check(&TokenKind::KeywordStruct) {
                let decl = self.parse_struct(false)?;
                let span = decl.span;
                stmts.push(Stmt::Decl {
                    decl: Box::new(Decl::Struct(decl)),
                    span,
                });
                self.consume_stmt_separator(terminator)?;
                self.skip_newlines();
                continue;
            }

            if self.check(&TokenKind::KeywordImpl) {
                let decl = self.parse_impl()?;
                let span = decl.span;
                stmts.push(Stmt::Decl {
                    decl: Box::new(Decl::Impl(decl)),
                    span,
                });
                self.consume_stmt_separator(terminator)?;
                self.skip_newlines();
                continue;
            }

            if self.check(&TokenKind::At) {
                let meta = self.parse_annotation()?;
                stmts.push(Stmt::Meta {
                    span: meta.span,
                    decl: meta,
                });
                self.consume_stmt_separator(terminator)?;
                self.skip_newlines();
                continue;
            }

            if self.check(&TokenKind::KeywordDef) || self.check(&TokenKind::KeywordFn) {
                let function = self.parse_function_decl(false)?;
                stmts.push(Stmt::Function {
                    span: function.span,
                    decl: function,
                });
                self.consume_stmt_separator(terminator)?;
                self.skip_newlines();
                continue;
            }

            let expr = self.parse_expr()?;
            if self.match_kind(&TokenKind::Eq) {
                let value = self.parse_expr()?;
                let span = merge_spans(expr.span(), value.span());
                stmts.push(Stmt::Assign {
                    target: expr,
                    value,
                    span,
                });
                self.consume_stmt_separator(terminator)?;
                self.skip_newlines();
                continue;
            }
            if self.expression_is_tail(terminator) {
                tail = Some(expr);
                break;
            }

            let span = expr.span();
            stmts.push(Stmt::Expr { expr, span });
            self.consume_stmt_separator(terminator)?;
            self.skip_newlines();
        }

        let end = tail
            .as_ref()
            .map_or_else(|| stmts.last().map_or(start, Stmt::span), Expr::span);
        Ok(BlockBody {
            stmts,
            tail,
            span: merge_spans(start, end),
        })
    }

    fn parse_binding_stmt(&mut self) -> Result<Stmt, Stage0Error> {
        let (start, mutable) = if matches!(self.peek_kind(), TokenKind::Ident(name) if name == "var") {
            let start = self.bump().span;
            (start, true)
        } else if self.match_kind(&TokenKind::KeywordLet) {
            let let_span = self.last_consumed_span(self.peek().span);
            (let_span, self.match_kind(&TokenKind::KeywordMut))
        } else {
            (self.expect(&TokenKind::KeywordMut)?.span, true)
        };
        let pattern = self.parse_binding_pattern()?;
        let inferred_type = if self.match_kind(&TokenKind::Colon) {
            Some(self.parse_type()?)
        } else {
            None
        };
        let _ = self.expect(&TokenKind::Eq)?;
        let value = self.parse_expr()?;
        Ok(Stmt::Let {
            pattern,
            mutable,
            value: value.clone(),
            inferred_type,
            span: merge_spans(start, value.span()),
        })
    }

    fn parse_binding_pattern(&mut self) -> Result<Pattern, Stage0Error> {
        match self.peek_kind() {
            TokenKind::LParen => self.parse_tuple_pattern(),
            _ => self.parse_pattern(),
        }
    }

    fn parse_while_stmt(&mut self) -> Result<Stmt, Stage0Error> {
        let negated = self.match_kind(&TokenKind::KeywordUntil);
        let start = if negated {
            self.last_consumed_span(self.peek().span)
        } else {
            self.expect(&TokenKind::KeywordWhile)?.span
        };
        let condition = self.parse_expr()?;
        self.skip_optional_do();
        self.skip_newlines();
        let body = self.parse_block_body_until_any(&[TokenKind::KeywordEnd])?;
        self.skip_newlines();
        let end = self.expect(&TokenKind::KeywordEnd)?.span;
        let condition = if negated {
            Expr::Unary {
                op: UnaryOp::Not,
                span: merge_spans(start, condition.span()),
                expr: Box::new(condition),
            }
        } else {
            condition
        };
        Ok(Stmt::While {
            condition,
            body,
            span: merge_spans(start, end),
        })
    }

    fn parse_for_stmt(&mut self) -> Result<Stmt, Stage0Error> {
        let start = self.expect(&TokenKind::KeywordFor)?.span;
        let pattern = self.parse_binding_pattern()?;
        let _ = self.expect(&TokenKind::KeywordIn)?;
        let iterable = self.parse_expr()?;
        self.skip_optional_do();
        self.skip_newlines();
        let body = self.parse_block_body_until_any(&[TokenKind::KeywordEnd])?;
        self.skip_newlines();
        let end = self.expect(&TokenKind::KeywordEnd)?.span;
        Ok(Stmt::For {
            pattern,
            iterable,
            body,
            span: merge_spans(start, end),
        })
    }

    fn parse_loop_stmt(&mut self) -> Result<Stmt, Stage0Error> {
        let start = self.expect(&TokenKind::KeywordLoop)?.span;
        self.skip_optional_do();
        self.skip_newlines();
        let body = self.parse_block_body_until_any(&[TokenKind::KeywordEnd])?;
        self.skip_newlines();
        let end = self.expect(&TokenKind::KeywordEnd)?.span;
        Ok(Stmt::Loop {
            body,
            span: merge_spans(start, end),
        })
    }

    fn parse_return_stmt(&mut self, terminator: &TokenKind) -> Result<Stmt, Stage0Error> {
        let start = self.expect(&TokenKind::KeywordReturn)?.span;
        let value = if self.expression_is_tail(terminator) {
            None
        } else {
            Some(self.parse_expr()?)
        };
        let end = value.as_ref().map_or(start, Expr::span);
        Ok(Stmt::Return {
            value,
            span: merge_spans(start, end),
        })
    }

    fn parse_break_stmt(&mut self) -> Result<Stmt, Stage0Error> {
        let span = self.expect(&TokenKind::KeywordBreak)?.span;
        Ok(Stmt::Break { span })
    }

    fn parse_next_stmt(&mut self) -> Result<Stmt, Stage0Error> {
        let span = self.expect(&TokenKind::KeywordNext)?.span;
        Ok(Stmt::Next { span })
    }

    fn parse_signature(&mut self, public: bool) -> Result<FunctionSig, Stage0Error> {
        let start = self.expect_function_keyword()?.span;
        let name = self.parse_type_name()?;
        let type_params = self.parse_optional_type_params()?;
        let _ = self.expect(&TokenKind::LParen)?;
        self.skip_newlines();
        let params = self.parse_params()?;
        self.skip_newlines();
        let _ = self.expect(&TokenKind::RParen)?;
        let return_type = if self.match_kind(&TokenKind::Arrow) {
            self.parse_type()?
        } else {
            TypeRef::Unit { span: self.peek().span }
        };
        let where_clause = self.parse_optional_where_clause()?;
        Ok(FunctionSig {
            name,
            public,
            type_params,
            params,
            return_type: return_type.clone(),
            where_clause,
            span: merge_spans(start, return_type.span()),
        })
    }

    fn parse_params(&mut self) -> Result<Vec<Param>, Stage0Error> {
        let mut params = Vec::new();
        if self.check(&TokenKind::RParen) {
            return Ok(params);
        }

        loop {
            self.skip_newlines();
            if self.check(&TokenKind::RParen) {
                break;
            }
            params.push(self.parse_param()?);
            if !self.match_kind(&TokenKind::Comma) {
                break;
            }
            self.skip_newlines();
        }

        Ok(params)
    }

    fn parse_param(&mut self) -> Result<Param, Stage0Error> {
        let start = self.peek().span;
        match self.peek_kind() {
            TokenKind::Amp => self.parse_borrowed_self_param(start),
            TokenKind::KeywordSelfValue
                if matches!(self.tokens.get(self.cursor + 1).map(|token| &token.kind), Some(TokenKind::Colon)) =>
            {
                self.parse_named_param(start, false)
            }
            TokenKind::KeywordMut => self.parse_named_param(start, true),
            TokenKind::KeywordSelfTy | TokenKind::KeywordSelfValue => {
                let token = self.bump();
                Ok(Param {
                    name: "self".to_string(),
                    mutable: false,
                    ty: TypeRef::SelfTy { span: token.span },
                    default_value: None,
                    span: merge_spans(start, token.span),
                })
            }
            TokenKind::Ident(name) if name == "self"
                && !matches!(self.tokens.get(self.cursor + 1).map(|token| &token.kind), Some(TokenKind::Colon)) =>
            {
                let token = self.bump();
                Ok(Param {
                    name: "self".to_string(),
                    mutable: false,
                    ty: TypeRef::SelfTy { span: token.span },
                    default_value: None,
                    span: merge_spans(start, token.span),
                })
            }
            TokenKind::Ident(_)
            | TokenKind::KeywordBudget
            | TokenKind::KeywordCap
            | TokenKind::KeywordConst
            | TokenKind::KeywordDef
            | TokenKind::KeywordEffect
            | TokenKind::KeywordEdition
            | TokenKind::KeywordExtern
            | TokenKind::KeywordFinally
            | TokenKind::KeywordGuard
            | TokenKind::KeywordImplies
            | TokenKind::KeywordInline
            | TokenKind::KeywordLoop
            | TokenKind::KeywordModule
            | TokenKind::KeywordNext
            | TokenKind::KeywordPost
            | TokenKind::KeywordPre
            | TokenKind::KeywordPub
            | TokenKind::KeywordRationale
            | TokenKind::KeywordType => self.parse_named_param(start, false),
            other => Err(Stage0Error::parse(
                self.peek().span,
                format!("unexpected parameter token: {other:?}"),
            )),
        }
    }

    fn parse_borrowed_self_param(&mut self, start: Span) -> Result<Param, Stage0Error> {
        let amp_span = self.bump().span;
        let mutable_ref = self.match_kind(&TokenKind::KeywordMut);
        match self.peek_kind() {
            TokenKind::KeywordSelfTy | TokenKind::KeywordSelfValue => {
                let token = self.bump();
                Ok(Param {
                    name: "self".to_string(),
                    mutable: false,
                    ty: TypeRef::Ref {
                        inner: Box::new(TypeRef::SelfTy { span: token.span }),
                        mutable: mutable_ref,
                        span: merge_spans(amp_span, token.span),
                    },
                    default_value: None,
                    span: merge_spans(start, token.span),
                })
            }
            TokenKind::Ident(name) if name == "self" => {
                let token = self.bump();
                Ok(Param {
                    name: "self".to_string(),
                    mutable: false,
                    ty: TypeRef::Ref {
                        inner: Box::new(TypeRef::SelfTy { span: token.span }),
                        mutable: mutable_ref,
                        span: merge_spans(amp_span, token.span),
                    },
                    default_value: None,
                    span: merge_spans(start, token.span),
                })
            }
            other => Err(Stage0Error::parse(
                self.peek().span,
                format!("unexpected parameter token: {other:?}"),
            )),
        }
    }

    fn parse_named_param(&mut self, start: Span, mutable: bool) -> Result<Param, Stage0Error> {
        if mutable {
            let _ = self.bump();
        }
        let name = self.expect_ident()?;
        let _ = self.expect(&TokenKind::Colon)?;
        let ty = self.parse_type()?;
        let default_value = if self.match_kind(&TokenKind::Eq) {
            Some(self.parse_expr()?)
        } else {
            None
        };
        let end = default_value.as_ref().map_or_else(|| ty.span(), Expr::span);
        Ok(Param {
            name,
            mutable,
            ty,
            default_value,
            span: merge_spans(start, end),
        })
    }

    #[allow(clippy::too_many_lines)]
    fn parse_type(&mut self) -> Result<TypeRef, Stage0Error> {
        if self.match_kind(&TokenKind::Star) {
            let span = self.last_consumed_span(self.peek().span);
            let mutable = self.match_kind(&TokenKind::KeywordMut);
            let inner = self.parse_type()?;
            return Ok(TypeRef::Ref {
                inner: Box::new(inner),
                mutable,
                span,
            });
        }
        if self.match_kind(&TokenKind::Amp) {
            let span = self.last_consumed_span(self.peek().span);
            let mutable = self.match_kind(&TokenKind::KeywordMut);
            let inner = self.parse_type()?;
            return Ok(TypeRef::Ref {
                inner: Box::new(inner),
                mutable,
                span,
            });
        }
        if self.match_kind(&TokenKind::KeywordFn) {
            let start = self.last_consumed_span(self.peek().span);
            let _ = self.expect(&TokenKind::LParen)?;
            let mut params = Vec::new();
            if !self.check(&TokenKind::RParen) {
                loop {
                    params.push(self.parse_type()?);
                    if !self.match_kind(&TokenKind::Comma) {
                        break;
                    }
                }
            }
            let _ = self.expect(&TokenKind::RParen)?;
            let _ = self.expect(&TokenKind::Arrow)?;
            let return_type = self.parse_type()?;
            return Ok(TypeRef::Function {
                params,
                return_type: Box::new(return_type.clone()),
                span: merge_spans(start, return_type.span()),
            });
        }
        if self.match_kind(&TokenKind::PipePipe) {
            let start = self.last_consumed_span(self.peek().span);
            let _ = self.expect(&TokenKind::Arrow)?;
            let return_type = self.parse_type()?;
            return Ok(TypeRef::Function {
                params: Vec::new(),
                return_type: Box::new(return_type.clone()),
                span: merge_spans(start, return_type.span()),
            });
        }
        if self.match_kind(&TokenKind::Pipe) {
            let start = self.last_consumed_span(self.peek().span);
            let mut params = Vec::new();
            if !self.check(&TokenKind::Pipe) {
                loop {
                    params.push(self.parse_type()?);
                    if !self.match_kind(&TokenKind::Comma) {
                        break;
                    }
                }
            }
            let _ = self.expect(&TokenKind::Pipe)?;
            let _ = self.expect(&TokenKind::Arrow)?;
            let return_type = self.parse_type()?;
            return Ok(TypeRef::Function {
                params,
                return_type: Box::new(return_type.clone()),
                span: merge_spans(start, return_type.span()),
            });
        }
        let token = self.bump();
        match token.kind {
            TokenKind::LParen => {
                let mut elements = Vec::new();
                if !self.check(&TokenKind::RParen) {
                    loop {
                        elements.push(self.parse_type()?);
                        if !self.match_kind(&TokenKind::Comma) {
                            break;
                        }
                    }
                }
                let end = self.expect(&TokenKind::RParen)?.span;
                let span = merge_spans(token.span, end);
                if elements.is_empty() {
                    Ok(TypeRef::Unit { span })
                } else {
                    Ok(TypeRef::Tuple { elements, span })
                }
            }
            TokenKind::LBracket => {
                let element = self.parse_type()?;
                let len = if self.match_kind(&TokenKind::Semi) {
                    match self.bump().kind {
                        TokenKind::Integer(value) => Some(value),
                        other => {
                            return Err(Stage0Error::parse(
                                self.peek().span,
                                format!("expected array length integer, found {other:?}"),
                            ));
                        }
                    }
                } else {
                    None
                };
                let end = self.expect(&TokenKind::RBracket)?.span;
                Ok(TypeRef::Array {
                    element: Box::new(element),
                    len,
                    span: merge_spans(token.span, end),
                })
            }
            TokenKind::Ident(name) if name == "Int" => Ok(TypeRef::Int { span: token.span }),
            TokenKind::Ident(name) if name == "Float" => Ok(TypeRef::Float { span: token.span }),
            TokenKind::Ident(name) if name == "Char" => Ok(TypeRef::Char { span: token.span }),
            TokenKind::Ident(name) if name == "String" => Ok(TypeRef::String { span: token.span }),
            TokenKind::Ident(name) if name == "Bool" => Ok(TypeRef::Bool { span: token.span }),
            TokenKind::Ident(name) if name == "Unit" => Ok(TypeRef::Unit { span: token.span }),
            TokenKind::KeywordSelfTy => {
                if self.match_kind(&TokenKind::ColonColon) {
                    let mut name = "Self::".to_string();
                    name.push_str(&self.expect_ident()?);
                    let type_args = self.parse_optional_type_args()?;
                    Ok(TypeRef::Named {
                        name,
                        type_args,
                        span: token.span,
                    })
                } else {
                    Ok(TypeRef::SelfTy { span: token.span })
                }
            }
            TokenKind::KeywordDyn => {
                let trait_name = self.parse_type_name()?;
                Ok(TypeRef::DynTrait {
                    trait_name,
                    span: token.span,
                })
            }
            TokenKind::Ident(name) => {
                let full_name = self.parse_type_name_tail(name)?;
                let type_args = self.parse_optional_type_args()?;
                Ok(TypeRef::Named {
                    name: full_name,
                    type_args,
                    span: token.span,
                })
            }
            other => Err(Stage0Error::parse(
                token.span,
                format!("unexpected type token: {other:?}"),
            )),
        }
    }

    fn parse_expr(&mut self) -> Result<Expr, Stage0Error> {
        if self.check(&TokenKind::Pipe) {
            let start = self.expect(&TokenKind::Pipe)?.span;
            return self.parse_closure_expr(start);
        }
        if self.check(&TokenKind::PipePipe) {
            let start = self.expect(&TokenKind::PipePipe)?.span;
            return self.parse_zero_param_closure_expr(start);
        }
        if self.check(&TokenKind::KeywordMatch) {
            let start = self.expect(&TokenKind::KeywordMatch)?.span;
            let expr = self.parse_match_expr(start)?;
            return self.parse_postfix_from(expr);
        }
        if self.check(&TokenKind::KeywordIf) {
            let start = self.expect(&TokenKind::KeywordIf)?.span;
            let expr = self.parse_if_expr(start)?;
            return self.parse_postfix_from(expr);
        }
        if self.check(&TokenKind::KeywordUnless) {
            let start = self.expect(&TokenKind::KeywordUnless)?.span;
            let expr = self.parse_unless_expr(start)?;
            return self.parse_postfix_from(expr);
        }
        self.parse_or()
    }

    fn parse_or(&mut self) -> Result<Expr, Stage0Error> {
        let mut expr = self.parse_and()?;
        loop {
            self.skip_infix_newlines();
            if !self.match_kind(&TokenKind::PipePipe) {
                break;
            }
            self.skip_newlines();
            let right = self.parse_and()?;
            let span = merge_spans(expr.span(), right.span());
            expr = Expr::Binary {
                left: Box::new(expr),
                op: BinaryOp::Or,
                right: Box::new(right),
                span,
            };
        }
        Ok(expr)
    }

    fn parse_and(&mut self) -> Result<Expr, Stage0Error> {
        let mut expr = self.parse_equality()?;
        loop {
            self.skip_infix_newlines();
            if !self.match_kind(&TokenKind::AmpAmp) {
                break;
            }
            self.skip_newlines();
            let right = self.parse_equality()?;
            let span = merge_spans(expr.span(), right.span());
            expr = Expr::Binary {
                left: Box::new(expr),
                op: BinaryOp::And,
                right: Box::new(right),
                span,
            };
        }
        Ok(expr)
    }

    fn parse_equality(&mut self) -> Result<Expr, Stage0Error> {
        let mut expr = self.parse_comparison()?;
        loop {
            self.skip_infix_newlines();
            let op = if self.match_kind(&TokenKind::EqEq) {
                Some(BinaryOp::Eq)
            } else if self.match_kind(&TokenKind::BangEq) {
                Some(BinaryOp::NotEq)
            } else {
                None
            };
            let Some(op) = op else { break };
            self.skip_newlines();
            let right = self.parse_comparison()?;
            let span = merge_spans(expr.span(), right.span());
            expr = Expr::Binary {
                left: Box::new(expr),
                op,
                right: Box::new(right),
                span,
            };
        }
        Ok(expr)
    }

    fn parse_comparison(&mut self) -> Result<Expr, Stage0Error> {
        let mut expr = self.parse_range()?;
        loop {
            self.skip_infix_newlines();
            let op = if self.match_kind(&TokenKind::Lt) {
                Some(BinaryOp::Lt)
            } else if self.match_kind(&TokenKind::LtEq) {
                Some(BinaryOp::LtEq)
            } else if self.match_kind(&TokenKind::Gt) {
                Some(BinaryOp::Gt)
            } else if self.match_kind(&TokenKind::GtEq) {
                Some(BinaryOp::GtEq)
            } else {
                None
            };
            let Some(op) = op else { break };
            self.skip_newlines();
            let right = self.parse_range()?;
            let span = merge_spans(expr.span(), right.span());
            expr = Expr::Binary {
                left: Box::new(expr),
                op,
                right: Box::new(right),
                span,
            };
        }
        Ok(expr)
    }

    fn parse_range(&mut self) -> Result<Expr, Stage0Error> {
        let expr = self.parse_bitwise_or()?;
        let inclusive = if self.match_kind(&TokenKind::DotDotEq) {
            Some(true)
        } else if self.match_kind(&TokenKind::DotDot) {
            Some(false)
        } else {
            None
        };
        let Some(inclusive) = inclusive else {
            return Ok(expr);
        };
        self.skip_newlines();
        let right = self.parse_bitwise_or()?;
        let span = merge_spans(expr.span(), right.span());
        Ok(Expr::Range {
            start: Box::new(expr),
            end: Box::new(right),
            inclusive,
            span,
        })
    }

    fn parse_bitwise_or(&mut self) -> Result<Expr, Stage0Error> {
        let mut expr = self.parse_bitwise_xor()?;
        loop {
            self.skip_infix_newlines();
            if !self.match_kind(&TokenKind::Pipe) {
                break;
            }
            self.skip_newlines();
            let right = self.parse_bitwise_xor()?;
            let span = merge_spans(expr.span(), right.span());
            expr = Expr::Binary {
                left: Box::new(expr),
                op: BinaryOp::BitOr,
                right: Box::new(right),
                span,
            };
        }
        Ok(expr)
    }

    fn parse_bitwise_xor(&mut self) -> Result<Expr, Stage0Error> {
        let mut expr = self.parse_bitwise_and()?;
        loop {
            self.skip_infix_newlines();
            if !self.match_kind(&TokenKind::Caret) {
                break;
            }
            self.skip_newlines();
            let right = self.parse_bitwise_and()?;
            let span = merge_spans(expr.span(), right.span());
            expr = Expr::Binary {
                left: Box::new(expr),
                op: BinaryOp::BitXor,
                right: Box::new(right),
                span,
            };
        }
        Ok(expr)
    }

    fn parse_bitwise_and(&mut self) -> Result<Expr, Stage0Error> {
        let mut expr = self.parse_shift()?;
        loop {
            self.skip_infix_newlines();
            if !self.match_kind(&TokenKind::Amp) {
                break;
            }
            self.skip_newlines();
            let right = self.parse_shift()?;
            let span = merge_spans(expr.span(), right.span());
            expr = Expr::Binary {
                left: Box::new(expr),
                op: BinaryOp::BitAnd,
                right: Box::new(right),
                span,
            };
        }
        Ok(expr)
    }

    fn parse_shift(&mut self) -> Result<Expr, Stage0Error> {
        let mut expr = self.parse_additive()?;
        loop {
            self.skip_infix_newlines();
            let op = if self.match_kind(&TokenKind::Shl) {
                Some(BinaryOp::Shl)
            } else if self.match_kind(&TokenKind::Shr) {
                Some(BinaryOp::Shr)
            } else {
                None
            };
            let Some(op) = op else { break };
            self.skip_newlines();
            let right = self.parse_additive()?;
            let span = merge_spans(expr.span(), right.span());
            expr = Expr::Binary {
                left: Box::new(expr),
                op,
                right: Box::new(right),
                span,
            };
        }
        Ok(expr)
    }

    fn parse_additive(&mut self) -> Result<Expr, Stage0Error> {
        let mut expr = self.parse_multiplicative()?;
        loop {
            self.skip_infix_newlines();
            let op = if self.match_kind(&TokenKind::Plus) {
                Some(BinaryOp::Add)
            } else if self.match_kind(&TokenKind::Minus) {
                Some(BinaryOp::Sub)
            } else {
                None
            };
            let Some(op) = op else { break };
            self.skip_newlines();
            let right = self.parse_multiplicative()?;
            let span = merge_spans(expr.span(), right.span());
            expr = Expr::Binary {
                left: Box::new(expr),
                op,
                right: Box::new(right),
                span,
            };
        }
        Ok(expr)
    }

    fn parse_multiplicative(&mut self) -> Result<Expr, Stage0Error> {
        let mut expr = self.parse_unary()?;
        loop {
            self.skip_infix_newlines();
            let op = if self.match_kind(&TokenKind::Star) {
                Some(BinaryOp::Mul)
            } else if self.match_kind(&TokenKind::Slash) {
                Some(BinaryOp::Div)
            } else if self.match_kind(&TokenKind::Percent) {
                Some(BinaryOp::Mod)
            } else {
                None
            };
            let Some(op) = op else { break };
            self.skip_newlines();
            let right = self.parse_unary()?;
            let span = merge_spans(expr.span(), right.span());
            expr = Expr::Binary {
                left: Box::new(expr),
                op,
                right: Box::new(right),
                span,
            };
        }
        Ok(expr)
    }

    fn parse_unary(&mut self) -> Result<Expr, Stage0Error> {
        if self.match_kind(&TokenKind::Bang) {
            let span = self.last_consumed_span(self.peek().span);
            let expr = self.parse_unary()?;
            return Ok(Expr::Unary {
                op: UnaryOp::Not,
                span: merge_spans(span, expr.span()),
                expr: Box::new(expr),
            });
        }
        if self.match_kind(&TokenKind::Tilde) {
            let span = self.last_consumed_span(self.peek().span);
            let expr = self.parse_unary()?;
            return Ok(Expr::Unary {
                op: UnaryOp::BitNot,
                span: merge_spans(span, expr.span()),
                expr: Box::new(expr),
            });
        }
        if self.match_kind(&TokenKind::Minus) {
            let span = self.last_consumed_span(self.peek().span);
            let expr = self.parse_unary()?;
            return Ok(Expr::Unary {
                op: UnaryOp::Neg,
                span: merge_spans(span, expr.span()),
                expr: Box::new(expr),
            });
        }
        if self.match_kind(&TokenKind::Star) {
            let span = self.last_consumed_span(self.peek().span);
            let expr = self.parse_unary()?;
            return Ok(Expr::Unary {
                op: UnaryOp::Deref,
                span: merge_spans(span, expr.span()),
                expr: Box::new(expr),
            });
        }
        if self.match_kind(&TokenKind::Amp) {
            let start = self.last_consumed_span(self.peek().span);
            let op = if self.match_kind(&TokenKind::KeywordMut) {
                UnaryOp::BorrowMut
            } else {
                UnaryOp::Borrow
            };
            let expr = self.parse_unary()?;
            return Ok(Expr::Unary {
                op,
                span: merge_spans(start, expr.span()),
                expr: Box::new(expr),
            });
        }
        self.parse_postfix()
    }

    fn parse_postfix(&mut self) -> Result<Expr, Stage0Error> {
        let expr = self.parse_primary()?;
        self.parse_postfix_from(expr)
    }

    fn parse_postfix_from(&mut self, mut expr: Expr) -> Result<Expr, Stage0Error> {
        loop {
            if let Some(desugared) = self.try_parse_vec_macro_expr(&expr)? {
                expr = desugared;
                continue;
            }
            let saved = self.cursor;
            self.skip_postfix_newlines();
            if self.cursor != saved && !can_continue_postfix_after_newline(&expr) {
                self.cursor = saved;
            }
            if self.match_kind(&TokenKind::LParen) {
                let args = self.parse_argument_list()?;
                let end = self.expect(&TokenKind::RParen)?.span;
                let start = expr.span();
                expr = Expr::Call {
                    callee: Box::new(expr),
                    args,
                    span: merge_spans(start, end),
                };
                continue;
            }
            if self.match_kind(&TokenKind::Dot) {
                let start = expr.span();
                let field_span = self.peek().span;
                let field = if matches!(self.peek_kind(), TokenKind::Integer(_)) {
                    match self.bump().kind {
                        TokenKind::Integer(value) => value,
                        _ => unreachable!("peeked integer token must remain integer"),
                    }
                } else {
                    self.expect_ident().map_err(|_| {
                        Stage0Error::parse(
                            self.peek().span,
                            format!("expected field name or tuple index, found {:?}", self.peek_kind()),
                        )
                    })?
                };
                expr = Expr::Field {
                    base: Box::new(expr),
                    field,
                    span: merge_spans(start, field_span),
                };
                continue;
            }
            if matches!(expr, Expr::Name { .. } | Expr::Field { .. }) && self.check(&TokenKind::LBracket) {
                let saved = self.cursor;
                if self.parse_optional_type_args().is_ok() && self.check(&TokenKind::LParen) {
                    continue;
                }
                self.cursor = saved;
            }
            if self.match_kind(&TokenKind::LBracket) {
                let index = self.parse_expr()?;
                let end = self.expect(&TokenKind::RBracket)?.span;
                let start = expr.span();
                expr = Expr::Index {
                    base: Box::new(expr),
                    index: Box::new(index),
                    span: merge_spans(start, end),
                };
                continue;
            }
            if matches!(expr, Expr::Name { .. } | Expr::Field { .. })
                && !self.check(&TokenKind::Newline)
                && can_start_implicit_call_arg(self.peek_kind())
            {
                let arg = self.parse_expr()?;
                let end = arg.span();
                let start = expr.span();
                expr = Expr::Call {
                    callee: Box::new(expr),
                    args: vec![CallArg {
                        label: None,
                        value: arg,
                    }],
                    span: merge_spans(start, end),
                };
                continue;
            }
            if self.match_kind(&TokenKind::Question) {
                let end = self.last_consumed_span(expr.span());
                let start = expr.span();
                expr = Expr::Try {
                    expr: Box::new(expr),
                    span: merge_spans(start, end),
                };
                continue;
            }
            if self.match_kind(&TokenKind::KeywordAs) {
                let start = expr.span();
                let ty = self.parse_type()?;
                expr = Expr::Cast {
                    expr: Box::new(expr),
                    span: merge_spans(start, ty.span()),
                    ty,
                };
                continue;
            }
            break;
        }
        Ok(expr)
    }

    fn try_parse_vec_macro_expr(&mut self, expr: &Expr) -> Result<Option<Expr>, Stage0Error> {
        let Expr::Name { name, span } = expr else {
            return Ok(None);
        };
        if name != "vec" || !self.check(&TokenKind::Bang) {
            return Ok(None);
        }
        let Some(next_kind) = self.tokens.get(self.cursor + 1).map(|token| &token.kind) else {
            return Ok(None);
        };
        if !matches!(next_kind, TokenKind::LBracket) {
            return Ok(None);
        }
        let _ = self.bump();
        let array_start = self.expect(&TokenKind::LBracket)?.span;
        let array_expr = self.parse_array_expr(array_start)?;
        let end = array_expr.span();
        Ok(Some(Expr::Call {
            callee: Box::new(Expr::Name {
                name: "Vec::from".to_string(),
                span: *span,
            }),
            args: vec![CallArg {
                label: None,
                value: array_expr,
            }],
            span: merge_spans(*span, end),
        }))
    }

    fn parse_argument_list(&mut self) -> Result<Vec<CallArg>, Stage0Error> {
        let mut args = Vec::new();
        if self.check(&TokenKind::RParen) {
            return Ok(args);
        }
        loop {
            self.skip_newlines();
            args.push(self.parse_call_arg()?);
            self.skip_newlines();
            if !self.match_kind(&TokenKind::Comma) {
                break;
            }
        }
        Ok(args)
    }

    fn parse_call_arg(&mut self) -> Result<CallArg, Stage0Error> {
        let label = if matches!(self.peek_kind(), TokenKind::Ident(_))
            && matches!(self.tokens.get(self.cursor + 1).map(|token| &token.kind), Some(TokenKind::Colon))
        {
            let label = self.expect_ident()?;
            let _ = self.expect(&TokenKind::Colon)?;
            Some(label)
        } else {
            None
        };
        let value = self.parse_expr()?;
        Ok(CallArg { label, value })
    }

    #[allow(clippy::too_many_lines)]
    fn parse_primary(&mut self) -> Result<Expr, Stage0Error> {
        let token = self.bump();
        match token.kind {
            TokenKind::Integer(value) => Ok(Expr::Integer {
                value: self.parse_numeric_literal_suffix(value, token.span),
                span: token.span,
            }),
            TokenKind::Float(value) => Ok(Expr::Float {
                value: self.parse_numeric_literal_suffix(value, token.span),
                span: token.span,
            }),
            TokenKind::Char(value) => Ok(Expr::Char {
                value,
                span: token.span,
            }),
            TokenKind::String(value) => Ok(Expr::String {
                value,
                span: token.span,
            }),
            TokenKind::KeywordTrue => Ok(Expr::Bool {
                value: true,
                span: token.span,
            }),
            TokenKind::KeywordFalse => Ok(Expr::Bool {
                value: false,
                span: token.span,
            }),
            TokenKind::KeywordIf => self.parse_if_expr(token.span),
            TokenKind::KeywordUnless => self.parse_unless_expr(token.span),
            TokenKind::KeywordMatch => self.parse_match_expr(token.span),
            TokenKind::PipePipe => self.parse_zero_param_closure_expr(token.span),
            TokenKind::Pipe => self.parse_closure_expr(token.span),
            TokenKind::LBracket => self.parse_array_expr(token.span),
            TokenKind::LBrace => self.parse_brace_block_expr(token.span),
            TokenKind::KeywordModule => Ok(Expr::Name {
                name: "module".to_string(),
                span: token.span,
            }),
            TokenKind::KeywordCap => Ok(Expr::Name {
                name: "cap".to_string(),
                span: token.span,
            }),
            TokenKind::KeywordBudget => Ok(Expr::Name {
                name: "budget".to_string(),
                span: token.span,
            }),
            TokenKind::KeywordConst => Ok(Expr::Name {
                name: "const".to_string(),
                span: token.span,
            }),
            TokenKind::KeywordDef => Ok(Expr::Name {
                name: "def".to_string(),
                span: token.span,
            }),
            TokenKind::KeywordEffect => Ok(Expr::Name {
                name: "effect".to_string(),
                span: token.span,
            }),
            TokenKind::KeywordEdition => Ok(Expr::Name {
                name: "edition".to_string(),
                span: token.span,
            }),
            TokenKind::KeywordExtern => Ok(Expr::Name {
                name: "extern".to_string(),
                span: token.span,
            }),
            TokenKind::KeywordFinally => Ok(Expr::Name {
                name: "finally".to_string(),
                span: token.span,
            }),
            TokenKind::KeywordGuard => Ok(Expr::Name {
                name: "guard".to_string(),
                span: token.span,
            }),
            TokenKind::KeywordImplies => Ok(Expr::Name {
                name: "implies".to_string(),
                span: token.span,
            }),
            TokenKind::KeywordInline => Ok(Expr::Name {
                name: "inline".to_string(),
                span: token.span,
            }),
            TokenKind::KeywordLoop => Ok(Expr::Name {
                name: "loop".to_string(),
                span: token.span,
            }),
            TokenKind::KeywordPost => Ok(Expr::Name {
                name: "post".to_string(),
                span: token.span,
            }),
            TokenKind::KeywordPre => Ok(Expr::Name {
                name: "pre".to_string(),
                span: token.span,
            }),
            TokenKind::KeywordPub => Ok(Expr::Name {
                name: "pub".to_string(),
                span: token.span,
            }),
            TokenKind::KeywordRationale => Ok(Expr::Name {
                name: "rationale".to_string(),
                span: token.span,
            }),
            TokenKind::KeywordNext => Ok(Expr::Name {
                name: "next".to_string(),
                span: token.span,
            }),
            TokenKind::KeywordType => Ok(Expr::Name {
                name: "type".to_string(),
                span: token.span,
            }),
            TokenKind::Ident(name) => {
                let full_name = self.parse_type_name_tail(name)?;
                if self.check(&TokenKind::LBrace)
                    && (full_name.contains("::") || starts_with_uppercase(&full_name))
                {
                    self.parse_struct_literal(full_name, token.span)
                } else if !full_name.contains("::")
                    && starts_with_uppercase(&full_name)
                    && self.looks_like_end_struct_literal()
                {
                    self.parse_end_struct_literal(full_name, token.span)
                } else {
                    Ok(Expr::Name {
                        name: full_name,
                        span: token.span,
                    })
                }
            }
            TokenKind::KeywordSelfTy => Ok(Expr::Name {
                name: self.parse_type_name_tail("Self".to_string())?,
                span: token.span,
            }),
            TokenKind::KeywordSelfValue => Ok(Expr::Name {
                name: "self".to_string(),
                span: token.span,
            }),
            TokenKind::KeywordUnsafe => self.parse_unsafe_expr(token.span),
            TokenKind::LParen => self.parse_paren_expr(token.span),
            other => Err(Stage0Error::parse(
                token.span,
                format!("unexpected expression token: {other:?}"),
            )),
        }
    }

    fn expression_is_tail(&mut self, terminator: &TokenKind) -> bool {
        self.expression_is_tail_any(std::slice::from_ref(terminator))
    }

    fn expression_is_tail_any(&mut self, terminators: &[TokenKind]) -> bool {
        if terminators.iter().any(|terminator| self.check(terminator)) {
            return true;
        }
        if !self.check(&TokenKind::Newline) {
            return false;
        }

        let saved = self.cursor;
        self.skip_newlines();
        let is_tail = terminators.iter().any(|terminator| self.check(terminator));
        self.cursor = saved;
        is_tail
    }

    fn consume_stmt_separator(&mut self, terminator: &TokenKind) -> Result<(), Stage0Error> {
        self.consume_stmt_separator_any(std::slice::from_ref(terminator))
    }

    fn consume_stmt_separator_any(&mut self, terminators: &[TokenKind]) -> Result<(), Stage0Error> {
        if terminators.iter().any(|terminator| self.check(terminator)) {
            return Ok(());
        }
        if self.match_kind(&TokenKind::Semi) || self.match_kind(&TokenKind::Newline) {
            self.skip_newlines();
            return Ok(());
        }
        Err(Stage0Error::parse(
            self.peek().span,
            "expected statement separator or branch terminator",
        ))
    }

    fn expect_function_keyword(&mut self) -> Result<Token, Stage0Error> {
        match self.peek_kind() {
            TokenKind::KeywordFn | TokenKind::KeywordDef => Ok(self.bump()),
            other => Err(Stage0Error::parse(
                self.peek().span,
                format!("expected function keyword, found {other:?}"),
            )),
        }
    }

    fn skip_newlines(&mut self) {
        while self.match_kind(&TokenKind::Newline) {}
    }

    fn skip_infix_newlines(&mut self) {
        let saved = self.cursor;
        self.skip_newlines();
        if !is_infix_operator(self.peek_kind()) {
            self.cursor = saved;
        }
    }

    fn skip_postfix_newlines(&mut self) {
        let saved = self.cursor;
        self.skip_newlines();
        if !matches!(
            self.peek_kind(),
            TokenKind::LParen
                | TokenKind::Dot
                | TokenKind::LBracket
                | TokenKind::Question
                | TokenKind::KeywordAs
        ) {
            self.cursor = saved;
        }
    }

    fn parse_field_decl(&mut self) -> Result<FieldDecl, Stage0Error> {
        let field_start = self.peek().span;
        let public = self.match_kind(&TokenKind::KeywordPub);
        let field_name = self.expect_ident()?;
        let _ = self.expect(&TokenKind::Colon)?;
        let field_type = self.parse_type()?;
        let field_end = field_type.span();
        Ok(FieldDecl {
            public,
            name: field_name,
            ty: field_type,
            span: merge_spans(field_start, field_end),
        })
    }

    fn parse_variant_decl(&mut self) -> Result<VariantDecl, Stage0Error> {
        let start = self.peek().span;
        let name = self.expect_ident()?;
        let tuple_fields = if self.match_kind(&TokenKind::LParen) {
            let mut fields = Vec::new();
            if !self.check(&TokenKind::RParen) {
                loop {
                    if matches!(self.peek_kind(), TokenKind::Ident(_)) {
                        let saved = self.cursor;
                        let _ = self.bump();
                        if !self.match_kind(&TokenKind::Colon) {
                            self.cursor = saved;
                        }
                    }
                    fields.push(self.parse_type()?);
                    if !self.match_kind(&TokenKind::Comma) {
                        break;
                    }
                    if self.check(&TokenKind::RParen) {
                        break;
                    }
                }
            }
            let _ = self.expect(&TokenKind::RParen)?;
            fields
        } else {
            Vec::new()
        };
        let named_fields = if self.match_kind(&TokenKind::LBrace) {
            let mut fields = Vec::new();
            self.skip_newlines();
            while !self.check(&TokenKind::RBrace) {
                let field_start = self.peek().span;
                let field_name = self.expect_ident()?;
                let _ = self.expect(&TokenKind::Colon)?;
                let field_type = self.parse_type()?;
                fields.push(FieldDecl {
                    public: false,
                    name: field_name,
                    ty: field_type.clone(),
                    span: merge_spans(field_start, field_type.span()),
                });
                self.skip_newlines();
                if !self.match_kind(&TokenKind::Comma) {
                    break;
                }
                self.skip_newlines();
            }
            let _ = self.expect(&TokenKind::RBrace)?;
            fields
        } else {
            Vec::new()
        };
        Ok(VariantDecl {
            name,
            tuple_fields,
            named_fields,
            span: merge_spans(start, self.last_consumed_span(start)),
        })
    }

    fn parse_optional_type_params(&mut self) -> Result<Vec<TypeParam>, Stage0Error> {
        let mut params = Vec::new();
        if !self.match_kind(&TokenKind::LBracket) {
            return Ok(params);
        }
        if self.check(&TokenKind::RBracket) {
            let _ = self.expect(&TokenKind::RBracket)?;
            return Ok(params);
        }
        loop {
            let start = self.peek().span;
            let name = self.expect_ident()?;
            let bounds = if self.match_kind(&TokenKind::Colon) {
                self.parse_bound_list()?
            } else {
                Vec::new()
            };
            params.push(TypeParam {
                name,
                bounds,
                span: merge_spans(start, self.last_consumed_span(start)),
            });
            if !self.match_kind(&TokenKind::Comma) {
                break;
            }
        }
        let _ = self.expect(&TokenKind::RBracket)?;
        Ok(params)
    }

    fn parse_optional_type_args(&mut self) -> Result<Vec<TypeRef>, Stage0Error> {
        let mut args = Vec::new();
        if !self.match_kind(&TokenKind::LBracket) {
            return Ok(args);
        }
        if self.check(&TokenKind::RBracket) {
            let _ = self.expect(&TokenKind::RBracket)?;
            return Ok(args);
        }
        loop {
            args.push(self.parse_type()?);
            if !self.match_kind(&TokenKind::Comma) {
                break;
            }
        }
        let _ = self.expect(&TokenKind::RBracket)?;
        Ok(args)
    }

    fn parse_type_name(&mut self) -> Result<String, Stage0Error> {
        let name = self.expect_ident()?;
        self.parse_type_name_tail(name)
    }

    fn parse_type_name_tail(&mut self, mut name: String) -> Result<String, Stage0Error> {
        while self.match_kind(&TokenKind::ColonColon) {
            name.push_str("::");
            name.push_str(&self.expect_ident()?);
        }
        Ok(name)
    }

    fn parse_struct_literal(&mut self, name: String, start: Span) -> Result<Expr, Stage0Error> {
        let _ = self.expect(&TokenKind::LBrace)?;
        self.skip_newlines();
        let mut fields = Vec::new();
        while !self.check(&TokenKind::RBrace) && !self.check(&TokenKind::KeywordEnd) {
            self.skip_newlines();
            if self.check(&TokenKind::RBrace) || self.check(&TokenKind::KeywordEnd) {
                break;
            }
            let field_name = self.expect_ident()?;
            let value = if self.match_kind(&TokenKind::Colon) {
                self.parse_expr()?
            } else {
                Expr::Name {
                    name: field_name.clone(),
                    span: self.last_consumed_span(start),
                }
            };
            fields.push((field_name, value));
            if !self.match_kind(&TokenKind::Comma) {
                break;
            }
            self.skip_newlines();
            if self.check(&TokenKind::RBrace) || self.check(&TokenKind::KeywordEnd) {
                break;
            }
        }
        self.skip_newlines();
        let end = if self.match_kind(&TokenKind::RBrace) {
            self.last_consumed_span(start)
        } else {
            self.expect(&TokenKind::KeywordEnd)?.span
        };
        Ok(Expr::StructLiteral {
            name,
            fields,
            span: merge_spans(start, end),
        })
    }

    fn parse_end_struct_literal(&mut self, name: String, start: Span) -> Result<Expr, Stage0Error> {
        self.skip_newlines();
        let mut fields = Vec::new();
        while !self.check(&TokenKind::KeywordEnd) {
            let field_name = self.expect_ident()?;
            let _ = self.expect(&TokenKind::Colon)?;
            let value = self.parse_expr()?;
            fields.push((field_name, value));
            self.consume_stmt_separator(&TokenKind::KeywordEnd)?;
            self.skip_newlines();
        }
        let end = self.expect(&TokenKind::KeywordEnd)?.span;
        Ok(Expr::StructLiteral {
            name,
            fields,
            span: merge_spans(start, end),
        })
    }

    fn looks_like_end_struct_literal(&self) -> bool {
        let mut index = self.cursor;
        if !matches!(self.tokens[index].kind, TokenKind::Newline) {
            return false;
        }
        while index < self.tokens.len() && matches!(self.tokens[index].kind, TokenKind::Newline) {
            index += 1;
        }
        matches!(self.tokens.get(index).map(|token| &token.kind), Some(TokenKind::Ident(_)))
            && matches!(self.tokens.get(index + 1).map(|token| &token.kind), Some(TokenKind::Colon))
    }

    fn parse_if_expr(&mut self, start: Span) -> Result<Expr, Stage0Error> {
        let mut branches = Vec::new();
        branches.push(self.parse_if_branch(start)?);
        self.skip_newlines();
        while self.match_kind(&TokenKind::KeywordElsif) {
            let branch_start = self.last_consumed_span(start);
            branches.push(self.parse_if_branch(branch_start)?);
            self.skip_newlines();
        }

        let mut else_branch = None;
        while self.match_kind(&TokenKind::KeywordElse) {
            let else_if = self.check(&TokenKind::KeywordIf);
            self.skip_optional_then();
            if else_if {
                let _ = self.expect(&TokenKind::KeywordIf)?;
                let branch_start = self.last_consumed_span(start);
                branches.push(self.parse_if_branch(branch_start)?);
                self.skip_newlines();
                continue;
            }
            self.skip_newlines();
            else_branch = Some(Box::new(self.parse_block_body_until_any(&[TokenKind::KeywordEnd])?));
            break;
        }

        self.skip_newlines();
        let end = self.expect(&TokenKind::KeywordEnd)?.span;
        Ok(Expr::If {
            branches,
            else_branch,
            span: merge_spans(start, end),
        })
    }

    fn parse_if_branch(&mut self, start: Span) -> Result<IfBranch, Stage0Error> {
        let guard = if self.match_kind(&TokenKind::KeywordLet) {
            let pattern = self.parse_variant_pattern()?;
            let _ = self.expect(&TokenKind::Eq)?;
            let value = self.parse_expr()?;
            BranchGuard::Let { pattern, value }
        } else {
            BranchGuard::Expr(self.parse_expr()?)
        };
        self.skip_optional_then();
        self.skip_newlines();
        let body = self.parse_block_body_until_any(&[
            TokenKind::KeywordElsif,
            TokenKind::KeywordElse,
            TokenKind::KeywordEnd,
        ])?;
        Ok(IfBranch {
            guard,
            span: merge_spans(start, body.span),
            body: Box::new(body),
        })
    }

    fn parse_variant_pattern(&mut self) -> Result<Pattern, Stage0Error> {
        self.parse_pattern()
    }

    fn parse_pattern(&mut self) -> Result<Pattern, Stage0Error> {
        let first = self.parse_pattern_atom()?;
        if !self.match_kind(&TokenKind::Pipe) {
            return Ok(first);
        }

        let mut alternatives = vec![first];
        loop {
            alternatives.push(self.parse_pattern_atom()?);
            if !self.match_kind(&TokenKind::Pipe) {
                break;
            }
        }
        let start = alternatives.first().map_or(self.peek().span, Pattern::span);
        let end = alternatives.last().map_or(start, Pattern::span);
        Ok(Pattern::Or {
            alternatives,
            span: merge_spans(start, end),
        })
    }

    fn parse_pattern_atom(&mut self) -> Result<Pattern, Stage0Error> {
        let token = self.bump();
        match token.kind {
            TokenKind::Ident(name) if name == "ref" => self.parse_pattern_atom(),
            TokenKind::KeywordMut => self.parse_pattern_atom(),
            TokenKind::Ident(name) if name == "_" => Ok(Pattern::Wildcard { span: token.span }),
            TokenKind::Integer(value) => Ok(Pattern::Integer {
                value,
                span: token.span,
            }),
            TokenKind::Float(value) => Ok(Pattern::Float {
                value,
                span: token.span,
            }),
            TokenKind::Char(value) => Ok(Pattern::Char {
                value,
                span: token.span,
            }),
            TokenKind::String(value) => Ok(Pattern::String {
                value,
                span: token.span,
            }),
            TokenKind::KeywordTrue => Ok(Pattern::Bool {
                value: true,
                span: token.span,
            }),
            TokenKind::KeywordFalse => Ok(Pattern::Bool {
                value: false,
                span: token.span,
            }),
            TokenKind::LParen => self.parse_tuple_pattern_from_start(token.span),
            TokenKind::Ident(name) => self.parse_ident_pattern(name, token.span),
            TokenKind::KeywordBudget => self.parse_ident_pattern("budget".to_string(), token.span),
            TokenKind::KeywordCap => self.parse_ident_pattern("cap".to_string(), token.span),
            TokenKind::KeywordConst => self.parse_ident_pattern("const".to_string(), token.span),
            TokenKind::KeywordDef => self.parse_ident_pattern("def".to_string(), token.span),
            TokenKind::KeywordEffect => self.parse_ident_pattern("effect".to_string(), token.span),
            TokenKind::KeywordEdition => self.parse_ident_pattern("edition".to_string(), token.span),
            TokenKind::KeywordFinally => self.parse_ident_pattern("finally".to_string(), token.span),
            TokenKind::KeywordGuard => self.parse_ident_pattern("guard".to_string(), token.span),
            TokenKind::KeywordImplies => self.parse_ident_pattern("implies".to_string(), token.span),
            TokenKind::KeywordInline => self.parse_ident_pattern("inline".to_string(), token.span),
            TokenKind::KeywordLoop => self.parse_ident_pattern("loop".to_string(), token.span),
            TokenKind::KeywordModule => self.parse_ident_pattern("module".to_string(), token.span),
            TokenKind::KeywordType => self.parse_ident_pattern("type".to_string(), token.span),
            TokenKind::KeywordNext => self.parse_ident_pattern("next".to_string(), token.span),
            TokenKind::KeywordPre => self.parse_ident_pattern("pre".to_string(), token.span),
            TokenKind::KeywordPost => self.parse_ident_pattern("post".to_string(), token.span),
            TokenKind::KeywordRationale => self.parse_ident_pattern("rationale".to_string(), token.span),
            TokenKind::KeywordPub => self.parse_ident_pattern("pub".to_string(), token.span),
            TokenKind::KeywordWhen => self.parse_ident_pattern("when".to_string(), token.span),
            other => Err(Stage0Error::parse(
                token.span,
                format!("unexpected pattern token: {other:?}"),
            )),
        }
    }

    fn parse_tuple_pattern(&mut self) -> Result<Pattern, Stage0Error> {
        let start = self.expect(&TokenKind::LParen)?.span;
        self.parse_tuple_pattern_from_start(start)
    }

    fn parse_tuple_pattern_from_start(&mut self, start: Span) -> Result<Pattern, Stage0Error> {
        let mut elements = Vec::new();
        if !self.check(&TokenKind::RParen) {
            loop {
                elements.push(self.parse_pattern()?);
                if !self.match_kind(&TokenKind::Comma) {
                    break;
                }
                if self.check(&TokenKind::RParen) {
                    break;
                }
            }
        }
        let end = self.expect(&TokenKind::RParen)?.span;
        Ok(Pattern::Tuple {
            elements,
            span: merge_spans(start, end),
        })
    }

    fn parse_ident_pattern(&mut self, name: String, start: Span) -> Result<Pattern, Stage0Error> {
        let mut enum_name = None;
        let mut variant_name = name.clone();
        if self.match_kind(&TokenKind::ColonColon) {
            enum_name = Some(name.clone());
            variant_name = self.expect_ident()?;
        }
        if enum_name.is_some() || self.check(&TokenKind::LParen) || starts_with_uppercase(&variant_name) {
            let fields = if self.match_kind(&TokenKind::LParen) {
                let mut fields = Vec::new();
                if !self.check(&TokenKind::RParen) {
                    loop {
                        fields.push(self.parse_pattern()?);
                        if !self.match_kind(&TokenKind::Comma) {
                            break;
                        }
                        if self.check(&TokenKind::RParen) {
                            break;
                        }
                    }
                }
                let _ = self.expect(&TokenKind::RParen)?;
                fields
            } else {
                Vec::new()
            };
            let named_fields = if self.match_kind(&TokenKind::LBrace) {
                let mut fields = Vec::new();
                if !self.check(&TokenKind::RBrace) {
                    loop {
                        let field_name = self.expect_ident()?;
                        let field_pattern = if self.match_kind(&TokenKind::Colon) {
                            self.parse_pattern()?
                        } else {
                            Pattern::Binding {
                                name: field_name.clone(),
                                span: self.last_consumed_span(start),
                            }
                        };
                        fields.push((field_name, field_pattern));
                        if !self.match_kind(&TokenKind::Comma) {
                            break;
                        }
                        if self.check(&TokenKind::RBrace) {
                            break;
                        }
                    }
                }
                let _ = self.expect(&TokenKind::RBrace)?;
                fields
            } else {
                Vec::new()
            };
            Ok(Pattern::Variant {
                enum_name,
                variant_name,
                fields,
                named_fields,
                span: merge_spans(start, self.last_consumed_span(start)),
            })
        } else {
            Ok(Pattern::Binding { name, span: start })
        }
    }

    fn skip_optional_then(&mut self) {
        let _ = self.match_kind(&TokenKind::KeywordThen);
    }

    fn skip_optional_do(&mut self) {
        let _ = self.match_kind(&TokenKind::KeywordDo);
    }

    #[allow(clippy::too_many_lines)]
    fn parse_block_body_until_any(&mut self, terminators: &[TokenKind]) -> Result<BlockBody, Stage0Error> {
        self.skip_newlines();
        let start = self.peek().span;
        let mut stmts = Vec::new();
        let mut tail = None;

        loop {
            self.skip_newlines();
            if terminators.iter().any(|terminator| self.check(terminator)) {
                break;
            }
            if self.at_eof() {
                return Err(Stage0Error::parse(start, "expected branch terminator before EOF"));
            }

            if let Some(stmt) = self.try_parse_nested_decl_stmt()? {
                stmts.push(stmt);
                self.consume_stmt_separator_any(terminators)?;
                self.skip_newlines();
                continue;
            }

            if self.check(&TokenKind::KeywordRequires) {
                let requires_span = self.expect(&TokenKind::KeywordRequires)?.span;
                let capability = self.expect_ident()?;
                stmts.push(Stmt::Requires {
                    capability,
                    span: merge_spans(requires_span, self.last_consumed_span(requires_span)),
                });
                self.consume_stmt_separator_any(terminators)?;
                self.skip_newlines();
                continue;
            }

            if self.check(&TokenKind::KeywordExtern) {
                let decl = self.parse_extern_decl()?;
                let span = decl.span;
                stmts.push(Stmt::Decl {
                    decl: Box::new(Decl::Extern(decl)),
                    span,
                });
                self.consume_stmt_separator_any(terminators)?;
                self.skip_newlines();
                continue;
            }

            if self.check(&TokenKind::KeywordWhile) || self.check(&TokenKind::KeywordUntil) {
                let stmt = self.parse_while_stmt()?;
                stmts.push(stmt);
                self.consume_stmt_separator_any(terminators)?;
                self.skip_newlines();
                continue;
            }

            if self.check(&TokenKind::KeywordLoop) {
                let stmt = self.parse_loop_stmt()?;
                stmts.push(stmt);
                self.consume_stmt_separator_any(terminators)?;
                self.skip_newlines();
                continue;
            }

            if self.check(&TokenKind::KeywordFor) {
                let stmt = self.parse_for_stmt()?;
                stmts.push(stmt);
                self.consume_stmt_separator_any(terminators)?;
                self.skip_newlines();
                continue;
            }

            if self.check(&TokenKind::KeywordReturn) {
                let stmt = self.parse_return_stmt_any(terminators)?;
                stmts.push(stmt);
                self.consume_stmt_separator_any(terminators)?;
                self.skip_newlines();
                continue;
            }

            if self.check(&TokenKind::KeywordBreak) {
                let stmt = self.parse_break_stmt()?;
                stmts.push(stmt);
                self.consume_stmt_separator_any(terminators)?;
                self.skip_newlines();
                continue;
            }

            if self.check(&TokenKind::KeywordNext) {
                let stmt = self.parse_next_stmt()?;
                stmts.push(stmt);
                self.consume_stmt_separator_any(terminators)?;
                self.skip_newlines();
                continue;
            }

            if self.check(&TokenKind::KeywordLet)
                || self.check(&TokenKind::KeywordMut)
                || matches!(self.peek_kind(), TokenKind::Ident(name) if name == "var")
            {
                let stmt = self.parse_binding_stmt()?;
                stmts.push(stmt);
                self.consume_stmt_separator_any(terminators)?;
                self.skip_newlines();
                continue;
            }

            if self.check(&TokenKind::KeywordUse) {
                let meta = self.parse_use_decl()?;
                stmts.push(Stmt::Use {
                    path: meta.detail,
                    span: meta.span,
                });
                self.consume_stmt_separator_any(terminators)?;
                self.skip_newlines();
                continue;
            }

            if self.check(&TokenKind::KeywordExtern) {
                let decl = self.parse_extern_decl()?;
                let span = decl.span;
                stmts.push(Stmt::Decl {
                    decl: Box::new(Decl::Extern(decl)),
                    span,
                });
                self.consume_stmt_separator_any(terminators)?;
                self.skip_newlines();
                continue;
            }

            if self.check(&TokenKind::KeywordStruct) {
                let decl = self.parse_struct(false)?;
                let span = decl.span;
                stmts.push(Stmt::Decl {
                    decl: Box::new(Decl::Struct(decl)),
                    span,
                });
                self.consume_stmt_separator_any(terminators)?;
                self.skip_newlines();
                continue;
            }

            if self.check(&TokenKind::KeywordImpl) {
                let decl = self.parse_impl()?;
                let span = decl.span;
                stmts.push(Stmt::Decl {
                    decl: Box::new(Decl::Impl(decl)),
                    span,
                });
                self.consume_stmt_separator_any(terminators)?;
                self.skip_newlines();
                continue;
            }

            if self.check(&TokenKind::At) {
                let meta = self.parse_annotation()?;
                stmts.push(Stmt::Meta {
                    span: meta.span,
                    decl: meta,
                });
                self.consume_stmt_separator_any(terminators)?;
                self.skip_newlines();
                continue;
            }

            if self.check(&TokenKind::KeywordDef) || self.check(&TokenKind::KeywordFn) {
                let function = self.parse_function_decl(false)?;
                stmts.push(Stmt::Function {
                    span: function.span,
                    decl: function,
                });
                self.consume_stmt_separator_any(terminators)?;
                self.skip_newlines();
                continue;
            }

            let expr = self.parse_expr()?;
            if self.match_kind(&TokenKind::Eq) {
                let value = self.parse_expr()?;
                let span = merge_spans(expr.span(), value.span());
                stmts.push(Stmt::Assign {
                    target: expr,
                    value,
                    span,
                });
                self.consume_stmt_separator_any(terminators)?;
                self.skip_newlines();
                continue;
            }
            if self.expression_is_tail_any(terminators) {
                tail = Some(expr);
                break;
            }

            let span = expr.span();
            stmts.push(Stmt::Expr { expr, span });
            self.consume_stmt_separator_any(terminators)?;
            self.skip_newlines();
        }

        let end = tail
            .as_ref()
            .map_or_else(|| stmts.last().map_or(start, Stmt::span), Expr::span);
        Ok(BlockBody {
            stmts,
            tail,
            span: merge_spans(start, end),
        })
    }

    fn parse_unsafe_expr(&mut self, start: Span) -> Result<Expr, Stage0Error> {
        let reason = match self.bump().kind {
            TokenKind::String(value) => value,
            other => {
                return Err(Stage0Error::parse(
                    self.peek().span,
                    format!("expected unsafe reason string, found {other:?}"),
                ));
            }
        };
        self.skip_optional_do();
        self.skip_newlines();
        let mut block = self.parse_block_body(&TokenKind::KeywordEnd)?;
        self.skip_newlines();
        let end = self.expect(&TokenKind::KeywordEnd)?.span;
        block.span = merge_spans(start, end);
        Ok(Expr::UnsafeBlock {
            reason,
            block: Box::new(block),
            span: merge_spans(start, end),
        })
    }

    fn parse_brace_block_expr(&mut self, start: Span) -> Result<Expr, Stage0Error> {
        self.skip_newlines();
        let mut block = self.parse_block_body(&TokenKind::RBrace)?;
        self.skip_newlines();
        let end = self.expect(&TokenKind::RBrace)?.span;
        block.span = merge_spans(start, end);
        Ok(Expr::Block {
            block: Box::new(block),
            span: merge_spans(start, end),
        })
    }

    fn try_parse_nested_decl_stmt(&mut self) -> Result<Option<Stmt>, Stage0Error> {
        let saved = self.cursor;
        let public = self.match_kind(&TokenKind::KeywordPub);
        if public {
            self.skip_newlines();
        }

        match self.peek_kind() {
            TokenKind::KeywordFn | TokenKind::KeywordDef => {
                let function = self.parse_function_decl(public)?;
                Ok(Some(Stmt::Function {
                    span: function.span,
                    decl: function,
                }))
            }
            TokenKind::KeywordExtern => {
                let decl = Decl::Extern(self.parse_extern_decl()?);
                let span = match &decl {
                    Decl::Extern(decl) => decl.span,
                    _ => unreachable!("unexpected nested declaration kind"),
                };
                Ok(Some(Stmt::Decl {
                    decl: Box::new(decl),
                    span,
                }))
            }
            TokenKind::KeywordStruct => {
                let decl = Decl::Struct(self.parse_struct(public)?);
                let span = match &decl {
                    Decl::Struct(decl) => decl.span,
                    _ => unreachable!("unexpected nested declaration kind"),
                };
                Ok(Some(Stmt::Decl {
                    decl: Box::new(decl),
                    span,
                }))
            }
            TokenKind::KeywordEnum => {
                let decl = Decl::Enum(self.parse_enum(public)?);
                let span = match &decl {
                    Decl::Enum(decl) => decl.span,
                    _ => unreachable!("unexpected nested declaration kind"),
                };
                Ok(Some(Stmt::Decl {
                    decl: Box::new(decl),
                    span,
                }))
            }
            TokenKind::KeywordTrait => {
                let decl = Decl::Trait(self.parse_trait(public)?);
                let span = match &decl {
                    Decl::Trait(decl) => decl.span,
                    _ => unreachable!("unexpected nested declaration kind"),
                };
                Ok(Some(Stmt::Decl {
                    decl: Box::new(decl),
                    span,
                }))
            }
            TokenKind::KeywordType => {
                let decl = Decl::TypeAlias(self.parse_type_alias(public)?);
                let span = match &decl {
                    Decl::TypeAlias(decl) => decl.span,
                    _ => unreachable!("unexpected nested declaration kind"),
                };
                Ok(Some(Stmt::Decl {
                    decl: Box::new(decl),
                    span,
                }))
            }
            TokenKind::KeywordImpl if !public => {
                let decl = Decl::Impl(self.parse_impl()?);
                let span = match &decl {
                    Decl::Impl(decl) => decl.span,
                    _ => unreachable!("unexpected nested declaration kind"),
                };
                Ok(Some(Stmt::Decl {
                    decl: Box::new(decl),
                    span,
                }))
            }
            _ => {
                self.cursor = saved;
                Ok(None)
            }
        }
    }

    fn parse_unless_expr(&mut self, start: Span) -> Result<Expr, Stage0Error> {
        let condition = self.parse_expr()?;
        self.skip_optional_then();
        self.skip_newlines();
        let body = self.parse_block_body_until_any(&[TokenKind::KeywordElse, TokenKind::KeywordEnd])?;
        self.skip_newlines();
        let else_branch = if self.match_kind(&TokenKind::KeywordElse) {
            self.skip_optional_then();
            self.skip_newlines();
            Some(Box::new(self.parse_block_body_until_any(&[TokenKind::KeywordEnd])?))
        } else {
            None
        };
        self.skip_newlines();
        let end = self.expect(&TokenKind::KeywordEnd)?.span;
        let negated = Expr::Unary {
            op: UnaryOp::Not,
            span: merge_spans(start, condition.span()),
            expr: Box::new(condition),
        };
        Ok(Expr::If {
            branches: vec![IfBranch {
                guard: BranchGuard::Expr(negated),
                span: merge_spans(start, body.span),
                body: Box::new(body),
            }],
            else_branch,
            span: merge_spans(start, end),
        })
    }

    fn parse_match_expr(&mut self, start: Span) -> Result<Expr, Stage0Error> {
        let value = self.parse_expr()?;
        self.skip_newlines();
        if self.match_kind(&TokenKind::LBrace) {
            return self.parse_brace_match_expr(start, value);
        }
        let mut arms = Vec::new();
        while self.match_kind(&TokenKind::KeywordWhen) {
            let arm_start = self.last_consumed_span(start);
            let pattern = self.parse_pattern()?;
            self.skip_optional_then();
            let body = self.parse_match_arm_body()?;
            arms.push(MatchArm {
                pattern,
                span: merge_spans(arm_start, body.span),
                body,
            });
            self.skip_newlines();
        }
        if self.match_kind(&TokenKind::KeywordElse) {
            let arm_start = self.last_consumed_span(start);
            let body = self.parse_match_arm_body()?;
            arms.push(MatchArm {
                pattern: Pattern::Wildcard { span: arm_start },
                span: merge_spans(arm_start, body.span),
                body,
            });
            self.skip_newlines();
        }
        let end = self.expect(&TokenKind::KeywordEnd)?.span;
        Ok(Expr::Match {
            value: Box::new(value),
            arms,
            span: merge_spans(start, end),
        })
    }

    fn parse_brace_match_expr(&mut self, start: Span, value: Expr) -> Result<Expr, Stage0Error> {
        self.skip_newlines();
        let mut arms = Vec::new();
        while !self.check(&TokenKind::RBrace) && !self.check(&TokenKind::KeywordEnd) {
            let arm_start = self.peek().span;
            if self.match_kind(&TokenKind::KeywordElse) {
                let body = self.parse_brace_match_arm_body_until_any(&[
                    TokenKind::Comma,
                    TokenKind::KeywordEnd,
                    TokenKind::RBrace,
                ])?;
                arms.push(MatchArm {
                    pattern: Pattern::Wildcard { span: arm_start },
                    span: merge_spans(arm_start, body.span),
                    body,
                });
                self.skip_newlines();
                let _ = self.match_kind(&TokenKind::Comma);
                self.skip_newlines();
                continue;
            }
            let when_style = self.match_kind(&TokenKind::KeywordWhen);
            let pattern = self.parse_pattern()?;
            let body = if when_style {
                self.skip_optional_then();
                self.parse_brace_match_arm_body_until_any(&[
                    TokenKind::Comma,
                    TokenKind::KeywordWhen,
                    TokenKind::KeywordElse,
                    TokenKind::KeywordEnd,
                    TokenKind::RBrace,
                ])?
            } else {
                let _ = self.expect(&TokenKind::FatArrow)?;
                self.parse_brace_match_arm_body_until_any(&[TokenKind::Comma, TokenKind::RBrace])?
            };
            arms.push(MatchArm {
                pattern,
                span: merge_spans(arm_start, body.span),
                body,
            });
            self.skip_newlines();
            if self.match_kind(&TokenKind::Comma) {
                self.skip_newlines();
                continue;
            }
            if self.check(&TokenKind::KeywordWhen)
                || self.check(&TokenKind::KeywordElse)
                || self.check(&TokenKind::KeywordEnd)
                || self.check(&TokenKind::RBrace)
            {
                continue;
            }
            if !when_style {
                break;
            }
        }
        let _ = self.match_kind(&TokenKind::KeywordEnd);
        self.skip_newlines();
        let end = self.expect(&TokenKind::RBrace)?.span;
        Ok(Expr::Match {
            value: Box::new(value),
            arms,
            span: merge_spans(start, end),
        })
    }

    fn parse_brace_match_arm_body_until_any(&mut self, terminators: &[TokenKind]) -> Result<BlockBody, Stage0Error> {
        if self.match_kind(&TokenKind::Newline) {
            self.skip_newlines();
            return self.parse_block_body_until_any(terminators);
        }
        let expr = self.parse_expr()?;
        if self.match_kind(&TokenKind::Eq) {
            let value = self.parse_expr()?;
            let span = merge_spans(expr.span(), value.span());
            return Ok(BlockBody {
                stmts: vec![Stmt::Assign {
                    target: expr,
                    value,
                    span,
                }],
                tail: None,
                span,
            });
        }
        if self.match_kind(&TokenKind::Semi) {
            self.skip_newlines();
            let mut rest = self.parse_block_body_until_any(terminators)?;
            let expr_span = expr.span();
            let mut stmts = vec![Stmt::Expr {
                expr,
                span: expr_span,
            }];
            stmts.append(&mut rest.stmts);
            return Ok(BlockBody {
                stmts,
                tail: rest.tail,
                span: merge_spans(expr_span, rest.span),
            });
        }
        let span = expr.span();
        Ok(BlockBody {
            stmts: Vec::new(),
            tail: Some(expr),
            span,
        })
    }

    #[allow(clippy::too_many_lines)]
    fn parse_match_arm_body(&mut self) -> Result<BlockBody, Stage0Error> {
        if self.match_kind(&TokenKind::Newline) {
            self.skip_newlines();
            return self.parse_block_body_until_any(&[
                TokenKind::KeywordWhen,
                TokenKind::KeywordElse,
                TokenKind::KeywordEnd,
            ]);
        }
        if self.check(&TokenKind::KeywordReturn) {
            let stmt = self.parse_return_stmt_any(&[
                TokenKind::KeywordWhen,
                TokenKind::KeywordElse,
                TokenKind::KeywordEnd,
            ])?;
            let span = stmt.span();
            return Ok(BlockBody {
                stmts: vec![stmt],
                tail: None,
                span,
            });
        }
        if self.check(&TokenKind::KeywordBreak) {
            let stmt = self.parse_break_stmt()?;
            let span = stmt.span();
            return Ok(BlockBody {
                stmts: vec![stmt],
                tail: None,
                span,
            });
        }
        if self.check(&TokenKind::KeywordNext) {
            let stmt = self.parse_next_stmt()?;
            let span = stmt.span();
            return Ok(BlockBody {
                stmts: vec![stmt],
                tail: None,
                span,
            });
        }
        if self.check(&TokenKind::KeywordLet)
            || self.check(&TokenKind::KeywordMut)
            || matches!(self.peek_kind(), TokenKind::Ident(name) if name == "var")
        {
            let stmt = self.parse_binding_stmt()?;
            let stmt_span = stmt.span();
            if self.check(&TokenKind::KeywordWhen)
                || self.check(&TokenKind::KeywordElse)
                || self.check(&TokenKind::KeywordEnd)
            {
                return Ok(BlockBody {
                    stmts: vec![stmt],
                    tail: None,
                    span: stmt_span,
                });
            }
            self.consume_stmt_separator_any(&[
                TokenKind::KeywordWhen,
                TokenKind::KeywordElse,
                TokenKind::KeywordEnd,
            ])?;
            self.skip_newlines();
            let mut rest = self.parse_block_body_until_any(&[
                TokenKind::KeywordWhen,
                TokenKind::KeywordElse,
                TokenKind::KeywordEnd,
            ])?;
            let mut stmts = vec![stmt];
            stmts.append(&mut rest.stmts);
            return Ok(BlockBody {
                stmts,
                tail: rest.tail,
                span: merge_spans(stmt_span, rest.span),
            });
        }
        let expr = self.parse_expr()?;
        if self.match_kind(&TokenKind::Eq) {
            let value = self.parse_expr()?;
            let span = merge_spans(expr.span(), value.span());
            self.consume_inline_match_arm_separator();
            return Ok(BlockBody {
                stmts: vec![Stmt::Assign {
                    target: expr,
                    value,
                    span,
                }],
                tail: None,
                span,
            });
        }
        if self.consume_inline_match_arm_separator() {
            let span = expr.span();
            return Ok(BlockBody {
                stmts: Vec::new(),
                tail: Some(expr),
                span,
            });
        }
        if self.match_kind(&TokenKind::Semi) {
            self.skip_newlines();
            let mut rest = self.parse_block_body_until_any(&[
                TokenKind::KeywordWhen,
                TokenKind::KeywordElse,
                TokenKind::KeywordEnd,
            ])?;
            let expr_span = expr.span();
            let mut stmts = vec![Stmt::Expr {
                expr,
                span: expr_span,
            }];
            stmts.append(&mut rest.stmts);
            return Ok(BlockBody {
                stmts,
                tail: rest.tail,
                span: merge_spans(expr_span, rest.span),
            });
        }
        let span = expr.span();
        Ok(BlockBody {
            stmts: Vec::new(),
            tail: Some(expr),
            span,
        })
    }

    fn consume_inline_match_arm_separator(&mut self) -> bool {
        if !self.check(&TokenKind::Semi) {
            return false;
        }
        let saved = self.cursor;
        let _ = self.bump();
        self.skip_newlines();
        if !matches!(
            self.peek_kind(),
            TokenKind::KeywordWhen | TokenKind::KeywordElse | TokenKind::KeywordEnd
        ) {
            self.cursor = saved;
            return false;
        }
        true
    }

    fn parse_numeric_literal_suffix(&mut self, mut value: String, token_span: Span) -> String {
        let TokenKind::Ident(suffix) = self.peek_kind() else {
            return value;
        };
        let suffix = suffix.clone();
        let suffix_span = self.peek().span;
        let contiguous = suffix_span.start == token_span.end;
        let supported = matches!(
            suffix.as_str(),
            "u8" | "u16" | "u32" | "u64" | "usize" | "i8" | "i16" | "i32" | "i64" | "f32" | "f64"
        );
        if contiguous && supported {
            let _ = self.bump();
            value.push_str(&suffix);
        }
        value
    }

    fn parse_array_expr(&mut self, start: Span) -> Result<Expr, Stage0Error> {
        let mut elements = Vec::new();
        self.skip_newlines();
        if !self.check(&TokenKind::RBracket) {
            loop {
                self.skip_newlines();
                elements.push(self.parse_expr()?);
                self.skip_newlines();
                if !self.match_kind(&TokenKind::Comma) {
                    break;
                }
                self.skip_newlines();
                if self.check(&TokenKind::RBracket) {
                    break;
                }
            }
        }
        let end = self.expect(&TokenKind::RBracket)?.span;
        Ok(Expr::Array {
            elements,
            span: merge_spans(start, end),
        })
    }

    fn parse_paren_expr(&mut self, start: Span) -> Result<Expr, Stage0Error> {
        if self.check(&TokenKind::RParen) {
            let end = self.expect(&TokenKind::RParen)?.span;
            return Ok(Expr::Tuple {
                elements: Vec::new(),
                span: merge_spans(start, end),
            });
        }
        let first = self.parse_expr()?;
        if !self.match_kind(&TokenKind::Comma) {
            let _ = self.expect(&TokenKind::RParen)?;
            return Ok(first);
        }
        let mut elements = vec![first];
        loop {
            elements.push(self.parse_expr()?);
            if !self.match_kind(&TokenKind::Comma) {
                break;
            }
        }
        let end = self.expect(&TokenKind::RParen)?.span;
        Ok(Expr::Tuple {
            elements,
            span: merge_spans(start, end),
        })
    }

    fn parse_closure_expr(&mut self, start: Span) -> Result<Expr, Stage0Error> {
        let mut params = Vec::new();
        if !self.check(&TokenKind::Pipe) {
            loop {
                if self.match_kind(&TokenKind::LParen) {
                    if !self.check(&TokenKind::RParen) {
                        loop {
                            params.push(self.expect_ident()?);
                            if !self.match_kind(&TokenKind::Comma) {
                                break;
                            }
                        }
                    }
                    let _ = self.expect(&TokenKind::RParen)?;
                } else {
                    params.push(self.expect_ident()?);
                }
                if !self.match_kind(&TokenKind::Comma) {
                    break;
                }
            }
        }
        let _ = self.expect(&TokenKind::Pipe)?;
        let body = if self.match_kind(&TokenKind::KeywordDo) {
            self.skip_newlines();
            let body = self.parse_block_body_until_any(&[TokenKind::KeywordEnd])?;
            self.skip_newlines();
            let _ = self.expect(&TokenKind::KeywordEnd)?;
            body
        } else if self.match_kind(&TokenKind::LBrace) {
            self.skip_newlines();
            let body = self.parse_block_body_until_any(&[TokenKind::RBrace])?;
            self.skip_newlines();
            let _ = self.expect(&TokenKind::RBrace)?;
            body
        } else if self.match_kind(&TokenKind::Newline) {
            self.skip_newlines();
            self.parse_block_body_until_any(&[
                TokenKind::RParen,
                TokenKind::Comma,
                TokenKind::RBracket,
            ])?
        } else {
            let expr = self.parse_expr()?;
            let span = expr.span();
            BlockBody {
                stmts: Vec::new(),
                tail: Some(expr),
                span,
            }
        };
        let span = merge_spans(start, body.span);
        Ok(Expr::Closure {
            closure: Box::new(ClosureExpr { params, body, span }),
            span,
        })
    }

    fn parse_zero_param_closure_expr(&mut self, start: Span) -> Result<Expr, Stage0Error> {
        let body = if self.match_kind(&TokenKind::KeywordDo) {
            self.skip_newlines();
            let body = self.parse_block_body_until_any(&[TokenKind::KeywordEnd])?;
            self.skip_newlines();
            let _ = self.expect(&TokenKind::KeywordEnd)?;
            body
        } else if self.match_kind(&TokenKind::LBrace) {
            self.skip_newlines();
            let body = self.parse_block_body_until_any(&[TokenKind::RBrace])?;
            self.skip_newlines();
            let _ = self.expect(&TokenKind::RBrace)?;
            body
        } else {
            let expr = self.parse_expr()?;
            let span = expr.span();
            BlockBody {
                stmts: Vec::new(),
                tail: Some(expr),
                span,
            }
        };
        let span = merge_spans(start, body.span);
        Ok(Expr::Closure {
            closure: Box::new(ClosureExpr {
                params: Vec::new(),
                body,
                span,
            }),
            span,
        })
    }

    fn parse_type_alias(&mut self, public: bool) -> Result<TypeAliasDecl, Stage0Error> {
        let start = self.expect(&TokenKind::KeywordType)?.span;
        let name = self.expect_ident()?;
        let target = if self.match_kind(&TokenKind::Eq) {
            Some(self.parse_type()?)
        } else {
            None
        };
        let end = target.as_ref().map_or(start, TypeRef::span);
        Ok(TypeAliasDecl {
            name,
            public,
            target,
            span: merge_spans(start, end),
        })
    }

    fn parse_const_decl(&mut self, public: bool) -> Result<ConstDecl, Stage0Error> {
        let start = self.expect(&TokenKind::KeywordConst)?.span;
        let name = self.expect_ident()?;
        let ty = if self.match_kind(&TokenKind::Colon) {
            Some(self.parse_type()?)
        } else {
            None
        };
        let _ = self.expect(&TokenKind::Eq)?;
        let value = self.parse_expr()?;
        Ok(ConstDecl {
            name,
            public,
            ty,
            span: merge_spans(start, value.span()),
            value,
        })
    }

    fn parse_global_decl(&mut self, public: bool) -> Result<crate::ast::decl::GlobalDecl, Stage0Error> {
        let start = self.expect(&TokenKind::KeywordMut)?.span;
        let name = self.expect_ident()?;
        let ty = if self.match_kind(&TokenKind::Colon) {
            Some(self.parse_type()?)
        } else {
            None
        };
        let _ = self.expect(&TokenKind::Eq)?;
        let value = self.parse_expr()?;
        let value_span = value.span();
        Ok(crate::ast::decl::GlobalDecl {
            name,
            public,
            mutable: true,
            ty,
            value,
            span: merge_spans(start, value_span),
        })
    }

    fn parse_extern_decl(&mut self) -> Result<ExternBlockDecl, Stage0Error> {
        let start = self.expect(&TokenKind::KeywordExtern)?.span;
        let abi = if let TokenKind::String(value) = self.peek_kind() {
            let value = value.clone();
            let _ = self.bump();
            self.skip_newlines();
            Some(value)
        } else {
            None
        };

        if self.check(&TokenKind::KeywordDef) {
            let function = self.parse_extern_function_sig()?;
            let span = function.span;
            return Ok(ExternBlockDecl {
                abi,
                functions: vec![function],
                span: merge_spans(start, span),
            });
        }

        self.skip_newlines();
        let mut functions = Vec::new();
        while !self.check(&TokenKind::KeywordEnd) {
            if self.at_eof() {
                return Err(Stage0Error::parse(start, "expected KeywordEnd before EOF"));
            }
            self.skip_newlines();
            if self.check(&TokenKind::KeywordEnd) {
                break;
            }
            functions.push(self.parse_extern_function_sig()?);
            self.skip_newlines();
        }
        let end = self.expect(&TokenKind::KeywordEnd)?.span;
        Ok(ExternBlockDecl {
            abi,
            functions,
            span: merge_spans(start, end),
        })
    }

    fn parse_extern_function_sig(&mut self) -> Result<FunctionSig, Stage0Error> {
        self.parse_signature(false)
    }

    fn parse_optional_where_clause(&mut self) -> Result<Vec<WherePredicate>, Stage0Error> {
        if !self.match_kind(&TokenKind::KeywordWhere) {
            return Ok(Vec::new());
        }
        let mut predicates = Vec::new();
        loop {
            let start = self.peek().span;
            let ty = self.parse_type()?;
            let _ = self.expect(&TokenKind::Colon)?;
            let bounds = self.parse_bound_list()?;
            predicates.push(WherePredicate {
                ty,
                bounds,
                span: merge_spans(start, self.last_consumed_span(start)),
            });
            if !self.match_kind(&TokenKind::Comma) {
                break;
            }
        }
        Ok(predicates)
    }

    fn parse_bound_list(&mut self) -> Result<Vec<String>, Stage0Error> {
        let mut bounds = vec![self.parse_type_name()?];
        while self.match_kind(&TokenKind::Plus) {
            bounds.push(self.parse_type_name()?);
        }
        Ok(bounds)
    }

    fn parse_return_stmt_any(&mut self, terminators: &[TokenKind]) -> Result<Stmt, Stage0Error> {
        let start = self.expect(&TokenKind::KeywordReturn)?.span;
        let value = if self.expression_is_tail_any(terminators) {
            None
        } else {
            Some(self.parse_expr()?)
        };
        let end = value.as_ref().map_or(start, Expr::span);
        Ok(Stmt::Return {
            value,
            span: merge_spans(start, end),
        })
    }

    fn parse_annotation(&mut self) -> Result<MetaDecl, Stage0Error> {
        let start = self.expect(&TokenKind::At)?.span;
        let detail = self.collect_until_newline_or_eof();
        Ok(MetaDecl {
            kind: MetaKind::Annotation,
            detail,
            span: merge_spans(start, self.last_consumed_span(start)),
        })
    }

    fn parse_use_decl(&mut self) -> Result<MetaDecl, Stage0Error> {
        let start = self.expect(&TokenKind::KeywordUse)?.span;
        let detail = self.collect_use_path();
        Ok(MetaDecl {
            kind: MetaKind::Use,
            detail,
            span: merge_spans(start, self.last_consumed_span(start)),
        })
    }

    fn parse_edition_decl(&mut self) -> Result<MetaDecl, Stage0Error> {
        let start = self.expect(&TokenKind::KeywordEdition)?.span;
        let value = match self.bump().kind {
            TokenKind::String(value) => value,
            other => {
                return Err(Stage0Error::parse(
                    self.peek().span,
                    format!("expected edition string, found {other:?}"),
                ));
            }
        };
        Ok(MetaDecl {
            kind: MetaKind::Edition,
            detail: value,
            span: merge_spans(start, self.last_consumed_span(start)),
        })
    }

    fn parse_rationale_decl(&mut self) -> Result<MetaDecl, Stage0Error> {
        let start = self.expect(&TokenKind::KeywordRationale)?.span;
        self.skip_newlines();
        let detail = self.collect_until_keyword_end();
        let end = self.expect(&TokenKind::KeywordEnd)?.span;
        Ok(MetaDecl {
            kind: MetaKind::Rationale,
            detail,
            span: merge_spans(start, end),
        })
    }

    fn parse_cap_decl(&mut self) -> Result<MetaDecl, Stage0Error> {
        let start = self.expect(&TokenKind::KeywordCap)?.span;
        let name = self.expect_ident()?;
        let end = self.expect(&TokenKind::KeywordEnd)?.span;
        Ok(MetaDecl {
            kind: MetaKind::Capability,
            detail: name,
            span: merge_spans(start, end),
        })
    }

    fn collect_until_newline_or_eof(&mut self) -> String {
        let mut parts = Vec::new();
        while !self.check(&TokenKind::Newline) && !self.at_eof() {
            parts.push(self.bump().lexeme);
        }
        parts.join("")
    }

    fn collect_use_path(&mut self) -> String {
        let mut parts = Vec::new();
        let mut brace_depth = 0_u32;
        let mut paren_depth = 0_u32;
        let mut bracket_depth = 0_u32;

        while !self.at_eof() {
            match self.peek_kind() {
                TokenKind::Newline if brace_depth == 0 && paren_depth == 0 && bracket_depth == 0 => {
                    break;
                }
                TokenKind::LBrace => brace_depth += 1,
                TokenKind::RBrace => brace_depth = brace_depth.saturating_sub(1),
                TokenKind::LParen => paren_depth += 1,
                TokenKind::RParen => paren_depth = paren_depth.saturating_sub(1),
                TokenKind::LBracket => bracket_depth += 1,
                TokenKind::RBracket => bracket_depth = bracket_depth.saturating_sub(1),
                _ => {}
            }
            parts.push(self.bump().lexeme);
        }

        parts.join("")
    }

    fn collect_until_keyword_end(&mut self) -> String {
        let mut parts = Vec::new();
        while !self.check(&TokenKind::KeywordEnd) && !self.at_eof() {
            parts.push(self.bump().lexeme);
        }
        parts.join("")
    }

    fn last_consumed_span(&self, fallback: Span) -> Span {
        if self.cursor == 0 {
            fallback
        } else {
            self.tokens[self.cursor.saturating_sub(1)].span
        }
    }

    fn check(&self, expected: &TokenKind) -> bool {
        std::mem::discriminant(self.peek_kind()) == std::mem::discriminant(expected)
    }

    fn match_kind(&mut self, expected: &TokenKind) -> bool {
        if self.check(expected) {
            let _ = self.bump();
            true
        } else {
            false
        }
    }

    fn expect(&mut self, expected: &TokenKind) -> Result<Token, Stage0Error> {
        let token = self.bump();
        if std::mem::discriminant(&token.kind) == std::mem::discriminant(expected) {
            Ok(token)
        } else {
            Err(Stage0Error::parse(
                token.span,
                format!("expected {expected:?}, found {:?}", token.kind),
            ))
        }
    }

    fn expect_ident(&mut self) -> Result<String, Stage0Error> {
        let token = self.advance();
        match token.kind {
            TokenKind::Ident(name) => Ok(name),
            TokenKind::KeywordBudget => Ok("budget".to_string()),
            TokenKind::KeywordDef => Ok("def".to_string()),
            TokenKind::KeywordExtern => Ok("extern".to_string()),
            TokenKind::KeywordFinally => Ok("finally".to_string()),
            TokenKind::KeywordLoop => Ok("loop".to_string()),
            TokenKind::KeywordSelfValue => Ok("self".to_string()),
            TokenKind::KeywordNext => Ok("next".to_string()),
            TokenKind::KeywordModule => Ok("module".to_string()),
            TokenKind::KeywordRationale => Ok("rationale".to_string()),
            TokenKind::KeywordType => Ok("type".to_string()),
            TokenKind::KeywordCap => Ok("cap".to_string()),
            TokenKind::KeywordConst => Ok("const".to_string()),
            TokenKind::KeywordEffect => Ok("effect".to_string()),
            TokenKind::KeywordEdition => Ok("edition".to_string()),
            TokenKind::KeywordGuard => Ok("guard".to_string()),
            TokenKind::KeywordImplies => Ok("implies".to_string()),
            TokenKind::KeywordInline => Ok("inline".to_string()),
            TokenKind::KeywordMut => Ok("mut".to_string()),
            TokenKind::KeywordPre => Ok("pre".to_string()),
            TokenKind::KeywordPost => Ok("post".to_string()),
            TokenKind::KeywordPub => Ok("pub".to_string()),
            other => Err(Stage0Error::parse(
                token.span,
                format!("expected identifier, found {other:?}"),
            )),
        }
    }

    fn at_eof(&self) -> bool {
        matches!(self.peek_kind(), TokenKind::Eof)
    }

    fn peek_kind(&self) -> &TokenKind {
        &self.peek().kind
    }

    fn bump(&mut self) -> Token {
        self.advance()
    }
}

fn merge_spans(start: Span, end: Span) -> Span {
    Span::new(start.line, start.col, start.start, end.end)
}

fn function_body_span(body: &FunctionBody) -> Span {
    match body {
        FunctionBody::Declaration { span } => *span,
        FunctionBody::Block(block) => block.span,
    }
}

fn target_type_name(ty: &TypeRef) -> Result<String, Stage0Error> {
    match ty {
        TypeRef::Named { name, .. } => Ok(name.clone()),
        TypeRef::Int { .. } => Ok("Int".to_string()),
        TypeRef::Float { .. } => Ok("Float".to_string()),
        TypeRef::Char { .. } => Ok("Char".to_string()),
        TypeRef::String { .. } => Ok("String".to_string()),
        TypeRef::Bool { .. } => Ok("Bool".to_string()),
        TypeRef::Unit { .. } => Ok("Unit".to_string()),
        TypeRef::Tuple { .. } | TypeRef::Function { .. } => {
            Err(Stage0Error::parse(ty.span(), "impl target must be a concrete named type"))
        }
        _ => Err(Stage0Error::parse(ty.span(), "impl target must be a concrete named type")),
    }
}

fn starts_with_uppercase(value: &str) -> bool {
    value.chars().next().is_some_and(char::is_uppercase)
}

fn can_start_expression(kind: &TokenKind) -> bool {
    matches!(
        kind,
        TokenKind::Integer(_)
            | TokenKind::Float(_)
            | TokenKind::Char(_)
            | TokenKind::String(_)
            | TokenKind::Ident(_)
            | TokenKind::KeywordPre
            | TokenKind::KeywordModule
            | TokenKind::KeywordType
            | TokenKind::KeywordNext
            | TokenKind::KeywordSelfTy
            | TokenKind::KeywordSelfValue
            | TokenKind::KeywordTrue
            | TokenKind::KeywordFalse
            | TokenKind::KeywordIf
            | TokenKind::KeywordUnless
            | TokenKind::KeywordMatch
            | TokenKind::KeywordUnsafe
            | TokenKind::LParen
            | TokenKind::LBracket
            | TokenKind::Bang
            | TokenKind::Minus
            | TokenKind::Amp
    )
}

fn can_start_implicit_call_arg(kind: &TokenKind) -> bool {
    can_start_expression(kind) && !matches!(kind, TokenKind::Minus | TokenKind::Amp)
}

fn can_continue_postfix_after_newline(expr: &Expr) -> bool {
    matches!(
        expr,
        Expr::Name { .. }
            | Expr::Field { .. }
            | Expr::Index { .. }
            | Expr::Call { .. }
            | Expr::Try { .. }
            | Expr::Cast { .. }
    )
}

fn is_infix_operator(kind: &TokenKind) -> bool {
    matches!(
        kind,
        TokenKind::EqEq
            | TokenKind::BangEq
            | TokenKind::Lt
            | TokenKind::LtEq
            | TokenKind::Gt
            | TokenKind::GtEq
            | TokenKind::Pipe
            | TokenKind::Plus
            | TokenKind::Slash
            | TokenKind::Percent
            | TokenKind::Caret
            | TokenKind::Shl
            | TokenKind::Shr
            | TokenKind::DotDot
            | TokenKind::DotDotEq
    )
}

#[cfg(test)]
mod tests {
    use crate::ast::decl::{Decl, MetaKind};
    use crate::ast::expr::{Expr, FunctionBody, Pattern, Stmt};
    use crate::lexer::Lexer;
    use crate::lexer::token::{Token, TokenKind};
    use crate::span::Span;

    use super::Parser;

    #[test]
    fn advance_stops_at_eof() {
        let span = Span::new(1, 1, 0, 0);
        let tokens = vec![
            Token::new(TokenKind::KeywordStruct, "struct", span),
            Token::new(TokenKind::Ident("Node".to_string()), "Node", span),
            Token::new(TokenKind::LBrace, "{", span),
        ];
        let mut parser = Parser::new(tokens);
        let _ = parser.advance();
        let _ = parser.advance();
        let _ = parser.advance();
        let eof = parser.advance();
        assert!(matches!(eof.kind, TokenKind::Eof));
        assert!(matches!(parser.peek().kind, TokenKind::Eof));
    }

    #[test]
    fn parses_trait_impl_and_struct_without_erasure() {
        let source = concat!(
            "trait Draw { fn draw(Self) -> dyn Surface; }\n",
            "struct Pixel { id: Int }\n",
            "impl Draw Pixel { fn draw(Self) -> dyn Surface {} }\n"
        );
        let tokens = Lexer::new(source).lex_all().expect("lex should succeed");
        let module = Parser::new(tokens).parse_module().expect("parse should succeed");
        assert_eq!(module.decls.len(), 3);

        match &module.decls[0] {
            Decl::Trait(trait_decl) => assert_eq!(trait_decl.methods[0].sig.name, "draw"),
            other => panic!("expected trait, got {other:?}"),
        }

        match &module.decls[2] {
            Decl::Impl(impl_decl) => assert_eq!(impl_decl.methods[0].sig.name, "draw"),
            other => panic!("expected impl, got {other:?}"),
        }

        match &module.decls[1] {
            Decl::Struct(struct_decl) => assert_eq!(struct_decl.fields[0].ty.to_string(), "Int"),
            other => panic!("expected struct, got {other:?}"),
        }
    }

    #[test]
    fn parses_real_tangerine_function_body() {
        let source = concat!(
            "def add(a: Int, b: Int) -> Int\n",
            "  let sum = a + b\n",
            "  sum\n",
            "end\n"
        );
        let tokens = Lexer::new(source).lex_all().expect("lex should succeed");
        let module = Parser::new(tokens).parse_module().expect("parse should succeed");
        match &module.decls[0] {
            Decl::Function(function) => match &function.body {
                FunctionBody::Block(block) => {
                    assert_eq!(block.stmts.len(), 1);
                    assert!(matches!(block.stmts[0], Stmt::Let { .. }));
                    assert!(matches!(block.tail, Some(Expr::Name { .. })));
                }
                FunctionBody::Declaration { .. } => panic!("expected block body"),
            },
            other => panic!("expected function, got {other:?}"),
        }
    }

    #[test]
    fn parses_deref_assignments_with_bitwise_ops() {
        let source = concat!(
            "def rng_next(state: &mut UInt) -> UInt\n",
            "  *state = *state ^ (*state << 13)\n",
            "  *state = *state ^ (*state >> 7)\n",
            "  *state = *state | (*state & 255)\n",
            "  *state\n",
            "end\n"
        );
        let tokens = Lexer::new(source).lex_all().expect("lex should succeed");
        let module = Parser::new(tokens).parse_module().expect("parse should succeed");
        assert_eq!(module.decls.len(), 1);
    }

    #[test]
    fn parses_multiline_function_params() {
        let source = concat!(
            "def check_perf_regressions(current: &Vec[PerfMetric], baseline: &PerfBaseline,\n",
            "                            threshold_pct: Float) -> Vec[String]\n",
            "  Vec::new()\n",
            "end\n"
        );
        let tokens = Lexer::new(source).lex_all().expect("lex should succeed");
        let module = Parser::new(tokens).parse_module().expect("parse should succeed");
        assert_eq!(module.decls.len(), 1);
    }

    #[test]
    fn parses_cast_expressions() {
        let source = concat!(
            "def ratio(value: Int) -> Float\n",
            "  value as Float\n",
            "end\n"
        );
        let tokens = Lexer::new(source).lex_all().expect("lex should succeed");
        let module = Parser::new(tokens).parse_module().expect("parse should succeed");
        assert_eq!(module.decls.len(), 1);
    }

    #[test]
    fn parses_tuple_positional_field_access() {
        let source = concat!(
            "def first(pair: (String, Int)) -> String\n",
            "  pair.0\n",
            "end\n"
        );
        let tokens = Lexer::new(source).lex_all().expect("lex should succeed");
        let module = Parser::new(tokens).parse_module().expect("parse should succeed");
        assert_eq!(module.decls.len(), 1);
    }

    #[test]
    fn parses_metadata_and_inline_function_body() {
        let source = concat!(
            "@test\n",
            "use std::core::{Option, Result}\n",
            "edition \"2026\"\n",
            "rationale\n",
            "  objective: \"x\"\n",
            "end\n",
            "cap FileCap end\n",
            "def square(x: Int) -> Int = x * x\n"
        );
        let tokens = Lexer::new(source).lex_all().expect("lex should succeed");
        let module = Parser::new(tokens).parse_module().expect("parse should succeed");
        assert!(matches!(module.decls[0], Decl::Meta(_)));
        assert!(matches!(module.decls[1], Decl::Meta(_)));
        assert!(matches!(module.decls[2], Decl::Meta(_)));
        match &module.decls[3] {
            Decl::Meta(meta) => assert!(matches!(meta.kind, MetaKind::Rationale)),
            other => panic!("expected rationale meta, got {other:?}"),
        }
        match &module.decls[5] {
            Decl::Function(function) => match &function.body {
                FunctionBody::Block(block) => assert!(block.tail.is_some()),
                FunctionBody::Declaration { .. } => panic!("expected inline body"),
            },
            other => panic!("expected function, got {other:?}"),
        }
    }

    #[test]
    fn parses_pipe_function_types() {
        let source = concat!(
            "struct Hooks\n",
            "  before_each: Option[|| -> Unit]\n",
            "  transform: |Int, String| -> Bool\n",
            "end\n",
            "def wrap(f: || -> Unit) -> || -> Unit\n",
            "  f\n",
            "end\n"
        );
        let tokens = Lexer::new(source).lex_all().expect("lex should succeed");
        let module = Parser::new(tokens).parse_module().expect("parse should succeed");

        match &module.decls[0] {
            Decl::Struct(struct_decl) => {
                assert_eq!(struct_decl.fields[0].ty.to_string(), "Option[fn() -> Unit]");
                assert_eq!(struct_decl.fields[1].ty.to_string(), "fn(Int, String) -> Bool");
            }
            other => panic!("expected struct, got {other:?}"),
        }

        match &module.decls[1] {
            Decl::Function(function_decl) => {
                assert_eq!(function_decl.sig.params[0].ty.to_string(), "fn() -> Unit");
                assert_eq!(function_decl.sig.return_type.to_string(), "fn() -> Unit");
            }
            other => panic!("expected function, got {other:?}"),
        }
    }

    #[test]
    fn parses_struct_literals_closed_with_end() {
        let source = concat!(
            "def build() -> Config\n",
            "  Config {\n",
            "    enabled: true,\n",
            "    name: \"demo\"\n",
            "  end\n",
            "end\n"
        );
        let tokens = Lexer::new(source).lex_all().expect("lex should succeed");
        let module = Parser::new(tokens).parse_module().expect("parse should succeed");

        match &module.decls[0] {
            Decl::Function(function_decl) => match &function_decl.body {
                FunctionBody::Block(block) => match block.tail.as_ref() {
                    Some(Expr::StructLiteral { name, fields, .. }) => {
                        assert_eq!(name, "Config");
                        assert_eq!(fields.len(), 2);
                    }
                    other => panic!("expected struct literal tail, got {other:?}"),
                },
                FunctionBody::Declaration { .. } => panic!("expected block body"),
            },
            other => panic!("expected function, got {other:?}"),
        }
    }

    #[test]
    fn parses_brace_block_expressions() {
        let source = concat!(
            "def empty() -> Unit = {}\n",
            "def compute() -> Int = { let value = 41; value + 1 }\n"
        );
        let tokens = Lexer::new(source).lex_all().expect("lex should succeed");
        let module = Parser::new(tokens).parse_module().expect("parse should succeed");

        match &module.decls[0] {
            Decl::Function(function_decl) => match &function_decl.body {
                FunctionBody::Block(block) => match block.tail.as_ref() {
                    Some(Expr::Block { block, .. }) => {
                        assert!(block.stmts.is_empty());
                        assert!(block.tail.is_none());
                    }
                    other => panic!("expected brace block tail, got {other:?}"),
                },
                FunctionBody::Declaration { .. } => panic!("expected block body"),
            },
            other => panic!("expected function, got {other:?}"),
        }

        match &module.decls[1] {
            Decl::Function(function_decl) => match &function_decl.body {
                FunctionBody::Block(block) => match block.tail.as_ref() {
                    Some(Expr::Block { block, .. }) => {
                        assert_eq!(block.stmts.len(), 1);
                        assert!(matches!(block.tail, Some(Expr::Binary { .. })));
                    }
                    other => panic!("expected brace block tail, got {other:?}"),
                },
                FunctionBody::Declaration { .. } => panic!("expected block body"),
            },
            other => panic!("expected function, got {other:?}"),
        }
    }

    #[test]
    fn parses_soft_keyword_field_names() {
        let source = concat!(
            "struct BudgetViolation\n",
            "  budget: Int\n",
            "  loop: Int\n",
            "end\n"
        );
        let tokens = Lexer::new(source).lex_all().expect("lex should succeed");
        let module = Parser::new(tokens).parse_module().expect("parse should succeed");

        match &module.decls[0] {
            Decl::Struct(struct_decl) => {
                assert_eq!(struct_decl.fields[0].name, "budget");
                assert_eq!(struct_decl.fields[1].name, "loop");
            }
            other => panic!("expected struct, got {other:?}"),
        }
    }

    #[test]
    fn parses_soft_keyword_param_names() {
        let source = concat!(
            "def consume(budget: Int, loop: Int) -> Int\n",
            "  0\n",
            "end\n"
        );
        let tokens = Lexer::new(source).lex_all().expect("lex should succeed");
        let module = Parser::new(tokens).parse_module().expect("parse should succeed");

        match &module.decls[0] {
            Decl::Function(function_decl) => {
                assert_eq!(function_decl.sig.params[0].name, "budget");
                assert_eq!(function_decl.sig.params[1].name, "loop");
            }
            other => panic!("expected function, got {other:?}"),
        }
    }

    #[test]
    fn parses_explicit_generic_method_calls_before_indexing() {
        let source = concat!(
            "trait Deserializer\n",
            "  def deserialize_map[K, V](self: &mut Self) -> Result[Map[K, V], String]\n",
            "end\n",
            "def decode(d: &mut dyn Deserializer) -> Result[Map[String, Int], String]\n",
            "  d.deserialize_map[String, Int]()\n",
            "end\n"
        );
        let tokens = Lexer::new(source).lex_all().expect("lex should succeed");
        let module = Parser::new(tokens).parse_module().expect("parse should succeed");

        assert!(!module.decls.is_empty());
    }

    #[test]
    fn parses_path_qualified_function_declarations() {
        let source = concat!(
            "struct ValueSerializer {}\n",
            "def ValueSerializer::new() -> ValueSerializer\n",
            "  ValueSerializer {}\n",
            "end\n"
        );
        let tokens = Lexer::new(source).lex_all().expect("lex should succeed");
        let module = Parser::new(tokens).parse_module().expect("parse should succeed");

        match &module.decls[1] {
            Decl::Function(function_decl) => assert_eq!(function_decl.sig.name, "ValueSerializer::new"),
            other => panic!("expected function, got {other:?}"),
        }
    }

    #[test]
    fn parses_postfix_after_if_expression() {
        let source = concat!(
            "def render(flag: Bool) -> String\n",
            "  if flag then \"true\" else \"false\" end.to_string()\n",
            "end\n"
        );
        let tokens = Lexer::new(source).lex_all().expect("lex should succeed");
        let module = Parser::new(tokens).parse_module().expect("parse should succeed");

        match &module.decls[0] {
            Decl::Function(function_decl) => match &function_decl.body {
                FunctionBody::Block(block) => {
                    assert!(matches!(block.tail, Some(Expr::Call { .. })));
                }
                FunctionBody::Declaration { .. } => panic!("expected block body"),
            },
            other => panic!("expected function, got {other:?}"),
        }
    }

    #[test]
    fn parses_tuple_style_closure_bindings() {
        let source = concat!(
            "def render(items: Vec[(String, Int)]) -> Int\n",
            "  items.iter().map(|(k, v)| v).count()\n",
            "end\n"
        );
        let tokens = Lexer::new(source).lex_all().expect("lex should succeed");
        let module = Parser::new(tokens).parse_module().expect("parse should succeed");

        assert!(!module.decls.is_empty());
    }

    #[test]
    fn parses_vec_macro_sugar_as_vec_from_call() {
        let source = concat!(
            "def values() -> Vec[Int]\n",
            "  vec![1, 2, 3]\n",
            "end\n"
        );
        let tokens = Lexer::new(source).lex_all().expect("lex should succeed");
        let module = Parser::new(tokens).parse_module().expect("parse should succeed");

        match &module.decls[0] {
            Decl::Function(function_decl) => match &function_decl.body {
                FunctionBody::Block(block) => match block.tail.as_ref() {
                    Some(Expr::Call { callee, args, .. }) => {
                        assert!(matches!(callee.as_ref(), Expr::Name { name, .. } if name == "Vec::from"));
                        assert_eq!(args.len(), 1);
                        assert!(matches!(args[0].value, Expr::Array { .. }));
                    }
                    other => panic!("expected Vec::from call, got {other:?}"),
                },
                FunctionBody::Declaration { .. } => panic!("expected block body"),
            },
            other => panic!("expected function, got {other:?}"),
        }
    }

    #[test]
    fn rejects_invalid_top_level_token() {
        let tokens = Lexer::new("let x = 1").lex_all().expect("lex should succeed");
        let error = Parser::new(tokens).parse_module().expect_err("parse should fail");
        assert!(error.to_string().contains("unexpected token at top level"));
    }

    #[test]
    fn rejects_struct_field_without_type() {
        let tokens = Lexer::new("struct Node { id: }")
            .lex_all()
            .expect("lex should succeed");
        let error = Parser::new(tokens).parse_module().expect_err("parse should fail");
        assert!(error.to_string().contains("unexpected type token"));
    }

    #[test]
    fn rejects_trait_fields() {
        let tokens = Lexer::new("trait Rs { a: Int }")
            .lex_all()
            .expect("lex should succeed");
        let error = Parser::new(tokens).parse_module().expect_err("parse should fail");
        assert!(error.to_string().contains("expected function keyword"));
    }

    #[test]
    fn parses_semicolon_separated_match_arms_and_or_patterns() {
        let source = concat!(
            "def classify(mode: String) -> Bool\n",
            "  match mode\n",
            "    when \"arm64\" | \"aarch64\" then true;\n",
            "    when \"x64\" then false\n",
            "  end\n",
            "end\n"
        );
        let tokens = Lexer::new(source).lex_all().expect("lex should succeed");
        let module = Parser::new(tokens).parse_module().expect("parse should succeed");
        match &module.decls[0] {
            Decl::Function(function) => match &function.body {
                FunctionBody::Block(block) => match block.tail.as_ref() {
                    Some(Expr::Match { arms, .. }) => {
                        assert_eq!(arms.len(), 2);
                        assert!(matches!(arms[0].pattern, Pattern::Or { .. }));
                    }
                    other => panic!("expected match expression tail, got {other:?}"),
                },
                FunctionBody::Declaration { .. } => panic!("expected block body"),
            },
            other => panic!("expected function, got {other:?}"),
        }
    }

    #[test]
    fn parses_semicolon_separated_enum_variants() {
        let source = "enum Register\n  RAX; RCX; RDX\nend\n";
        let tokens = Lexer::new(source).lex_all().expect("lex should succeed");
        let module = Parser::new(tokens).parse_module().expect("parse should succeed");
        match &module.decls[0] {
            Decl::Enum(enum_decl) => {
                assert_eq!(enum_decl.variants.len(), 3);
                assert_eq!(enum_decl.variants[1].name, "RCX");
            }
            other => panic!("expected enum, got {other:?}"),
        }
    }

    #[test]
    fn parses_brace_match_array_types_and_struct_shorthand() {
        let source = concat!(
            "struct Program { items: [String] }\n",
            "struct Wrap { program: Program, did_expand: Bool }\n",
            "def build(items: [String], flag: Bool) -> Wrap\n",
            "  let status = match flag { true => items, false => items }\n",
            "  Wrap { program: Program { items: status }, did_expand: flag }\n",
            "end\n"
        );
        let tokens = Lexer::new(source).lex_all().expect("lex should succeed");
        let module = Parser::new(tokens).parse_module().expect("parse should succeed");
        assert_eq!(module.decls.len(), 3);
    }

    #[test]
    fn keeps_struct_literal_binding_separate_from_following_tuple_tail() {
        let source = concat!(
            "struct FrameInfo { stack_size: Int }\n",
            "def build() -> (Int, FrameInfo)\n",
            "  let frame = FrameInfo { stack_size: 1 }\n",
            "  (1, frame)\n",
            "end\n"
        );
        let tokens = Lexer::new(source).lex_all().expect("lex should succeed");
        let module = Parser::new(tokens).parse_module().expect("parse should succeed");
        match &module.decls[1] {
            Decl::Function(function) => match &function.body {
                FunctionBody::Block(block) => {
                    match &block.stmts[0] {
                        Stmt::Let { value, .. } => {
                            assert!(matches!(value, Expr::StructLiteral { .. }));
                        }
                        other => panic!("expected let statement, got {other:?}"),
                    }
                    assert!(matches!(block.tail, Some(Expr::Tuple { .. })));
                }
                FunctionBody::Declaration { .. } => panic!("expected block body"),
            },
            other => panic!("expected function, got {other:?}"),
        }
    }
}
