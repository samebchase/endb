(defpackage :endb/lib/cst
  (:use :cl)
  (:export  #:parse-sql-cst #:render-error-report #:cst->ast)
  (:import-from :endb/lib)
  (:import-from :endb/lib/parser)
  (:import-from :endb/json)
  (:import-from :cffi)
  (:import-from :trivial-utf-8)
  (:import-from :trivia))
(in-package :endb/lib/cst)

(cffi:defcfun "endb_parse_sql_cst" :void
  (filename (:pointer :char))
  (input (:pointer :char))
  (on_open :pointer)
  (on_close :pointer)
  (on_token :pointer)
  (on_error :pointer))

(cffi:defcfun "endb_render_json_error_report" :void
  (report_json (:pointer :char))
  (on_success :pointer)
  (on_error :pointer))

(cffi:defcallback parse-sql-cst-on-error :void
    ((err :string))
  (error 'endb/lib/parser:sql-parse-error :message err))

(defvar *parse-sql-cst-on-open*)

(cffi:defcallback parse-sql-cst-on-open :void
    ((label-ptr :pointer)
     (label-size :size))
  (funcall *parse-sql-cst-on-open* label-ptr label-size))

(defvar *parse-sql-cst-on-close*)

(cffi:defcallback parse-sql-cst-on-close :void
    ()
  (funcall *parse-sql-cst-on-close*))

(defvar *parse-sql-cst-on-token*)

(cffi:defcallback parse-sql-cst-on-token :void
    ((start :size)
     (end :size))
  (funcall *parse-sql-cst-on-token* start end))

(defparameter +kw-cache+ (make-hash-table))

(defun parse-sql-cst (input &key (filename ""))
  (endb/lib:init-lib)
  (if (zerop (length input))
      (error 'endb/lib/parser:sql-parse-error :message "Empty input")
      (let* ((result (list (list)))
             (input-bytes (trivial-utf-8:string-to-utf-8-bytes input))
             (*parse-sql-cst-on-open* (lambda (label-ptr label-size)
                                        (let* ((address (cffi:pointer-address label-ptr))
                                               (kw (or (gethash address +kw-cache+)
                                                       (let* ((kw-string (make-array label-size :element-type 'character)))
                                                         (dotimes (n label-size)
                                                           (setf (aref kw-string n)
                                                                 (code-char (cffi:mem-ref label-ptr :char n))))
                                                         (setf (gethash address +kw-cache+)
                                                               (intern kw-string :keyword))))))
                                          (push (list kw) result))))
             (*parse-sql-cst-on-close* (lambda ()
                                         (push (nreverse (pop result)) (first result))))
             (*parse-sql-cst-on-token* (lambda (start end)
                                         (let ((token (trivial-utf-8:utf-8-bytes-to-string input-bytes :start start :end end)))
                                           (push (list token start end) (first result))))))
        (if (and (typep filename 'base-string)
                 (typep input 'base-string))
            (cffi:with-pointer-to-vector-data (filename-ptr input)
              (cffi:with-pointer-to-vector-data (input-ptr input)
                (endb-parse-sql-cst filename-ptr
                                    input-ptr
                                    (cffi:callback parse-sql-cst-on-open)
                                    (cffi:callback parse-sql-cst-on-close)
                                    (cffi:callback parse-sql-cst-on-token)
                                    (cffi:callback parse-sql-cst-on-error))))
            (cffi:with-foreign-string (filename-ptr input)
              (cffi:with-foreign-string (input-ptr input)
                (endb-parse-sql-cst filename-ptr
                                    input-ptr
                                    (cffi:callback parse-sql-cst-on-open)
                                    (cffi:callback parse-sql-cst-on-close)
                                    (cffi:callback parse-sql-cst-on-token)
                                    (cffi:callback parse-sql-cst-on-error)))))
        (caar result))))

(defvar *render-json-error-report-on-success*)

(cffi:defcallback render-json-error-report-on-success :void
    ((report :string))
  (funcall *render-json-error-report-on-success* report))

(cffi:defcallback render-json-error-report-on-error :void
    ((err :string))
  (error err))

(defun render-error-report (report)
  (endb/lib:init-lib)
  (let* ((result)
         (*render-json-error-report-on-success* (lambda (report)
                                                  (setf result report)))
         (report-json (endb/json:json-stringify report)))
    (cffi:with-foreign-string (report-json-ptr report-json)
      (endb-render-json-error-report report-json-ptr
                                     (cffi:callback render-json-error-report-on-success)
                                     (cffi:callback render-json-error-report-on-error)))
    (endb/lib/parser:strip-ansi-escape-codes result)))

(defun cst->ast (input cst)
  (labels ((strip-delimiters (delimiters xs)
             (remove-if (lambda (x)
                          (trivia:match x
                            ((trivia:guard (list x _ _)
                                           (member x delimiters :test 'equal))
                             t)))
                        xs))
           (binary-op-tree (xs)
             (reduce
              (lambda (lhs op-rhs)
                (list (first op-rhs)
                      lhs
                      (second op-rhs)))
              (loop for (x y) on (rest xs) by #'cddr
                    collect (list (intern (first x) :keyword) (walk y)))
              :initial-value (walk (first xs))))
           (walk (cst)
             (trivia:ematch cst
               ((list :|ident| (list id start end))
                (let ((s (make-symbol id)))
                  (setf (get s :start) start (get s :end) end (get s :input) input)
                  s))

               ((list :|sql_stmt_list| x)
                (walk x))

               ((list* :|sql_stmt_list| xs)
                (list :multiple-statments (mapcar #'walk (strip-delimiters '(";") xs))))

               ((list* :|select_stmt| xs)
                (mapcan #'walk xs))

               ((list* :|create_table_stmt| _ _ table-name xs)
                (list :create-table (walk table-name) (mapcar #'walk (strip-delimiters '("(" ")" ",") xs))))

               ((list :|column_def| column-name _)
                (walk column-name))

               ((list :|insert_stmt| _ _ table-name _ column-name-list _ query)
                (list :insert (walk table-name) (walk query) :column-names (walk column-name-list)))

               ((list* :|column_name_list| xs)
                (mapcar #'walk (strip-delimiters '(",") xs)))

               ((list* :|select_core| (list "SELECT" _ _) xs)
                (cons :select (mapcan #'walk xs)))

               ((list* :|values_clause| _ xs)
                (cons :values (list (mapcar #'walk (strip-delimiters '("(" ")" ",") xs)))))

               ((list* :|result_expr_list| xs)
                (list (mapcar #'walk (strip-delimiters '(",") xs))))

               ((list :|result_column| x)
                (list (walk x)))

               ((list* :|from_clause| _ xs)
                (cons :from (mapcar #'walk xs)))

               ((list* :|join_clause| xs)
                (mapcar #'walk xs))

               ((list :|table_or_subquery| table-name)
                (list (walk table-name)))

               ((list :|table_or_subquery| table-name _ alias)
                (list (walk table-name) (walk alias)))

               ((list :|where_clause| _ expr)
                (list :where (walk expr)))

               ((list* :|order_by_clause| _ _ xs)
                (list :order-by (mapcar #'walk (strip-delimiters '(",") xs))))

               ((list :|ordering_term| x (list dir _ _))
                (list (walk x) (intern dir :keyword)))

               ((list :|ordering_term| x)
                (list (walk x) :asc))

               ((list :|column_reference| table-name _ column-name)
                (make-symbol (concatenate 'string (symbol-name (walk table-name)) "." (symbol-name (walk column-name)))))

               ((list* :|unary_expr| (list op _ _) x)
                (list (intern op :keyword) (walk (list :|unary_expr| x))))

               ((list* :|concat_expr| xs)
                (binary-op-tree xs))

               ((list* :|mul_expr| xs)
                (binary-op-tree xs))

               ((list* :|add_expr| xs)
                (binary-op-tree xs))

               ((list* :|bit_expr| xs)
                (binary-op-tree xs))

               ((list* :|rel_expr| xs)
                (binary-op-tree xs))

               ((list* :|equal_expr| xs)
                (binary-op-tree xs))

               ((list* :|not_expr| (list op _ _) x)
                (list (intern op :keyword) (walk (list :|not_expr| x))))

               ((list* :|and_expr| xs)
                (binary-op-tree xs))

               ((list* :|or_expr| xs)
                (binary-op-tree xs))

               ((list* :|function_call_expr| function-name xs)
                (let ((args (mapcar #'walk (strip-delimiters '("(" ")") xs)))
                      (fn (trivia:match function-name
                            ((list _ (list _ (list fn _ _)))
                             fn))))
                  (if (member fn '("COUNT" "AVG" "SUM" "TOTAL" "MIN" "MAX" "ARRAY_AGG" "OBJECT_AGG" "GROUP_CONCAT") :test 'equalp)
                      (cons :aggregate-function (cons (intern (string-upcase fn) :keyword) args))
                      (cons :function (cons (walk function-name) args)))))

               ((list* :|case_expr| _ xs)
                (cons :case (list (mapcar #'walk (strip-delimiters '("END") xs)))))

               ((list :|case_when_then_expr| _ when-expr _ then-expr)
                (list (walk when-expr) (walk then-expr)))

               ((list :|case_else_expr| _ else-expr)
                (list :else (walk else-expr)))

               ((list :|paren_expr| _ expr _)
                (walk expr))

               ((list :|exists_expr| _ query)
                (list :exists (second (walk query))))

               ((list :|subquery| _ query _)
                (list :scalar-subquery (walk query)))

               ((list* :|expr_list| xs)
                (mapcar #'walk (strip-delimiters '(",") xs)))

               ((list :|numeric_literal| (list x _ _))
                (read-from-string x))

               ((trivia:guard (list kw x) (keywordp kw))
                (walk x)))))
    (let ((*read-eval* nil)
          (*read-default-float-format* 'double-float))
      (walk cst))))
