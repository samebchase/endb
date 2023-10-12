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
  (on_literal :pointer)
  (on_pattern :pointer)
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

(defvar *parse-sql-cst-on-literal*)

(cffi:defcallback parse-sql-cst-on-literal :void
    ((literal-ptr :pointer)
     (literal-size :size)
     (start :size)
     (end :size))
  (funcall *parse-sql-cst-on-literal* literal-ptr literal-size start end))

(defvar *parse-sql-cst-on-pattern*)

(cffi:defcallback parse-sql-cst-on-pattern :void
    ((start :size)
     (end :size))
  (funcall *parse-sql-cst-on-pattern* start end))

(defparameter +kw-cache+ (make-hash-table))
(defparameter +literal-cache+ (make-hash-table))

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
             (*parse-sql-cst-on-literal* (lambda (literal-ptr literal-size start end)
                                           (let* ((address (cffi:pointer-address literal-ptr))
                                                  (literal (or (gethash address +literal-cache+)
                                                               (let* ((literal-string (make-array literal-size :element-type 'character)))
                                                                 (dotimes (n literal-size)
                                                                   (setf (aref literal-string n)
                                                                         (code-char (cffi:mem-ref literal-ptr :char n))))
                                                                 (setf (gethash address +literal-cache+) literal-string)))))
                                             (push (list literal start end) (first result)))))
             (*parse-sql-cst-on-pattern* (lambda (start end)
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
                                    (cffi:callback parse-sql-cst-on-literal)
                                    (cffi:callback parse-sql-cst-on-pattern)
                                    (cffi:callback parse-sql-cst-on-error))))
            (cffi:with-foreign-string (filename-ptr input)
              (cffi:with-foreign-string (input-ptr input)
                (endb-parse-sql-cst filename-ptr
                                    input-ptr
                                    (cffi:callback parse-sql-cst-on-open)
                                    (cffi:callback parse-sql-cst-on-close)
                                    (cffi:callback parse-sql-cst-on-literal)
                                    (cffi:callback parse-sql-cst-on-pattern)
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
                                           (member x delimiters :test 'equalp))
                             t)))
                        xs))
           (split-binary-ops (acc xs)
             (trivia:ematch xs
               ((list* (list "BETWEEN" _ _) x (list "AND" _ _) y xs)
                (split-binary-ops (cons (list :between (list (walk x) (walk y))) acc)
                                  xs))
               ((list* (list "NOT" _ _) (list "BETWEEN" _ _) x (list "AND" _ _) y xs)
                (split-binary-ops (cons (list (list :not :between) (list (walk x) (walk y))) acc)
                                  xs))
               ((trivia:guard (list* (list op _ _) x xs)
                              (stringp op))
                (split-binary-ops (cons (list (intern op :keyword) (walk x)) acc)
                                  xs))
               ((list) (reverse acc))))
           (binary-op-tree (xs)
             (reduce
              (lambda (lhs op-rhs)
                (or (trivia:match op-rhs
                      ((list (list :not :between) (list x y))
                       (list :not (list :between lhs x y)))
                      ((list :between (list x y))
                       (list :between lhs x y))
                      ((list :not :null)
                       (list :not (list :is lhs :null))))
                    (list (first op-rhs)
                          lhs
                          (second op-rhs))))
              (split-binary-ops () (rest xs))
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
                (list :create-table (walk table-name) (remove nil (mapcar #'walk (strip-delimiters '("(" ")" ",") xs)))))

               ((list* :|column_def| column-name _)
                (walk column-name))

               ((list* :|table_constraint| _))

               ((list* :|create_index_stmt| _ (list "UNIQUE" _ _) _ index-name _ table-name _)
                (list :create-index (walk index-name) (walk table-name)))

               ((list* :|create_index_stmt| _ _ index-name _ table-name _)
                (list :create-index (walk index-name) (walk table-name)))

               ((list :|create_view_stmt| _ _ view-name _ query)
                (list :create-view (walk view-name) (walk query)))

               ((list :|create_view_stmt| _ _ _ view-name _ query)
                (list :create-view (walk view-name) (walk query)))

               ((list :|insert_stmt| _ _ table-name query)
                (list :insert (walk table-name) (walk query)))

               ((list :|insert_stmt| _ _ _ _ table-name query)
                (list :insert (walk table-name) (walk query)))

               ((list :|insert_stmt| _ _ table-name _ column-name-list _ query)
                (list :insert (walk table-name) (walk query) :column-names (walk column-name-list)))

               ((list :|delete_stmt| _ _ table-name _ expr)
                (list :delete (walk table-name) :where (walk expr)))

               ((list :|drop_table_stmt| _ _ table-name)
                (list :drop-table (walk table-name)))

               ((list :|drop_table_stmt| _ _ _ _ table-name)
                (list :drop-table (walk table-name) :if-exists :if-exists))

               ((list :|drop_view_stmt| _ _ view-name)
                (list :drop-view (walk view-name)))

               ((list :|drop_view_stmt| _ _ _ _ view-name)
                (list :drop-view (walk view-name) :if-exists :if-exists))

               ((list :|drop_index_stmt| _ _ index-name)
                (list :drop-index (walk index-name)))

               ((list :|drop_index_stmt| _ _ _ _ index-name)
                (list :drop-index (walk index-name) :if-exists :if-exists))

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

               ((list :|result_column| x alias)
                (list (walk x) (walk alias)))

               ((list :|result_column| x _ alias)
                (list (walk x) (walk alias)))

               ((list* :|from_clause| _ xs)
                (cons :from (mapcar #'walk xs)))

               ((list* :|join_clause| xs)
                (mapcar #'walk xs))

               ((list :|table_or_subquery| table-name)
                (list (walk table-name)))

               ((list :|table_or_subquery| table-name alias)
                (list (walk table-name) (walk alias)))

               ((list :|table_or_subquery| table-name _ alias)
                (list (walk table-name) (walk alias)))

               ((list :|where_clause| _ expr)
                (list :where (walk expr)))

               ((list* :|group_by_clause| _ _ xs)
                (list :group-by (mapcan #'walk xs)))

               ((list :|having_clause| _ expr)
                (list :having (walk expr)))

               ((list* :|order_by_clause| _ _ xs)
                (list :order-by (mapcar #'walk (strip-delimiters '(",") xs))))

               ((list :|ordering_term| x (list dir _ _))
                (list (walk x) (intern dir :keyword)))

               ((list :|ordering_term| x)
                (list (walk x) :asc))

               ((list :|column_reference| table-name _ column-name)
                (make-symbol (concatenate 'string (symbol-name (walk table-name)) "." (symbol-name (walk column-name)))))

               ((list* :|unary_expr| (list op _ _) x)
                (list (intern op :keyword) (walk (cons :|unary_expr| x))))

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
                (list (intern op :keyword) (walk (cons :|not_expr| x))))

               ((list* :|and_expr| xs)
                (binary-op-tree xs))

               ((list* :|or_expr| xs)
                (binary-op-tree xs))

               ((list* :|function_call_expr| (trivia:guard (list :|function_name|
                                                                 (list :|ident| (list fn _ _)))
                                                           (equalp "COUNT" fn))
                       (list _ (list "*" _ _) _))
                (list :aggregate-function :count-star nil))

               ((list* :|function_call_expr| function-name xs)
                (let* ((args (mapcar #'walk (strip-delimiters '("(" ")") xs)))
                       (fn (trivia:match function-name
                             ((list :|function_name| (list :|ident| (list fn _ _)))
                              (string-upcase fn)))))
                  (if (member fn '("COUNT" "AVG" "SUM" "TOTAL" "MIN" "MAX" "ARRAY_AGG" "OBJECT_AGG" "GROUP_CONCAT") :test 'equal)
                      (cons :aggregate-function (cons (intern fn :keyword) args))
                      (cons :function (cons (walk function-name) args)))))

               ((list* :|case_expr| _ xs)
                (or (trivia:match (first xs)
                      ((list* :|case_when_then_expr| _)
                       (cons :case (list (mapcar #'walk (strip-delimiters '("END") xs))))))
                    (cons :case (cons (walk (first xs)) (list (mapcar #'walk (strip-delimiters '("END") (rest xs))))))))

               ((list :|case_when_then_expr| _ when-expr _ then-expr)
                (list (walk when-expr) (walk then-expr)))

               ((list :|case_else_expr| _ else-expr)
                (list :else (walk else-expr)))

               ((list :|paren_expr| _ expr _)
                (walk expr))

               ((list :|exists_expr| _ query)
                (list :exists (walk query)))

               ((list :|cast_expr| _ _ expr _ type _)
                (list :cast (walk expr) (walk type)))

               ((list :|atom| (list :|subquery| _ query _))
                (list :scalar-subquery (walk query)))

               ((list :|subquery| _ query _)
                (walk query))

               ((list* :|expr_list| xs)
                (mapcar #'walk (strip-delimiters '(",") xs)))

               ((list :|numeric_literal| (list x _ _))
                (read-from-string x))

               ((list :|string_literal| (list x _ _))
                (endb/lib/parser:sql-string-to-cl (eql #\' (char x 0)) (subseq x 1 (1- (length x)))))

               ((list "NULL"  _ _)
                :null)

               ((trivia:guard (list kw x) (keywordp kw))
                (walk x)))))
    (let ((*read-eval* nil)
          (*read-default-float-format* 'double-float))
      (walk cst))))
