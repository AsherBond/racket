#lang racket/base

(require compiler/embed
         racket/file
	 racket/format
	 racket/system
         racket/port
         launcher
         compiler/distribute
         (only-in pkg/lib installed-pkg-names))

(define skip-mred? (and (getenv "PLT_TEST_NO_GUI")
                        #t))

(define (test expect f/label . args)
  (define r (apply (if (procedure? f/label)
                       f/label
                       values)
                   args))
  (unless (equal? expect r)
    (error "failed\n")))

(define (mk-dest-bin mred?)
  (case (system-type)
    [(windows) "e.exe"]
    [(unix) "e"]
    [(macosx) (if mred?
                  "e.app"
                  "e")]))

(define (mk-dest mred?)
  (build-path (find-system-path 'temp-dir) 
              (mk-dest-bin mred?)))

(define mz-dest (mk-dest #f))
(define mr-dest (mk-dest #t))

(define dist-dir (build-path (find-system-path 'temp-dir)
                             "e-dist"))
(define dist-mz-exe (build-path
                     (case (system-type)
                       [(windows) 'same]
                       [else "bin"])
                     (mk-dest-bin #f)))
(define dist-mred-exe (build-path
                       (case (system-type)
                         [(windows macosx) 'same]
                         [else "bin"])
                       (mk-dest-bin #t)))

(define (call-with-retries thunk)
  (let loop ([sleep-time 0.01])
    (with-handlers* ([exn:fail:filesystem? (lambda (exn)
                                             ;; Accommodate Windows background tasks,
                                             ;; like anti-virus software and indexing,
                                             ;; that can prevent an ".exe" from being deleted
                                             (if (= sleep-time 1.0)
                                                 (raise exn)
                                                 (begin
                                                   (sleep sleep-time)
                                                   (loop (* 2 sleep-time)))))])
      (thunk))))

(define (printf/flush . args)
  (printf "~a " (~r #:min-width 10 #:precision '(= 2) (/ (current-process-milliseconds 'subprocesses) 1000.)))
  (apply printf args)
  (flush-output))

(define (prepare exe src)
  (printf/flush "Making ~a with ~a...\n" exe src)
  (when (file-exists? exe)
    (call-with-retries (lambda () (delete-file exe)))))

(define (try-one-exe exe expect mred?)
  (printf/flush "Running ~a\n" exe)
  (let ([plthome (getenv "PLTHOME")]
	[collects (getenv "PLTCOLLECTS")]
        [out (open-output-string)])
    (define temp-home-dir (make-temporary-file "racket-tmp-home~a" 'directory))
    ;; Try to hide usual collections:
    (parameterize ([current-environment-variables
                    (environment-variables-copy
                     (current-environment-variables))])
      (putenv "PLTUSERHOME" (path->string temp-home-dir))
      (when plthome
        (putenv "PLTHOME" (path->string (build-path (find-system-path 'temp-dir) "NOPE"))))
      (when collects
        (putenv "PLTCOLLECTS" (path->string (build-path (find-system-path 'temp-dir) "NOPE"))))
      ;; Execute:
      (parameterize ([current-directory (find-system-path 'temp-dir)])
        (when (file-exists? "stdout")
          (delete-file "stdout"))
        (let ([path (if (and mred? (eq? 'macosx (system-type)))
                        (let-values ([(base name dir?) (split-path exe)])
                          (build-path exe "Contents" "MacOS"
                                      (path-replace-suffix name #"")))
                        exe)])
          (test #t
                path
                (parameterize ([current-output-port out])
			      (system* path))))))
    (call-with-retries
     (lambda ()
       (delete-directory/files temp-home-dir)))
    (let ([stdout-file (build-path (find-system-path 'temp-dir) "stdout")])
      (if (file-exists? stdout-file)
          (test expect with-input-from-file stdout-file
                (lambda () (read-string 5000)))
          (test expect get-output-string out)))))
  
(define (try-exe exe expect mred? [dist-hook void] #:dist? [dist? #t] . collects)
  (try-one-exe exe expect mred?)
  (when dist?
    ;; Build a distribution directory, and try that, too:
    (printf/flush " ... from distribution ...\n")
    (when (directory-exists? dist-dir)
      (call-with-retries
       (lambda ()
	 (delete-directory/files dist-dir))))
    (assemble-distribution dist-dir (list exe) #:copy-collects collects)
    (dist-hook)
    (try-one-exe (build-path dist-dir
                             (if mred?
                                 dist-mred-exe
                                 dist-mz-exe))
                 expect mred?)
    (when (directory-exists? dist-dir)
      (call-with-retries
       (lambda ()
         (delete-directory/files dist-dir))))))

(define (base-compile e)
  (parameterize ([current-namespace (make-base-namespace)])
    (compile e)))
(define (kernel-compile e)
  (parameterize ([current-namespace (make-base-empty-namespace)])
    (namespace-require ''#%kernel)
    (compile e)))

(define (mz-tests mred?)
  (define dest (if mred? mr-dest mz-dest))
  (define (flags s)
    (string-append "-" s))
  (define (one-mz-test filename expect literal?
                       #:only-via-path? [only-via-path? #f])
    (unless only-via-path?
      ;; Try simple mode: one module, launched from cmd line:
      (prepare dest filename)
      (make-embedding-executable 
       dest mred? #f
       `((#t (lib ,filename "tests" "compiler" "embed")))
       null
       #f
       `(,(flags "l") ,(string-append "tests/compiler/embed/" filename)))
      (try-exe dest expect mred?)

      ;; As a launcher:
      (prepare dest filename)
      ((if mred? make-gracket-launcher make-racket-launcher)
       (list "-l" (string-append "tests/compiler/embed/" filename))
       dest)
      (try-exe dest expect mred? #:dist? #f)

      ;; Try explicit prefix:
      (printf/flush ">>>explicit prefix\n")
      (let ([w/prefix
             (lambda (pfx)
               (prepare dest filename)
               (make-embedding-executable 
                dest mred? #f
                `((,pfx (lib ,filename "tests" "compiler" "embed"))
                  (#t (lib "scheme/init")))
                null
                #f
                `(,(flags "lne") 
                  "scheme/base"
                  ,(format "(require '~a~a)" 
                           (or pfx "")
                           (regexp-replace #rx"[.].*$" filename ""))))
               (try-exe dest expect mred?))])
        (w/prefix #f)
        (w/prefix 'before:)))

    (when (or literal?
              only-via-path?)
      (define main-mod-name
        `'',(string->symbol (regexp-replace #rx"[.].*$" filename "")))
      
      ;; Try full path, and use literal S-exp to start
      (printf/flush ">>>literal sexp\n")
      (prepare dest filename)
      (let ([path (build-path (collection-path "tests" "compiler" "embed") filename)])
        (make-embedding-executable 
         dest mred? #f
         `((#f ,path))
         null
         (base-compile
          `(namespace-require ,main-mod-name))
         `(,(flags ""))))
      (try-exe dest expect mred?)
      
      ;; Use `file' form:
      (printf/flush ">>>file\n")
      (prepare dest filename)
      (let ([path (build-path (collection-path "tests" "compiler" "embed") filename)])
        (make-embedding-executable 
         dest mred? #f
         `((#f (file ,(path->string path))))
         null
         (base-compile
          `(namespace-require ,main-mod-name))
         `(,(flags ""))))
      (try-exe dest expect mred?)

      ;; Use relative path
      (printf/flush ">>>relative path\n")
      (prepare dest filename)
      (parameterize ([current-directory (collection-path "tests" "compiler" "embed")])
        (make-embedding-executable 
         dest mred? #f
         `((#f ,filename))
         null
         (base-compile
          `(namespace-require ,main-mod-name))
         `(,(flags ""))))
      (try-exe dest expect mred?))
    
    (when literal?
      ;; Try multiple modules
      (printf/flush ">>>multiple\n")
      (prepare dest filename)
      (make-embedding-executable 
       dest mred? #f
       `((#t (lib ,filename "tests" "compiler" "embed"))
         (#t (lib "embed-me3.rkt" "tests" "compiler" "embed")))
       null
       (base-compile
        `(begin
           (namespace-require '(lib "embed-me3.rkt" "tests" "compiler" "embed"))
           (namespace-require '(lib ,filename "tests" "compiler" "embed"))))
       `(,(flags "")))
      (try-exe dest (string-append "3 is here, too? #t\n" expect) mred?)

      ;; Try a literal file
      (printf/flush ">>>literal\n")
      (prepare dest filename)
      (let ([tmp (make-temporary-file)])
        (with-output-to-file tmp 
          #:exists 'truncate
          (lambda ()
            (write (kernel-compile
                    '(namespace-require ''#%kernel)))))
        (make-embedding-executable 
         dest mred? #f
         `((#t (lib ,filename "tests" "compiler" "embed")))
         (list 
          tmp
          (build-path (collection-path "tests" "compiler" "embed") "embed-me4.rktl"))
         `(with-output-to-file (build-path (find-system-path 'temp-dir) "stdout")
            (lambda () (display "... and more!\n"))
            'append)
         `(,(flags "l") ,(string-append "tests/compiler/embed/" filename)))
        (delete-file tmp))
      (try-exe dest (string-append 
                     "This is the literal expression 4.\n" 
                     "... and more!\n"
                     expect)
               mred?)))

  (one-mz-test "embed-me1.rkt" "This is 1\n" #t)
  (unless mred?
    (one-mz-test "embed-me1b.rkt" "This is 1b\n" #f)
    (one-mz-test "embed-me1c.rkt" "This is 1c\n" #f)
    (one-mz-test "embed-me1d.rkt" "This is 1d\n" #f)
    (one-mz-test "embed-me1e.rkt" "This is 1e\n" #f)
    (one-mz-test "embed-me1f.rkt" "This is 1f\n" #f)
    (one-mz-test "embed-me2.rkt" "This is 1\nThis is 2: #t\n" #t)
    (one-mz-test "embed-me13.rkt" "This is 14\n" #f)
    (one-mz-test "embed-me14.rkt" "This is 14\n" #f)
    (one-mz-test "embed-me15.rkt" "This is 15.\n" #f)
    (one-mz-test "embed-me17.rkt" "This is 17.\n" #f)
    (one-mz-test "embed-me18.rkt" "This is 18.\n" #f)
    (one-mz-test "embed-me19.rkt" "This is 19.\n" #f)
    (one-mz-test "embed-me21.rkt" "This is 21.\n" #f)
    (one-mz-test "embed-me31.rkt" "This is 31.\n" #f)
    (one-mz-test "embed-me34.rkt" "This is 34 in a second place.\n" #f)
    (one-mz-test "embed-me35.rkt" "'ok-35\n" #f)
    (one-mz-test "embed-me36.rkt" "'ok-36\n" #f)
    (one-mz-test "embed-me38.rkt" "\"found license\"\n" #f)
    (one-mz-test "embed-me40.rkt" "#t\n" #f #:only-via-path? #t)
    (one-mz-test "embed-me41.rkt" "'ok-41\n" #f))

  ;; Try unicode expr and cmdline:
  (when (equal? (locale-string-encoding) "UTF-8")
    (prepare dest "unicode")
    (make-embedding-executable 
     dest mred? #f
     '((#t scheme/base))
     null
     (base-compile
      '(begin 
         (require scheme/base)
         (eval '(define (out s)
                  (with-output-to-file (build-path (find-system-path 'temp-dir) "stdout")
                    (lambda () (printf s))
                    #:exists 'append)))
         (out "\uA9, \u7238, and \U1D670\n")))
     `(,(flags "ne") "(out \"\u7237...\U1D671\n\")"))
    (try-exe dest "\uA9, \u7238, and \U1D670\n\u7237...\U1D671\n" mred?)))

(define (try-basic)
  (mz-tests #f)
  (unless skip-mred?
    (mz-tests #t)
    (begin
      (prepare mr-dest "embed-me5.rkt")
      (make-embedding-executable 
       mr-dest #t #f
       `((#t (lib "embed-me5.rkt" "tests" "compiler" "embed")))
       null
       #f
       `("-l" "tests/compiler/embed/embed-me5.rkt"))
      (try-exe mr-dest "This is 5: #<class:button%>\n" #t))))

(define (try-embedded-dlls)
  (prepare mz-dest "embed-me1.rkt")
  (make-embedding-executable 
   mz-dest #f #f
   `((#t (lib "embed-me1.rkt" "tests" "compiler" "embed")))
   '()
   #f
   `("-l" "tests/compiler/embed/embed-me1.rkt")
   '((embed-dlls? . #t)))
  (try-exe mz-dest "This is 1\n" #t)

  (unless skip-mred?
    (prepare mr-dest "embed-me5.rkt")
    (make-embedding-executable 
     mr-dest #t #f
     `((#t (lib "embed-me5.rkt" "tests" "compiler" "embed")))
     '()
     #f
     `("-l" "tests/compiler/embed/embed-me5.rkt")
     '((embed-dlls? . #t)))
    (try-exe mr-dest "This is 5: #<class:button%>\n" #t)))

;; Try the raco interface:
(require setup/dirs
	 mzlib/file
         compiler/find-exe)
(define (add-suffixes s)
  (define me (path-replace-suffix (find-exe) #""))
  (define ending (regexp-match #rx#"(?i:racket([cs3mgbc]*))$" me))
  (define s2 (string-append s (bytes->string/utf-8 (cadr ending))))
  (if (eq? 'windows (system-type))
      (string-append s2 ".exe")
      s2))
(define mzc (build-path (find-console-bin-dir) (add-suffixes "mzc")))
(define raco (build-path (find-console-bin-dir) (add-suffixes "raco")))

(define (system+ . args)
  (printf/flush "> ~a\n" (car (reverse args)))
  (unless (apply system* args)
    (error 'system+ "command failed ~s" args)))

(define (short-mzc-tests mred?)
  (parameterize ([current-directory (find-system-path 'temp-dir)])

    ;; raco exe
    (system+ raco
             "exe"
	     "-o" (path->string (mk-dest mred?))
	     (if mred? "--gui" "--")
	     (path->string (build-path (collection-path "tests" "compiler" "embed") "embed-me1.rkt")))
    (try-exe (mk-dest mred?) "This is 1\n" mred?)

    ;; raco exe on a module with a `main' submodule
    (system+ raco
             "exe"
	     "-o" (path->string (mk-dest mred?))
	     (if mred? "--gui" "--")
	     (path->string (build-path (collection-path "tests" "compiler" "embed") "embed-me16.rkt")))
    (try-exe (mk-dest mred?) "This is 16.\n" mred?)))

(define (mzc-tests mred?)
  (short-mzc-tests mred?)
  (parameterize ([current-directory (find-system-path 'temp-dir)])

    ;; raco exe
    (system+ raco
             "exe"
	     "-o" (path->string (mk-dest mred?))
	     (if mred? "--gui" "--")
	     (path->string (build-path (collection-path "tests" "compiler" "embed") "embed-me1.rkt")))
    (try-exe (mk-dest mred?) "This is 1\n" mred?)

    ;; raco exe on a module with a `main' submodule
    (system+ raco
             "exe"
	     "-o" (path->string (mk-dest mred?))
	     (if mred? "--gui" "--")
	     (path->string (build-path (collection-path "tests" "compiler" "embed") "embed-me16.rkt")))
    (try-exe (mk-dest mred?) "This is 16.\n" mred?)

    ;; raco exe on a module with a `main' submodule+
    (system+ raco
             "exe"
	     "-o" (path->string (mk-dest mred?))
	     (if mred? "--gui" "--")
	     (path->string (build-path (collection-path "tests" "compiler" "embed") "embed-me20.rkt")))
    (try-exe (mk-dest mred?) "This is 20.\n" mred?)

    ;; raco exe on a module with a `configure-runtime' submodule
    (system+ raco
             "exe"
	     "-o" (path->string (mk-dest mred?))
	     (if mred? "--gui" "--")
	     (path->string (build-path (collection-path "tests" "compiler" "embed") "embed-me29.rkt")))
    (try-exe (mk-dest mred?) "'inside\n" mred?)

    ;; raco exe on a module with a submodule that references another file's submodule
    (system+ raco
             "exe"
	     "-o" (path->string (mk-dest mred?))
	     (if mred? "--gui" "--")
	     (path->string (build-path (collection-path "tests" "compiler" "embed") "embed-me22.rkt")))
    (try-exe (mk-dest mred?) "Configure!\nThis is 22.\n" mred?)

    ;; raco exe on a module with serialization
    (system+ raco
             "exe"
	     "-o" (path->string (mk-dest mred?))
	     (if mred? "--gui" "--")
	     (path->string (build-path (collection-path "tests" "compiler" "embed") "embed-me23.rkt")))
    (try-exe (mk-dest mred?) "1\n2\n" mred?)

    ;; raco exe on a module with `place`
    (system+ raco
             "exe"
	     "-o" (path->string (mk-dest mred?))
	     (if mred? "--gui" "--")
	     (path->string (build-path (collection-path "tests" "compiler" "embed") "embed-me28.rkt")))
    (try-exe (mk-dest mred?) "28\n" mred?)

    ;; raco exe on a `require`d module with `place` --- test supplied by Chris Vig
    (system+ raco
             "exe"
	     "-o" (path->string (mk-dest mred?))
	     (if mred? "--gui" "--")
	     (path->string (build-path (collection-path "tests" "compiler" "embed") "embed-me30.rkt")))
    (try-exe (mk-dest mred?) "Hello from a place!\n" mred?)

    ;; raco exe on a module with a `main' submodule+ with a define-runtime-path within it
    (system+ raco
             "exe"
	     "-o" (path->string (mk-dest mred?))
	     (if mred? "--gui" "--")
	     (path->string (build-path (collection-path "tests" "compiler" "embed") "embed-me39.rkt")))
    (try-exe (mk-dest mred?) "found license\n" mred?)

    ;; raco exe --launcher
    (printf/flush ">>launcher\n")
    (system+ raco
             "exe"
             "--launcher"
	     "-o" (path->string (mk-dest mred?))
	     (if mred? "--gui" "--")
	     (path->string (build-path (collection-path "tests" "compiler" "embed") "embed-me1.rkt")))
    (try-exe (mk-dest mred?) "This is 1\n" mred? #:dist? #f)

    ;; the rest use mzc...

    (printf/flush ">>mzc\n")
    (system+ mzc 
	     (if mred? "--gui-exe" "--exe")
	     (path->string (mk-dest mred?))
	     (path->string (build-path (collection-path "tests" "compiler" "embed") "embed-me1.rkt")))
    (try-exe (mk-dest mred?) "This is 1\n" mred?)

    (define (check-collection-path prog lib in-main?)
      ;; Check that etc.rkt isn't found if it's not included:
      (printf/flush ">>not included\n")
      (system+ mzc 
               (if mred? "--gui-exe" "--exe")
               (path->string (mk-dest mred?))
               (path->string (build-path (collection-path "tests" "compiler" "embed") prog)))
      (try-exe (mk-dest mred?) "This is 6\nno etc.ss\n" mred?)

      ;; And it is found if it is included:
      (printf/flush ">>included\n")
      (system+ mzc 
               (if mred? "--gui-exe" "--exe")
               (path->string (mk-dest mred?))
               "++lib" lib
               (path->string (build-path (collection-path "tests" "compiler" "embed") prog)))
      (try-exe (mk-dest mred?) "This is 6\n#t\n" mred?)

      ;; Or, it's found if we set the collection path:
      (printf/flush ">>set coll path\n")
      (system+ mzc 
               (if mred? "--gui-exe" "--exe")
               (path->string (mk-dest mred?))
               "--collects-path"
               (path->string (find-collects-dir))
               (path->string (build-path (collection-path "tests" "compiler" "embed") prog)))
      ;; Don't try a distribution for this one:
      (try-one-exe (mk-dest mred?) (if in-main? "This is 6\n#t\n" "This is 6\nno etc.ss\n") mred?)

      ;; Or, it's found if we set the collection path and the config path (where the latter
      ;; finds links for packages):
      (printf/flush ">>set coll path plus config\n")
      (system+ mzc 
               (if mred? "--gui-exe" "--exe")
               (path->string (mk-dest mred?))
               "--collects-path"
               (path->string (find-collects-dir))
               "--config-path"
               (path->string (find-config-dir))
               (path->string (build-path (collection-path "tests" "compiler" "embed") prog)))
      ;; Don't try a distribution for this one:
      (try-one-exe (mk-dest mred?) "This is 6\n#t\n" mred?)

      ;; Try --collects-dest mode
      (printf/flush ">>--collects-dest\n")
      (system+ mzc 
               (if mred? "--gui-exe" "--exe")
               (path->string (mk-dest mred?))
               "++lib" lib
               "--collects-dest" "cts"
               "--collects-path" "cts"
               (path->string (build-path (collection-path "tests" "compiler" "embed") prog)))
      (try-exe (mk-dest mred?) "This is 6\n#t\n" mred? void "cts") ; <- cts copied to distribution
      (delete-directory/files "cts")
      (parameterize ([current-error-port (open-output-nowhere)])
        (test #f system* (mk-dest mred?))))
    (check-collection-path "embed-me6b.rkt" "racket/fixnum.rkt" #t)
    (check-collection-path "embed-me6.rkt" "mzlib/etc.rkt"
                           ;; "mzlib" is found via the "collects" path
                           ;; if it is accessible via the default
                           ;; collection-links configuration, which is
                           ;; essentially the same as being in installation
                           ;; scope:
                           (member "compatibility-lib"
                                   (installed-pkg-names #:scope 'installation)))

    (void)))

(define (try-mzc)
  (mzc-tests #f)
  (unless skip-mred?
    (short-mzc-tests #t)))

(require dynext/file)
(define (extension-test mred?)
  (parameterize ([current-directory (find-system-path 'temp-dir)])
    
    (define obj-file
      (build-path (find-system-path 'temp-dir) (append-object-suffix "embed-me8")))

    (define ext-base-dir
      (build-path (find-system-path 'temp-dir)
                  (let ([l (use-compiled-file-paths)])
                    (if (pair? l)
                        (car l)
                        "compiled"))))

    (define ext-dir
      (build-path ext-base-dir
                  "native"
                  (system-library-subpath)))

    (define ext-file
      (build-path ext-dir (append-extension-suffix "embed-me8_rkt")))

    (define ss-file
      (build-path (find-system-path 'temp-dir) "embed-me9.rkt"))

    (make-directory* ext-dir)
    
    (system+ mzc 
             "--cc"
             "-d" (path->string (path-only obj-file))
             (path->string (build-path (collection-path "tests" "compiler" "embed") "embed-me8.c")))
    (system+ mzc 
             "--ld"
             (path->string ext-file)
             (path->string obj-file))

    (when (file-exists? ss-file)
      (delete-file ss-file))
    (copy-file (build-path (collection-path "tests" "compiler" "embed") "embed-me9.rkt")
               ss-file)

    (system+ mzc 
             (if mred? "--gui-exe" "--exe")
             (path->string (mk-dest mred?))
             (path->string ss-file))

    (delete-file ss-file)

    (try-exe (mk-dest mred?) "Hello, world!\n" mred? (lambda ()
                                                       (delete-directory/files ext-base-dir)))

    ;; openssl, which needs extra binaries under Windows
    (system+ mzc 
             (if mred? "--gui-exe" "--exe")
             (path->string (mk-dest mred?))
             (path->string (build-path (collection-path "tests" "compiler" "embed") "embed-me10.rkt")))
    (try-exe (mk-dest mred?) "#t\n" mred?)))

(define (try-extension)
  (extension-test #f)
  (unless skip-mred?
    (extension-test #t)))

(define (try-gracket)
  (unless skip-mred?
    ;; A GRacket-specific test with mzc:
    (parameterize ([current-directory (find-system-path 'temp-dir)])
      (system+ mzc 
               "--gui-exe"
               (path->string (mk-dest #t))
               (path->string (build-path (collection-path "tests" "compiler" "embed") "embed-me5.rkt")))
      (try-exe (mk-dest #t) "This is 5: #<class:button%>\n" #t))))

;; Try including source that needs a reader extension

(define (try-reader-test 12? mred? ss-file? ss-reader?)
  ;; actual "11" files use ".rkt", actual "12" files use ".ss"
  (define dest (mk-dest mred?))
  (define filename (format (if ss-file?
                               "embed-me~a.ss"
                               "embed-me~a.rkt")
                           (if 12? "12" "11")))
  (define (flags s)
    (string-append "-" s))

  (printf/flush "Trying ~s ~s ~s ~s...\n" (if 12? "12" "11") mred? ss-file? ss-reader?)

  (create-embedding-executable 
   dest
   #:modules `((#t (lib ,filename "tests" "compiler" "embed")))
   #:cmdline `(,(flags "l") ,(string-append "tests/compiler/embed/" filename))
   #:src-filter (lambda (f)
                  (let-values ([(base name dir?) (split-path f)])
                    (equal? name (path-replace-suffix (string->path filename) 
                                                      (if 12? #".ss" #".rkt")))))
   #:get-extra-imports (lambda (f code)
                         (let-values ([(base name dir?) (split-path f)])
                           (if (equal? name (path-replace-suffix (string->path filename) 
                                                                 (if 12? #".ss" #".rkt")))
                               `((lib ,(format (if ss-reader?
                                                   "embed-me~a-rd.ss"
                                                   "embed-me~a-rd.rkt")
                                               (if 12? "12" "11"))
                                      "tests" 
                                      "compiler"
                                      "embed"))
                               null)))
   #:mred? mred?)

  (putenv "ELEVEN" "eleven")
  (try-exe dest "It goes to eleven!\n" mred?)
  (putenv "ELEVEN" "done"))

(define (try-reader)
  (for ([12? (in-list '(#f #t))])
    (try-reader-test 12? #f #f #f)
    (unless skip-mred?
      (try-reader-test 12? #t #f #f))
    (try-reader-test 12? #f #t #f)
    (try-reader-test 12? #f #f #t)))

;; ----------------------------------------

(define (try-lang)
  (system+ raco
           "exe"
           "-o" (path->string (mk-dest #f))
           "++lang" "racket/base"
           (path->string (build-path (collection-path "tests" "compiler" "embed") "embed-me32.rkt")))
  (try-exe (mk-dest #f) "This is 32.\n" #f)
  
  (system+ raco
           "exe"
           "-o" (path->string (mk-dest #f))
           "++lang" "at-exp racket/base"
           (path->string (build-path (collection-path "tests" "compiler" "embed") "embed-me33.rkt")))
  (try-exe (mk-dest #f) "This is 33.\n" #f))

;; ----------------------------------------

(define (try-prefix)
  (system+ raco
           "exe"
           "-o" (path->string (mk-dest #f))
           "++named-lib"
           "basic:"
           "racket/base"
           "++named-file"
           "mine:"
           (path->string (build-path (collection-path "tests" "compiler" "embed") "embed-me37b.rkt"))
           (path->string (build-path (collection-path "tests" "compiler" "embed") "embed-me37.rkt")))
  (try-exe (mk-dest #f) "'(b mine:embed-me37b)\n'(a #%mzc:embed-me37)\n" #f)
  
  (system+ raco
           "exe"
           "-o" (path->string (mk-dest #f))
           "++named-lib"
           "basic:"
           "racket/base"
           "++named-file"
           "mine:"
           (path->string (build-path (collection-path "tests" "compiler" "embed") "embed-me37b.rkt"))
           "++named-file"
           "main:"
           (path->string (build-path (collection-path "tests" "compiler" "embed") "embed-me37.rkt"))
           (path->string (build-path (collection-path "tests" "compiler" "embed") "embed-me37.rkt")))
  (try-exe (mk-dest #f) "'(b mine:embed-me37b)\n'(a main:embed-me37)\n" #f))

;; ----------------------------------------

(define (try-source)
  (define (try-one file submod start result)
    (define mred? #f)
    (define dest (mk-dest mred?))
    
    (printf/flush "> ~a ~s from source\n" file submod)
    (create-embedding-executable
     dest
     #:modules `((#%mzc: ,(collection-file-path file "tests/compiler/embed") ,submod))
     #:configure-via-first-module? #t
     #:literal-expression
     (parameterize ([current-namespace (make-base-namespace)])
       (compile
        `(begin
          (namespace-require ',start))))
     #:src-filter (lambda (p) (or (equal? p (collection-file-path "embed-me25.rkt" "tests/compiler/embed"))
                             (equal? p (collection-file-path "embed-me26.rkt" "tests/compiler/embed"))
                             (equal? p (collection-file-path "embed-me27.rkt" "tests/compiler/embed"))))
     #:get-extra-imports (lambda (src mod)
                           (list 'racket/base/lang/reader)))
    
    (try-exe dest result mred?))
  
  (try-one "embed-me25.rkt" null ''|#%mzc:embed-me25| "10\n")
  (try-one "embed-me25.rkt" '(main) '(submod '|#%mzc:embed-me25| main) "10\n12\n")
  (try-one "embed-me25.rkt" '(submod) '(submod '|#%mzc:embed-me25| submod) "11\n")
  (try-one "embed-me26.rkt" null ''|#%mzc:embed-me26| "'y\n10\n")
  (try-one "embed-me26.rkt" '(submod) '(submod '|#%mzc:embed-me26| submod) "11\n")
  (try-one "embed-me26.rkt" '(main) '(submod '|#%mzc:embed-me26| main) "'y\n10\n12\n"))

;; ----------------------------------------

(define planet (build-path (find-console-bin-dir) (if (eq? 'windows (system-type))
                                                      "planet.exe"
                                                      "planet")))

(define (try-planet)
  (system+ raco "planet" "link" "racket-tester" "p1.plt" "1" "0"
           (path->string (collection-path "tests" "compiler" "embed" "embed-planet-1")))
  (system+ raco "planet" "link" "racket-tester" "p2.plt" "2" "2"
           (path->string (collection-path "tests" "compiler" "embed" "embed-planet-2")))

  (let ([go (lambda (path expected)
              (printf/flush "Trying planet ~s...\n" path)
              (let ([tmp (make-temporary-file)]
                    [dest (mk-dest #f)])
                (with-output-to-file tmp
                  #:exists 'truncate
                  (lambda ()
                    (printf "#lang racket/base (require ~s)\n" path)))
                (system+ mzc "--exe" (path->string dest) (path->string tmp))
                (try-exe dest expected #f)

                (delete-directory/files dest)

                (delete-file tmp)))])
    (go '(planet racket-tester/p1) "one\n")
    (go '(planet "racket-tester/p1:1") "one\n")
    (go '(planet "racket-tester/p1:1:0") "one\n")
    (go '(planet "racket-tester/p1:1:0/main.ss") "one\n")
    (go '(planet racket-tester/p2) "two\n")

    (go '(planet racket-tester/p1/alt) "one\nalt\n")
    (go '(planet racket-tester/p1/other) "two\nother\n")
    (go '(planet "private/sub.rkt" ("racket-tester" "p2.plt" 2 0)) "two\nsub\n")
    (go '(planet "private/sub.ss" ("racket-tester" "p2.plt" 2 0)) "two\nsub\n")
    (go '(planet "main.ss" ("racket-tester" "p2.plt" 2 0)) "two\n")

    (go '(planet racket-tester/p1/dyn-sub) "out\n")

    (void))
  
  (system+ raco "planet" "unlink" "racket-tester" "p1.plt" "1" "0")
  (system+ raco "planet" "unlink" "racket-tester" "p2.plt" "2" "2"))

;; ----------------------------------------

(define (try-*sl)
  (define (try-one src)
    (printf/flush "Trying ~a...\n" src)
    (define exe (path->string (mk-dest #f)))
    (system+ raco
             "exe"
             "-o" exe
             "--"
             (path->string (build-path (collection-path "tests" "compiler" "embed") src)))
    (try-exe exe "10\n" #f))

  (try-one "embed-bsl.rkt")
  (try-one "embed-bsla.rkt")
  (try-one "embed-isl.rkt")
  (try-one "embed-isll.rkt")
  (try-one "embed-asl.rkt"))

;; ----------------------------------------

(try-basic)
(try-mzc)
(when (eq? 'racket (system-type 'vm))
  (unless (eq? 'windows (system-type))
    (try-extension)))
(try-gracket)
(try-reader)
(try-lang)
(try-prefix)
(try-planet)
(try-*sl)
(try-source)
(when (eq? 'windows (system-type))
  (try-embedded-dlls))

;; ----------------------------------------
;; Make sure that embedding does not break future module declarations

(let ()
  (parameterize ([current-output-port (open-output-bytes)])
    (write-module-bundle
     #:modules (list (list #f (collection-file-path "embed-me24.rkt" "tests" "compiler" "embed")))))
  
  (parameterize ([read-accept-reader #t]
                 [current-namespace (make-base-namespace)])
    (eval (read (open-input-string "#lang racket 10")))))
