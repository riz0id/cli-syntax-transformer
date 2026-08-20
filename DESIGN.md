# cli-spec-transform: checked mappings between cli-spec specifications

Design document, 2026-08-19. Status: implemented.

Companion to [`cli-spec`](https://github.com/riz0id/cli-syntax)'s DESIGN.md;
section references of the form §N there are cited as *spec-§N* here.

## 1. Motivation

`cli-spec` turns a CLI's grammar into a value. This package describes
*mappings between two such values*: a version migration (`--jobs` becomes
`--parallelism`, `--legacy-io` is gone), a port between tools (`git → jj`),
a deprecation shim that accepts the old surface and re-execs the new one.

Ad-hoc versions of these share one failure mode: **silent partiality**. A
migration script handles the flags its author remembered; the flag added
last quarter falls through and the shim mangles it at 2am. Here a
transformer is only accepted if it says what happens to **every** flag,
positional, rest clause, and subcommand of the source spec — mapped, merged,
kept, or *explicitly* dropped with a reason. The check runs at expansion
time, so a forgotten field is a compile-time syntax error, not a runtime
surprise.

Both ends of the mapping are complete `cli-spec` specifications, **given as
inputs**. The transformer declares nothing about either CLI — no types, no
aliases, no arities, no docs; all of that lives in the two specs. A
transformer is solely the correspondence: which source item pairs with which
target item. "Pattern-based" means exactly this: each clause *selects* one
item of the source specification — this flag, that positional, that
subcommand — and names its counterpart in the target. Selection is by name,
within a clause structure that mirrors the source spec's subcommand tree.
There are no wildcards: one source item, one clause, written by someone who
looked at it.

**Non-goals**

- Declaring interface surface. Anything that *describes* a CLI belongs in a
  `cli-spec` specification; a clause that restates a type or an alias would
  be redundant with the target spec and is a syntax error.
- Inferring mappings from name similarity; every correspondence is written.
- Verifying that the target tool *means* the same thing; the mapping is the
  author's recorded claim.

## 2. What a transformer is

The whole package is **two macros and two operations**. There is no
intermediate representation and no runtime rule engine: all selection and
checking happens while the macros expand, and what remains at runtime is
plain data.

```racket
(define-transformer git->jj
  #:source git-spec       ; a cli-spec command value
  #:target jj-spec        ; another one, declared once, elsewhere
  clause ...)
```

`define-transformer` binds `git->jj` to an opaque `transformer` value
holding the two specs plus the **resolved mapping**: for each source item,
its counterpart item in the target spec (the actual struct, resolved during
expansion) and an optional value-translation procedure. A transformer may
also carry a **guard** (`#:when`, §3.6) restricting it to a subset of source
invocations, and guarded transformers combine into a **transformer set**
(`define-transformer-set`, §3.7) that dispatches an invocation to its first
matching member — that is the second macro.

The two operations:

```racket
(transformer-target t)      ; → command      the target spec, as given
(transform-argv t argv)     ; → xform-result rewrite a source invocation
```

`transform-argv` parses `argv` with the source spec (reusing `parse-argv`;
no argv lexing is reimplemented), translates the values through the mapping,
and renders an invocation of the target spec. It returns the rewritten argv
plus the target spec it is an invocation of (relevant for sets, where the
target varies by member) and a warning per dropped item the invocation
actually used, or the underlying `parse-error` unchanged if the source spec
rejects the input, or an `xform-dropped` when the invocation reaches a
dropped subtree, or an `xform-unmatched` when a guarded transformer is
applied directly to an invocation its guard rejects.

### 2.1 Why the check can be static

Coverage and resolution are checked at expansion time, which requires both
specs to be compile-time values. `cli-spec` ASTs are prefab struct trees
built by pure constructors (spec-§2.2), so a module providing a spec at
runtime provides the *same value* at expansion time simply by being required
at phase 1 as well. The package supplies sugar for that:

```racket
(require cli-spec-transform)
(require (for-transform "git-spec.rkt" "jj-spec.rkt"))
; ≡ (require "git-spec.rkt" "jj-spec.rkt"
;            (for-syntax "git-spec.rkt" "jj-spec.rkt"))
```

(Two `require` forms: a require transformer cannot be used in the same form
that imports it.) Nothing else crosses phases: clause right-hand sides are
name references — pure syntax, never evaluated — and the `#:value`/`#:by`
procedures are compiled only into the runtime value.

Specs constructed dynamically at runtime cannot be checked this way by
definition; supporting them is out of scope (§7.5).

## 3. The mapping language

A transformer body **mirrors the source spec**: one clause per flag,
positional, and rest clause, and one `subcommand` block per subcommand,
nested the way the source nests. Reading a transformer next to its source
spec is a line-by-line correspondence; the checker's job is to keep it one —
on both ends.

### 3.1 Clauses

Each clause selects a source item by class and name (bare, unquoted — syntax
the macro resolves against the source spec) and gives a right-hand side:

```racket
(flag git-dir  => (flag 'repository))   ; ↦ the target's repository flag
(flag paginate => (drop "jj always pages; configure ui.pager instead"))
(arg  pathspec => keep)
(rest paths    => keep)
```

The right-hand side is one of:

- **a reference** — `(flag 'NAME)`, `(arg 'NAME)`, or `(rest 'NAME)`, naming
  an item of the mapped target node. References are class-preserving (a
  source flag maps to a target flag) and contain the name and *nothing
  else*; the target item's type, aliases, arity, defaults, and docs all come
  from the target spec. If the source and target items' declared shapes are
  not equal, the clause must also say how parsed values cross, and may
  always do so:

  ```racket
  (flag porcelain => (flag 'template)
        #:value (λ (v) (if (equal? v "v2") "json_status" "text_status")))
  ```

  With equal shapes `#:value` defaults to identity. (Shapes compare
  structurally; two `custom` types compare by name, since parse procedures
  cannot be compared.)

- **`keep`** — sugar for a reference to the *same name*: the target node has
  an item so named, and the target's declaration is authoritative. If the
  namesake's shape differs, the clause must be written as an explicit
  reference with `#:value`.

- **`(drop REASON)`** — the item has no counterpart. The reason string is
  mandatory; it is what `transform-argv` reports when a real invocation
  uses the dropped item.

### 3.2 Subcommand blocks

A `subcommand` block pairs tree nodes: it names the target child the source
child maps to (omitting the `=>` means same name) and scopes the clauses for
the node's contents:

```racket
(subcommand status => st
  (flag short ...) (flag long ...) (flag porcelain ...) (arg pathspec ...))

(subcommand log            ; the target also has a `log`
  (flag n ...) ...)

(subcommand checkout => (drop "use `jj new`; no pathspec-checkout analogue"))
```

A subcommand dropped this way needs no inner clauses and no target
counterpart — the drop covers the entire source subtree, and the reason is
reported for any invocation that reaches it. This is the only clause that
covers more than one item, kept because "this subtree has no counterpart" is
a genuinely singular decision.

### 3.3 Merging

The one many-to-one form, for the `--quiet`/`--verbose` → `--log-level`
family of migrations:

```racket
(merge (short long) => (flag 'format)
       #:by (λ (short? long?) (cond [short? "short"] [long? "long"] [else #f])))
```

The left-hand names must be flags of the enclosing source node; the merge
clause covers all of them. `#:by` receives their parsed values in the listed
order and produces the target value (`#f` for "absent"). Because a merge
always crosses values through `#:by`, no shape comparison applies.

The dual (one source item to several target items) is deliberately absent
for now (§7.1).

### 3.4 Constraint groups

Groups (spec-§3.5) need no clauses on either side. Source groups constrain
*inputs*, and every input has already satisfied them by the time it parses;
target groups belong to the target spec. The checker's only group
obligation is on the target side: a `one-of` group in the target must have
at least one member produced by the mapping (§4, check 6), since otherwise
no rewritten invocation could ever satisfy it.

### 3.5 Grammar

```
xform   ::= (define-transformer NAME #:source ID #:target ID
              [#:when guard] clause ...)
xset    ::= (define-transformer-set NAME ID ID ...)
clause  ::= (flag NAME => rhs) | (arg NAME => rhs) | (rest NAME => rhs)
          | (merge (NAME NAME ...) => ref #:by EXPR)
          | (emit (flag 'NAME) [#:value STRING])
          | (subcommand NAME [=> NAME] clause ...)
          | (subcommand NAME => (drop STRING))
rhs     ::= ref [#:value EXPR] | keep | (drop STRING)
ref     ::= (flag 'NAME) | (arg 'NAME) | (rest 'NAME)
guard   ::= (flag NAME) | (flag NAME = STRING) | (arg NAME)
          | (not guard) | (and guard ...) | (or guard ...)
          | (subcommand NAME guard ...)
```

Quoted names in references are canonical; bare names are also accepted.

### 3.6 Guards

A transformer may claim only a *slice* of the source surface. The motivating
shape is `sed`: `sed -n` invocations rewrite one way (suppressed auto-print
has a direct analogue in the target), everything else another way, possibly
to a different target spec entirely. `#:when` attaches that condition:

```racket
(define-transformer sed-n->awk
  #:source sed-spec
  #:target awk-spec
  #:when (flag n)          ; only invocations that supplied -n
  clause ...)
```

A guard is a boolean pattern over the *parsed* invocation, so it shares the
source spec's vocabulary and none of argv's: `(flag n)` holds when the
invocation supplied the flag with a non-default value; `(flag NAME = "LIT")`
additionally requires the parsed value to equal `"LIT"` parsed under the
flag's declared type (for `#:repeat 'list` flags, membership); `(arg NAME)`
holds when the positional was supplied (non-empty, if variadic);
`(subcommand NAME guard ...)` holds when the invocation descends into that
subcommand and the inner guards (an implicit `and`, possibly empty) hold at
that node; `not`/`and`/`or` combine as expected.

Guard names resolve against the source spec at expansion time with the same
diagnostics as clauses (§4); a `=` test on a typeless switch is a syntax
error, as is a literal its flag's type rejects.

**Absorption.** An item the guard names is covered by the guard: it needs no
clause, and if it has none it is consumed silently — no tokens emitted, no
warning. (`sed -n`'s `-n` said everything it had to say by selecting this
transformer.) A clause on a guard-named item wins over absorption and
behaves exactly as usual. Items the guard does *not* name keep their full
coverage obligation: any flag can co-occur with `-n`, so the clause tree
still mirrors the whole source spec.

`transform-argv` on a guarded transformer applied directly returns
`(xform-unmatched)` when the guard rejects the parsed invocation.

### 3.7 Transformer sets

Guarded transformers combine into an ordered dispatcher:

```racket
(define-transformer-set sed->awk
  sed-n->awk        ; guarded members, tried in order
  sed-default->awk) ; the final member must be unguarded
```

`transform-argv` on a set parses argv once with the shared source spec and
rewrites through the first member whose guard matches. Exhaustiveness is
syntactic, not semantic: the final member must be unguarded, every earlier
member must be guarded (an earlier unguarded member would make the rest
unreachable), and all members must share the same `#:source` spec — each of
these is an expansion-time error on the offending member. Members may name
different `#:target` specs; the `xform-ok` result carries the chosen one.
Guards are not checked for disjointness: order is meaningful, first match
wins.

### 3.8 Target-only emission

The dual of `drop`: the *target* needs a flag the source has no item for.
The motivating shape is defaults that disagree — `sed -n '/re/p'` prints
bare matched lines while `rg` prefixes `file:` when given several paths, so
the faithful rewrite must always say `--no-filename` even though no source
word selects it. `emit` is a clause with no left-hand side:

```racket
(emit (flag 'no-filename))            ; a switch, emitted on every rewrite
(emit (flag 'color) #:value "never")  ; a valued flag with a constant value
```

An `emit` belongs to a node and fires whenever a rewrite passes through
that node, after the node's source-driven flags. It claims its target flag
like any other clause (two clauses mapping the same target item stay an
error, §4 check 4) and counts toward target totality (§4 check 6) — an
`emit` can be what produces a required target flag. `#:value` is a string
literal, parsed under the target flag's declared type at expansion time;
it is required exactly when the flag takes a value (a bare arity-`'?`
occurrence may omit it) and forbidden on a switch. Source coverage is
untouched: `emit` consumes nothing.

Only flags can be emitted. A target-only *positional* constant is
deliberately absent: positionals carry the invocation's operands, and a
transformer inventing operand words would no longer be rewriting the
user's command.

## 4. Static checking

Expansion performs one simultaneous walk over three trees — the source spec,
the clause tree, and the target spec. Every failure is a syntax error on the
responsible form.

Source side:

1. **Coverage.** Every flag, positional, and rest clause of every reachable
   source node — *including* `#:hidden` and `#:deprecated` flags, which are
   exactly the ones migration scripts forget — and every subcommand node
   must have exactly one clause. Items the transformer's guard names are
   the one exception: the guard covers them (§3.6). Missing ones are listed
   by path:

   ```
   git->jj: transformer does not cover its source spec
     uncovered:
       git → status → flag porcelain
       git → log → rest paths
     2 of 16 items uncovered
   ```

2. **Unknown and duplicate source selections.** A clause naming an item the
   node doesn't have errors with a suggestion (the same Levenshtein courtesy
   as `parse-argv`, spec-§4.1) — this is how upstream *removals* surface.
   Two clauses claiming the same source item error citing both.

Target side:

3. **Reference resolution.** Every reference must name an existing item of
   the mapped target node, and every subcommand block must name an existing
   target child — with suggestions, so drift in the *target* spec breaks
   the transformer just as loudly.

4. **At most one clause per target item.** Two clauses mapping into the
   same target flag or positional is an error — the target value would be
   ambiguous.

5. **Value crossing.** `#:value` is required exactly when the two declared
   shapes are not structurally equal (kind, repeat, arity, type), and a
   `keep` whose target namesake has a different shape errors with
   instructions to map it explicitly. A variadic source positional cannot
   map to a single-value target positional at all. Only presence is
   checkable — the procedures themselves are opaque and never run during
   expansion.

6. **Target totality.** For each mapped node pair: required target flags,
   target positionals with minimum arity ≥ 1, and target `one-of` groups
   must be the image of some clause (an `emit`, §3.8, counts) — otherwise
   every rewritten invocation would be rejected by the target spec for a
   missing argument. Likewise, a leaf source node may not map to a target
   node that demands a subcommand.

Guards and sets (§3.6–3.7):

7. **Guard resolution.** Every flag, positional, and subcommand a guard
   tests must exist at its node of the source spec (with suggestions, as in
   check 2); a `=` test needs a valued flag, and its literal must parse
   under that flag's declared type.

8. **Set shape.** Every member of a `define-transformer-set` must be
   `define-transformer`-bound; all members must share the same `#:source`
   spec; every member but the last must be guarded; the last must not be.

The net effect is that drift in *either* spec lands somewhere loud: an item
added to the source fails coverage (1); one removed from the source orphans
its clause (2); one removed or renamed in the target breaks the reference
(3); a retype on either side trips the `#:value` requirement (5); a new
required target field fails totality (6); a removed or retyped item a guard
tests breaks the guard (7). What cannot be checked statically
— that value functions behave, and that `#:by` produces a value whenever the
target requires one — is covered dynamically by the standard property test:
`gen-invocation` (spec-§4.5) samples valid source argvs and asserts the
target spec parses `transform-argv`'s output.

## 5. Worked example

Source: the `git-spec` slice from spec-§5. Target: `jj-spec`, a slice of
`jj` (jujutsu) declared once, in its own module, as an ordinary `cli-spec`
specification (the test suite's `tests/jj-spec.rkt` is such a module). Its
root carries a `repository` flag; its `st` subcommand carries `format`,
`template`, and `pathspec`; its `log` subcommand carries `limit`, `author`,
`revset`, and a `paths` rest clause. Neither spec's declaration appears in
this document — declaring interfaces is `cli-spec`'s job, and the
transformer sees both specs only as inputs.

The transformer is the entire correspondence:

```racket
(require cli-spec-transform)
(require (for-transform "git-spec.rkt" "jj-spec.rkt"))

(define-transformer git->jj
  #:source git-spec
  #:target jj-spec

  (flag git-dir  => (flag 'repository))
  (flag paginate => (drop "jj always pages; configure ui.pager instead"))

  (subcommand status => st
    (merge (short long) => (flag 'format)
           #:by (λ (s? l?) (cond [s? "short"] [l? "long"] [else #f])))
    (flag porcelain => (flag 'template)
          #:value (λ (v) (if (equal? v "v2") "json_status" "text_status")))
    (arg pathspec => keep))

  (subcommand log
    (flag n        => (flag 'limit))
    (flag oneline  => (drop "use -T builtin_log_oneline instead"))
    (flag author   => keep)
    (arg  revision => (arg 'revset))
    (rest paths    => keep))

  (subcommand checkout => (drop "use `jj new`/`jj edit`; no checkout analogue")))
```

Delete the `porcelain` clause and expansion fails with the coverage error of
§4. Rename `limit` in `jj-spec` and the `(flag 'limit)` reference fails with
"the target has no flag limit here (nearest: …)". Retype `template` and the
`porcelain` clause is fine (it has `#:value`) — but retype `author` and its
`keep` demands an explicit mapping. Add a required flag to a mapped `jj`
node and totality fails. All before any argv exists.

Using it:

```racket
(transform-argv git->jj
  '("--git-dir" "/tmp/r" "log" "-n" "5" "--author" "linus" "--oneline"))
; ⇒ (xform-ok jj-spec   ; the target the rewritten argv is an invocation of
;             '("--repository" "/tmp/r" "log" "--limit" "5" "--author" "linus")
;             (list (dropped 'oneline "use -T builtin_log_oneline instead")))

(spec->help (transformer-target git->jj) '(jj log))
; help for the target surface — jj-spec itself
```

## 6. Implementation sketch

Collection layout:

```
cli-spec-transform/
  main.rkt       ; public API: define-transformer, define-transformer-set,
                 ;   for-transform, transformer-target, transform-argv
  walk.rkt       ; the three-tree walk: coverage, selection, reference
                 ;   resolution, totality — plus guard resolution and the
                 ;   set invariants (pure; used at phase 1 and 0)
  rewrite.rkt    ; transform-argv: parse with source, evaluate guards,
                 ;   dispatch, translate, render
```

Notes:

- **The macro is the product.** `define-transformer` (built with
  `syntax/parse`) parses the clause tree into a skeleton whose references
  are name symbols, calls `walk.rkt`'s `resolve-transformer` against the
  phase-1 specs — re-raising findings as syntax errors on the offending
  clause's syntax object — and emits code that rebuilds the same skeleton at
  module initialization (with the `#:value`/`#:by` procedures compiled in)
  and resolves it again via `make-transformer`. Resolution replaces every
  reference and `keep` with the actual target item struct, so the runtime
  rewriter never searches the target spec for items. Guards follow the same
  two-phase pattern: a `p:*` skeleton whose `=` literals are raw strings,
  resolved (names checked, literals parsed, the source param attached) at
  both phases; guard-named items resolve to an `x:absorb` action when
  unclaused.
- **Sets are checked at expansion too.** `define-transformer` binds its name
  through a compile-time record (a `prop:rename-transformer` struct
  forwarding expression uses to a hidden runtime definition) carrying the
  source-spec binding and whether the transformer is guarded;
  `define-transformer-set` reads members' records via
  `syntax-local-value/immediate` to enforce the §4 check 8 invariants
  statically, and the emitted `make-transformer-set` re-checks them at
  module initialization.
- **Rendering is the one new runtime piece.** `transform-argv` needs to
  print translated values as an argv of the target spec — a straightforward
  inverse of `parse-argv` for a checked spec. Flags are emitted per node
  before the next subcommand word (so `'before-subcommand` globals land
  where they must); positionals are emitted in the *target* node's declared
  order, since the two specs may order them differently.
- **Dependencies.** `deps = (base cli-spec)`.

## 7. Open questions

1. **Splits.** The dual of `merge` (one source flag to several target
   items) has real instances (`--credentials user:pass` → `--user`/
   `--password`) but complicates rendering and the `#:value` story;
   deferred until a concrete migration needs it.
2. **Composition.** `t₁ : A → B` and `t₂ : B → C` compose in principle;
   whether fused clauses (a map into a flag that `t₂` drops becomes a drop)
   can be checked as cleanly as written ones decides if this is worth
   having.
3. **Migration docs.** The clause tree contains everything a human
   "upgrading from 1.x" section needs (renames, drops with reasons, merges
   as prose). A `transformer->doc` renderer is mechanical once the surface
   stabilizes.
4. **Guard overlap analysis.** Set dispatch is ordered first-match; nothing
   warns when an earlier guard shadows a later one entirely (`(flag n)`
   before `(and (flag n) (flag e))`). Deciding subsumption for the current
   guard language is feasible (it is propositional over a finite vocabulary)
   but only worth its complexity if shadowing bites in practice.
5. **Dynamically built specs.** Programs that construct specs at runtime
   would need `resolve-transformer` exposed over a first-class clause
   representation built procedurally. The resolution machinery already
   exists; only a public constructor surface is missing. Left out until
   someone actually needs it.
