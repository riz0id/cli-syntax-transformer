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

;; help renders for the target surface
(check-true (string? (spec->help (transformer-target git->jj) '(jj log))))

;; ---------------------------------------------------------------------------
;; transform-argv

(let ([r (transform-argv git->jj
           '("--git-dir" "/tmp/r" "log" "-n" "5"
             "--author" "linus" "--oneline"))])
  (check-pred xform-ok? r)
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
