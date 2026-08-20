#lang racket/base

;; cli-spec-transform public API. (require cli-spec-transform)
;;
;; define-transformer expands in one pass over the phase-1 source and target
;; specs: it parses the clause tree (right-hand sides are name references
;; into the target spec — pure syntax, never evaluated), runs walk.rkt's
;; coverage/selection/resolution checks (re-raising findings as syntax
;; errors on the offending clause), and emits code that rebuilds the same
;; transformer value at module initialization — where the #:value/#:by
;; procedures are compiled in.

(require racket/require-syntax
         cli-spec
         "walk.rkt"
         "rewrite.rkt"
         (for-syntax racket/base
                     racket/match
                     racket/syntax
                     syntax/parse
                     cli-spec
                     "walk.rkt"))

(provide define-transformer
         for-transform
         transformer?
         transformer-source
         transformer-target
         transform-argv
         (struct-out xform-ok)
         (struct-out xform-dropped)
         (struct-out dropped)
         xform-result?
         (all-from-out cli-spec))

;; ---------------------------------------------------------------------------
;; for-transform: require a spec module at phases 0 and 1 (DESIGN.md §2.1)

(define-require-syntax (for-transform stx)
  (syntax-case stx ()
    [(_ mod ...)
     #'(combine-in mod ... (for-syntax mod ...))]))

;; ---------------------------------------------------------------------------
;; Clause parsing (phase 1)

(begin-for-syntax

  ;; one parsed node of the clause tree; rhs entries are
  ;; (vector kind payload value-stx blame-stx) with kind ∈ 'keep 'drop 'map
  ;; — for 'map, payload is the referenced target item's name (a symbol)
  (struct nrec (flags     ; ((name . rhs) ...)
                args      ; ((name . rhs) ...)
                rst       ; (name . rhs) | #f
                merges    ; ((members target-name by-stx blame) ...)
                subs      ; ((name . (list 'dropped reason blame)
                          ;        | (list 'node rename nrec blame)) ...)
                blame))

  ;; a target reference: (flag 'limit) — or bare, (flag limit); the head
  ;; must match the clause's item class
  (define (parse-ref ref-stx c class)
    (define (check-class cls)
      (unless (eq? (syntax-e cls) class)
        (raise-syntax-error
         'define-transformer
         (format "expected a ~a reference, (~a 'name)" class class)
         c ref-stx)))
    (syntax-parse ref-stx
      #:datum-literals (quote)
      [(cls:id (quote n:id)) (check-class #'cls) (syntax-e #'n)]
      [(cls:id n:id) (check-class #'cls) (syntax-e #'n)]
      [_ (raise-syntax-error
          'define-transformer
          (format "expected a target reference, (~a 'name)" class)
          c ref-stx)]))

  (define (parse-rhs rhs-stx c class)
    (syntax-parse rhs-stx
      #:datum-literals (keep drop)
      [(keep) (vector 'keep #f #f c)]
      [((drop reason:str)) (vector 'drop (syntax-e #'reason) #f c)]
      [(ref) (vector 'map (parse-ref #'ref c class) #f c)]
      [(ref #:value vf:expr) (vector 'map (parse-ref #'ref c class) #'vf c)]
      [_ (raise-syntax-error
          'define-transformer
          (format "expected (~a 'name) [#:value expr], keep, or (drop \"reason\")"
                  class)
          c)]))

  (define (parse-node-clauses clauses whole)
    (define flags '())
    (define args '())
    (define rst #f)
    (define merges '())
    (define subs '())
    (define (dup! what nm c)
      (raise-syntax-error
       'define-transformer (format "duplicate clause for ~a ~a" what nm) c))
    (for ([c (in-list clauses)])
      (syntax-parse c
        #:datum-literals (flag arg rest merge subcommand => drop)
        [(flag n:id => . rhs)
         (define nm (syntax-e #'n))
         (when (assq nm flags) (dup! 'flag nm c))
         (set! flags (cons (cons nm (parse-rhs #'rhs c 'flag)) flags))]
        [(arg n:id => . rhs)
         (define nm (syntax-e #'n))
         (when (assq nm args) (dup! 'arg nm c))
         (set! args (cons (cons nm (parse-rhs #'rhs c 'arg)) args))]
        [(rest n:id => . rhs)
         (when rst
           (raise-syntax-error 'define-transformer "duplicate rest clause" c))
         (set! rst (cons (syntax-e #'n) (parse-rhs #'rhs c 'rest)))]
        [(merge (m1:id m2:id ms:id ...) => ref #:by by:expr)
         (set! merges
               (cons (list (map syntax-e (syntax->list #'(m1 m2 ms ...)))
                           (parse-ref #'ref c 'flag) #'by c)
                     merges))]
        [(subcommand n:id => (drop reason:str))
         (define nm (syntax-e #'n))
         (when (assq nm subs) (dup! 'subcommand nm c))
         (set! subs
               (cons (cons nm (list 'dropped (syntax-e #'reason) c)) subs))]
        [(subcommand n:id => new:id sub-clause ...)
         (define nm (syntax-e #'n))
         (when (assq nm subs) (dup! 'subcommand nm c))
         (set! subs
               (cons (cons nm (list 'node (syntax-e #'new)
                                    (parse-node-clauses
                                     (syntax->list #'(sub-clause ...)) c)
                                    c))
                     subs))]
        [(subcommand n:id sub-clause ...)
         (define nm (syntax-e #'n))
         (when (assq nm subs) (dup! 'subcommand nm c))
         (set! subs
               (cons (cons nm (list 'node #f
                                    (parse-node-clauses
                                     (syntax->list #'(sub-clause ...)) c)
                                    c))
                     subs))]
        [_ (raise-syntax-error
            'define-transformer "invalid transformer clause" c)]))
    (nrec (reverse flags) (reverse args) rst
          (reverse merges) (reverse subs) whole))

  ;; --- the phase-1 (unresolved) skeleton ------------------------------------

  ;; x:map item is the target name; value-fn is #t/#f — the walk only checks
  ;; presence at phase 1, the procedure itself exists only at phase 0
  (define (rhs->action r)
    (match r
      [(vector 'keep _ _ c) (x:keep c)]
      [(vector 'drop reason _ c) (x:drop reason c)]
      [(vector 'map tname vf c) (x:map tname (and vf #t) c)]))

  (define (tree->xnode t rename)
    (x:node rename #f
            (for/list ([e (in-list (nrec-flags t))])
              (cons (car e) (rhs->action (cdr e))))
            (for/list ([e (in-list (nrec-args t))])
              (cons (car e) (rhs->action (cdr e))))
            (let ([re (nrec-rst t)])
              (and re (cons (car re) (rhs->action (cdr re)))))
            (for/list ([m (in-list (nrec-merges t))])
              (match-define (list members tname by c) m)
              (x:merge members tname #t c))
            (for/list ([e (in-list (nrec-subs t))])
              (match (cdr e)
                [(list 'dropped reason c)
                 (cons (car e) (x:node #f reason '() '() #f '() '() c))]
                [(list 'node ren sub-t c)
                 (cons (car e) (tree->xnode sub-t ren))]))
            (nrec-blame t)))

  ;; --- code generation ------------------------------------------------------

  (define (rhs->code r)
    (match r
      [(vector 'keep _ _ _) #'(x:keep #f)]
      [(vector 'drop reason _ _) #`(x:drop #,reason #f)]
      [(vector 'map tname vf _) #`(x:map '#,tname #,(or vf #'#f) #f)]))

  (define (tree->code t rename)
    #`(x:node '#,rename #f
              (list #,@(for/list ([e (in-list (nrec-flags t))])
                         #`(cons '#,(car e) #,(rhs->code (cdr e)))))
              (list #,@(for/list ([e (in-list (nrec-args t))])
                         #`(cons '#,(car e) #,(rhs->code (cdr e)))))
              #,(let ([re (nrec-rst t)])
                  (if re
                      #`(cons '#,(car re) #,(rhs->code (cdr re)))
                      #'#f))
              (list #,@(for/list ([m (in-list (nrec-merges t))])
                         (match-define (list members tname by _) m)
                         #`(x:merge '#,members '#,tname #,by #f)))
              (list #,@(for/list ([e (in-list (nrec-subs t))])
                         (match (cdr e)
                           [(list 'dropped reason _)
                            #`(cons '#,(car e)
                                    (x:node #f #,reason '() '() #f '() '() #f))]
                           [(list 'node ren sub-t _)
                            #`(cons '#,(car e) #,(tree->code sub-t ren))])))
              #f)))

;; ---------------------------------------------------------------------------
;; define-transformer

(define-syntax (define-transformer stx)
  (syntax-parse stx
    [(_ name:id #:source src:id #:target tgt:id clause ...)
     ;; both specs, at phase 1
     (define (spec-of id-stx what)
       (define v
         (with-handlers
             ([exn:fail?
               (lambda (e)
                 (raise-syntax-error
                  'define-transformer
                  (format
                   "~a spec is not available at expansion time (require its module with for-transform): ~a"
                   what (exn-message e))
                  stx id-stx))])
           (syntax-local-eval id-stx)))
       (unless (command? v)
         (raise-syntax-error
          'define-transformer
          (format "~a is not a cli-spec command" what) stx id-stx))
       v)
     (define source (spec-of #'src "#:source"))
     (define target (spec-of #'tgt "#:target"))
     ;; parse and check the mapping
     (define tree (parse-node-clauses (syntax->list #'(clause ...)) stx))
     (define (fail blame msg)
       (raise-syntax-error 'define-transformer msg stx
                           (and (syntax? blame) blame)))
     (resolve-transformer source target (tree->xnode tree #f) fail)
     ;; emit: rebuild the (checked) transformer at module initialization,
     ;; with the #:value/#:by procedures compiled in
     #`(define name (make-transformer src tgt #,(tree->code tree #f)))]))
