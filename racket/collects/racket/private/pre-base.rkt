;; A sane "core" for finishing up the "racket/base" library

(module pre-base '#%kernel
  (#%require (for-syntax '#%kernel
                         "stx.rkt"
                         "qq-and-or.rkt"))
  (#%require "more-scheme.rkt"
             "misc.rkt"
             (all-except "define.rkt" define define-syntax define-for-syntax)
             "letstx-scheme.rkt"
             "kw.rkt"
             "define-struct.rkt"
             "reqprov.rkt"
             (prefix printing: "modbeg.rkt")
             "for.rkt"
             "map.rkt" ; shadows #%kernel bindings
             "member.rkt"
             "kernstruct.rkt"
             "performance-hint.rkt"
             "top-int.rkt"
             "collect.rkt"
             '#%builtin  ; so it's attached
             (for-syntax "kw.rkt"
                         "norm-define.rkt"))

  (define-values (new-apply-proc)
    (make-keyword-procedure
     (lambda (kws kw-args proc args . rest)
       (keyword-apply proc kws kw-args (apply list* args rest)))
     apply))

  (define-syntaxes (new-apply)
    ;; Convert (apply ...) without keyword args to primitive `apply',
    ;;  so that oher optimizations are available.
    (lambda (stx)
      (let-values ([(here) (quote-syntax here)])
        (if (symbol? (syntax-e stx))
            (datum->syntax here 'new-apply-proc stx)
            (let-values ([(l) (syntax->list stx)])
              (let-values ([(app) (if (if l
                                          (ormap (lambda (x) (keyword? (syntax-e x))) l)
                                          #t)
                                      'new-apply-proc
                                      'apply)]
                           [(fst) (car (syntax-e stx))])
                (datum->syntax
                 stx
                 (cons (datum->syntax here app fst fst)
                       (cdr (syntax-e stx)))
                 stx)))))))

  (define-values (new-keyword-apply)
    (make-keyword-procedure
     (lambda (kws kw-args proc orig-kws orig-kw-args args . rest)
       (let-values ([(kws kw-args)
                     (let loop ([kws kws] [kw-args kw-args]
                                [kws2 orig-kws] [kw-args2 orig-kw-args]
                                [swapped? #f])
                       (cond
                        [(null? kws) (values kws2 kw-args2)]
                        [(null? kws2) (values kws kw-args)]
                        [(keyword<? (car kws) (car kws2))
                         (let-values ([(res-kws res-kw-args)
                                       (loop (cdr kws) (cdr kw-args) kws2 kw-args2 #f)])
                           (values (cons (car kws) res-kws)
                                   (cons (car kw-args) res-kw-args)))]
                        [swapped?
                         (raise-mismatch-error
                          'keyword-apply
                          "keyword duplicated in list and direct keyword arguments: "
                          (car kws))]
                        [else (loop kws2 kw-args2 kws kw-args #t)]))])
         (keyword-apply proc kws kw-args (apply list* args rest))))
     keyword-apply))

  (define-syntaxes (new-define-syntax)
    (lambda (stx)
      (let-values ([(id rhs)
                    (normalize-definition stx (quote-syntax new-lambda) #t #t)]
                   [(def) (quote-syntax define-syntaxes)])
        (datum->syntax
         def
         (list def (list id) rhs)
         stx
         stx))))

  (define-syntaxes (new-define-for-syntax)
    (lambda (stx)
      (let-values ([(id rhs)
                    (normalize-definition stx (quote-syntax new-lambda) #t #t)]
                   [(def) (quote-syntax define-values-for-syntax)])
        (datum->syntax
         def
         (list def (list id) rhs)
         stx
         stx))))

  (define-values (double-flonum?) ; for symmetry with single-flonum?
    (lambda (x) (flonum? x)))

  (begin-encourage-inline
   (define-values (-random) ; more featureful than #%kernel's `random`
     (let ([random ; to get the right name
            (case-lambda
              [() (random)] ; no args, random float
              [(x) ; one arg, either random float with prng, or random integer
               ;; can just pass through to #%kernel's `random`, which will do the
               ;; necessary checking
               (random x)]
              [(x y)
               ;; two args, either max and prng, or min and max
               (cond [(exact-integer? y) ; min and max case
                      (unless (exact-integer? x)
                        (raise-argument-error 'random "exact-integer?" 0 x y))
                      (unless (< x y)
                        (raise-argument-error
                         'random
                         (string-append "(>/c " (number->string x) ")")
                         1 x y))
                      (let ([d (- y x)])
                        (unless (<= d 4294967087)
                          (raise-arguments-error
                           'random
                           "difference between arguments is greater than 4294967087"
                           "min" x "max" y))
                        (+ x (random d)))]
                     [(pseudo-random-generator? y) ; int and prng case
                      (unless (and (exact-integer? x)
                                   (<= 1 x 4294967087))
                        (raise-argument-error
                         'random "(integer-in 1 4294967087)" 0 x y))
                      (random x y)]
                     [else
                      (unless (exact-integer? x)
                        (raise-argument-error 'random "exact-integer?" 0 x y))
                      (raise-argument-error
                       'random
                       "(or/c exact-integer? pseudo-random-generator?)"
                       1 x y)])]
              [(min max prng) ; three args: min, max, and prng
               (unless (exact-integer? min)
                 (raise-argument-error 'random "exact-integer?" 0 min max prng))
               (unless (exact-integer? max)
                 (raise-argument-error 'random "exact-integer?" 1 min max prng))
               (unless (< min max)
                 (raise-argument-error
                  'random
                  (string-append "(>/c " (number->string min) ")")
                  1 min max prng))
               (let ([d (- max min)])
                 (unless (<= d 4294967087)
                   (raise-arguments-error
                    'random
                    "difference between first and second arguments is greater than 4294967087"
                    "min" min "max" max "rand-gen" prng))
                 (unless (pseudo-random-generator? prng)
                   (raise-argument-error
                    'random "pseudo-random-generator?" 2 min max prng))
                 (+ min (random d prng)))])])
       random)))

  (define-syntaxes (module-begin)
    (lambda (stx)
      (let-values ([(l) (syntax->list stx)])
        (if l
            (datum->syntax
             stx
             (if (ormap (lambda (e)
                          (and (stx-pair? e)
                               (let ([i (stx-car e)])
                                 (and (identifier? (stx-car e))
                                      (or (free-identifier=? i (quote-syntax module))
                                          (free-identifier=? i (quote-syntax module*)))))
                               (let ([p (stx-cdr e)])
                                 (and (stx-pair? p)
                                      (eq? (syntax-e (stx-car p)) 'configure-runtime)))))
                        (cdr l))
                 ;; There's a `configure-runtime' declaration already:
                 (cons (quote-syntax printing:module-begin) (cdr l))
                 (list* (quote-syntax printing:module-begin)
                        (quote-syntax (module configure-runtime '#%kernel
                                        (#%require racket/runtime-config)
                                        (configure #f)))
                        (cdr l)))
             stx)
            (raise-syntax-error #f "bad syntax" stx)))))

  (#%provide (all-from-except "more-scheme.rkt" old-case fluid-let)
             (all-from-except "misc.rkt" collection-path collection-file-path)
             (all-from "define.rkt")
             (all-from-except "letstx-scheme.rkt" -define -define-syntax -define-struct old-cond)
             (rename new-lambda lambda)
             (rename new-λ λ)
             (rename new-define define)
             (rename new-define-syntax define-syntax)
             (rename new-define-for-syntax define-for-syntax)
             (rename new-app #%app)
             (rename new-apply apply)
             new-apply-proc ; for access by Typed Racket
             (rename new-prop:procedure prop:procedure)
             (rename #%app #%plain-app)
             (rename lambda #%plain-lambda)
             (rename case-lambda case-λ)
             (rename #%module-begin #%plain-module-begin)
             (rename printing:module-begin #%printing-module-begin)
             (rename module-begin #%module-begin)
             (rename new:procedure-reduce-arity procedure-reduce-arity)
             (rename new:procedure-reduce-arity-mask procedure-reduce-arity-mask)
             (rename new:procedure->method procedure->method)
             (rename new:procedure-rename procedure-rename)
             (rename new:procedure-realm procedure-realm)
             (rename new:chaperone-procedure chaperone-procedure)
             (rename new:impersonate-procedure impersonate-procedure)
             (rename new:chaperone-procedure* chaperone-procedure*)
             (rename new:impersonate-procedure* impersonate-procedure*)
             (rename new:collection-path collection-path)
             (rename new:collection-file-path collection-file-path)
             (all-from-except '#%kernel lambda λ #%app #%module-begin apply prop:procedure
                              procedure-reduce-arity procedure-reduce-arity-mask
                              procedure->method procedure-rename procedure-realm
                              chaperone-procedure impersonate-procedure
                              chaperone-procedure* impersonate-procedure*
                              assq assv assoc
                              prop:incomplete-arity prop:method-arity-error
                              list-pair? interned-char? true-object?
                              random
                              collection-path collection-file-path
                              symbol->immutable-string
                              keyword->immutable-string
                              immutable-string? immutable-bytes? immutable-vector?
                              immutable-hash? immutable-box?
                              mutable-string? mutable-bytes? mutable-vector?
                              mutable-hash? mutable-box?
                              syntax-srcloc
                              vector-copy vector-append vector-set/copy
                              vector*-copy vector*-set/copy vector*-append
                              vector-extend vector*-extend)
             (all-from "reqprov.rkt")
             (all-from-except "for.rkt"
                              define-in-vector-like
                              define-:vector-like-gen
                              make-in-vector-like
                              stream-ref stream-via-prop?
                              stream? stream-empty? stream-first stream-rest
                              prop:stream in-stream empty-stream make-do-stream
                              split-for-body
                              expand-for-clause)
             (all-from "kernstruct.rkt")
             (all-from "member.rkt")
             #%top-interaction

             map for-each andmap ormap
             make-keyword-procedure
             (rename new-keyword-apply keyword-apply)
             procedure-keywords
             procedure-reduce-keyword-arity
             procedure-reduce-keyword-arity-mask
             (rename define-struct* define-struct)
             define-struct/derived
             struct/derived
             struct-field-index
             struct-copy
             double-flonum?
             (rename -random random)))
