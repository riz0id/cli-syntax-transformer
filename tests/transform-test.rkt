#lang racket/base

(require rackunit
         syntax/macro-testing
         cli-spec-transform)
(require (for-transform "git-spec.rkt" "jj-spec.rkt"))

;; ---------------------------------------------------------------------------
;; The DESIGN.md §5 worked example: pure name-to-name mapping between two
;; independently declared specs

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

  (subcommand checkout
    => (drop "use `jj new`/`jj edit`; no checkout analogue")))

;; the transformer value; its target is the input spec, verbatim
(check-true (transformer? git->jj))
(check-eq? (transformer-target git->jj) jj-spec)
(check-equal? (command-name (transformer-target git->jj)) 'jj)

;; an unguarded transformer has no guard
(check-false (transformer-guard git->jj))

;; help renders for the target surface
(check-true (string? (spec->help (transformer-target git->jj) '(jj log))))

;; ---------------------------------------------------------------------------
;; transform-argv

(let ([r (transform-argv git->jj
           '("--git-dir" "/tmp/r" "log" "-n" "5"
             "--author" "linus" "--oneline"))])
  (check-pred xform-ok? r)
  (check-eq? (xform-ok-target r) jj-spec)
  (check-equal? (xform-ok-argv r)
                '("--repository" "/tmp/r" "log" "--limit" "5"
                  "--author" "linus"))
  (check-equal? (map dropped-name (xform-ok-warnings r)) '(oneline)))

;; merge, optional-value flag, variadic positional, subcommand rename
(let ([r (transform-argv git->jj
           '("status" "-s" "--porcelain=v2" "src/a" "src/b"))])
  (check-pred xform-ok? r)
  (check-equal? (xform-ok-argv r)
                '("st" "--format=short" "--template" "json_status"
                  "src/a" "src/b"))
  (check-equal? (xform-ok-warnings r) '()))

;; bare occurrence of an arity-'? flag crosses through #:value
(let ([r (transform-argv git->jj '("status" "--porcelain"))])
  (check-pred xform-ok? r)
  (check-equal? (xform-ok-argv r) '("st" "--template" "text_status")))

;; rest args after --
(let ([r (transform-argv git->jj '("log" "--" "src/"))])
  (check-pred xform-ok? r)
  (check-equal? (xform-ok-argv r) '("log" "--" "src/")))

;; a dropped subtree cannot be rewritten
(let ([r (transform-argv git->jj '("checkout" "main"))])
  (check-pred xform-dropped? r)
  (check-equal? (xform-dropped-path r) '(git checkout)))

;; source parse errors pass through unchanged
(check-pred parse-error? (transform-argv git->jj '("log" "--frobnicate")))

;; every rewritten invocation parses under the target spec
(let ([r (transform-argv git->jj
           '("--git-dir" "/tmp/r" "log" "-n" "5" "--author" "linus"))])
  (define pr (parse-argv jj-spec (xform-ok-argv r)))
  (check-pred parse-ok? pr)
  (check-equal? (parse-ok-path pr) '(jj log))
  (check-equal? (hash-ref (parse-ok-values pr) 'limit) 5)
  (check-equal? (hash-ref (parse-ok-values pr) 'author) '("linus")))

;; ---------------------------------------------------------------------------
;; Guards and transformer sets (DESIGN.md §3.6–3.7)

;; presence guard; the guard-named flag needs no clause (absorbed)
(define-transformer tiny-a->t2
  #:source tiny-spec
  #:target tiny-target2
  #:when (flag a)
  (flag b => keep))

(define-transformer tiny-any->t
  #:source tiny-spec
  #:target tiny-target
  (flag a => keep)
  (flag b => (drop "no b")))

(define-transformer-set tiny->either
  tiny-a->t2
  tiny-any->t)

(check-true (transformer-set? tiny->either))
(check-eq? (transformer-set-source tiny->either) tiny-spec)
(check-equal? (length (transformer-set-members tiny->either)) 2)

;; --a present: the guarded member fires; a is absorbed silently
(let ([r (transform-argv tiny->either '("--a" "--b"))])
  (check-pred xform-ok? r)
  (check-eq? (xform-ok-target r) tiny-target2)
  (check-equal? (xform-ok-argv r) '("--b"))
  (check-equal? (xform-ok-warnings r) '()))

;; --a absent: falls through to the unguarded catch-all
(let ([r (transform-argv tiny->either '("--b"))])
  (check-pred xform-ok? r)
  (check-eq? (xform-ok-target r) tiny-target)
  (check-equal? (xform-ok-argv r) '())
  (check-equal? (map dropped-name (xform-ok-warnings r)) '(b)))

;; a guarded transformer applied directly reports a non-match
(check-pred xform-unmatched? (transform-argv tiny-a->t2 '("--b")))
(check-pred xform-ok? (transform-argv tiny-a->t2 '("--a")))

;; parse errors pass through a set unchanged
(check-pred parse-error? (transform-argv tiny->either '("--frobnicate")))

;; = value guards parse the literal under the flag's declared type
(define-transformer tt-x
  #:source tiny-typed
  #:target tiny-typed-target
  #:when (flag mode = "x")
  (flag k => keep))

(define-transformer tt-else
  #:source tiny-typed
  #:target tiny-typed-target
  (flag mode => keep)
  (flag k => keep))

(define-transformer-set tt-dispatch
  tt-x
  tt-else)

(let ([r (transform-argv tt-dispatch '("--mode" "x" "--k"))])
  (check-pred xform-ok? r)
  (check-eq? (xform-ok-target r) tiny-typed-target)
  (check-equal? (xform-ok-argv r) '("--k")))   ; mode absorbed by the guard

(let ([r (transform-argv tt-dispatch '("--mode" "y" "--k"))])
  (check-pred xform-ok? r)
  (check-equal? (xform-ok-argv r) '("--mode" "y" "--k")))

;; subcommand-scoped guards: same mapping as git->jj, but only for
;; `git log -n …` invocations
(define-transformer git-log-n->jj
  #:source git-spec
  #:target jj-spec
  #:when (subcommand log (flag n))

  (flag git-dir  => (flag 'repository))
  (flag paginate => (drop "jj always pages; configure ui.pager instead"))

  (subcommand status => st
    (merge (short long) => (flag 'format)
           #:by (λ (s? l?) (cond [s? "short"] [l? "long"] [else #f])))
    (flag porcelain => (flag 'template)
          #:value (λ (v) (if (equal? v "v2") "json_status" "text_status")))
    (arg pathspec => keep))

  (subcommand log
    (flag n        => (flag 'limit))   ; a clause wins over absorption
    (flag oneline  => (drop "use -T builtin_log_oneline instead"))
    (flag author   => keep)
    (arg  revision => (arg 'revset))
    (rest paths    => keep))

  (subcommand checkout
    => (drop "use `jj new`/`jj edit`; no checkout analogue")))

(let ([r (transform-argv git-log-n->jj '("log" "-n" "5"))])
  (check-pred xform-ok? r)
  (check-equal? (xform-ok-argv r) '("log" "--limit" "5")))
(check-pred xform-unmatched? (transform-argv git-log-n->jj '("log")))
(check-pred xform-unmatched? (transform-argv git-log-n->jj '("status")))

;; ---------------------------------------------------------------------------
;; Target-only emission (DESIGN.md §3.8)

;; a switch emitted on every rewrite, whatever the invocation used
(define-transformer tiny->t-emit
  #:source tiny-spec
  #:target tiny-target
  (emit (flag 'a))
  (flag a => (drop "no counterpart"))
  (flag b => (drop "no counterpart")))

(let ([r (transform-argv tiny->t-emit '())])
  (check-pred xform-ok? r)
  (check-equal? (xform-ok-argv r) '("--a"))
  (check-equal? (xform-ok-warnings r) '()))

;; a valued emit: the literal parses at expansion, renders at rewrite,
;; and lands after the node's source-driven flags
(define-transformer tiny->t-emit-val
  #:source tiny-spec
  #:target tiny-target
  (flag a => (flag 'a))
  (flag b => (drop "gone"))
  (emit (flag 'b2) #:value "7"))

(let ([r (transform-argv tiny->t-emit-val '("--a"))])
  (check-pred xform-ok? r)
  (check-equal? (xform-ok-argv r) '("--a" "--b2" "7")))

;; an emit produces the target's required surface (totality, §4 check 6)
(define-transformer tiny->req-emit
  #:source tiny-spec
  #:target tiny-req-target
  (flag a => (flag 'a))
  (flag b => (drop "gone"))
  (emit (flag 'must) #:value "3"))

(let ([r (transform-argv tiny->req-emit '())])
  (check-pred xform-ok? r)
  (check-equal? (xform-ok-argv r) '("--must" "3")))

;; ---------------------------------------------------------------------------
;; Static errors (DESIGN.md §4), converted to runtime exns for testing

(check-exn
 #rx"does not cover.*tiny → flag b"
 (λ ()
   (convert-compile-time-error
    (let ()
      (define-transformer bad-coverage
        #:source tiny-spec
        #:target tiny-target
        (flag a => keep))
      (void)))))

(check-exn
 #rx"no flag c.*nearest"
 (λ ()
   (convert-compile-time-error
    (let ()
      (define-transformer bad-unknown-source
        #:source tiny-spec
        #:target tiny-target
        (flag a => keep)
        (flag b => (drop "gone"))
        (flag c => keep))
      (void)))))

(check-exn
 #rx"the target has no flag nope"
 (λ ()
   (convert-compile-time-error
    (let ()
      (define-transformer bad-unknown-target
        #:source tiny-spec
        #:target tiny-target
        (flag a => keep)
        (flag b => (flag 'nope)))
      (void)))))

(check-exn
 #rx"different shape; map it explicitly with #:value"
 (λ ()
   (convert-compile-time-error
    (let ()
      (define-transformer bad-keep-shape
        #:source tiny-spec
        #:target tiny-target2
        (flag a => keep)   ; target's a is 'int-valued; source's is a switch
        (flag b => keep))
      (void)))))

(check-exn
 #rx"shapes differ; #:value is required"
 (λ ()
   (convert-compile-time-error
    (let ()
      (define-transformer bad-crossing
        #:source tiny-spec
        #:target tiny-target
        (flag a => keep)
        (flag b => (flag 'b2)))
      (void)))))

(check-exn
 #rx"two clauses map to target flag a"
 (λ ()
   (convert-compile-time-error
    (let ()
      (define-transformer bad-target-dup
        #:source tiny-spec
        #:target tiny-target
        (flag a => (flag 'a))
        (flag b => (flag 'a)))
      (void)))))

(check-exn
 #rx"claimed twice"
 (λ ()
   (convert-compile-time-error
    (let ()
      (define-transformer bad-source-dup
        #:source tiny-spec
        #:target tiny-target
        (flag a => keep)
        (merge (a b) => (flag 'b2) #:by (λ (a? b?) 0)))
      (void)))))

(check-exn
 #rx"required target flag must is not produced"
 (λ ()
   (convert-compile-time-error
    (let ()
      (define-transformer bad-totality
        #:source tiny-spec
        #:target tiny-req-target
        (flag a => (flag 'a))
        (flag b => (drop "gone")))
      (void)))))

;; --- emits ---

(check-exn
 #rx"emit: target flag a is a switch; #:value is not allowed"
 (λ ()
   (convert-compile-time-error
    (let ()
      (define-transformer bad-emit-switch-value
        #:source tiny-spec
        #:target tiny-target
        (flag a => (drop "gone"))
        (flag b => (drop "gone"))
        (emit (flag 'a) #:value "1"))
      (void)))))

(check-exn
 #rx"emit: target flag b2 takes a value; #:value is required"
 (λ ()
   (convert-compile-time-error
    (let ()
      (define-transformer bad-emit-missing-value
        #:source tiny-spec
        #:target tiny-target
        (flag a => (drop "gone"))
        (flag b => (drop "gone"))
        (emit (flag 'b2)))
      (void)))))

(check-exn
 #rx"emit: the value \"zz\" does not parse as target flag b2's type"
 (λ ()
   (convert-compile-time-error
    (let ()
      (define-transformer bad-emit-literal
        #:source tiny-spec
        #:target tiny-target
        (flag a => (drop "gone"))
        (flag b => (drop "gone"))
        (emit (flag 'b2) #:value "zz"))
      (void)))))

(check-exn
 #rx"emit: the target has no flag nope here"
 (λ ()
   (convert-compile-time-error
    (let ()
      (define-transformer bad-emit-unknown
        #:source tiny-spec
        #:target tiny-target
        (flag a => (drop "gone"))
        (flag b => (drop "gone"))
        (emit (flag 'nope)))
      (void)))))

(check-exn
 #rx"two clauses map to target flag a"
 (λ ()
   (convert-compile-time-error
    (let ()
      (define-transformer bad-emit-collision
        #:source tiny-spec
        #:target tiny-target
        (flag a => (flag 'a))
        (flag b => (drop "gone"))
        (emit (flag 'a)))
      (void)))))

;; --- guards ---

(check-exn
 #rx"guard: tiny: no flag zz"
 (λ ()
   (convert-compile-time-error
    (let ()
      (define-transformer bad-guard-name
        #:source tiny-spec
        #:target tiny-target
        #:when (flag zz)
        (flag a => keep)
        (flag b => (drop "gone")))
      (void)))))

(check-exn
 #rx"flag a is a switch; a = value test needs a valued flag"
 (λ ()
   (convert-compile-time-error
    (let ()
      (define-transformer bad-guard-switch-test
        #:source tiny-spec
        #:target tiny-target
        #:when (flag a = "1")
        (flag b => (drop "gone")))
      (void)))))

(check-exn
 #rx"does not parse as flag mode's type"
 (λ ()
   (convert-compile-time-error
    (let ()
      (define-transformer bad-guard-literal
        #:source tiny-typed
        #:target tiny-typed-target
        #:when (flag mode = "z")
        (flag k => keep))
      (void)))))

;; the guard only covers the items it names; the rest still need clauses
(check-exn
 #rx"does not cover.*tiny → flag b"
 (λ ()
   (convert-compile-time-error
    (let ()
      (define-transformer bad-guard-coverage
        #:source tiny-spec
        #:target tiny-target
        #:when (flag a))
      (void)))))

;; --- transformer sets ---

(check-exn
 #rx"the final member must be unguarded"
 (λ ()
   (convert-compile-time-error
    (let ()
      (define-transformer-set bad-set-no-catch-all
        tiny-a->t2)
      (void)))))

(check-exn
 #rx"only the final member may be unguarded"
 (λ ()
   (convert-compile-time-error
    (let ()
      (define-transformer-set bad-set-unreachable
        tiny-any->t
        tiny-a->t2)
      (void)))))

(check-exn
 #rx"members do not share the same #:source spec"
 (λ ()
   (convert-compile-time-error
    (let ()
      (define-transformer-set bad-set-sources
        tt-x
        tiny-any->t)
      (void)))))

(check-exn
 #rx"member is not a transformer defined by define-transformer"
 (λ ()
   (convert-compile-time-error
    (let ()
      (define-transformer-set bad-set-member
        tiny-spec
        tiny-any->t)
      (void)))))
