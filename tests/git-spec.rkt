#lang racket/base

;; Source specs for the transformer tests: the git slice from cli-spec's
;; DESIGN.md §5 (minus the custom revision type), plus a two-flag source
;; spec and the small target specs used to exercise the static errors.

(require cli-spec)

(provide git-spec tiny-spec tiny-target tiny-target2 tiny-req-target)

(define git-spec
  (cmd 'git
    #:doc "the stupid content tracker"
    (flag 'git-dir 'dir
          #:global? #t #:global-position 'before-subcommand
          #:env "GIT_DIR"
          #:doc "path to the repository")
    (flag 'paginate #:aliases '(-p --paginate) #:negatable? #t #:global? #t)

    (subcommand 'status
      #:doc "show the working tree status"
      (at-most-one
        (flag 'short #:aliases '(-s --short))
        (flag 'long #:aliases '(--long)))
      (flag 'porcelain (or-type 'nat (enum "v1" "v2")) #:arity '?)
      (arg 'pathspec 'path #:arity '*))

    (subcommand 'log
      #:doc "show commit logs"
      (flag 'n 'int #:aliases '(-n --max-count) #:metavar "N"
            #:doc "limit the number of commits")
      (flag 'oneline)
      (flag 'author 'string #:repeat 'list)
      (arg 'revision 'string #:arity '?)
      (rest 'paths #:after 'double-dash))

    (subcommand 'checkout #:aliases '(co)
      (one-of
        (flag 'branch 'string #:aliases '(-b))
        (arg 'target 'string))
      (arg 'pathspec 'path #:arity '*))))

(define tiny-spec
  (cmd 'tiny
    (flag 'a)
    (flag 'b)))

;; targets for the static-error tests
(define tiny-target
  (cmd 'T
    (flag 'a)
    (flag 'b2 'int)))

(define tiny-target2
  (cmd 'T2
    (flag 'a 'int)   ; same name as tiny-spec's a, different shape
    (flag 'b)))

(define tiny-req-target
  (cmd 'R
    (flag 'a)
    (flag 'must 'int #:required? #t)))
