#lang racket/base

;; The transformer skeleton (x:* structs) and the simultaneous walk over
;; three trees — source spec, clause skeleton, target spec — that checks the
;; mapping (DESIGN.md §4) and resolves every target reference to the actual
;; target item struct. Pure: define-transformer instantiates this module at
;; phase 1 and turns walk failures into syntax errors via the `fail` hook;
;; make-transformer runs the same walk at phase 0, where a failure means the
;; phase-1 check was somehow bypassed.

(require racket/match
         racket/string
         cli-spec
         cli-spec/ast)

(provide (struct-out x:map)
         (struct-out x:keep)
         (struct-out x:drop)
         (struct-out x:absorb)
         (struct-out x:merge)
         (struct-out x:node)
         (struct-out p:flag)
         (struct-out p:arg)
         (struct-out p:not)
         (struct-out p:and)
         (struct-out p:or)
         (struct-out p:sub)
         (struct-out transformer)
         (struct-out transformer-set)
         make-transformer
         make-transformer-set
         resolve-transformer)

;; ---------------------------------------------------------------------------
;; Skeleton structs
;;
;; blame slots hold the originating clause's syntax object at phase 1 and #f
;; in the code define-transformer emits. Before resolution, x:map item and
;; x:merge item hold the referenced target item's *name* (a symbol) and
;; x:map value-fn holds #t/#f (only presence is checked at phase 1); after
;; resolution, item holds the target param/positional/rest-args struct,
;; x:keep is gone (resolved into an x:map of the same-named target item),
;; and x:node rename holds the mapped target node's name.

(struct x:map   (item value-fn blame) #:transparent)
(struct x:keep  (blame) #:transparent)
(struct x:drop  (reason blame) #:transparent)
(struct x:absorb () #:transparent)   ; guard-named item with no clause: the
                                     ; guard covers it; consumed silently
(struct x:merge (members item by blame) #:transparent) ; members: (listof symbol)
(struct x:node  (rename         ; symbol | #f (same name as the source node)
                 drop           ; string | #f — whole subtree dropped
                 flags          ; ((source-name . action) ...)
                 args           ; ((source-name . action) ...)
                 rst            ; (source-name . action) | #f
                 merges         ; (listof x:merge)
                 subs           ; ((source-name . x:node) ...)
                 blame) #:transparent)

;; Guard skeletons (DESIGN.md §3.6). In p:flag, test is #f (a presence test)
;; or a one-element list holding the = literal — the raw string before
;; resolution, the value parsed under the flag's declared type after — and
;; param is #f before resolution, the source param struct after (evaluation
;; needs its default and repeat). Likewise p:arg positional.

(struct p:flag (name test param blame) #:transparent)
(struct p:arg  (name positional blame) #:transparent)
(struct p:not  (g) #:transparent)
(struct p:and  (gs) #:transparent)
(struct p:or   (gs) #:transparent)
(struct p:sub  (name gs blame) #:transparent)

(struct transformer (source target guard xnode))

(define (make-transformer src tgt xn [guard #f])
  (define-values (guard* xn*) (resolve-transformer src tgt xn guard))
  (transformer src tgt guard* xn*))

;; ordered first-match dispatch: guarded members first, an unguarded
;; catch-all last, all over one source spec. define-transformer-set checks
;; the same invariants at expansion; this is the emitted path's re-check.
(struct transformer-set (source members))

(define (make-transformer-set members)
  (unless (and (pair? members) (andmap transformer? members))
    (raise-argument-error 'make-transformer-set
                          "a non-empty list of transformers" members))
  (define src (transformer-source (car members)))
  (for ([m (in-list (cdr members))])
    (unless (equal? (transformer-source m) src)
      (runtime-fail #f "transformer-set members do not share a source spec")))
  (let loop ([ms members])
    (cond
      [(null? (cdr ms))
       (when (transformer-guard (car ms))
         (runtime-fail #f "the final transformer-set member must be unguarded"))]
      [else
       (unless (transformer-guard (car ms))
         (runtime-fail #f "only the final transformer-set member may be unguarded"))
       (loop (cdr ms))]))
  (transformer-set src members))

;; ---------------------------------------------------------------------------
;; Failure plumbing

(define (runtime-fail blame msg)
  (raise (exn:fail (string-append "cli-spec-transform: " msg)
                   (current-continuation-marks))))

(define (action-blame a)
  (cond [(x:map? a) (x:map-blame a)]
        [(x:keep? a) (x:keep-blame a)]
        [(x:drop? a) (x:drop-blame a)]
        [(x:merge? a) (x:merge-blame a)]
        [(x:node? a) (x:node-blame a)]
        [else #f]))

(define (spec-path->string path)
  (string-join (map symbol->string path) " → "))

;; ---------------------------------------------------------------------------
;; Suggestions for unknown selections and references

(define (levenshtein a b)
  (define la (string-length a))
  (define lb (string-length b))
  (define prev (build-vector (add1 lb) values))
  (define curr (make-vector (add1 lb) 0))
  (for ([i (in-range 1 (add1 la))])
    (vector-set! curr 0 i)
    (for ([j (in-range 1 (add1 lb))])
      (vector-set!
       curr j
       (min (add1 (vector-ref prev j))
            (add1 (vector-ref curr (sub1 j)))
            (+ (vector-ref prev (sub1 j))
               (if (char=? (string-ref a (sub1 i)) (string-ref b (sub1 j)))
                   0
                   1)))))
    (let ([tmp prev])
      (set! prev curr)
      (set! curr tmp)))
  (vector-ref prev lb))

(define (nearest-note nm cands)
  (define s (symbol->string nm))
  (define limit (max 2 (quotient (string-length s) 3)))
  (define best
    (for/fold ([b #f] [bd (add1 limit)] #:result b)
              ([c (in-list cands)])
      (define d (levenshtein s (symbol->string c)))
      (if (< d bd) (values c d) (values b bd))))
  (if best (format " (nearest: ~a)" best) ""))

;; ---------------------------------------------------------------------------
;; Type and shape comparison (DESIGN.md §4)
;;
;; #:value is required exactly when values could not cross unchanged between
;; the two declared shapes. Types compare structurally; custom types
;; (procedure in the parse field) compare by name, since predicates cannot
;; be compared.

(define (type-equal? a b)
  (define pa (cli-type-parse a))
  (define pb (cli-type-parse b))
  (cond
    [(or (procedure? pa) (procedure? pb))
     (and (procedure? pa) (procedure? pb)
          (eq? (cli-type-name a) (cli-type-name b)))]
    [(not (eq? pa pb)) #f]
    [else
     (case pa
       [(enum) (equal? (cli-type-base a) (cli-type-base b))]
       [(list-of)
        (and (equal? (cadr (cli-type-base a)) (cadr (cli-type-base b)))
             (type-equal? (car (cli-type-base a)) (car (cli-type-base b))))]
       [(pair-of)
        (and (equal? (caddr (cli-type-base a)) (caddr (cli-type-base b)))
             (type-equal? (car (cli-type-base a)) (car (cli-type-base b)))
             (type-equal? (cadr (cli-type-base a)) (cadr (cli-type-base b))))]
       [(or)
        (and (= (length (cli-type-base a)) (length (cli-type-base b)))
             (andmap type-equal? (cli-type-base a) (cli-type-base b)))]
       [else #t])]))  ; the same known atom

(define (param-shape-equal? sp tp)
  (and (eq? (param-kind sp) (param-kind tp))
       (eq? (param-repeat sp) (param-repeat tp))
       (equal? (param-arity sp) (param-arity tp))
       (if (param-type sp)
           (and (param-type tp) (type-equal? (param-type sp) (param-type tp)))
           (not (param-type tp)))))

(define (positional-shape-equal? sa ta)
  (and (eq? (variadic-arity? (positional-arity sa))
            (variadic-arity? (positional-arity ta)))
       (type-equal? (positional-type sa) (positional-type ta))))

;; ---------------------------------------------------------------------------
;; Guard resolution (DESIGN.md §3.6)
;;
;; Validates every name the guard tests against the source spec, parses =
;; literals under the tested flag's declared type, and records which items
;; each node's guard mentions — those are exempt from coverage (absorbed).

;; resolve-guard : (or/c #f guard) command fail
;;              → (values (or/c #f guard) gnames)
;; gnames : hash of relative path (listof symbol) → (cons flags args), each a
;; mutable hasheq of name → #t
(define (resolve-guard g src fail)
  (define gnames (make-hash))
  (define (note! rel kind nm)
    (define cell
      (hash-ref! gnames rel (λ () (cons (make-hasheq) (make-hasheq)))))
    (hash-set! (if (eq? kind 'flag) (car cell) (cdr cell)) nm #t))
  (define (gfail! blame abs fmt . a)
    (fail blame (format "guard: ~a: ~a"
                        (spec-path->string abs) (apply format fmt a))))
  (define (walk g cmd rel abs)
    (match g
      [(p:flag nm test _ blame)
       (define sp
         (or (for/first ([p (in-list (command-params cmd))]
                         #:when (eq? (param-name p) nm))
               p)
             (gfail! blame abs "no flag ~a here~a"
                     nm (nearest-note nm (map param-name (command-params cmd))))))
       (note! rel 'flag nm)
       (define test*
         (cond
           [(not test) #f]
           [(not (param-type sp))
            (gfail! blame abs
                    "flag ~a is a switch; a = value test needs a valued flag"
                    nm)]
           [else
            (match (type-parse (param-type sp) (car test))
              [(list 'ok v) (list v)]
              [_ (gfail! blame abs
                         "the value ~s does not parse as flag ~a's type"
                         (car test) nm)])]))
       (p:flag nm test* sp blame)]
      [(p:arg nm _ blame)
       (define sa
         (or (for/first ([a (in-list (command-positionals cmd))]
                         #:when (eq? (positional-name a) nm))
               a)
             (gfail! blame abs "no positional ~a here~a"
                     nm (nearest-note
                         nm (map positional-name (command-positionals cmd))))))
       (note! rel 'arg nm)
       (p:arg nm sa blame)]
      [(p:not g1) (p:not (walk g1 cmd rel abs))]
      [(p:and gs) (p:and (for/list ([x (in-list gs)]) (walk x cmd rel abs)))]
      [(p:or gs)  (p:or  (for/list ([x (in-list gs)]) (walk x cmd rel abs)))]
      [(p:sub nm gs blame)
       (define child
         (or (for/first ([s (in-list (command-subcommands cmd))]
                         #:when (eq? (command-name s) nm))
               s)
             (gfail! blame abs "no subcommand ~a here~a"
                     nm (nearest-note
                         nm (map command-name (command-subcommands cmd))))))
       (p:sub nm
              (for/list ([x (in-list gs)])
                (walk x child
                      (append rel (list nm)) (append abs (list nm))))
              blame)]))
  (values (and g (walk g src '() (list (command-name src)))) gnames))

;; ---------------------------------------------------------------------------
;; The walk

;; resolve-transformer : command command x:node [guard] [fail]
;;                    → (values guard x:node) (both resolved)
;; fail : (or/c #f syntax?) string → escapes (raises)
(define (resolve-transformer src tgt xn [guard #f] [fail runtime-fail])
  (define uncovered '())      ; (list path class name), reversed
  (define total 0)
  (define (uncover! path class name)
    (set! uncovered (cons (list path class name) uncovered)))
  (define (count!) (set! total (add1 total)))
  (define-values (guard* gnames) (resolve-guard guard src fail))
  (define result (resolve-node src tgt xn '() gnames uncover! count! fail))
  (when (pair? uncovered)
    (fail #f
          (format
           "transformer does not cover its source spec\n  uncovered:\n~a\n  ~a of ~a items uncovered"
           (string-join
            (for/list ([u (in-list (reverse uncovered))])
              (format "    ~a → ~a ~a"
                      (spec-path->string (car u)) (cadr u) (caddr u)))
            "\n")
           (length uncovered) total)))
  (values guard* result))

(define (resolve-node cmd tcmd xn path gnames uncover! count! fail)
  (define here (append path (list (command-name cmd))))
  (define (fail! blame fmt . a)
    (fail blame (format "~a: ~a" (spec-path->string here) (apply format fmt a))))

  ;; items this node's guard tests are covered by the guard (DESIGN.md §3.6)
  (define gcell (hash-ref gnames (cdr here) #f))
  (define (guard-covers-flag? nm) (and gcell (hash-ref (car gcell) nm #f)))
  (define (guard-covers-arg? nm) (and gcell (hash-ref (cdr gcell) nm #f)))

  (define params (command-params cmd))
  (define positionals (command-positionals cmd))
  (define rst (command-rest cmd))
  (define subs (command-subcommands cmd))
  (define pnames (map param-name params))
  (define anames (map positional-name positionals))
  (define snames (map command-name subs))

  (define tparams (command-params tcmd))
  (define tpositionals (command-positionals tcmd))
  (define trst (command-rest tcmd))
  (define tsubs (command-subcommands tcmd))
  (define tpnames (map param-name tparams))
  (define tanames (map positional-name tpositionals))
  (define tsnames (map command-name tsubs))

  ;; unknown source selections (DESIGN.md §4.2)
  (for ([e (in-list (x:node-flags xn))])
    (unless (memq (car e) pnames)
      (fail! (action-blame (cdr e)) "no flag ~a here~a"
             (car e) (nearest-note (car e) pnames))))
  (for ([e (in-list (x:node-args xn))])
    (unless (memq (car e) anames)
      (fail! (action-blame (cdr e)) "no positional ~a here~a"
             (car e) (nearest-note (car e) anames))))
  (let ([re (x:node-rst xn)])
    (when re
      (cond
        [(not rst)
         (fail! (action-blame (cdr re)) "there is no rest clause here")]
        [(not (eq? (car re) (rest-args-name rst)))
         (fail! (action-blame (cdr re)) "the rest clause here is named ~a, not ~a"
                (rest-args-name rst) (car re))])))
  (for ([m (in-list (x:node-merges xn))])
    (for ([mn (in-list (x:merge-members m))])
      (unless (memq mn pnames)
        (fail! (x:merge-blame m) "merge member ~a is not a flag here~a"
               mn (nearest-note mn pnames)))))
  (for ([e (in-list (x:node-subs xn))])
    (unless (memq (car e) snames)
      (fail! (action-blame (cdr e)) "no subcommand ~a here~a"
             (car e) (nearest-note (car e) snames))))

  ;; claims: exactly one action per source item (duplicate clauses for one
  ;; name are caught by the macro; flag-vs-merge overlaps are caught here)
  (define claims (make-hasheq))
  (for ([e (in-list (x:node-flags xn))])
    (hash-set! claims (car e) (cdr e)))
  (for ([m (in-list (x:node-merges xn))])
    (for ([mn (in-list (x:merge-members m))])
      (when (hash-ref claims mn #f)
        (fail! (x:merge-blame m) "flag ~a is claimed twice" mn))
      (hash-set! claims mn m)))
  (define aclaims (make-hasheq))
  (for ([e (in-list (x:node-args xn))])
    (hash-set! aclaims (car e) (cdr e)))

  ;; target reference resolution + at-most-one-clause-per-target-item
  (define (resolve-target-param nm blame who)
    (or (for/first ([tp (in-list tparams)] #:when (eq? (param-name tp) nm)) tp)
        (fail! blame "~a: the target has no flag ~a here~a"
               who nm (nearest-note nm tpnames))))
  (define (resolve-target-positional nm blame who)
    (or (for/first ([ta (in-list tpositionals)]
                    #:when (eq? (positional-name ta) nm))
          ta)
        (fail! blame "~a: the target has no positional ~a here~a"
               who nm (nearest-note nm tanames))))
  (define timage-flags (make-hasheq))   ; target flag name → #t
  (define timage-args (make-hasheq))    ; target positional name → #t
  (define (claim-target-flag! tp blame)
    (when (hash-ref timage-flags (param-name tp) #f)
      (fail! blame "two clauses map to target flag ~a" (param-name tp)))
    (hash-set! timage-flags (param-name tp) #t))
  (define (claim-target-positional! ta blame)
    (when (hash-ref timage-args (positional-name ta) #f)
      (fail! blame "two clauses map to target positional ~a"
             (positional-name ta)))
    (hash-set! timage-args (positional-name ta) #t))

  ;; flags: resolve keep/map to the target param, check value crossing
  (define flags*
    (for/fold ([acc '()] #:result (reverse acc))
              ([sp (in-list params)])
      (count!)
      (define nm (param-name sp))
      (define act (hash-ref claims nm #f))
      (cond
        [(not act)
         (cond
           [(guard-covers-flag? nm) (cons (cons nm (x:absorb)) acc)]
           [else (uncover! here 'flag nm) acc])]
        [(x:drop? act) (cons (cons nm act) acc)]
        [(x:merge? act) acc]  ; carried in merges*; coverage is satisfied
        [(x:keep? act)
         (define tp (resolve-target-param nm (x:keep-blame act)
                                          (format "flag ~a: keep" nm)))
         (claim-target-flag! tp (x:keep-blame act))
         (unless (param-shape-equal? sp tp)
           (fail! (x:keep-blame act)
                  "flag ~a: the target's flag ~a has a different shape; map it explicitly with #:value"
                  nm nm))
         (cons (cons nm (x:map tp #f (x:keep-blame act))) acc)]
        [else ; x:map with a target name
         (define tp (resolve-target-param (x:map-item act) (x:map-blame act)
                                          (format "flag ~a" nm)))
         (claim-target-flag! tp (x:map-blame act))
         (unless (or (x:map-value-fn act) (param-shape-equal? sp tp))
           (fail! (x:map-blame act)
                  "flag ~a: source and target shapes differ; #:value is required"
                  nm))
         (cons (cons nm (x:map tp (x:map-value-fn act) (x:map-blame act)))
               acc)])))

  ;; merges: resolve the target flag; #:by always crosses the values
  (define merges*
    (for/list ([m (in-list (x:node-merges xn))])
      (define tp (resolve-target-param (x:merge-item m) (x:merge-blame m)
                                       "merge"))
      (claim-target-flag! tp (x:merge-blame m))
      (x:merge (x:merge-members m) tp (x:merge-by m) (x:merge-blame m))))

  ;; positionals
  (define args*
    (for/fold ([acc '()] #:result (reverse acc))
              ([sa (in-list positionals)])
      (count!)
      (define nm (positional-name sa))
      (define act (hash-ref aclaims nm #f))
      (define (resolve-arg tnm blame who vf)
        (define ta (resolve-target-positional tnm blame who))
        (claim-target-positional! ta blame)
        (when (and (variadic-arity? (positional-arity sa))
                   (not (variadic-arity? (positional-arity ta))))
          (fail! blame
                 "variadic positional ~a cannot map to single-value target positional ~a"
                 nm tnm))
        (unless (or vf (positional-shape-equal? sa ta))
          (fail! blame
                 "positional ~a: source and target shapes differ; #:value is required"
                 nm))
        (x:map ta vf blame))
      (cond
        [(not act)
         (cond
           [(guard-covers-arg? nm) (cons (cons nm (x:absorb)) acc)]
           [else (uncover! here 'arg nm) acc])]
        [(x:drop? act) (cons (cons nm act) acc)]
        [(x:keep? act)
         (cons (cons nm (resolve-arg nm (x:keep-blame act)
                                     (format "positional ~a: keep" nm) #f))
               acc)]
        [else
         (cons (cons nm (resolve-arg (x:map-item act) (x:map-blame act)
                                     (format "positional ~a" nm)
                                     (x:map-value-fn act)))
               acc)])))

  ;; rest: both sides are uninterpreted string lists, so only existence and
  ;; the referenced name are checked; #:value stays optional
  (define rest*
    (cond
      [(not rst) #f]
      [else
       (count!)
       (define nm (rest-args-name rst))
       (define re (x:node-rst xn))
       (define act (and re (cdr re)))
       (define (resolve-rest tnm blame who vf)
         (unless trst
           (fail! blame "~a: the target has no rest clause here" who))
         (unless (eq? tnm (rest-args-name trst))
           (fail! blame "~a: the target rest clause is named ~a, not ~a"
                  who (rest-args-name trst) tnm))
         (cons nm (x:map trst vf blame)))
       (cond
         [(not act) (uncover! here 'rest nm) #f]
         [(x:drop? act) (cons nm act)]
         [(x:keep? act)
          (resolve-rest nm (x:keep-blame act)
                        (format "rest ~a: keep" nm) #f)]
         [else
          (resolve-rest (x:map-item act) (x:map-blame act)
                        (format "rest ~a" nm) (x:map-value-fn act))])]))

  ;; target totality: the target's required surface must be produced
  (for ([tp (in-list tparams)])
    (when (and (param-required? tp)
               (not (hash-ref timage-flags (param-name tp) #f)))
      (fail! (x:node-blame xn)
             "required target flag ~a is not produced by any clause"
             (param-name tp))))
  (for ([ta (in-list tpositionals)])
    (define-values (lo _hi) (arity->bounds (positional-arity ta)))
    (when (and (>= lo 1)
               (not (hash-ref timage-args (positional-name ta) #f)))
      (fail! (x:node-blame xn)
             "required target positional ~a is not produced by any clause"
             (positional-name ta))))
  (for ([g (in-list (command-groups tcmd))])
    (when (eq? (group-mode g) 'one-of)
      (unless (for/or ([m (in-list (group-members g))])
                (or (hash-ref timage-flags m #f)
                    (hash-ref timage-args m #f)))
        (fail! (x:node-blame xn)
               "target one-of group (~a) has no member produced by any clause"
               (group-members g)))))
  (when (and (null? subs)
             (pair? tsubs)
             (not (command-default-subcommand tcmd))
             (null? tpositionals)
             (not trst))
    (fail! (x:node-blame xn)
           "the target node requires a subcommand, but the source node is a leaf"))

  ;; subcommands: pair source children with target children
  (define subs*
    (for/fold ([acc '()] #:result (reverse acc))
              ([sc (in-list subs)])
      (count!)
      (define e (assq (command-name sc) (x:node-subs xn)))
      (cond
        [(not e) (uncover! here 'subcommand (command-name sc)) acc]
        [(x:node-drop (cdr e)) (cons e acc)]
        [else
         (define cxn (cdr e))
         (define tname (or (x:node-rename cxn) (command-name sc)))
         (define tchild
           (or (for/first ([ts (in-list tsubs)]
                           #:when (eq? (command-name ts) tname))
                 ts)
               (fail! (x:node-blame cxn)
                      "the target has no subcommand ~a here~a"
                      tname (nearest-note tname tsnames))))
         (cons (cons (command-name sc)
                     (resolve-node sc tchild cxn here gnames
                                   uncover! count! fail))
               acc)])))

  (x:node (command-name tcmd) #f
          flags* args* rest* merges* subs* (x:node-blame xn)))
