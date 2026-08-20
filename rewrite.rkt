#lang racket/base

;; transform-argv (DESIGN.md §2): parse an invocation with the source spec,
;; translate the values through the resolved mapping, and render an
;; invocation of the target spec. Rendering is the one piece of argv-level
;; code this package adds; parsing is cli-spec's parse-argv. This module
;; only ever sees resolved skeletons (walk.rkt): actions are x:map (with the
;; target item struct), x:drop, and x:merge.

(require racket/match
         racket/string
         racket/format
         net/url
         cli-spec
         cli-spec/ast
         "walk.rkt")

(provide (struct-out xform-ok)
         (struct-out xform-dropped)
         (struct-out dropped)
         xform-result?
         transform-argv)

(struct xform-ok (argv warnings) #:transparent)
(struct dropped (name reason) #:transparent)          ; a warning entry
(struct xform-dropped (path reason) #:transparent)    ; invocation reached a
                                                      ; dropped subtree

(define (xform-result? v)
  (or (xform-ok? v) (xform-dropped? v) (parse-error? v)))

(define absent (string->uninterned-symbol "absent"))

;; ---------------------------------------------------------------------------
;; Value rendering: the inverse of type-parse, per type

(define (render-value t v)
  (define tag (cli-type-parse t))
  (cond
    [(procedure? tag)
     ;; custom type: the clause's value function must have produced the
     ;; argv-level string already
     (unless (string? v)
       (error 'transform-argv
              "cannot render a value of custom type ~a; #:value must produce a string, got: ~e"
              (cli-type-name t) v))
     v]
    [else
     (case tag
       [(string glob host enum) (if (string? v) v (format "~a" v))]
       [(int nat float port) (number->string v)]
       [(bool) (if v "true" "false")]
       [(path file dir) (if (path? v) (path->string v) (format "~a" v))]
       [(regex)
        (let ([n (object-name v)]) (if (string? n) n (format "~a" v)))]
       [(date)
        (match v
          [(list y m d)
           (format "~a-~a-~a"
                   (~r y #:min-width 4 #:pad-string "0")
                   (~r m #:min-width 2 #:pad-string "0")
                   (~r d #:min-width 2 #:pad-string "0"))])]
       [(duration)
        (cond
          [(and (exact? v) (integer? v)) (format "~as" v)]
          [(and (exact? v) (integer? (* 1000 v))) (format "~ams" (* 1000 v))]
          [else (format "~as" (inexact->exact (round v)))])]
       [(url) (url->string v)]
       [(list-of)
        (match-define (list inner sep) (cli-type-base t))
        (string-join (for/list ([e (in-list v)]) (render-value inner e)) sep)]
       [(pair-of)
        (match-define (list lt rt sep) (cli-type-base t))
        (string-append (render-value lt (car v)) sep (render-value rt (cdr v)))]
       [(or)
        ;; pick the first branch that renders and round-trips to this value
        (or (for/or ([inner (in-list (cli-type-base t))])
              (with-handlers ([exn:fail? (lambda (_) #f)])
                (define s (render-value inner v))
                (and (match (type-parse inner s)
                       [(list 'ok v2) (equal? v2 v)]
                       [_ #f])
                     s)))
            (error 'transform-argv "cannot render ~e as ~a"
                   v (describe-type t)))]
       [else (error 'transform-argv "cannot render type ~a" tag)])]))

;; ---------------------------------------------------------------------------
;; Flag emission

;; prefer a long spelling so attached values (--x=v) are available
(define (pick-spelling p)
  (define sps (param-base-spellings p))
  (or (for/or ([s (in-list sps)]) (and (string-prefix? s "--") s))
      (car sps)))

(define (pick-negated p)
  (define ns (param-negated-spellings p))
  (and (pair? ns) (car ns)))

;; emit-flag : target-param value → (listof string)
(define (emit-flag tp v)
  (cond
    ;; the target's own default needs no tokens
    [(and (param-has-default? tp) (equal? v (param-default tp))) '()]
    [(eq? (param-kind tp) 'switch) (emit-switch tp v)]
    ;; #f on a defaultless valued flag means "absent" (a merge's #:by or a
    ;; #:value function declining to produce a value)
    [(eq? v #f) '()]
    [else (emit-valued tp v)]))

(define (emit-switch tp v)
  (define sp (pick-spelling tp))
  (case (param-repeat tp)
    [(count)
     (if (exact-nonnegative-integer? v)
         (for/list ([_ (in-range v)]) sp)
         '())]
    [(list)
     (apply append
            (for/list ([b (in-list v)])
              (cond [b (list sp)]
                    [(pick-negated tp) => list]
                    [else '()])))]
    [else
     (cond [v (list sp)]
           ;; #f against a non-#f default: only expressible when negatable
           [(pick-negated tp) => list]
           [else '()])]))

(define (emit-valued tp v)
  (case (param-repeat tp)
    [(list)
     (apply append (for/list ([e (in-list v)]) (emit-valued-one tp e)))]
    [else (emit-valued-one tp v)]))

(define (emit-valued-one tp v)
  (define sp (pick-spelling tp))
  (cond
    ;; #t is a bare occurrence of an optional-value (arity '?) flag
    [(eq? v #t) (list sp)]
    [else
     (define s (render-value (param-type tp) v))
     (cond
       ;; arity-'? values must be attached; dash-leading values would
       ;; otherwise be read as flags
       [(or (eq? (param-arity tp) '?) (string-prefix? s "-"))
        (list (if (string-prefix? sp "--")
                  (string-append sp "=" s)
                  (string-append sp s)))]
       [else (list sp s)])]))

;; ---------------------------------------------------------------------------
;; Per-node token generation

(define (make-claims xn)
  (define h (make-hasheq))
  (for ([e (in-list (x:node-flags xn))]) (hash-set! h (car e) (cdr e)))
  (for ([m (in-list (x:node-merges xn))])
    (for ([mn (in-list (x:merge-members m))]) (hash-set! h mn m)))
  h)

(define (flag-used? sp v)
  (and (not (eq? v absent))
       (or (not (param-has-default? sp))
           (not (equal? v (param-default sp))))))

(define (node-flag-tokens cmd xn vals warn!)
  (define claims (make-claims xn))
  (define emitted (make-hasheq))
  (apply append
         (for/list ([sp (in-list (command-params cmd))])
           (define act (hash-ref claims (param-name sp) #f))
           (define v (hash-ref vals (param-name sp) absent))
           (cond
             [(x:drop? act)
              (when (flag-used? sp v)
                (warn! (param-name sp) (x:drop-reason act)))
              '()]
             [(x:merge? act)
              (cond
                [(hash-ref emitted act #f) '()]
                [else
                 (hash-set! emitted act #t)
                 (define mv
                   (apply (x:merge-by act)
                          (for/list ([mn (in-list (x:merge-members act))])
                            (define x (hash-ref vals mn absent))
                            (if (eq? x absent) #f x))))
                 (emit-flag (x:merge-item act) mv)])]
             [(x:map? act)
              (if (eq? v absent)
                  '()
                  (emit-flag (x:map-item act)
                             (let ([f (x:map-value-fn act)])
                               (if f (f v) v))))]
             [else '()]))))

;; positionals are emitted in the *target* node's declared order — the two
;; specs may order them differently
(define (node-positional-tokens cmd tcmd xn vals warn!)
  (define by-target (make-hasheq))  ; target name → (cons source-name value-fn)
  (for ([e (in-list (x:node-args xn))])
    (define act (cdr e))
    (cond
      [(x:drop? act)
       (define v (hash-ref vals (car e) absent))
       (when (and (not (eq? v absent)) (not (and (list? v) (null? v))))
         (warn! (car e) (x:drop-reason act)))]
      [(x:map? act)
       (hash-set! by-target (positional-name (x:map-item act))
                  (cons (car e) (x:map-value-fn act)))]))
  (apply append
         (for/list ([ta (in-list (command-positionals tcmd))])
           (define e (hash-ref by-target (positional-name ta) #f))
           (define v (and e (hash-ref vals (car e) absent)))
           (cond
             [(or (not e) (eq? v absent)) '()]
             [else
              (define v* (let ([f (cdr e)]) (if f (f v) v)))
              (define-values (_lo hi) (arity->bounds (positional-arity ta)))
              (if (equal? hi 1)
                  (list (render-value (positional-type ta) v*))
                  (for/list ([x (in-list v*)])
                    (render-value (positional-type ta) x)))]))))

(define (node-rest-tokens cmd xn vals warn!)
  (define r (command-rest cmd))
  (cond
    [(not r) '()]
    [else
     (define re (x:node-rst xn))
     (define act (and re (cdr re)))
     (define v (hash-ref vals (rest-args-name r) absent))
     (cond
       [(eq? v absent) '()]
       [(x:drop? act)
        (when (pair? v) (warn! (rest-args-name r) (x:drop-reason act)))
        '()]
       [(x:map? act)
        (define tr (x:map-item act))
        (define v* (let ([f (x:map-value-fn act)]) (if f (f v) v)))
        (cond
          [(null? v*) '()]
          [(eq? (rest-args-after tr) 'double-dash) (cons "--" v*)]
          [else v*])]
       [else '()])]))

;; ---------------------------------------------------------------------------
;; transform-argv

(define (transform-argv t argv)
  (define src (transformer-source t))
  (define pr (parse-argv src argv))
  (cond
    [(parse-error? pr) pr]
    [else
     (define vals (parse-ok-values pr))
     (define warnings '())
     (define (warn! nm reason)
       (set! warnings (cons (dropped nm reason) warnings)))
     (define result
       (let/ec escape
         ;; emit node by node down the matched path: a node's flags come
         ;; before the next subcommand word (so 'before-subcommand globals
         ;; land where they must), positionals and rest close the argv
         (let loop ([cmd src]
                    [tcmd (transformer-target t)]
                    [xn (transformer-xnode t)]
                    [words (cdr (parse-ok-path pr))]
                    [acc '()])  ; reversed tokens
           (define acc*
             (for/fold ([a acc])
                       ([tok (in-list (node-flag-tokens cmd xn vals warn!))])
               (cons tok a)))
           (cond
             [(null? words)
              (define tail
                (append (node-positional-tokens cmd tcmd xn vals warn!)
                        (node-rest-tokens cmd xn vals warn!)))
              (append (reverse acc*) tail)]
             [else
              (define w (car words))
              (define child
                (for/first ([s (in-list (command-subcommands cmd))]
                            #:when (eq? (command-name s) w))
                  s))
              (define cxn (cdr (assq w (x:node-subs xn))))
              (when (x:node-drop cxn)
                (escape (xform-dropped (parse-ok-path pr)
                                       (x:node-drop cxn))))
              (define tname (x:node-rename cxn))
              (define tchild
                (for/first ([s (in-list (command-subcommands tcmd))]
                            #:when (eq? (command-name s) tname))
                  s))
              (loop child tchild cxn (cdr words)
                    (cons (symbol->string tname) acc*))]))))
     (if (xform-dropped? result)
         result
         (xform-ok result (reverse warnings)))]))
