(defpackage :endb-test/sql
  (:use :cl :fiveam :endb/sql)
  (:import-from :local-time)
  (:import-from :sqlite))
(in-package :endb-test/sql)

(in-suite* :all-tests)

(test create-db-and-insert
  (let ((db (create-db)))
    (multiple-value-bind (result result-code)
        (execute-sql db "CREATE TABLE t1(a INTEGER, b INTEGER, c INTEGER, d INTEGER, e INTEGER)")
      (is (null result))
      (is (eq t result-code))
      (is (equal '("a" "b" "c" "d" "e")
                 (endb/sql/expr:base-table-columns (gethash "t1" db)))))

    (multiple-value-bind (result result-code)
        (execute-sql db "INSERT INTO t1 VALUES(103,102,100,101,104)")
      (is (null result))
      (is (= 1 result-code))
      (is (equal '((103 102 100 101 104))
                 (endb/sql/expr:base-table-rows (gethash "t1" db)))))

    (multiple-value-bind (result result-code)
        (execute-sql db "INSERT INTO t1(e,c,b,d,a) VALUES(103,102,100,101,104), (NULL,102,NULL,101,104)")
      (is (null result))
      (is (= 2 result-code))
      (is (equal '((104 100 102 101 103)
                   (104 :null 102 101 :null)
                   (103 102 100 101 104))
                 (endb/sql/expr:base-table-rows (gethash "t1" db)))))

    (multiple-value-bind (result result-code)
        (execute-sql db "CREATE INDEX t1i0 ON t1(a1,b1,c1,d1,e1,x1)")
      (is (null result))
      (is (eq t result-code)))))

(test simple-select
  (let ((db (create-db)))

    (multiple-value-bind (result columns)
        (execute-sql db "SELECT 1 + 1")
      (is (equal '((2)) result))
      (is (equal '("column1") columns)))

    (multiple-value-bind (result columns)
        (execute-sql db "SELECT CASE 1 + 1 WHEN 3 THEN 1 WHEN 2 THEN 2 END")
      (is (equal '((2)) result))
      (is (equal '("column1") columns)))

    (multiple-value-bind (result columns)
        (execute-sql db "SELECT CASE WHEN TRUE THEN 2 WHEN FALSE THEN 1 END")
      (is (equal '((2)) result))
      (is (equal '("column1") columns)))

    (multiple-value-bind (result columns)
        (execute-sql db "SELECT CASE WHEN FALSE THEN 2 ELSE 1 END")
      (is (equal '((1)) result))
      (is (equal '("column1") columns)))

    (execute-sql db "CREATE TABLE t1(a INTEGER, b INTEGER, c INTEGER, d INTEGER, e INTEGER)")
    (execute-sql db "INSERT INTO t1 VALUES(103,102,100,101,104)")

    (multiple-value-bind (result columns)
        (execute-sql db "SELECT a FROM t1")
      (is (equal '((103)) result))
      (is (equal '("a") columns)))

    (multiple-value-bind (result columns)
        (execute-sql db "SELECT a FROM t1 LIMIT 0")
      (is (equal '() result))
      (is (equal '("a") columns)))

    (multiple-value-bind (result columns)
        (execute-sql db "SELECT t1.b + t1.c AS x FROM t1")
      (is (equal '((202)) result))
      (is (equal '("x") columns)))

    (multiple-value-bind (result columns)
        (execute-sql db "SELECT * FROM t1")
      (is (equal '((103 102 100 101 104)) result))
      (is (equal '("a" "b" "c" "d" "e") columns)))

    (multiple-value-bind (result columns)
        (execute-sql db "SELECT * FROM t1 WHERE a IN (102, 103)")
      (is (equal '((103 102 100 101 104)) result))
      (is (equal '("a" "b" "c" "d" "e") columns)))

    (multiple-value-bind (result columns)
        (execute-sql db "SELECT * FROM t1 WHERE a IN (VALUES (102), (103))")
      (is (equal '((103 102 100 101 104)) result))
      (is (equal '("a" "b" "c" "d" "e") columns)))

    (multiple-value-bind (result columns)
        (execute-sql db "SELECT * FROM t1 WHERE b = 102")
      (is (equal '((103 102 100 101 104)) result))
      (is (equal '("a" "b" "c" "d" "e") columns)))

    (multiple-value-bind (result columns)
        (execute-sql db "SELECT b, COUNT(t1.a) FROM t1 GROUP BY b")
      (is (equal '((102 1)) result))
      (is (equal '("b" "column2") columns)))

    (multiple-value-bind (result columns)
        (execute-sql db "SELECT SUM(a) FROM t1")
      (is (equal '((103)) result))
      (is (equal '("column1") columns)))

    (multiple-value-bind (result columns)
        (execute-sql db "SELECT 1 FROM t1 HAVING SUM(a) = 103")
      (is (equal '((1)) result))
      (is (equal '("column1") columns)))

    (multiple-value-bind (result columns)
        (execute-sql db "SELECT t1.a, x.a FROM t1, t1 AS x WHERE t1.a = x.a")
      (is (equal '((103 103)) result))
      (is (equal '("a" "a") columns)))

    (execute-sql db "INSERT INTO t1(e,c,b,d,a) VALUES(103,102,102,101,104), (NULL,102,NULL,101,104)")

    (multiple-value-bind (result columns)
        (execute-sql db "SELECT COUNT(*), COUNT(e), SUM(e), AVG(a), MIN(b), MAX(c), b FROM t1 GROUP BY b")
      (is (equal '((1 0 :null 104.0d0 :null 102 :null) (2 2 207 103.5d0 102 102 102)) result))
      (is (equal '("column1" "column2" "column3" "column4" "column5" "column6" "b") columns)))

    (multiple-value-bind (result columns)
        (execute-sql db "SELECT COUNT(*) FROM t1 WHERE FALSE")
      (is (equal '((0)) result))
      (is (equal '("column1") columns)))

    (multiple-value-bind (result columns)
        (execute-sql db "SELECT ALL 74 * - COALESCE ( + CASE - CASE WHEN NOT ( NOT - 79 >= NULL ) THEN 48 END WHEN + + COUNT( * ) THEN 6 END, MIN( ALL + - 30 ) * 45 * 77 ) * - 14")
      (is (equal '((-107692200)) result))
      (is (equal '("column1") columns)))

    (multiple-value-bind (result columns)
        (execute-sql db "VALUES(0,6,5.6,'jtqxx',9,5.19,'qvgba')")
      (is (equal '((0 6 5.6d0 "jtqxx" 9 5.19d0 "qvgba")) result))
      (is (equal '("column1" "column2" "column3" "column4" "column5" "column6" "column7") columns)))

    (multiple-value-bind (result columns)
        (execute-sql db "SELECT 1 IN (2)")
      (is (equal '((nil)) result))
      (is (equal '("column1") columns)))

    (multiple-value-bind (result columns)
        (execute-sql db "SELECT SUM(t1.b) FROM t1 HAVING SUM(t1.b) = 204")
      (is (equal '((204)) result))
      (is (equal '("column1") columns)))))

(defun eval-expr (expr)
  (sqlite:with-open-database (sqlite ":memory:")
    (let* ((endb (create-db))
           (query (format nil "SELECT ~A" expr))
           (sqlite-result (sqlite:execute-single sqlite query))
           (endb-result (first (first (execute-sql endb query)))))
      (list endb-result sqlite-result))))

(defun expr-test (expr)
  (destructuring-bind (endb-result sqlite-result)
      (eval-expr expr)
      (is (equal (cond
                   ((null endb-result) 0)
                   ((eq t endb-result) 1)
                   ((eq :null endb-result) nil)
                   ((typep endb-result 'local-time:date)
                    (local-time:format-timestring nil endb-result :format local-time:+rfc3339-format/date-only+))
                   (t endb-result))
                 sqlite-result))))


(defun expr (expr)
  (sqlite:with-open-database (sqlite ":memory:")
    (let* ((endb (create-db))
           (query (format nil "SELECT ~A" expr))
           (sqlite-result (sqlite:execute-single sqlite query))
           (endb-result (first (first (execute-sql endb query)))))
      (list endb-result sqlite-result expr))))

(defun endb->sqlite (x)
  (cond
    ((null x) 0)
    ((eq t x) 1)
    ((eq :null x) nil)
    ((typep x 'local-time:date)
     (local-time:format-timestring nil x :format local-time:+rfc3339-format/date-only+))
    (t x)))

(defun is-valid (result)
  (destructuring-bind (endb-result sqlite-result expr)
      result
    (is (equal (endb->sqlite endb-result) sqlite-result)
        "~2&~S~2% evaluated to ~2&~S~2% which is not ~2&~S~2% to ~2&~S~2%"
        expr endb-result 'equal sqlite-result)))

(test sqlite-expr
  (is-valid (expr "FALSE"))
  (is-valid (expr "TRUE"))
  (is-valid (expr "NULL"))

  (is-valid (expr "1 + 2"))
  (is-valid (expr "1 - 2"))
  (is-valid (expr "1 * 2"))
  (is-valid (expr "1 / 2"))
  (is-valid (expr "1 % 2"))
  (is-valid (expr "1 < 2"))
  (is-valid (expr "1 <= 2"))
  (is-valid (expr "1 > 2"))
  (is-valid (expr "1 >= 2"))

  (is-valid (expr "1 + 2.0"))
  (is-valid (expr "1 - 2.0"))
  (is-valid (expr "1 * 2.0"))
  (is-valid (expr "1 / 2.0"))
  (is-valid (expr "1 % 2.0"))
  (is-valid (expr "1 < 2.0"))
  (is-valid (expr "1 <= 2.0"))
  (is-valid (expr "1 > 2.0"))
  (is-valid (expr "1 >= 2.0"))

  (is-valid (expr "1 + NULL"))
  (is-valid (expr "1 - NULL"))
  (is-valid (expr "1 * NULL"))
  (is-valid (expr "1 / NULL"))
  (is-valid (expr "1 % NULL"))
  (is-valid (expr "1 < NULL"))
  (is-valid (expr "1 <= NULL"))
  (is-valid (expr "1 > NULL"))
  (is-valid (expr "1 >= NULL"))

  (is-valid (expr "NULL + 2.0"))
  (is-valid (expr "NULL - 2.0"))
  (is-valid (expr "NULL * 2.0"))
  (is-valid (expr "NULL / 2.0"))
  (is-valid (expr "NULL % 2.0"))
  (is-valid (expr "NULL < 2.0"))
  (is-valid (expr "NULL <= 2.0"))
  (is-valid (expr "NULL > 2.0"))
  (is-valid (expr "NULL >= 2.0"))

  (is-valid (expr "1 + 'foo'"))
  (is-valid (expr "1 - 'foo'"))
  (is-valid (expr "1 * 'foo'"))
  (is-valid (expr "1 / 'foo'"))
  (is-valid (expr "1 % 'foo'"))
  (is-valid (expr "1 < 'foo'"))
  (is-valid (expr "1 <= 'foo'"))
  (is-valid (expr "1 > 'foo'"))
  (is-valid (expr "1 >= 'foo'"))

  (is-valid (expr "'foo' + 2.0"))
  (is-valid (expr "'foo' - 2.0"))
  (is-valid (expr "'foo' * 2.0"))
  (is-valid (expr "'foo' / 2.0"))
  (is-valid (expr "'foo' % 2.0"))
  (is-valid (expr "'foo' < 2.0"))
  (is-valid (expr "'foo' <= 2.0"))
  (is-valid (expr "'foo' > 2.0"))
  (is-valid (expr "'foo' >= 2.0"))

  (is-valid (expr "'foo' + 'foo'"))
  (is-valid (expr "'foo' - 'foo'"))
  (is-valid (expr "'foo' * 'foo'"))
  (is-valid (expr "'foo' / 'foo'"))
  (is-valid (expr "'foo' % 'foo'"))

  (is-valid (expr "+1"))
  (is-valid (expr "-1"))

  (is-valid (expr "+NULL"))
  (is-valid (expr "-NULL"))

  (is-valid (expr "+'foo'"))
  (is-valid (expr "-'foo'"))

  (is-valid (expr "1 / 0"))
  (is-valid (expr "1 % 0"))

  (is-valid (expr "1 / 0.0"))
  (is-valid (expr "1 % 0.0"))

  (is-valid (expr "2 IS 2"))
  (is-valid (expr "2 IS 3"))
  (is-valid (expr "2 IS NULL"))
  (is-valid (expr "2 IS NOT NULL"))
  (is-valid (expr "NULL IS NULL"))
  (is-valid (expr "NULL IS NOT NULL"))

  (is-valid (expr "abs(2.0)"))
  (is-valid (expr "abs(-2)"))
  (is-valid (expr "abs(NULL)"))

  (is-valid (expr "nullif(1, 1)"))
  (is-valid (expr "nullif(1, 'foo')"))
  (is-valid (expr "nullif('foo', 1)"))

  (is-valid (expr "coalesce(NULL, 'foo', 1)"))
  (is-valid (expr "coalesce(NULL, NULL, 1)"))

  (is-valid (expr "date('2001-01-01')"))
  (is-valid (expr "date(NULL)"))
  (is-valid (expr "strftime('%Y', date('2001-01-01'))"))
  (is-valid (expr "strftime('%Y', NULL)"))
  (is-valid (expr "strftime(NULL, date('2001-01-01'))"))
  (is-valid (expr "strftime(NULL, NULL)"))

  (is-valid (expr "substring('foo', 1, 2)"))
  (is-valid (expr "substring('foo', 1, 5)"))
  (is-valid (expr "substring('foo', 1)"))
  (is-valid (expr "substring('foo', -1)"))
  (is-valid (expr "substring('foo', 2, 1)"))
  (is-valid (expr "substring(NULL, 1)"))
  (is-valid (expr "substring('foo', NULL)"))
  (is-valid (expr "substring('foo', NULL, NULL)"))
  (is-valid (expr "substring(NULL, NULL, NULL)"))

  (is-valid (expr "'foo' LIKE '%fo'"))
  (is-valid (expr "'foo' LIKE 'fo%'"))
  (is-valid (expr "'foo' LIKE 'bar'"))
  (is-valid (expr "NULL LIKE 'bar'"))
  (is-valid (expr "'foo' LIKE NULL")))
