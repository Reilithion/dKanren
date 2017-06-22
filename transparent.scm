(define-syntax let*/and
  (syntax-rules ()
    ((_ () rest ...) (and rest ...))
    ((_ ((name expr) ne* ...) rest ...)
     (let ((name expr))
       (and name (let*/and (ne* ...) rest ...))))))

(define-syntax defrecord
  (syntax-rules ()
    ((_ name name?)
     (begin
       (define name (vector 'name))
       (define (name? datum) (eq? name datum))))
    ((_ name name? (field set-field) ...)
     (begin
       (define (name field ...) (vector 'name field ...))
       (define (name? datum)
         (and (vector? datum) (eq? 'name (vector-ref datum 0))))
       (let ()
         (define (range-assoc start xs)
           (let loop ((xs xs) (idx start))
             (if (null? xs)
               '()
               (cons (cons (car xs) idx) (loop (cdr xs) (+ idx 1))))))
         (define (define-field-getter name rassc)
           (define idx (cdr (assoc name rassc)))
           (eval `(define (,name datum) (vector-ref datum ,idx))))
         (define (define-field-setter name rassc)
           (define idx (cdr (assoc name rassc)))
           (eval `(define (,name datum value)
                    (let ((new (vector-copy datum)))
                      (vector-set! new ,idx value)
                      new))))
         (let ((fns (range-assoc 1 '(field ...))))
           (begin (define-field-getter 'field fns) ...))
         (let ((set-fns (range-assoc 1 '(set-field ...))))
           (begin (define-field-setter 'set-field set-fns) ...)))))
    ((_ name name? field ...)
     (begin
       (define (name field ...) (vector 'name field ...))
       (define (name? datum)
         (and (vector? datum) (eq? 'name (vector-ref datum 0))))
       (let ()
         (define (range-assoc start xs)
           (let loop ((xs xs) (idx start))
             (if (null? xs)
               '()
               (cons (cons (car xs) idx) (loop (cdr xs) (+ idx 1))))))
         (define (define-field-getter name rassc)
           (define idx (cdr (assoc name rassc)))
           (eval `(define (,name datum) (vector-ref datum ,idx))))
         (let ((fns (range-assoc 1 '(field ...))))
           (begin (define-field-getter 'field fns) ...)))))))

(define store-empty '())
(define (store-ref store key . default)
  (let ((binding (assoc key store)))
    (if binding
      (cdr binding)
      (if (null? default)
        (error 'store-ref (format "missing key ~s in ~s" key store))
        (car default)))))
(define (store-set store key value) `((,key . ,value) . ,store))
(define (store-remove store key)
  (if (null? store)
    '()
    (if (eqv? key (caar store))
      (store-remove (cdr store) key)
      (cons (car store) (store-remove (cdr store) key)))))
(define (store-keys store) (map car store))

(define scope-new
  (let ((index -1))
    (lambda ()
      (set! index (+ 1 index))
      index)))
(define scope-bound #f)
(define scope-nonlocal #t)

(defrecord var var? var-scope var-value)
(define var/scope
  (let ((index -1))
    (lambda (scope)
      (set! index (+ 1 index))
      (var scope index))))
(define var=? eq?)
(define (var<? v1 v2) (< (var-value v1) (var-value v2)))
(define (var-bound? vr) (eq? scope-bound (var-scope vr)))
(define (set-var-value! vr value)
  (vector-set! vr 1 scope-bound)
  (vector-set! vr 2 value))

(define (vattrs-get vs vr) (store-ref vs vr vr))
(define (vattrs-set vs vr value) (store-set vs vr value))
(define (walk-vs vs tm)
  (if (var? tm)
    (if (var-bound? tm)
      (walk-vs vs (var-value tm))
      (let ((va (vattrs-get vs tm)))
        (if (var=? tm va)
          tm
          (walk-vs vs va))))
    tm))

(defrecord state state? (state-scope set-state-scope) (state-vs set-state-vs))
(define (walk st tm) (walk-vs (state-vs st) tm))
(define (var/state st) (var/scope (state-scope st)))
(define (state-empty) (state (scope-new) store-empty))
(define (state-var-get st vr) (vattrs-get (state-vs st) vr))
(define (state-var-set st vr value)
  (if (eqv? (state-scope st) (var-scope vr))
    (begin (set-var-value! vr value) st)
    (set-state-vs st (vattrs-set (state-vs st) vr value))))

(define (not-occurs? st vr tm)
  (if (pair? tm)
    (let*/and ((st (not-occurs? st vr (walk st (car tm)))))
      (not-occurs? st vr (walk st (cdr tm))))
    (and (not (var=? vr tm)) st)))
(define (state-var-== st vr value)
  (let*/and ((st (not-occurs? st vr value)))
    (state-var-set st vr value)))
(define (state-var-==-var st v1 va1 v2 va2)
  (if (var<? v1 v2)
    (state-var-set st v2 v1)
    (state-var-set st v1 v2)))

(define (unify st t1 t2)
  (let ((t1 (walk st t1)) (t2 (walk st t2)))
    (cond
      ((eqv? t1 t2) st)
      ((var? t1)
       (if (var? t2)
         (state-var-==-var st t1 t2)
         (state-var-== st t1 t2)))
      ((var? t2) (state-var-== st t2 t1))
      ((and (pair? t1) (pair? t2))
       (let*/and ((st (unify st (car t1) (car t2))))
         (unify st (cdr t1) (cdr t2))))
      (else #f))))
