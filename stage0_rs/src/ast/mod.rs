pub mod decl;
pub mod expr;
pub mod types;

#[cfg(test)]
mod tests {
    use crate::ast::decl::{Decl, FieldDecl, FunctionDecl, FunctionSig, MetaDecl, MetaKind, Module, Param, StructDecl, TraitDecl};
    use crate::ast::expr::{BinaryOp, CallArg, Expr, FunctionBody, Stmt};
    use crate::ast::types::TypeRef;
    use crate::span::Span;

    #[test]
    fn primitive_and_ref_types_preserve_shape() {
        let span = Span::new(1, 1, 0, 3);
        let ty = TypeRef::Ref {
            inner: Box::new(TypeRef::DynTrait {
                trait_name: "Registry".to_string(),
                span,
            }),
            mutable: false,
            span,
        };
        assert_eq!(TypeRef::Int { span }.to_string(), "Int");
        assert_eq!(ty.to_string(), "&dyn Registry");
    }

    #[test]
    fn module_preserves_trait_method_shape() {
        let span = Span::new(1, 1, 0, 10);
        let module = Module {
            decls: vec![
                Decl::Meta(MetaDecl {
                    kind: MetaKind::Use,
                    detail: "std::test::assert".to_string(),
                    span,
                }),
                Decl::Struct(StructDecl {
                    name: "Pixel".to_string(),
                    public: false,
                    type_params: Vec::new(),
                    where_clause: Vec::new(),
                    fields: vec![FieldDecl {
                        public: false,
                        name: "id".to_string(),
                        ty: TypeRef::Int { span },
                        span,
                    }],
                    span,
                }),
                Decl::Trait(TraitDecl {
                    name: "Draw".to_string(),
                    public: false,
                    type_params: Vec::new(),
                    supertraits: Vec::new(),
                    where_clause: Vec::new(),
                    methods: vec![FunctionDecl {
                        sig: FunctionSig {
                            name: "draw".to_string(),
                            public: false,
                            type_params: Vec::new(),
                            params: vec![Param {
                                name: "self".to_string(),
                                mutable: false,
                                ty: TypeRef::SelfTy { span },
                                default_value: None,
                                span,
                            }],
                            return_type: TypeRef::DynTrait {
                                trait_name: "Surface".to_string(),
                                span,
                            },
                            where_clause: Vec::new(),
                            span,
                        },
                        clauses: Vec::new(),
                        body: FunctionBody::Declaration { span },
                        span,
                    }],
                    associated_types: Vec::new(),
                    span,
                }),
            ],
        };

        match &module.decls[2] {
            Decl::Trait(trait_decl) => {
                assert_eq!(trait_decl.methods.len(), 1);
                assert_eq!(trait_decl.methods[0].sig.name, "draw");
            }
            other => panic!("expected trait, got {other:?}"),
        }

        match &module.decls[1] {
            Decl::Struct(struct_decl) => assert_eq!(struct_decl.fields[0].name, "id"),
            other => panic!("expected struct, got {other:?}"),
        }
    }

    #[test]
    fn function_body_preserves_statements_and_tail_expr() {
        let span = Span::new(1, 1, 0, 8);
        let body = FunctionBody::Block(crate::ast::expr::BlockBody {
            stmts: vec![Stmt::Let {
                pattern: crate::ast::expr::Pattern::Binding {
                    name: "x".to_string(),
                    span,
                },
                mutable: false,
                value: Expr::Integer {
                    value: "1".to_string(),
                    span,
                },
                inferred_type: Some(TypeRef::Int { span }),
                span,
            }],
            tail: Some(Expr::Binary {
                left: Box::new(Expr::Name {
                    name: "x".to_string(),
                    span,
                }),
                op: BinaryOp::Add,
                right: Box::new(Expr::Integer {
                    value: "1".to_string(),
                    span,
                }),
                span,
            }),
            span,
        });

        match body {
            FunctionBody::Block(block) => {
                assert_eq!(block.stmts.len(), 1);
                assert!(block.tail.is_some());
            }
            FunctionBody::Declaration { .. } => panic!("expected block body"),
        }
    }

    #[test]
    fn call_and_field_expr_preserve_shape() {
        let span = Span::new(1, 1, 0, 6);
        let expr = Expr::Call {
            callee: Box::new(Expr::Field {
                base: Box::new(Expr::Name {
                    name: "point".to_string(),
                    span,
                }),
                field: "length".to_string(),
                span,
            }),
            type_args: vec![],
            args: vec![CallArg {
                label: None,
                value: Expr::Bool { value: true, span },
            }],
            span,
        };
        match expr {
            Expr::Call { callee, args, .. } => {
                assert_eq!(args.len(), 1);
                assert!(args[0].label.is_none());
                assert!(matches!(*callee, Expr::Field { .. }));
            }
            other => panic!("expected call expr, got {other:?}"),
        }
    }
}
