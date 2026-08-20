#lang racket/base

;; The target spec for the transformer tests: a recognizable slice of jj
;; (jujutsu), independently declared — the transformer only references it.

(require cli-spec)

(provide jj-spec)

(define jj-spec
  (cmd 'jj
    #:doc "a Git-compatible VCS"
    (flag 'repository 'dir #:aliases '(-R --repository)
          #:global? #t
          #:doc "path to the repository")

    (subcommand 'st
      #:doc "show working copy status"
      (flag 'format (enum "short" "long") #:arity '?)
      (flag 'template 'string)
      (arg 'pathspec 'path #:arity '*))

    (subcommand 'log
      #:doc "show revision history"
      (flag 'limit 'int #:aliases '(-n --limit))
      (flag 'author 'string #:repeat 'list)
      (arg 'revset 'string #:arity '?)
      (rest 'paths #:after 'double-dash))))
