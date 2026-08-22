#!/usr/bin/env python3
#
# scripts/gen_grammar_f_specimens.py — the Gate F specimen generator.
#
# Gate F (the grammar-production coverage gate): every grammar production
# (the enumeration in docs/current/grammar_facts.toml, derived from
# docs/current/grammar.md's EBNF rule set) must carry FOUR specimens:
#   pos/<prod>_minimal.tg          the minimal positive program (the
#                                  construct alone, compiles cleanly)
#   pos/<prod>_nested.tg           the positive program with the construct
#                                  NESTED inside another construct
#   neg/<prod>_before.tg           the PRODUCTION-SPECIFIC malformation of
#                                  the production placed BEFORE the
#                                  construct (the parser must still reject
#                                  the program — the construct cannot
#                                  swallow the error)
#   neg/<prod>_after.tg            the PRODUCTION-SPECIFIC malformation of
#                                  the production placed AFTER the
#                                  construct (the parser must still reject
#                                  the program — the construct cannot
#                                  swallow what follows)
#
# The negative specimens are NOT the generic stray-paren mutation: the
# reviewer (item 10) rejected the weak generic `)` negatives. Every
# production's negatives are the production's OWN grammar violations from
# the per-production MALFORMATIONS catalog below (the wrong arity / the
# wrong keyword / the missing clause / the malformed internal structure —
# the production's own rule text is the catalog's ground). The gate
# (scripts/check_grammar_f_gate.sh) mechanically backstops the catalog: a
# negative file containing a bare `)` line FAILS (the generic stray paren
# is forbidden), and the malformation block's position relative to the
# construct marker is verified (BEFORE in the before file, AFTER in the
# after file).
#
# The positive templates live HERE (the generator is the single source of
# truth); the gate regenerates the whole corpus into a temp dir and diffs
# it against tests/grammar_f (the generate-then-diff discipline), then
# compiles the positives and rejects the negatives.
#
# Every template carries the marker line the gate scans for:
#   # gate-f: <prod> minimal-positive / nested-positive
# The neg files carry:
#   # gate-f: <prod> invalid-before / invalid-after
# and the malformation block carries:
#   # gate-f: <prod> malformed
#
# The `verify` mode per production (from grammar_facts.toml): "check" — the
# positive specimens must pass `tg check`; "parse" — the production is
# parse-level only (try_expr / handle_with_expr are REJECTED by the
# pipeline after parsing by design: "exceptions are not supported"), so
# the positives must pass `tg parse` and the checker documents the
# pipeline rejection.
#
# Usage: scripts/gen_grammar_f_specimens.py [--out DIR]
#   DIR defaults to <repo>/tests/grammar_f. Fails (exit 1) when a
#   production in the facts has no template OR no malformation catalog
#   entry — an uncovered production can never be shipped silently.

import os
import re
import sys
import tomllib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FACTS = os.path.join(ROOT, "docs", "current", "grammar_facts.toml")

# The per-production malformation catalog — the reviewer's item 10
# strengthening. For every production: (before_snippet, after_snippet),
# the production's OWN grammar violations (the wrong arity / the wrong
# keyword / the missing clause / the malformed internal structure —
# grounded in the production's rule text in grammar_facts.toml). The
# generic stray-paren negative is GONE: a production without a catalog
# entry fails the generation, and the gate backstops a bare `)` line.
# Each snippet is a standalone construct (top-level or a full wrapper
# containing the violation) that the compiler MUST reject.

# ———————————————————————————————————————————————————————————————
# The positive templates. For each production: (minimal, nested).
# The marker line is EMBEDDED directly above the construct.
# ———————————————————————————————————————————————————————————————

TEMPLATES = {
"program": (
"""# gate-f: program minimal-positive
def gate_f_program() -> Int
  0
end
""",
"""# gate-f: program nested-positive
module gate_f_program_nested
  def inner() -> Int
    0
  end
end

def gate_f_program_nested_main() -> Int
  gate_f_program_nested::inner()
end
"""),
"item": (
"""# gate-f: item minimal-positive
def gate_f_item() -> Int
  0
end
""",
"""module gate_f_item_nested
  # gate-f: item nested-positive
  def inner_item() -> Int
    0
  end
end
"""),
"vis": (
"""# gate-f: vis minimal-positive
pub def gate_f_vis() -> Int
  0
end
""",
"""module gate_f_vis_nested
  # gate-f: vis nested-positive
  private def inner_private() -> Int
    0
  end
end
"""),
"function_def": (
"""# gate-f: function_def minimal-positive
def gate_f_function_def(x: Int) -> Int
  x
end
""",
"""struct gate_f_function_def_host
  v: Int
end

impl gate_f_function_def_host
  # gate-f: function_def nested-positive
  def get(self: gate_f_function_def_host) -> Int
    self.v
  end
end
"""),
"fn_modifier": (
"""# gate-f: fn_modifier minimal-positive
unsafe def gate_f_fn_modifier() -> Int
  0
end
""",
"""module gate_f_fn_modifier_nested
  # gate-f: fn_modifier nested-positive
  inline def inner_inline() -> Int
    0
  end
end
"""),
"fn_clause": (
"""# gate-f: fn_clause minimal-positive
def gate_f_fn_clause(x: Int) -> Int pre x > 0
  x
end
""",
"""# gate-f: fn_clause nested-positive
def gate_f_fn_clause_nested(x: Int) -> Int pre x > 0 post x >= 0
  x
end
"""),
"budget_amount": (
"""# gate-f: budget_amount minimal-positive
def gate_f_budget_amount() -> Int @budget cpu: "10"
  0
end
""",
"""# gate-f: budget_amount nested-positive
def gate_f_budget_amount_nested() -> Int @budget cpu: "5", mem: "5"
  0
end
"""),
"type_params": (
"""# gate-f: type_params minimal-positive
def gate_f_type_params[T](x: T) -> T
  x
end
""",
"""module gate_f_type_params_nested
  struct Box[T]
    v: T
  end

  # gate-f: type_params nested-positive
  def wrap[T](x: T) -> Box[T]
    Box { v: x }
  end
end
"""),
"type_param": (
"""# gate-f: type_param minimal-positive
def gate_f_type_param[T: Copy](x: T) -> T
  x
end
""",
"""# gate-f: type_param nested-positive
def gate_f_type_param_nested[K: Hash + Eq, V](k: K, v: V) -> K
  k
end
"""),
"type_bound": (
"""# gate-f: type_bound minimal-positive
def gate_f_type_bound[T: Copy + Eq](x: T) -> T
  x
end
""",
"""# gate-f: type_bound nested-positive
def gate_f_type_bound_nested[K: Hash + Eq](k: K) -> K
  k
end
"""),
"where_clause": (
"""# gate-f: where_clause minimal-positive
def gate_f_where_clause[T](x: T) -> T where T: Copy
  x
end
""",
"""module gate_f_where_clause_nested
  # gate-f: where_clause nested-positive
  def inner[T](x: T) -> T where T: Copy
    x
  end
end
"""),
"where_pred": (
"""# gate-f: where_pred minimal-positive
def gate_f_where_pred[T, U](a: T, b: U) -> T where T: Copy, U: Copy
  a
end
""",
"""# gate-f: where_pred nested-positive
def gate_f_where_pred_nested[T](x: T) -> T where T: Copy + Eq
  x
end
"""),
"param_list": (
"""# gate-f: param_list minimal-positive
def gate_f_param_list(a: Int, b: Int) -> Int
  a + b
end
""",
"""struct gate_f_param_list_host
  v: Int
end

impl gate_f_param_list_host
  # gate-f: param_list nested-positive
  def sum3(self: gate_f_param_list_host, a: Int, b: Int) -> Int
    self.v + a + b
  end
end
"""),
"param": (
"""# gate-f: param minimal-positive
def gate_f_param(inout x: Int) -> Int
  x
end
""",
"""# gate-f: param nested-positive
def gate_f_param_nested(sink s: String, x: Int = 5) -> Int
  x + s.len()
end
"""),
"struct_def": (
"""# gate-f: struct_def minimal-positive
struct gate_f_struct_def
  v: Int
end
""",
"""module gate_f_struct_def_nested
  # gate-f: struct_def nested-positive
  struct Inner
    v: Int
  end
end
"""),
"field_def": (
"""# gate-f: field_def minimal-positive
struct gate_f_field_def
  x: Int
end
""",
"""module gate_f_field_def_nested
  struct Inner
    # gate-f: field_def nested-positive
    pub y: Int
    z: Int
  end
end
"""),
"resource_def": (
"""# gate-f: resource_def minimal-positive
resource gate_f_resource_def
  v: Int
end
""",
"""module gate_f_resource_def_nested
  # gate-f: resource_def nested-positive
  resource Inner
    v: Int

    def get(self: Inner) -> Int
      self.v
    end
  end
end
"""),
"deinit_def": (
"""# gate-f: deinit_def minimal-positive
resource gate_f_deinit_def
  v: Int

  # gate-f: deinit_def minimal-positive
  def deinit(sink self: Self) -> Unit
    ()
  end
end
""",
"""module gate_f_deinit_def_nested
  resource Inner
    v: Int

    # gate-f: deinit_def nested-positive
    def deinit(sink self: Self) -> Unit
      ()
    end
  end
end
"""),
"enum_def": (
"""# gate-f: enum_def minimal-positive
enum gate_f_enum_def
  A
  B(Int)
end
""",
"""module gate_f_enum_def_nested
  # gate-f: enum_def nested-positive
  enum Inner
    X
    Y(Int)
  end
end
"""),
"variant_def": (
"""# gate-f: variant_def minimal-positive
enum gate_f_variant_def
  Red
  Green(Int)
end
""",
"""# gate-f: variant_def nested-positive
enum gate_f_variant_def_nested
  Blue(v: Int)
  Cyan
end
"""),
"variant_field": (
"""# gate-f: variant_field minimal-positive
enum gate_f_variant_field
  Green(v: Int)
end
""",
"""# gate-f: variant_field nested-positive
enum gate_f_variant_field_nested
  C(x: Int, y: Int)
end
"""),
"trait_def": (
"""# gate-f: trait_def minimal-positive
trait gate_f_trait_def
  def f(self: gate_f_trait_def) -> Int
end
""",
"""module gate_f_trait_def_nested
  # gate-f: trait_def nested-positive
  trait Inner
    def f(self: Inner) -> Int
    def g(self: Inner) -> Int
  end
end
"""),
"supertrait_list": (
"""# gate-f: supertrait_list minimal-positive
trait gate_f_supertrait_base
  def f(self: gate_f_supertrait_base) -> Int
end

trait gate_f_supertrait_child: gate_f_supertrait_base
  def g(self: gate_f_supertrait_child) -> Int
end
""",
"""# gate-f: supertrait_list nested-positive
trait gate_f_supertrait_a
  def a(self: gate_f_supertrait_a) -> Int
end

trait gate_f_supertrait_b
  def b(self: gate_f_supertrait_b) -> Int
end

trait gate_f_supertrait_c: gate_f_supertrait_a + gate_f_supertrait_b
  def c(self: gate_f_supertrait_c) -> Int
end
"""),
"trait_item": (
"""# gate-f: trait_item minimal-positive
trait gate_f_trait_item
  # gate-f: trait_item minimal-positive
  def f(self: gate_f_trait_item) -> Int
end
""",
"""# gate-f: trait_item nested-positive
trait gate_f_trait_item_nested
  type Item: Copy
  def f(self: gate_f_trait_item_nested) -> Item
end
"""),
"function_sig": (
"""# gate-f: function_sig minimal-positive
trait gate_f_function_sig
  # gate-f: function_sig minimal-positive
  def f(self: gate_f_function_sig) -> Int
end
""",
"""# gate-f: function_sig nested-positive
trait gate_f_function_sig_nested
  def f[T](self: gate_f_function_sig_nested, x: T) -> T
end
"""),
"impl_block": (
"""struct gate_f_impl_block
  v: Int
end

# gate-f: impl_block minimal-positive
impl gate_f_impl_block
  def get(self: gate_f_impl_block) -> Int
    self.v
  end
end
""",
"""trait gate_f_impl_block_trait
  def f(self: gate_f_impl_block_trait) -> Int
end

struct gate_f_impl_block_host
  v: Int
end

# gate-f: impl_block nested-positive
impl gate_f_impl_block_trait for gate_f_impl_block_host
  def f(self: gate_f_impl_block_host) -> Int
    self.v
  end
end
"""),
"impl_item": (
"""struct gate_f_impl_item
  v: Int
end

impl gate_f_impl_item
  # gate-f: impl_item minimal-positive
  def get(self: gate_f_impl_item) -> Int
    self.v
  end
end
""",
"""struct gate_f_impl_item_host
  v: Int
end

impl gate_f_impl_item_host do
  # gate-f: impl_item nested-positive
  type Item = Int

  def get(self: gate_f_impl_item_host) -> Int
    self.v
  end
end
"""),
"use_decl": (
"""# gate-f: use_decl minimal-positive
use std::core::Option
""",
"""# gate-f: use_decl nested-positive
use std::collections::{Vec, Map}
use std::core::Option as Opt
"""),
"path": (
"""# gate-f: path minimal-positive
use std::core::Option
""",
"""module gate_f_path_nested
  def inner() -> Int
    0
  end
end

def gate_f_path_nested_main() -> Int
  # gate-f: path nested-positive
  gate_f_path_nested::inner()
end
"""),
"path_segment": (
"""# gate-f: path_segment minimal-positive
use std::core::Option
""",
"""module gate_f_path_segment_nested
  # gate-f: path_segment nested-positive
  def inner() -> Int
    0
  end
end

def gate_f_path_segment_main() -> Int
  gate_f_path_segment_nested::inner()
end
"""),
"name_list": (
"""# gate-f: name_list minimal-positive
use std::collections::{Vec, Map}
""",
"""# gate-f: name_list nested-positive
use std::core::{Option, Result}
use std::collections::{Vec, Map, Set}
"""),
"const_decl": (
"""# gate-f: const_decl minimal-positive
const GATE_F_CONST: Int = 5
""",
"""module gate_f_const_decl_nested
  # gate-f: const_decl nested-positive
  const INNER_CONST: Int = 7
end
"""),
"static_decl": (
"""# gate-f: static_decl minimal-positive
static GATE_F_STATIC: Int = 5
""",
"""module gate_f_static_decl_nested
  # gate-f: static_decl nested-positive
  static mut INNER_STATIC: Int = 7
end
"""),
"type_alias": (
"""# gate-f: type_alias minimal-positive
type GateFAlias = Int
""",
"""module gate_f_type_alias_nested
  # gate-f: type_alias nested-positive
  type Pair2[T] = (T, T)
end
"""),
"capability_decl": (
"""# gate-f: capability_decl minimal-positive
cap GateFCap
end
""",
"""cap GateFD
end

cap GateFE
end

# gate-f: capability_decl nested-positive
cap GateFF implies GateFD, GateFE
end
"""),
"effect_decl": (
"""# gate-f: effect_decl minimal-positive
effect GateFEffect
  op() -> Int
end
""",
"""module gate_f_effect_decl_nested
  # gate-f: effect_decl nested-positive
  effect InnerEffect
    op1() -> Int
    op2()
  end
end
"""),
"effect_op_sig": (
"""# gate-f: effect_op_sig minimal-positive
effect GateFEffectOp
  read_op(path: String) -> Int
end
""",
"""# gate-f: effect_op_sig nested-positive
effect GateFEffectOpNested
  op1(a: Int) -> Int
  op2(b: String)
end
"""),
"edition_decl": (
"""# gate-f: edition_decl minimal-positive
edition "2026"
""",
"""# gate-f: edition_decl nested-positive
edition "2026"

def gate_f_edition_after() -> Int
  0
end
"""),
"extern_item": (
"""# gate-f: extern_item minimal-positive
extern def gate_f_extern(x: Int) -> Int end
""",
"""# gate-f: extern_item nested-positive
extern "C" def gate_f_extern_c(x: Int) -> Int end

extern static GATE_F_EXTERN_STATIC: Int
"""),
"macro_decl": (
"""# gate-f: macro_decl minimal-positive
macro gate_f_macro(x: Expr)
  (x)
end
""",
"""module gate_f_macro_decl_nested
  # gate-f: macro_decl nested-positive
  macro inner_macro(x: Expr, y: Ident)
    (x)
  end
end
"""),
"macro_param": (
"""# gate-f: macro_param minimal-positive
macro gate_f_macro_param(x: Expr)
  (x)
end
""",
"""# gate-f: macro_param nested-positive
macro gate_f_macro_param_nested(x: Expr, y: Ident, z: Type)
  (x)
end
"""),
"macro_type": (
"""# gate-f: macro_type minimal-positive
macro gate_f_macro_type(x: Expr)
  (x)
end
""",
"""# gate-f: macro_type nested-positive
macro gate_f_macro_type_block(x: Block)
  (1)
end

macro gate_f_macro_type_pat(x: Pattern)
  (1)
end
"""),
"rationale_block": (
"""# gate-f: rationale_block minimal-positive
rationale
  why: "gate f"
end
""",
"""# gate-f: rationale_block nested-positive
rationale
  why: "gate f"
  count: 3
end
"""),
"rationale_field": (
"""# gate-f: rationale_field minimal-positive
rationale
  why: "gate f"
end
""",
"""# gate-f: rationale_field nested-positive
rationale
  why: "gate f"
  count: 3
end
"""),
"type_expr": (
"""# gate-f: type_expr minimal-positive
def gate_f_type_expr(x: Int) -> Int
  x
end
""",
"""# gate-f: type_expr nested-positive
def gate_f_type_expr_nested(x: Vec[Option[Int]]) -> Int
  x.len()
end
"""),
"type_primary": (
"""# gate-f: type_primary minimal-positive
def gate_f_type_primary(x: Vec[Int]) -> Int
  x.len()
end
""",
"""module gate_f_type_primary_nested
  struct Probe
    v: Int
  end

  # gate-f: type_primary nested-positive
  def inner(x: Probe) -> Int
    x.v
  end
end
"""),
"fn_type": (
"""# gate-f: fn_type minimal-positive
def gate_f_fn_type(g: fn(Int) -> Int) -> Int
  g(1)
end
""",
"""# gate-f: fn_type nested-positive
def gate_f_fn_type_nested(g: Fn(Int, Int) -> Int) -> Int
  g(1, 2)
end
"""),
"fn_type_param": (
"""# gate-f: fn_type_param minimal-positive
def gate_f_fn_type_param(g: fn(inout Int) -> Int) -> Int
  g(1)
end
""",
"""# gate-f: fn_type_param nested-positive
def gate_f_fn_type_param_nested(g: fn(sink Int, set Int) -> Int) -> Int
  g(1, 2)
end
"""),
"convention": (
"""# gate-f: convention minimal-positive
def gate_f_convention(g: fn(inout Int) -> Int) -> Int
  g(1)
end
""",
"""# gate-f: convention nested-positive
def gate_f_convention_nested(g: fn(sink Int, set Int) -> Int) -> Int
  g(1, 2)
end
"""),
"type_args": (
"""# gate-f: type_args minimal-positive
def gate_f_type_args(x: Vec[Int]) -> Int
  x.len()
end
""",
"""# gate-f: type_args nested-positive
def gate_f_type_args_nested(x: Map[String, Vec[Int]]) -> Int
  x.len()
end
"""),
"expr": (
"""def gate_f_expr() -> Int
  # gate-f: expr minimal-positive
  let v = 1 + 2
  v
end
""",
"""def gate_f_expr_nested() -> Int
  var total = 0
  if true then
    # gate-f: expr nested-positive
    total = total + 1 + 2
  end
  total
end
"""),
"logical_or": (
"""def gate_f_logical_or(a: Bool, b: Bool) -> Bool
  # gate-f: logical_or minimal-positive
  a || b
end
""",
"""def gate_f_logical_or_nested(a: Bool, b: Bool, c: Bool) -> Bool
  # gate-f: logical_or nested-positive
  a || b || c
end
"""),
"logical_and": (
"""def gate_f_logical_and(a: Bool, b: Bool) -> Bool
  # gate-f: logical_and minimal-positive
  a && b
end
""",
"""def gate_f_logical_and_nested(a: Bool, b: Bool, c: Bool) -> Bool
  # gate-f: logical_and nested-positive
  a && b && c
end
"""),
"range": (
"""def gate_f_range() -> Int
  var total = 0
  # gate-f: range minimal-positive
  for i in 0..3 do
    total = total + i
  end
  total
end
""",
"""def gate_f_range_nested() -> Int
  var total = 0
  # gate-f: range nested-positive
  for i in 0..=3 do
    total = total + i
  end
  total
end
"""),
"equality": (
"""def gate_f_equality(a: Int, b: Int) -> Bool
  # gate-f: equality minimal-positive
  a == b
end
""",
"""def gate_f_equality_nested(a: Int, b: Int) -> Bool
  # gate-f: equality nested-positive
  a != b
end
"""),
"comparison": (
"""def gate_f_comparison(a: Int, b: Int) -> Bool
  # gate-f: comparison minimal-positive
  a < b
end
""",
"""def gate_f_comparison_nested(a: Int, b: Int) -> Bool
  # gate-f: comparison nested-positive
  a <= b && b >= a
end
"""),
"bitwise_or": (
"""def gate_f_bitwise_or(a: Int, b: Int) -> Int
  # gate-f: bitwise_or minimal-positive
  a | b
end
""",
"""def gate_f_bitwise_or_nested(a: Int, b: Int, c: Int) -> Int
  # gate-f: bitwise_or nested-positive
  a | b | c
end
"""),
"bitwise_xor": (
"""def gate_f_bitwise_xor(a: Int, b: Int) -> Int
  # gate-f: bitwise_xor minimal-positive
  a ^ b
end
""",
"""def gate_f_bitwise_xor_nested(a: Int, b: Int, c: Int) -> Int
  # gate-f: bitwise_xor nested-positive
  a ^ b ^ c
end
"""),
"bitwise_and": (
"""def gate_f_bitwise_and(a: Int, b: Int) -> Int
  # gate-f: bitwise_and minimal-positive
  a & b
end
""",
"""def gate_f_bitwise_and_nested(a: Int, b: Int, c: Int) -> Int
  # gate-f: bitwise_and nested-positive
  a & b & c
end
"""),
"shift": (
"""def gate_f_shift(a: Int) -> Int
  # gate-f: shift minimal-positive
  a << 2
end
""",
"""def gate_f_shift_nested(a: Int) -> Int
  # gate-f: shift nested-positive
  a >> 1
end
"""),
"term": (
"""def gate_f_term(a: Int, b: Int) -> Int
  # gate-f: term minimal-positive
  a + b
end
""",
"""def gate_f_term_nested(a: Int, b: Int) -> Int
  # gate-f: term nested-positive
  a - b
end
"""),
"factor": (
"""def gate_f_factor(a: Int, b: Int) -> Int
  # gate-f: factor minimal-positive
  a * b
end
""",
"""def gate_f_factor_nested(a: Int, b: Int) -> Int
  # gate-f: factor nested-positive
  a / b + a % b
end
"""),
"unary": (
"""def gate_f_unary(a: Int) -> Int
  # gate-f: unary minimal-positive
  -a
end
""",
"""def gate_f_unary_nested(a: Int, b: Bool) -> Int
  # gate-f: unary nested-positive
  let inv = !b
  let bits = ~a
  if inv then bits else a end
end
"""),
"access_marker": (
"""def gate_f_access_helper(x: Int) -> Int
  x
end

def gate_f_access_marker() -> Int
  var counter = 3
  # gate-f: access_marker minimal-positive
  gate_f_access_helper(&counter)
end
""",
"""def gate_f_access_inout(inout x: Int) -> Int
  x
end

def gate_f_access_marker_nested() -> Int
  var counter = 3
  # gate-f: access_marker nested-positive
  gate_f_access_inout(&mut counter)
end
"""),
"raw_deref": (
"""def gate_f_raw_deref(p: *Int) -> Int
  # gate-f: raw_deref minimal-positive
  let v = *p
  v
end
""",
"""def gate_f_raw_deref_nested(pp: *Int) -> Int
  var v = 0
  # gate-f: raw_deref nested-positive
  v = *pp
  v
end
"""),
"postfix": (
"""def gate_f_postfix() -> Int
  let s = "abc".to_string()
  # gate-f: postfix minimal-positive
  s.len()
end
""",
"""def gate_f_postfix_nested() -> Int
  let items = [1, 2, 3]
  # gate-f: postfix nested-positive
  items[0] + items[1]
end
"""),
"postfix_op": (
"""def gate_f_postfix_op() -> Int
  let s = "abc".to_string()
  # gate-f: postfix_op minimal-positive
  s.len()
end
""",
"""def gate_f_postfix_op_nested() -> Int
  let items = [1, 2, 3]
  # gate-f: postfix_op nested-positive
  items[0]
end
"""),
"arg_list": (
"""def gate_f_arg_list_helper(a: Int, b: Int) -> Int
  a + b
end

def gate_f_arg_list() -> Int
  # gate-f: arg_list minimal-positive
  gate_f_arg_list_helper(1, 2)
end
""",
"""def gate_f_arg_list_helper3(a: Int, b: Int, c: Int) -> Int
  a + b + c
end

def gate_f_arg_list_nested() -> Int
  # gate-f: arg_list nested-positive
  gate_f_arg_list_helper3(1, 2, 3,)
end
"""),
"named_arg": (
"""def gate_f_named_arg_helper(x: Int, y: Int) -> Int
  x + y
end

def gate_f_named_arg() -> Int
  # gate-f: named_arg minimal-positive
  gate_f_named_arg_helper(x: 1, y: 2)
end
""",
"""def gate_f_named_arg_helper2(x: Int, y: Int) -> Int
  x + y
end

def gate_f_named_arg_nested() -> Int
  # gate-f: named_arg nested-positive
  gate_f_named_arg_helper2(1, y: 2)
end
"""),
"trailing_block": (
"""def gate_f_trailing_block(items: Vec[Int]) -> Int
  # gate-f: trailing_block minimal-positive
  items.map { |x| x * 2 }.len()
end
""",
"""def gate_f_trailing_block_nested(items: Vec[Int]) -> Int
  # gate-f: trailing_block nested-positive
  items.map { |a, b| a }.len()
end
"""),
"primary": (
"""def gate_f_primary() -> Int
  # gate-f: primary minimal-positive
  let v = 42
  v
end
""",
"""def gate_f_primary_nested() -> String
  # gate-f: primary nested-positive
  let v = "nested"
  v
end
"""),
"struct_literal": (
"""struct gate_f_struct_literal
  x: Int
  y: Int
end

def gate_f_struct_literal_spec() -> Int
  # gate-f: struct_literal minimal-positive
  let p = gate_f_struct_literal { x: 1, y: 2 }
  p.x + p.y
end
""",
"""def gate_f_struct_literal_nested() -> Int
  # gate-f: struct_literal nested-positive
  let v = Vec[Int]::new()
  v.len()
end
"""),
"field_init_list": (
"""struct gate_f_field_init_list
  x: Int
  y: Int
end

def gate_f_field_init_list_spec() -> Int
  # gate-f: field_init_list minimal-positive
  let p = gate_f_field_init_list { x: 1, y: 2 }
  p.x
end
""",
"""struct gate_f_field_init_list_nested
  x: Int
  y: Int
end

def gate_f_field_init_list_nested_spec() -> Int
  # gate-f: field_init_list nested-positive
  let p = gate_f_field_init_list_nested { x, y }
  p.x + p.y
end
"""),
"field_init": (
"""struct gate_f_field_init
  x: Int
end

def gate_f_field_init_spec() -> Int
  # gate-f: field_init minimal-positive
  let p = gate_f_field_init { x: 1 }
  p.x
end
""",
"""struct gate_f_field_init_nested
  x: Int
  y: Int
end

def gate_f_field_init_nested_spec() -> Int
  # gate-f: field_init nested-positive
  let p = gate_f_field_init_nested { x, y: 2 }
  p.x + p.y
end
"""),
"block_expr": (
"""def gate_f_block_expr() -> Int
  # gate-f: block_expr minimal-positive
  let v = do 3 end
  v
end
""",
"""def gate_f_block_expr_nested() -> Int
  # gate-f: block_expr nested-positive
  let f = do |x: Int, y: Int|
    x + y
  end
  f(1, 2)
end
"""),
"if_expr": (
"""def gate_f_if_expr(c: Bool) -> Int
  # gate-f: if_expr minimal-positive
  if c then 1 else 2 end
end
""",
"""def gate_f_if_expr_nested(a: Int, b: Bool) -> Int
  # gate-f: if_expr nested-positive
  if b then if a > 0 then a else 0 end else 0 end
end
"""),
"if_let": (
"""use std::core::Option

def gate_f_if_let(o: Option[Int]) -> Int
  # gate-f: if_let minimal-positive
  if let Option::Some(v) = o then
    v
  else
    0
  end
end
""",
"""use std::core::Option

def gate_f_if_let_nested(o: Option[Int]) -> Int
  # gate-f: if_let nested-positive
  if let Option::Some(v) = o then
    v
  elsif let Option::None = o then
    0
  else
    0
  end
end
"""),
"unless_expr": (
"""def gate_f_unless_expr(c: Bool) -> Int
  # gate-f: unless_expr minimal-positive
  unless c then 1 else 2 end
end
""",
"""def gate_f_unless_expr_nested(c: Bool) -> Int
  var out = 0
  # gate-f: unless_expr nested-positive
  unless c then
    out = 1
  end
  out
end
"""),
"match_expr": (
"""def gate_f_match_expr(n: Int) -> Int
  # gate-f: match_expr minimal-positive
  match n
  when 0 then 1
  when _ then 0
  end
end
""",
"""def gate_f_match_expr_nested(n: Int) -> Int
  # gate-f: match_expr nested-positive
  match n
  when 1 if n > 0 then 10
  when _ then 0
  end
end
"""),
"match_arm": (
"""def gate_f_match_arm(n: Int) -> Int
  match n
  # gate-f: match_arm minimal-positive
  when 0 then 1
  when _ then 0
  end
end
""",
"""def gate_f_match_arm_nested(n: Int) -> Int
  # gate-f: match_arm nested-positive
  match n
  1 => 10
  _ => 0
  end
end
"""),
"for_expr": (
"""def gate_f_for_expr() -> Int
  var total = 0
  # gate-f: for_expr minimal-positive
  for i in 0..3 do
    total = total + i
  end
  total
end
""",
"""def gate_f_for_expr_nested() -> Int
  var total = 0
  # gate-f: for_expr nested-positive
  for i in 0..2 do
    for j in 0..2 do
      total = total + i + j
    end
  end
  total
end
"""),
"while_expr": (
"""def gate_f_while_expr() -> Int
  var i = 0
  # gate-f: while_expr minimal-positive
  while i < 3 do
    i = i + 1
  end
  i
end
""",
"""def gate_f_while_expr_nested() -> Int
  var i = 0
  var j = 0
  # gate-f: while_expr nested-positive
  while i < 3 do
    while j < 2 do
      j = j + 1
    end
    i = i + 1
  end
  i + j
end
"""),
"until_expr": (
"""def gate_f_until_expr() -> Int
  var i = 0
  # gate-f: until_expr minimal-positive
  until i >= 3 do
    i = i + 1
  end
  i
end
""",
"""def gate_f_until_expr_nested() -> Int
  var i = 0
  var total = 0
  # gate-f: until_expr nested-positive
  until i >= 3 do
    total = total + i
    i = i + 1
  end
  total
end
"""),
"loop_expr": (
"""def gate_f_loop_expr() -> Int
  var i = 0
  # gate-f: loop_expr minimal-positive
  loop do
    i = i + 1
    if i >= 3 then break end
  end
  i
end
""",
"""def gate_f_loop_expr_nested() -> Int
  var i = 0
  if true then
    # gate-f: loop_expr nested-positive
    loop do
      i = i + 1
      if i >= 3 then break end
    end
  end
  i
end
"""),
"try_expr": (
"""# gate-f: try_expr minimal-positive
def gate_f_try_expr() -> Int
  try do
    1
  catch _ do
    2
  end
end
""",
"""# gate-f: try_expr nested-positive
def gate_f_try_expr_nested() -> Int
  try do
    1
  catch _ do
    2
  finally do
    3
  end
end
"""),
"guard_stmt": (
"""def gate_f_guard_stmt(x: Int) -> Int
  # gate-f: guard_stmt minimal-positive
  guard x > 0 else return 0
  x
end
""",
"""def gate_f_guard_stmt_nested(x: Int) -> Int
  # gate-f: guard_stmt nested-positive
  guard x > 0 else panic("bad")
  guard x < 100 else return 0
  x
end
"""),
"handle_with_expr": (
"""# gate-f: handle_with_expr minimal-positive
def gate_f_handle_with_expr() -> Int
  handle 1 with op do
    x
  end
end
""",
"""# gate-f: handle_with_expr nested-positive
def gate_f_handle_with_expr_nested() -> Int
  handle 1 with op1 do
    x
  with op2 do
    y
  end
end
"""),
"unsafe_block": (
"""def gate_f_unsafe_block() -> Int
  # gate-f: unsafe_block minimal-positive
  unsafe do
    1
  end
  0
end
""",
"""def gate_f_unsafe_block_nested() -> Int
  # gate-f: unsafe_block nested-positive
  let v = unsafe { 3 }
  v
end
"""),
"defer_block": (
"""def gate_f_defer_block() -> Int
  var x = 0
  # gate-f: defer_block minimal-positive
  defer do
    x = x + 1
  end
  x
end
""",
"""def gate_f_defer_block_nested() -> Int
  var x = 0
  loop do
    # gate-f: defer_block nested-positive
    defer do
      x = x + 1
    end
    if x >= 3 then break end
    x = x + 1
  end
  x
end
"""),
"async_block": (
"""def gate_f_async_block() -> Int
  # gate-f: async_block minimal-positive
  let f = async do
    1
  end
  1
end
""",
"""use std::async::{Executor, Duration, sleep}

def gate_f_async_block_nested() -> Int
  let e = Executor::new(1)
  # gate-f: async_block nested-positive
  e.spawn(async {
    sleep(Duration::from_millis(1)).await
    7
  })
  e.run()
  0
end
"""),
"comptime_block": (
"""def gate_f_comptime_block() -> Int
  # gate-f: comptime_block minimal-positive
  let v = comptime do
    1
  end
  v
end
""",
"""module gate_f_comptime_block_nested
  def inner() -> Int
    # gate-f: comptime_block nested-positive
    let v = comptime do
      2
    end
    v
  end
end
"""),
"return_expr": (
"""def gate_f_return_expr(x: Int) -> Int
  # gate-f: return_expr minimal-positive
  return x
end
""",
"""def gate_f_return_expr_nested(x: Int) -> Int
  if x > 0 then
    # gate-f: return_expr nested-positive
    return x
  end
  return
end
"""),
"break_expr": (
"""def gate_f_break_expr() -> Int
  var i = 0
  loop do
    i = i + 1
    # gate-f: break_expr minimal-positive
    if i >= 3 then break end
  end
  i
end
""",
"""def gate_f_break_expr_nested() -> Int
  # gate-f: break_expr nested-positive
  loop do
    break 7
  end
end
"""),
"closure_expr": (
"""def gate_f_closure_expr() -> Int
  # gate-f: closure_expr minimal-positive
  let f = |x: Int| x * 2
  f(3)
end
""",
"""def gate_f_closure_expr_nested() -> Int
  # gate-f: closure_expr nested-positive
  let f = do |x: Int, y: Int|
    x + y
  end
  f(1, 2)
end
"""),
"closure_params": (
"""def gate_f_closure_params() -> Int
  # gate-f: closure_params minimal-positive
  let f = |x: Int, y: Int| x + y
  f(1, 2)
end
""",
"""def gate_f_closure_params_nested() -> Int
  # gate-f: closure_params nested-positive
  let f = || 42
  f()
end
"""),
"closure_param": (
"""def gate_f_closure_param() -> Int
  # gate-f: closure_param minimal-positive
  let f = |x: Int| x * 2
  f(3)
end
""",
"""def gate_f_closure_param_nested() -> Int
  # gate-f: closure_param nested-positive
  let f = |x| x + 1
  f(4)
end
"""),
"pattern": (
"""def gate_f_pattern() -> Int
  # gate-f: pattern minimal-positive
  let x = 1
  x
end
""",
"""def gate_f_pattern_nested() -> Int
  # gate-f: pattern nested-positive
  let (a, b) = (1, 2)
  a + b
end
"""),
"single_pattern": (
"""def gate_f_single_pattern(n: Int) -> Int
  match n
  # gate-f: single_pattern minimal-positive
  when _ then 0
  end
end
""",
"""def gate_f_single_pattern_nested() -> Int
  # gate-f: single_pattern nested-positive
  let x = 1
  x
end
"""),
"range_pattern": (
"""def gate_f_range_pattern(n: Int) -> Int
  match n
  # gate-f: range_pattern minimal-positive
  when 1..5 then 10
  when _ then 0
  end
end
""",
"""def gate_f_range_pattern_nested(c: Char) -> Int
  match c
  # gate-f: range_pattern nested-positive
  when 'a'..='z' then 1
  when _ then 0
  end
end
"""),
"literal_pattern": (
"""def gate_f_literal_pattern(n: Int) -> Int
  match n
  # gate-f: literal_pattern minimal-positive
  when 1 then 10
  when _ then 0
  end
end
""",
"""def gate_f_literal_pattern_nested(s: String) -> Int
  match s
  # gate-f: literal_pattern nested-positive
  when "hi" then 1
  when _ then 0
  end
end
"""),
"field_pattern_list": (
"""struct gate_f_field_pattern_list
  x: Int
  y: Int
end

def gate_f_field_pattern_list_spec(p: gate_f_field_pattern_list) -> Int
  match p
  # gate-f: field_pattern_list minimal-positive
  when gate_f_field_pattern_list { x, y } then x + y
  when _ then 0
  end
end
""",
"""struct gate_f_field_pattern_list_nested
  x: Int
  y: Int
end

def gate_f_field_pattern_list_nested_spec(p: gate_f_field_pattern_list_nested) -> Int
  match p
  # gate-f: field_pattern_list nested-positive
  when gate_f_field_pattern_list_nested { x: a, y } then a + y
  when _ then 0
  end
end
"""),
"field_pattern": (
"""struct gate_f_field_pattern
  x: Int
end

def gate_f_field_pattern_spec(p: gate_f_field_pattern) -> Int
  match p
  # gate-f: field_pattern minimal-positive
  when gate_f_field_pattern { x } then x
  when _ then 0
  end
end
""",
"""struct gate_f_field_pattern_nested
  x: Int
  y: Int
end

def gate_f_field_pattern_nested_spec(p: gate_f_field_pattern_nested) -> Int
  match p
  # gate-f: field_pattern nested-positive
  when gate_f_field_pattern_nested { x: xv, y: yv } then xv + yv
  when _ then 0
  end
end
"""),
"statement": (
"""def gate_f_statement() -> Int
  # gate-f: statement minimal-positive
  let x = 1
  x
end
""",
"""def gate_f_statement_nested() -> Int
  var out = 0
  if true then
    # gate-f: statement nested-positive
    out = out + 1
  end
  out
end
"""),
"local_decl": (
"""def gate_f_local_decl() -> Int
  # gate-f: local_decl minimal-positive
  let x = 1
  x
end
""",
"""def gate_f_local_decl_nested() -> Int
  # gate-f: local_decl nested-positive
  var y = 2
  let mut z = 3
  y + z
end
"""),
"assignment": (
"""def gate_f_assignment() -> Int
  var x = 0
  # gate-f: assignment minimal-positive
  x = 5
  x
end
""",
"""def gate_f_assignment_nested() -> Int
  var x = 2
  # gate-f: assignment nested-positive
  x *= 3
  x
end
"""),
"expr_statement": (
"""def gate_f_expr_stmt_helper(x: Int) -> Int
  x
end

def gate_f_expr_statement() -> Int
  # gate-f: expr_statement minimal-positive
  gate_f_expr_stmt_helper(1)
  0
end
""",
"""def gate_f_expr_statement_nested() -> Int
  var total = 0
  if true then
    # gate-f: expr_statement nested-positive
    gate_f_expr_stmt_helper(1)
    total = 1
  end
  total
end
"""),
"attribute": (
"""# gate-f: attribute minimal-positive
@inline
def gate_f_attribute() -> Int
  0
end
""",
"""module gate_f_attribute_nested
  # gate-f: attribute nested-positive
  @inline
  def inner() -> Int
    0
  end
end
"""),
"attribute_args": (
"""# gate-f: attribute_args minimal-positive
@derive(Clone)
struct gate_f_attribute_args
  v: Int
end
""",
"""# gate-f: attribute_args nested-positive
@budget(cpu: "10")
def gate_f_attribute_args_nested() -> Int
  0
end
"""),
}


MALFORMATIONS = {
    # access_marker — the marker requires an operand; a dangling marker is
    # the production's own violation.
    "access_marker": (
        "gate_f_access_helper(&)",
        "gate_f_access_helper(&mut)",
    ),
    # arg_list — wrong arity / unterminated list.
    "arg_list": (
        "gate_f_arg_list_helper(1, 2, 3)",
        "gate_f_arg_list_helper(1, 2,",
    ),
    # assignment — missing operator / doubled operator.
    "assignment": (
        "x 5",
        "x = = 5",
    ),
    # async_block — wrong keyword / missing clause (end).
    "async_block": (
        "sync do 1 end",
        "async do 1",
    ),
    # attribute — dangling marker / doubled marker.
    "attribute": (
        "@",
        "@@inline",
    ),
    # attribute_args — unterminated parens / attribute with no name.
    "attribute_args": (
        "@derive(Clone",
        "@(Clone)",
    ),
    # bitwise_and — missing operator / missing operand.
    "bitwise_and": (
        "a b",
        "a &",
    ),
    # bitwise_or — missing operator / missing operand.
    "bitwise_or": (
        "a b",
        "a |",
    ),
    # bitwise_xor — missing operator / missing operand.
    "bitwise_xor": (
        "a b",
        "a ^",
    ),
    # block_expr — an extra closing end / a missing closing end.
    "block_expr": (
        "do 3 end end",
        "do 3",
    ),
    # break_expr — trailing junk after the optional operand / an
    # incomplete operand expression.
    "break_expr": (
        "break 1 2",
        "break 1 +",
    ),
    # budget_amount — the amount must be a STRING_LITERAL.
    "budget_amount": (
        '@budget cpu: "10',
        "@budget cpu: 10",
    ),
    # capability_decl — missing name / dangling implies.
    "capability_decl": (
        "cap",
        "cap GateFBad implies",
    ),
    # closure_expr — missing closing pipe / a nameless parameter.
    "closure_expr": (
        "|x: Int x * 2",
        "|: Int| x",
    ),
    # closure_param — colon without a type / missing colon.
    "closure_param": (
        "|x: | x",
        "|x Int| x",
    ),
    # closure_params — doubled comma / a trailing comma (not allowed in
    # closure_params, unlike arg_list).
    "closure_params": (
        "|x: Int,, y: Int| 1",
        "|x: Int, | 1",
    ),
    # comparison — missing operator / missing operand.
    "comparison": (
        "a b",
        "a <",
    ),
    # comptime_block — missing do / missing end.
    "comptime_block": (
        "comptime 1 end",
        "comptime do 1",
    ),
    # const_decl — missing colon / missing the = expr clause.
    "const_decl": (
        "const GATE_F_BAD Int = 5",
        "const GATE_F_BAD: Int",
    ),
    # convention — the legacy mut prefix (E100) / a wrong keyword.
    "convention": (
        "def gate_f_convention_bad(g: fn(mut Int) -> Int) -> Int\n  g(1)\nend",
        "def gate_f_convention_bad(g: fn(inoutt Int) -> Int) -> Int\n  g(1)\nend",
    ),
    # defer_block — missing do / an empty deferred block.
    "defer_block": (
        "defer x = x + 1 end",
        "defer do",
    ),
    # deinit_def — the receiver loses the sink convention / the body's
    # closing end is missing.
    "deinit_def": (
        "resource GateFBadDeinit\n  v: Int\n\n  def deinit(self: Self) -> Unit\n    ()\n  end\nend",
        "resource GateFBadDeinit\n  v: Int\n\n  def deinit(sink self: Self) -> Unit\n    ()",
    ),
    # edition_decl — missing the string / an unquoted edition.
    "edition_decl": (
        "edition",
        "edition 2026",
    ),
    # effect_decl — missing name / an unterminated op signature.
    "effect_decl": (
        "effect",
        "effect GateFBad\n  op( -> Int\nend",
    ),
    # effect_op_sig — the arrow with no type / a trailing token.
    "effect_op_sig": (
        "effect GateFBad\n  op1(path: String) ->\nend",
        "effect GateFBad\n  op1() -> Int Int\nend",
    ),
    # enum_def — wrong keyword / an unterminated variant payload.
    "enum_def": (
        "enumt gate_f_enum_bad",
        "enum gate_f_enum_bad\n  A\n  B(Int,",
    ),
    # equality — missing operator / missing operand.
    "equality": (
        "a b",
        "a ==",
    ),
    # expr — an incomplete expression / a doubled operator.
    "expr": (
        "let v = 1 +",
        "let v = = 2",
    ),
    # expr_statement — unterminated call / a call without parens.
    "expr_statement": (
        "gate_f_expr_stmt_helper(1",
        "gate_f_expr_stmt_helper 1",
    ),
    # extern_item — the arrow with no type / a static without its type.
    "extern_item": (
        "extern def gate_f_extern_bad(x: Int) ->",
        "extern static GATE_F_EXTERN_BAD",
    ),
    # factor — missing operator / missing operand.
    "factor": (
        "a b",
        "a *",
    ),
    # field_def — missing colon / missing type.
    "field_def": (
        "struct GateFBad\n  x Int\nend",
        "struct GateFBad\n  x: \nend",
    ),
    # field_init — the colon with no expr / a missing colon.
    "field_init": (
        "gate_f_field_init { x: }",
        "gate_f_field_init { x 1 }",
    ),
    # field_init_list — missing comma / a field with no value.
    "field_init_list": (
        "gate_f_field_init_list_bad { x: 1 y: 2 }",
        "gate_f_field_init_list_bad { x: 1, y: 2, z: }",
    ),
    # field_pattern — the colon with no pattern / a missing comma.
    "field_pattern": (
        "gate_f_field_pattern_bad { x: }",
        "gate_f_field_pattern_bad { x y }",
    ),
    # field_pattern_list — missing comma / a trailing comma (not allowed).
    "field_pattern_list": (
        "gate_f_field_pattern_list_bad { x, y x }",
        "gate_f_field_pattern_list_bad { x, y, }",
    ),
    # fn_clause — an incomplete pre expr / a missing clause expr.
    "fn_clause": (
        "def gate_f_fn_clause_bad(x: Int) -> Int pre x >\n  x\nend",
        "def gate_f_fn_clause_bad(x: Int) -> Int pre\n  x\nend",
    ),
    # fn_modifier — a wrong keyword in the modifier position.
    "fn_modifier": (
        "unsafely def gate_f_fn_modifier_bad() -> Int\n  0\nend",
        "safe def gate_f_fn_modifier_bad() -> Int\n  0\nend",
    ),
    # fn_type — missing comma / the arrow with no return type.
    "fn_type": (
        "def gate_f_fn_type_bad(g: fn(Int Int) -> Int) -> Int\n  g(1)\nend",
        "def gate_f_fn_type_bad(g: fn(Int) ->) -> Int\n  g(1)\nend",
    ),
    # fn_type_param — a wrong convention keyword / a missing comma.
    "fn_type_param": (
        "def gate_f_fn_type_param_bad(g: fn(inoutt Int) -> Int) -> Int\n  g(1)\nend",
        "def gate_f_fn_type_param_bad(g: fn(Int Int) -> Int) -> Int\n  g(1)\nend",
    ),
    # for_expr — missing pattern / missing in.
    "for_expr": (
        "for in 0..3 do 1 end",
        "for i 0..3 do 1 end",
    ),
    # function_def — missing arrow / missing the body's closing end.
    "function_def": (
        "def gate_f_function_def_bad(x: Int) Int\n  x\nend",
        "def gate_f_function_def_bad(x: Int) -> Int\n  x",
    ),
    # function_sig — missing arrow / the arrow with no type.
    "function_sig": (
        "trait GateFBad\n  def f(self: GateFBad) Int\nend",
        "trait GateFBad\n  def f(self: GateFBad) ->\nend",
    ),
    # guard_stmt — missing else / a dangling else.
    "guard_stmt": (
        "guard x > 0 return 0",
        "guard x > 0 else",
    ),
    # handle_with_expr (parse-mode) — with without an op name / with
    # without its do block.
    "handle_with_expr": (
        "def gate_f_handle_bad() -> Int\n  handle 1 with do\n    x\n  end\n  0\nend",
        "def gate_f_handle_bad() -> Int\n  handle 1 with op x\n  0\nend",
    ),
    # if_expr — missing condition / an extra closing end (the short form
    # makes a missing end legal, so the violation is the doubled end).
    "if_expr": (
        "if then 1 else 2 end",
        "if c then 1 else 2 end end",
    ),
    # if_let — missing the = / a missing end (no short form for if_let).
    "if_let": (
        "if let Option::Some(v) o then 1 else 0 end",
        "if let Option::Some(v) = o then 1 else 0",
    ),
    # impl_block — missing type / a dangling for.
    "impl_block": (
        "impl",
        "impl gate_f_impl_bad for",
    ),
    # impl_item — missing arrow / a nameless type item.
    "impl_item": (
        "impl GateFBad\n  def get(self: GateFBad) Int\n    self.v\n  end\nend",
        "impl GateFBad\n  type = Int\nend",
    ),
    # item — malformed params / a malformed field.
    "item": (
        "def gate_f_item_bad( -> Int\n  0\nend",
        "struct gate_f_item_bad\n  v Int\nend",
    ),
    # literal_pattern — an unterminated string literal / two literals.
    "literal_pattern": (
        'when "unterminated then 0',
        "when 1 1 then 0",
    ),
    # local_decl — missing = / a dangling =.
    "local_decl": (
        "let x 1",
        "var y =",
    ),
    # logical_and — missing operator / missing operand.
    "logical_and": (
        "a b",
        "a &&",
    ),
    # logical_or — missing operator / missing operand.
    "logical_or": (
        "a b",
        "a ||",
    ),
    # loop_expr — missing do / a missing closing end.
    "loop_expr": (
        "loop i = i + 1 end",
        "def gate_f_loop_bad() -> Int\n  var i = 0\n  loop do\n    i = i + 1\n    if i >= 3 then break end\n  end",
    ),
    # macro_decl — missing colon / a missing closing end.
    "macro_decl": (
        "macro gate_f_bad(x Expr)\n  (x)\nend",
        "macro gate_f_bad(x: Expr)\n  (x)",
    ),
    # macro_param — a non-vocabulary macro type / a missing macro type.
    "macro_param": (
        "macro gate_f_bad(x: Exprt)\n  (x)\nend",
        "macro gate_f_bad(x:)\n  (x)\nend",
    ),
    # macro_type — outside the vocabulary / wrong case.
    "macro_type": (
        "macro gate_f_bad(x: Stmt)\n  (x)\nend",
        "macro gate_f_bad(x: expr)\n  (x)\nend",
    ),
    # match_arm — missing pattern / a dangling =>.
    "match_arm": (
        "when then 1",
        "0 =>",
    ),
    # match_expr — missing scrutinee / a missing closing end.
    "match_expr": (
        "match",
        "match n\n  when 0 then 1",
    ),
    # name_list — missing comma / a trailing comma (not allowed).
    "name_list": (
        "use std::collections::{Vec Map}",
        "use std::collections::{Vec,}",
    ),
    # named_arg — missing colon / a missing label.
    "named_arg": (
        "gate_f_named_arg_helper(x: 1, y 2)",
        "gate_f_named_arg_helper(x: 1, : 2)",
    ),
    # param — missing colon / a convention with no name.
    "param": (
        "def gate_f_param_bad(inout x Int) -> Int\n  x\nend",
        "def gate_f_param_bad(inout) -> Int\n  x\nend",
    ),
    # param_list — missing comma / a doubled comma.
    "param_list": (
        "def gate_f_param_list_bad(a: Int b: Int) -> Int\n  a + b\nend",
        "def gate_f_param_list_bad(a: Int, , b: Int) -> Int\n  a + b\nend",
    ),
    # path — a dangling ::.
    "path": (
        "use std::core::Option::",
        "use std::core::",
    ),
    # path_segment — a numeric segment / a keyword segment.
    "path_segment": (
        "use std::core::123",
        "use std::core::Option::mut",
    ),
    # pattern — a dangling or-pipe / an or-pipe with no operands.
    "pattern": (
        "let x | = 1",
        "let | = 1",
    ),
    # postfix — an unterminated call / a dangling dot.
    "postfix": (
        "s.len(",
        "s.",
    ),
    # postfix_op — a leading comma in the call / a doubled dot.
    "postfix_op": (
        "s.len(,)",
        "s..len()",
    ),
    # primary — two adjacent primaries / an incomplete expression.
    "primary": (
        "let v = 42 43",
        "let v = 42 +",
    ),
    # program — malformed params / an extra closing end.
    "program": (
        "def gate_f_program_bad( -> Int\n  0\nend",
        "def gate_f_program_bad() -> Int\n  0\nend end",
    ),
    # range — missing the .. / a dangling ...
    "range": (
        "for i in 0 3 do 1 end",
        "for i in 0.. do 1 end",
    ),
    # range_pattern — a dangling .. / a trailing literal.
    "range_pattern": (
        "when 1.. then 10",
        "when 1..5 6 then 10",
    ),
    # rationale_block — a missing closing end / a value-less field.
    "rationale_block": (
        "rationale\n  why: \"gate f\"",
        "rationale\n  why:",
    ),
    # rationale_field — a nameless field / a missing colon.
    "rationale_field": (
        'rationale\n  "gate f"\nend',
        'rationale\n  why "gate f"\nend',
    ),
    # raw_deref — a dangling star / trailing junk after the deref.
    "raw_deref": (
        "let v = *",
        "let v = *p p",
    ),
    # resource_def — missing colon / a missing closing end.
    "resource_def": (
        "resource gate_f_bad\n  v Int\nend",
        "resource gate_f_bad\n  v: Int",
    ),
    # return_expr — trailing junk / a dangling =.
    "return_expr": (
        "def gate_f_return_bad() -> Int\n  return x y\nend",
        "def gate_f_return_bad() -> Int\n  return = x\nend",
    ),
    # shift — missing operator / missing operand.
    "shift": (
        "a b",
        "a <<",
    ),
    # single_pattern — two adjacent patterns / an empty tuple pattern.
    "single_pattern": (
        "when _ _ then 0",
        "when (,) then 0",
    ),
    # statement — a missing pattern / a missing =.
    "statement": (
        "def gate_f_statement_bad() -> Int\n  let = 1\n  1\nend",
        "def gate_f_statement_bad() -> Int\n  let x 1\n  1\nend",
    ),
    # static_decl — missing colon / missing the = expr clause.
    "static_decl": (
        "static GATE_F_BAD Int = 5",
        "static GATE_F_BAD: Int",
    ),
    # struct_def — a missing closing end / a body-less struct.
    "struct_def": (
        "struct gate_f_bad\n  v: Int",
        "struct gate_f_bad",
    ),
    # struct_literal — an unterminated list / a missing comma.
    "struct_literal": (
        "gate_f_struct_literal { x: 1, y: 2",
        "gate_f_struct_literal { x: 1 y: 2 }",
    ),
    # supertrait_list — a dangling + / a leading +.
    "supertrait_list": (
        "trait GateFBad: gate_f_supertrait_base +",
        "trait GateFBad: + gate_f_supertrait_base",
    ),
    # term — missing operator / missing operand.
    "term": (
        "a b",
        "a +",
    ),
    # trailing_block — an unterminated block / an empty closure body.
    "trailing_block": (
        "items.map { |x| x * 2",
        "items.map { |x| }",
    ),
    # trait_def — missing arrow / a missing closing end.
    "trait_def": (
        "trait GateFBad\n  def f(self: GateFBad) Int\nend",
        "trait GateFBad\n  def f(self: GateFBad) -> Int",
    ),
    # trait_item — missing arrow / a nameless type item.
    "trait_item": (
        "trait GateFBad\n  def f(self: GateFBad) Int\nend",
        "trait GateFBad\n  type : Copy\nend",
    ),
    # try_expr (parse-mode) — a catch without a pattern / a missing
    # closing end.
    "try_expr": (
        "def gate_f_try_bad() -> Int\n  try do\n    1\n  catch do\n    2\n  end\nend",
        "def gate_f_try_bad() -> Int\n  try do\n    1\n  catch _ do\n    2\n  end",
    ),
    # type_alias — missing = / a dangling =.
    "type_alias": (
        "type GateFBad Int",
        "type GateFBad =",
    ),
    # type_args — an unterminated list / an empty list.
    "type_args": (
        "def gate_f_type_args_bad(x: Vec[Int) -> Int\n  x.len()\nend",
        "def gate_f_type_args_bad(x: Vec[]) -> Int\n  x.len()\nend",
    ),
    # type_bound — a dangling + / a leading +.
    "type_bound": (
        "def gate_f_type_bound_bad[T: Copy +](x: T) -> T\n  x\nend",
        "def gate_f_type_bound_bad[T: + Eq](x: T) -> T\n  x\nend",
    ),
    # type_expr — the arrow with no type / a typeless parameter.
    "type_expr": (
        "def gate_f_type_bad(x: Int) ->\n  x\nend",
        "def gate_f_type_bad(x:) -> Int\n  x\nend",
    ),
    # type_param — a missing bound / a missing colon.
    "type_param": (
        "def gate_f_type_param_bad[T: ](x: T) -> T\n  x\nend",
        "def gate_f_type_param_bad[T Copy](x: T) -> T\n  x\nend",
    ),
    # type_params — a doubled comma / a missing comma.
    "type_params": (
        "def gate_f_type_params_bad[T,, U](x: T, y: U) -> T\n  x\nend",
        "def gate_f_type_params_bad[U: Copy T](x: U) -> U\n  x\nend",
    ),
    # type_primary — a numeric type / an empty type-args list.
    "type_primary": (
        "def gate_f_type_primary_bad(x: 123) -> Int\n  0\nend",
        "def gate_f_type_primary_bad(x: Vec[]) -> Int\n  0\nend",
    ),
    # unary — a dangling operator / two adjacent operands.
    "unary": (
        "-",
        "- a b",
    ),
    # unless_expr — missing condition / an extra closing end.
    "unless_expr": (
        "unless then 1 else 2 end",
        "unless c then 1 else 2 end end",
    ),
    # unsafe_block — missing do / a missing closing end.
    "unsafe_block": (
        "unsafe 1 end",
        "unsafe do 1",
    ),
    # until_expr — missing condition / a missing closing end.
    "until_expr": (
        "until do i = i + 1 end",
        "until i >= 3 do i = i + 1",
    ),
    # use_decl — a dangling as / an invalid alias.
    "use_decl": (
        "use std::core::Option as",
        "use std::core::Option as 123",
    ),
    # variant_def — a nameless variant / a missing comma in the payload.
    "variant_def": (
        "enum GateFBad\n  (Int)\nend",
        "enum GateFBad\n  A(Int)\n  B(Int Int)\nend",
    ),
    # variant_field — two types / a missing type.
    "variant_field": (
        "enum GateFBad\n  C(v: Int Int)\nend",
        "enum GateFBad\n  C(v: )\nend",
    ),
    # vis — the wrong keyword / a doubled visibility.
    "vis": (
        "public def gate_f_vis_bad() -> Int\n  0\nend",
        "pubpub def gate_f_vis_bad() -> Int\n  0\nend",
    ),
    # where_clause — missing colon / a missing type.
    "where_clause": (
        "def gate_f_where_clause_bad[T](x: T) -> T where T Copy\n  x\nend",
        "def gate_f_where_clause_bad[T](x: T) -> T where : Copy\n  x\nend",
    ),
    # where_pred — missing comma / a missing type.
    "where_pred": (
        "def gate_f_where_pred_bad[T, U](a: T, b: U) -> T where T: Copy U: Copy\n  a\nend",
        "def gate_f_where_pred_bad[T](x: T) -> T where T: Copy, : Eq\n  x\nend",
    ),
    # while_expr — missing condition / a missing closing end.
    "while_expr": (
        "while do i = i + 1 end",
        "while i < 3 do i = i + 1",
    ),
}


def malformed_block(prod: str, minimal: str, kind: str) -> str:
    """The production-specific malformation block: the marker line plus
    the catalog snippet, then the embedded minimal positive."""
    if prod not in MALFORMATIONS:
        raise SystemExit(
            "gen_grammar_f: production %r has no malformation catalog entry — "
            "the generic stray-paren negative is forbidden (the reviewer's "
            "item 10); every production needs its own grammar violation" % prod)
    before_snippet, after_snippet = MALFORMATIONS[prod]
    snippet = before_snippet if kind == "before" else after_snippet
    marker = "# gate-f: %s minimal-positive" % prod
    lines = minimal.split("\n")
    idx = next((i for i, l in enumerate(lines) if l.lstrip().startswith(marker)), None)
    if idx is None:
        raise SystemExit("gen_grammar_f: minimal template for %r has no marker line" % prod)
    if kind == "before":
        return "# gate-f: %s malformed\n%s\n\n%s" % (prod, snippet, minimal)
    return "%s\n\n# gate-f: %s malformed\n%s" % (minimal, prod, snippet)


def gen(out_dir: str) -> None:
    with open(FACTS, "rb") as fh:
        facts = tomllib.load(fh)
    productions = facts.get("production", {})
    if not productions:
        raise SystemExit("gen_grammar_f: no productions in %s" % FACTS)

    pos_dir = os.path.join(out_dir, "pos")
    neg_dir = os.path.join(out_dir, "neg")
    os.makedirs(pos_dir, exist_ok=True)
    os.makedirs(neg_dir, exist_ok=True)

    for prod, meta in sorted(productions.items()):
        if prod not in TEMPLATES:
            raise SystemExit(
                "gen_grammar_f: production %r has no specimen templates — "
                "an uncovered production cannot be shipped" % prod)
        minimal, nested = TEMPLATES[prod]
        verify = meta.get("verify", "check")

        def write(path, text):
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(text)
            if not text.endswith("\n"):
                with open(path, "a", encoding="utf-8") as fh:
                    fh.write("\n")

        header = (
            "# tests/grammar_f/%(where)s/%(prod)s_%(kind)s.tg — Gate F specimen\n"
            "# (generated by scripts/gen_grammar_f_specimens.py — do not edit;\n"
            "#  the gate regenerates and diffs)\n"
            "# production: %(prod)s  verify: %(verify)s\n" % {
                "where": "pos", "prod": prod, "kind": "minimal", "verify": verify})
        write(os.path.join(pos_dir, prod + "_minimal.tg"), header + minimal)

        header = header.replace("_minimal.tg", "_nested.tg").replace("minimal", "nested", 1)
        write(os.path.join(pos_dir, prod + "_nested.tg"), header + nested)

        before = (
            "# tests/grammar_f/neg/%(prod)s_before.tg — Gate F invalid-before specimen\n"
            "# (generated by scripts/gen_grammar_f_specimens.py — do not edit)\n"
            "# production: %(prod)s  verify: %(verify)s\n"
            "# gate-f: %(prod)s invalid-before\n"
            "# The PRODUCTION-SPECIFIC malformation (the production's own grammar\n"
            "# violation from the per-production catalog — the wrong arity / the\n"
            "# wrong keyword / the missing clause) is placed BEFORE the construct;\n"
            "# the parser must still reject the program.\n" % {
                "prod": prod, "verify": verify})
        write(os.path.join(neg_dir, prod + "_before.tg"), before + malformed_block(prod, minimal, "before"))

        after = (
            "# tests/grammar_f/neg/%(prod)s_after.tg — Gate F invalid-after specimen\n"
            "# (generated by scripts/gen_grammar_f_specimens.py — do not edit)\n"
            "# production: %(prod)s  verify: %(verify)s\n"
            "# gate-f: %(prod)s invalid-after\n"
            "# The PRODUCTION-SPECIFIC malformation (the production's own grammar\n"
            "# violation from the per-production catalog — the wrong arity / the\n"
            "# wrong keyword / the missing clause) is placed AFTER the construct;\n"
            "# the parser must still reject the program.\n" % {
                "prod": prod, "verify": verify})
        write(os.path.join(neg_dir, prod + "_after.tg"), after + malformed_block(prod, minimal, "after"))

    print("gen_grammar_f: %d production(s) x 4 specimens -> %s" % (len(productions), out_dir))


def main() -> None:
    out_dir = os.path.join(ROOT, "tests", "grammar_f")
    if len(sys.argv) >= 3 and sys.argv[1] == "--out":
        out_dir = sys.argv[2]
    gen(out_dir)


if __name__ == "__main__":
    main()
