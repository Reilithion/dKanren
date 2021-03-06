#lang racket/base
(provide
  term?
  eval-term
  initial-env
  )

(require
  racket/list
  racket/match
  racket/set
  )

(module+ test
  (require
    rackunit
    ))

(define (quotable? v)
  (match v
    (`(,a . ,d) (and (quotable? a) (quotable? d)))
    ((? procedure?) #f)
    (_ #t)))

(define (rev-append xs ys)
  (if (null? xs) ys (rev-append (cdr xs) (cons (car xs) ys))))

(define (denote-value val) (lambda (env) val))
(define (denote-lambda params body senv)
  (match params
    ((and (not (? symbol?)) params)
     (let ((body (denote-term body (extend-env* params params senv))))
       (lambda (env) (lambda args (body (rev-append args env))))))
    (sym
      (let ((body (denote-term body `((val . (,sym . ,sym)) . senv))))
        (lambda (env) (lambda args (body (cons args env))))))))
(define (denote-variable sym senv)
  (let loop ((idx 0) (senv senv))
    (match senv
      (`((val . (,y . ,b)) . ,rest)
        (if (equal? sym y)
          (begin
            (lambda (env)
            (list-ref env idx)))
          (loop (+ idx 1) rest)))
      (`((rec . ,binding*) . ,rest)
        (let loop-rec ((ridx 0) (binding* binding*))
          (match binding*
            ('() (loop (+ idx 1) rest))
            (`((,p-name ,_) . ,binding*)
              (if (equal? sym p-name)
                (lambda (env)
                  ((list-ref (list-ref env idx) ridx) (drop env idx)))
                (loop-rec (+ ridx 1) binding*)))))))))

(define (penv-reorderable? base src tgt)
  (equal? (list->set src) (list->set tgt)))
(define (penv-reordering base src tgt)
  (define (assoc-ref name tgt idx)
    (if (eq? name (caar tgt)) idx (assoc-ref name (cdr tgt) (+ 1 idx))))
  (if (equal? src tgt) (lambda (pb pt) pt)
    (let loop ((src src))
      (if (eq? base src) (lambda (pb pt) pb)
        (let ((idx (assoc-ref (caar src) tgt 0))
              (k (loop (cdr src))))
          (lambda (pb pt) (cons (list-ref pt idx) (k pb pt))))))))

(define (denote-qq qqterm senv)
  (match qqterm
    (`(,'unquote ,term) (denote-term term senv))
    (`(,a . ,d) (let ((da (denote-qq a senv)) (dd (denote-qq d senv)))
                  (lambda (env) `(,(da env) . ,(dd env)))))
    ((? quotable? datum) (denote-value datum))))
(define (denote-and t* senv)
  (match t*
    ('() (denote-value #t))
    (`(,t) (denote-term t senv))
    (`(,t . ,t*)
      (let ((d0 (denote-term t senv)) (d* (denote-and t* senv)))
        (lambda (env) (and (d0 env) (d* env)))))))
(define (denote-or t* senv)
  (match t*
    ('() (denote-value #f))
    (`(,t) (denote-term t senv))
    (`(,t . ,t*)
      (let ((d0 (denote-term t senv)) (d* (denote-or t* senv)))
        (lambda (env) (or (d0 env) (d* env)))))))
(define (denote-application proc a* senv)
  (let ((dp (denote-term proc senv)) (da* (denote-term-list a* senv)))
    (lambda (env) (apply (dp env) (da* env)))))
(define (denote-term-list terms senv)
  (let ((d* (map (lambda (term) (denote-term term senv)) terms)))
    (lambda (env) (map (lambda (d0) (d0 env)) d*))))

(define (denote-pattern-identity env penv v) penv)
(define (denote-pattern-literal literal penv)
  (values penv (lambda (k) (lambda (env penv v)
                             (and (equal? literal v) (k env penv v))))))
(define (denote-pattern-var b* vname penv)
  (let loop ((idx 0) (b* b*))
    (match b*
      ('() (values `((,vname ,vname) . ,penv)
                   (lambda (k) (lambda (env penv v)
                                 (k env (cons v penv) v)))))
      (`((,name ,x) . ,b*)
        (if (eq? name vname)
          (values penv
                  (lambda (k)
                    (lambda (env penv v)
                      (and (equal? (list-ref penv idx) v) (k env penv v)))))
          (loop (+ idx 1) b*))))))
(define (denote-pattern-qq qqpattern penv senv)
  (match qqpattern
    (`(,'unquote ,pat) (denote-pattern pat penv senv))
    (`(,a . ,d)
      (let*-values (((penv da) (denote-pattern-qq a penv senv))
                    ((penv dd) (denote-pattern-qq d penv senv)))
        (values penv
                (lambda (k)
                  (let* ((kd (dd k))
                         (k (lambda (env penv v)
                              ((da (lambda (_env penv _v)
                                     (kd env penv (cdr v))))
                               env penv (car v)))))
                    (lambda (env penv v)
                      (and (pair? v) (k env penv v))))))))
    ((? quotable? datum) (denote-pattern-literal datum penv))))
(define (denote-pattern-fail k) (lambda (env penv v) #f))
(define (denote-pattern-or pattern* penv penv-or senv)
  (match pattern*
    ('() (values penv-or denote-pattern-fail))
    (`(,pattern . ,pattern*)
      (let*-values (((penv0 d0) (denote-pattern pattern penv senv))
                    ((penv1 d*) (denote-pattern-or pattern* penv penv0 senv)))
        (let ((reorder0 (penv-reordering penv penv1 penv0)))
          (values penv1
                  (lambda (k)
                    (let ((k0 (d0 denote-pattern-identity))
                          (k* (d* k)))
                      (lambda (env penv v)
                        (let ((p0 (k0 env penv v)))
                          (if p0 (k env (reorder0 penv p0) v)
                            (k* env penv v))))))))))))
(define (denote-pattern* pattern* penv senv)
  (match pattern*
    ('() (values penv (lambda (k) k)))
    (`(,pattern . ,pattern*)
      (let*-values (((penv d0) (denote-pattern pattern penv senv))
                    ((penv d*) (denote-pattern* pattern* penv senv)))
        (values penv
                (lambda (k)
                  (let* ((k* (d* k)))
                    (lambda (env penv v)
                      ((d0 (lambda (_env penv _v) (k* env penv v)))
                       env penv v)))))))))
(define (denote-pattern pattern penv senv)
  (match pattern
    (`(quote ,(? quotable? datum)) (denote-pattern-literal datum penv))
    (`(quasiquote ,qqpat) (denote-pattern-qq qqpat penv senv))
    (`(not . ,pat*)
      (let-values (((_ dp) (denote-pattern* pat* penv senv)))
        (values penv
                (lambda (k)
                  (let ((k-not (dp k)))
                    (lambda (env penv v)
                      (and (not (k-not env penv v)) (k env penv v))))))))
    (`(and . ,pat*) (denote-pattern* pat* penv senv))
    (`(or . ,pat*) (denote-pattern-or pat* penv penv senv))
    (`(symbol . ,pat*)
      (let-values (((penv dp*) (denote-pattern* pat* penv senv)))
        (values penv
                (lambda (k)
                  (let ((k* (dp* k)))
                    (lambda (env penv v)
                      (and (symbol? v) (k* env penv v))))))))
    (`(number . ,pat*)
      (let-values (((penv dp*) (denote-pattern* pat* penv senv)))
        (values penv
                (lambda (k)
                  (let ((k* (dp* k)))
                    (lambda (env penv v)
                      (and (number? v) (k* env penv v))))))))
    (`(? ,predicate . ,pat*)
      (let ((dpred (denote-term predicate senv)))
        (let-values (((penv dp*) (denote-pattern* pat* penv senv)))
          (values penv
                  (lambda (k)
                    (let ((k* (dp* k)))
                      (lambda (env penv v)
                        (and ((dpred env) v)
                             (k* env penv v)))))))))
    ('_ (values penv (lambda (k) k)))
    ((? symbol? vname) (denote-pattern-var penv vname penv))
    ((? quotable? datum) (denote-pattern-literal datum penv))))
(define (denote-match pt*-all vt senv)
  (let ((dv (denote-term vt senv))
        (km (let loop ((pt* pt*-all))
              (match pt*
                ('() (lambda (env v)
                       (error (format "~s" `(match-failure ,v ,pt*-all)))))
                (`((,pat ,rhs) . ,pt*)
                  (let*-values (((penv dpat) (denote-pattern pat '() senv))
                                ((ps vs) (split-bindings penv)))
                    (let ((drhs (denote-term
                                  rhs (extend-env*
                                        (reverse ps) (reverse vs) senv)))
                          (k (dpat denote-pattern-identity))
                          (km (loop pt*)))
                      (lambda (env v)
                        (let ((penv (k env '() v)))
                          (if penv
                            (drhs (append penv env))
                            (km env v)))))))))))
    (lambda (env) (km env (dv env)))))

(define (denote-term term senv)
  (let ((bound? (lambda (sym) (in-env? senv sym))))
    (match term
      (#t (denote-value #t))
      (#f (denote-value #f))
      ((? number? num) (denote-value num))
      ((? symbol? sym) (denote-variable sym senv))
      ((and `(,op . ,_) operation)
       (match operation
         (`(,(or (? bound?) (not (? symbol?))) . ,rands)
           (denote-application op rands senv))
         (`(quote ,(? quotable? datum)) (denote-value datum))
         (`(quasiquote ,qqterm) (denote-qq qqterm senv))
         (`(if ,condition ,alt-true ,alt-false)
           (let ((dc (denote-term condition senv))
                 (dt (denote-term alt-true senv))
                 (df (denote-term alt-false senv)))
             (lambda (env) (if (dc env) (dt env) (df env)))))
         (`(lambda ,params ,body) (denote-lambda params body senv))
         (`(let ,binding* ,let-body)
           (let-values (((ps vs) (split-bindings binding*)))
             (let ((dp (denote-lambda ps let-body senv))
                   (da* (denote-term-list vs senv)))
               (lambda (env) (apply (dp env) (da* env))))))
         (`(letrec ,binding* ,letrec-body)
           (let* ((rsenv `((rec . ,binding*) . ,senv))
                  (dbody (denote-term letrec-body rsenv))
                  (db* (let loop ((binding* binding*))
                         (match binding*
                           ('() '())
                           (`((,_ (lambda ,params ,body)) . ,b*)
                             (cons (denote-lambda params body rsenv)
                                   (loop b*)))))))
             (lambda (env) (dbody (cons db* env)))))
         (`(and . ,t*) (denote-and t* senv))
         (`(or . ,t*) (denote-or t* senv))
         (`(match ,scrutinee . ,pt*) (denote-match pt* scrutinee senv)))))))

(define (in-env? env sym)
  (match env
    ('() #f)
    (`((val . (,a . ,_)) . ,d) (or (equal? a sym) (in-env? d sym)))
    (`((rec . ,binding*) . ,d) (in-env-rec? binding* d sym))))
(define (in-env-rec? binding* env sym)
  (match binding*
    ('() (in-env? env sym))
    (`((,a . ,_) . ,d) (or (equal? a sym) (in-env-rec? d env sym)))))
(define (extend-env* params args env)
  (match `(,params . ,args)
    (`(() . ()) env)
    (`((,x . ,dx*) . (,a . ,da*))
      (extend-env* dx* da* `((val . (,x . ,a)) . ,env)))))

(define (not-in-params? ps sym)
  (match ps
    ('() #t)
    (`(,a . ,d)
      (and (not (equal? a sym)) (not-in-params? d sym)))))
(define (param-list? x)
  (match x
    ('() #t)
    (`(,(? symbol? a) . ,d)
      (and (param-list? d) (not-in-params? d a)))
    (_ #f)))
(define (params? x)
  (match x
    ((? param-list?) #t)
    (x (symbol? x))))
(define (bindings? b*)
  (match b*
    ('() #t)
    (`((,p ,v) . ,b*) (bindings? b*))
    (_ #f)))
(define (split-bindings b*)
  (match b*
    ('() (values '() '()))
    (`((,param ,val) . ,b*)
      (let-values (((ps vs) (split-bindings b*)))
        (values (cons param ps) (cons val vs))))))

(define (pattern-var? b* vname ps)
  (match b*
    ('() `(,vname . ,ps))
    (`(,name . ,b*) (if (eq? name vname) ps (pattern-var? b* vname ps)))))
(define (pattern-qq? qqpattern ps env)
  (match qqpattern
    (`(,'unquote ,pat) (pattern? pat ps env))
    (`(,a . ,d) (let ((ps (pattern-qq? a ps env)))
                  (and ps (pattern-qq? d ps env))))
    ((? quotable?) ps)))
(define (pattern-or? pattern* ps ps-or env)
  (match pattern*
    ('() ps-or)
    (`(,pattern . ,pattern*)
      (let* ((ps0 (pattern? pattern ps env))
             (ps* (pattern-or? pattern* ps ps0 env)))
        (and (penv-reorderable? ps ps0 ps*) ps0)))))
(define (pattern*? pattern* ps env)
  (match pattern*
    ('() ps)
    (`(,pattern . ,pattern*)
      (let ((ps (pattern? pattern ps env)))
        (and ps (pattern*? pattern* ps env))))))
(define (pattern? pattern ps env)
  (match pattern
    (`(quote ,(? quotable?)) ps)
    (`(quasiquote ,qqpat) (pattern-qq? qqpat ps env))
    (`(not . ,pat*) (pattern*? pat* ps env))
    (`(and . ,pat*) (pattern*? pat* ps env))
    (`(or . ,pat*) (pattern-or? pat* ps ps env))
    (`(? ,predicate . ,pat*)
      (and (term? predicate env) (pattern*? pat* ps env)))
    ('_ ps)
    ((? symbol? vname) (pattern-var? ps vname ps))
    ((? quotable?) ps)))
(define (match-clauses? pt* env)
  (match pt*
    ('() #t)
    (`((,pat ,rhs) . ,pt*)
      (let ((ps (pattern? pat '() env)))
        (and
          ps (term? rhs (extend-env* ps ps env)) (match-clauses? pt* env))))))

(define (term-qq? qqterm env)
  (match qqterm
    (`(,'unquote ,term) (term? term env))
    (`(,a . ,d) (and (term-qq? a env) (term-qq? d env)))
    (datum (quotable? datum))))
(define (term? term env)
  (letrec ((term1? (lambda (v) (term? v env)))
           (terms? (lambda (ts env)
                     (match ts
                       ('() #t)
                       (`(,t . ,ts) (and (term? t env) (terms? ts env))))))
           (binding-lambdas?
             (lambda (binding* env)
               (match binding*
                 ('() #t)
                 (`((,_ ,(and `(lambda ,_ ,_) t)) . ,b*)
                   (and (term? t env) (binding-lambdas? b* env)))))))
    (match term
      (#t #t)
      (#f #t)
      ((? number?) #t)
      ((and (? symbol? sym)) (in-env? env sym))
      (`(,(? term1?) . ,rands) (terms? rands env))
      (`(quote ,datum) (quotable? datum))
      (`(quasiquote ,qqterm) (term-qq? qqterm env))
      (`(if ,c ,t ,f) (and (term1? c) (term1? t) (term1? f)))
      (`(lambda ,params ,body)
        (and (params? params)
             (let ((res (match params
                          ((not (? symbol? params))
                           (extend-env* params params env))
                          (sym `((val . (,sym . ,sym)) . ,env)))))
               (term? body res))))
      (`(let ,binding* ,let-body)
        (and (bindings? binding*)
             (let-values (((ps vs) (split-bindings binding*)))
               (and (terms? vs env)
                    (term? let-body (extend-env* ps ps env))))))
      (`(letrec ,binding* ,letrec-body)
        (let ((res `((rec . ,binding*) . ,env)))
          (and (binding-lambdas? binding* res) (term? letrec-body res))))
      (`(and . ,t*) (terms? t* env))
      (`(or . ,t*) (terms? t* env))
      (`(match ,s . ,pt*) (and (term1? s) (match-clauses? pt* env)))
      (_ #f))))

(define (eval-term term env) ((denote-term term env) (map cddr env)))

(define (primitive params body)
  ((denote-lambda params body '()) '()))

(define empty-env '())
(define initial-env `((val . (cons . ,(primitive '(a d) '`(,a . ,d))))
                      (val . (car . ,(primitive '(x) '(match x
                                                        (`(,a . ,d) a)))))
                      (val . (cdr . ,(primitive '(x) '(match x
                                                        (`(,a . ,d) d)))))
                      (val . (null? . ,(primitive '(x) '(match x
                                                          ('() #t)
                                                          (_ #f)))))
                      (val . (pair? . ,(primitive '(x) '(match x
                                                          (`(,a . ,d) #t)
                                                          (_ #f)))))
                      (val . (symbol? . ,(primitive '(x) '(match x
                                                            ((symbol) #t)
                                                            (_ #f)))))
                      (val . (number? . ,(primitive '(x) '(match x
                                                            ((number) #t)
                                                            (_ #f)))))
                      (val . (not . ,(primitive '(x) '(match x
                                                        (#f #t)
                                                        (_ #f)))))
                      (val . (equal? . ,(primitive '(x y) '(match `(,x . ,y)
                                                             (`(,a . ,a) #t)
                                                             (_ #f)))))
                      (val . (list . ,(primitive 'x 'x)))
                      . ,empty-env))

(module+ test
  (define-syntax test-eval
    (syntax-rules ()
     ((_ tm result)
      (let ((tm0 tm))
        (check-true (term? tm0 initial-env))
        (check-equal? (eval-term tm0 initial-env) result)))))
  (test-eval 3 3)
  (test-eval '3 3)
  (test-eval ''x 'x)
  (test-eval ''(1 (2) 3) '(1 (2) 3))
  (test-eval '(car '(1 (2) 3)) 1)
  (test-eval '(cdr '(1 (2) 3)) '((2) 3))
  (test-eval '(cons 'x 4) '(x . 4))
  (test-eval '(null? '()) #t)
  (test-eval '(null? '(0)) #f)
  (test-eval '(list 5 6) '(5 6))
  (test-eval '(and #f 9 10) #f)
  (test-eval '(and 8 9 10) 10)
  (test-eval '(or #f 11 12) 11)
  (test-eval '(let ((p (cons 8 9))) (cdr p)) 9)

  (define ex-append
    '(letrec ((append
                (lambda (xs ys)
                  (if (null? xs) ys (cons (car xs) (append (cdr xs) ys))))))
       (list (append '() '()) (append '(foo) '(bar)) (append '(1 2) '(3 4)))) )
  (define ex-append-answer '(() (foo bar) (1 2 3 4)))
  (test-eval ex-append ex-append-answer)
  (test-eval '`(1 ,(car `(,(cdr '(b 2)) 3)) ,'a) '(1 (2) a))

  (test-eval
    '(match '(1 (b 2))
       (`(1 (a ,x)) 3)
       (`(1 (b ,x)) x)
       (_ 4))
    2)
  (test-eval
    '(match '(1 1 2)
       (`(,a ,b ,a) `(first ,a ,b))
       (`(,a ,a ,b) `(second ,a ,b))
       (_ 4))
    '(second 1 2))

  (test-eval
    '(match '(1 b 3)
       ((or `(0 ,x ,y) `(1 ,x ,y)) (list x y))
       (_ 'fail))
    '(b 3))

  (test-eval
    '(match '(1 b 3)
       ((or `(0 ,x ,y) `(1 ,y ,x)) (list x y))
       (_ 'fail))
    '(3 b))

  (test-eval
    '(match '(0 b 3)
       ((or `(0 ,x ,y) `(1 ,y ,x)) (list x y))
       (_ 'fail))
    '(b 3))

  (define ex-match
    '(match '(1 2 1)
       (`(,a ,b ,a) `(first ,a ,b))
       (`(,a ,a ,b) `(second ,a ,b))
       (_ 4)))
  (test-eval ex-match '(first 1 2))

  (define ex-eval-expr
    '(letrec
       ((eval-expr
          (lambda (expr env)
            (match expr
              (`(quote ,datum) datum)
              (`(lambda (,(? symbol? x)) ,body)
                (lambda (a)
                  (eval-expr body (lambda (y)
                                    (if (equal? y x) a (env y))))))
              ((? symbol? x) (env x))
              (`(cons ,e1 ,e2) (cons (eval-expr e1 env) (eval-expr e2 env)))
              (`(,rator ,rand) ((eval-expr rator env)
                                (eval-expr rand env)))))))
       (list
         (eval-expr '((lambda (y) y) 'g1) 'initial-env)
         (eval-expr '(((lambda (z) z) (lambda (v) v)) 'g2) 'initial-env)
         (eval-expr '(((lambda (a) (a a)) (lambda (b) b)) 'g3) 'initial-env)
         (eval-expr '(((lambda (c) (lambda (d) c)) 'g4) 'g5) 'initial-env)
         (eval-expr '(((lambda (f) (lambda (v1) (f (f v1)))) (lambda (e) e)) 'g6) 'initial-env)
         (eval-expr '((lambda (g) ((g g) g)) (lambda (i) (lambda (j) 'g7))) 'initial-env))))
  (test-eval ex-eval-expr '(g1 g2 g3 g4 g6 g7))

  ; the goal is to support something like this interpreter
  (define ex-eval-complex
    `(let ((closure-tag ',(gensym "#%closure"))
           (prim-tag ',(gensym "#%primitive"))
           (empty-env '()))
       (let ((initial-env
               `((cons . (val . (,prim-tag . cons)))
                 (car . (val . (,prim-tag . car)))
                 (cdr . (val . (,prim-tag . cdr)))
                 (null? . (val . (,prim-tag . null?)))
                 (pair? . (val . (,prim-tag . pair?)))
                 (symbol? . (val . (,prim-tag . symbol?)))
                 (not . (val . (,prim-tag . not)))
                 (equal? . (val . (,prim-tag . equal?)))
                 (list . (val . (,closure-tag (lambda x x) ,empty-env)))
                 . ,empty-env))
             (closure-tag? (lambda (v) (equal? v closure-tag)))
             (prim-tag? (lambda (v) (equal? v prim-tag))))
         (letrec
           ((applicable-tag? (lambda (v) (or (closure-tag? v) (prim-tag? v))))
            (quotable? (lambda (v)
                         (match v
                           ((? symbol?) (not (applicable-tag? v)))
                           (`(,a . ,d) (and (quotable? a) (quotable? d)))
                           (_ #t))))
            (not-in-params? (lambda (ps sym)
                              (match ps
                                ('() #t)
                                (`(,a . ,d)
                                  (and (not (equal? a sym))
                                       (not-in-params? d sym))))))
            (param-list? (lambda (x)
                           (match x
                             ('() #t)
                             (`(,(? symbol? a) . ,d)
                               (and (param-list? d) (not-in-params? d a)))
                             (_ #f))))
            (params? (lambda (x)
                       (match x
                         ((? param-list?) #t)
                         (x (symbol? x)))))
            (in-env? (lambda (env sym)
                       (match env
                         ('() #f)
                         (`((,a . ,_). ,d)
                           (or (equal? a sym) (in-env? d sym))))))
            (extend-env*
              (lambda (params args env)
                (match `(,params . ,args)
                  (`(() . ()) env)
                  (`((,x . ,dx*) . (,a . ,da*))
                    (extend-env* dx* da* `((,x . (val . ,a)) . ,env))))))
            (lookup
              (lambda (env sym)
                (match env
                  (`((,y . ,b) . ,rest)
                    (if (equal? sym y)
                      (match b
                        (`(val . ,v) v)
                        (`(rec . ,lam-expr) `(,closure-tag ,lam-expr ,env)))
                      (lookup rest sym))))))
            (term?
              (lambda (term env)
                (letrec
                  ((term1? (lambda (v) (term? v env)))
                   (terms? (lambda (ts env)
                             (match ts
                               ('() #t)
                               (`(,t . ,ts)
                                 (and (term? t env) (terms? ts env)))))))
                  (match term
                    (#t #t)
                    (#f #t)
                    ((? number?) #t)
                    ((and (? symbol? sym)) (in-env? env sym))
                    (`(,(? term1?) . ,rands) (terms? rands env))
                    (`(quote ,datum) (quotable? datum))
                    (`(if ,c ,t ,f) (and (term1? c) (term1? t) (term1? f)))
                    (`(lambda ,params ,body)
                      (and (params? params)
                           (let ((res
                                   (match params
                                     ((and (not (? symbol?)) params)
                                      (extend-env* params params env))
                                     (sym `((,sym . (val . ,sym)) . ,env)))))
                             (term? body res))))
                    (`(letrec
                        ((,p-name ,(and `(lambda ,params ,body) lam-expr)))
                        ,letrec-body)
                      (and (params? params)
                           (let ((res `((,p-name
                                          . (rec . (lambda ,params ,body)))
                                        . ,env)))
                             (and (term? lam-expr res)
                                  (term? letrec-body res)))))
                    (_ #f)))))
            (eval-prim
              (lambda (prim-id args)
                (match `(,prim-id . ,args)
                  (`(cons ,a ,d) `(,a . ,d))
                  (`(car (,(and (not (? applicable-tag?)) a) . ,d)) a)
                  (`(cdr (,(and (not (? applicable-tag?)) a) . ,d)) d)
                  (`(null? ,v) (match v ('() #t) (_ #f)))
                  (`(pair? ,v) (match v
                                 (`(,(not (? applicable-tag?)) . ,_) #t)
                                 (_ #f)))
                  (`(symbol? ,v) (symbol? v))
                  (`(number? ,v) (number? v))
                  (`(not ,v) (match v (#f #t) (_ #f)))
                  (`(equal? ,v1 ,v2) (equal? v1 v2)))))
            (eval-term-list
              (lambda (terms env)
                (match terms
                  ('() '())
                  (`(,term . ,terms)
                    `(,(eval-term term env) . ,(eval-term-list terms env))))))
            (eval-term
              (lambda (term env)
                (let ((bound? (lambda (sym) (in-env? env sym)))
                      (term1? (lambda (v) (term? v env))))
                  (match term
                    (#t #t)
                    (#f #f)
                    ((? number? num) num)
                    (`(,(and 'quote (not (? bound?))) ,(? quotable? datum))
                      datum)
                    ((? symbol? sym) (lookup env sym))
                    ((and `(,op . ,_) operation)
                     (match operation
                       (`(,(or (? bound?) (not (? symbol?)))
                           . ,rands)
                         (let ((op (eval-term op env))
                               (a* (eval-term-list rands env)))
                           (match op
                             (`(,(? prim-tag?) . ,prim-id)
                               (eval-prim prim-id a*))
                             (`(,(? closure-tag?) (lambda ,x ,body) ,env^)
                               (let ((res (match x
                                            ((and (not (? symbol?)) params)
                                             (extend-env* params a* env^))
                                            (sym `((,sym . (val . ,a*))
                                                   . ,env^)))))
                                 (eval-term body res))))))
                       (`(if ,condition ,alt-true ,alt-false)
                         (if (eval-term condition env)
                           (eval-term alt-true env)
                           (eval-term alt-false env)))
                       (`(lambda ,params ,body)
                        `(,closure-tag (lambda ,params ,body) ,env))
                       (`(letrec ((,p-name (lambda ,params ,body)))
                           ,letrec-body)
                        (eval-term
                          letrec-body
                          `((,p-name . (rec . (lambda ,params ,body)))
                            . ,env))))))))))

        (let ((program ',ex-append))
          (and (term? program initial-env)
               (eval-term program initial-env)))))))
  (test-eval ex-eval-complex ex-append-answer)
  )
