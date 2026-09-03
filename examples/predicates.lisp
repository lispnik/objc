;;;; examples/predicates.lisp -- querying Cocoa collections, and variadic sends.
;;;;
;;;; NSPredicate is Cocoa's query language: a format string that compiles to a
;;;; test, which an array can filter itself by.  With NSSortDescriptor it is how
;;;; every table view in every Cocoa application decides what to show and in what
;;;; order, and from Lisp it is a pleasant way to ask questions of an NSArray
;;;; without walking it.
;;;;
;;;; THE REASON THIS EXAMPLE EXISTS is +predicateWithFormat:, which is VARIADIC,
;;;; and variadic sends are the one part of this library the README warns about
;;;; and nothing outside the test suite demonstrated.  On Apple silicon a
;;;; variadic function passes its variable arguments on the STACK while a
;;;; fixed-arity one passes them in registers, so calling one without saying so
;;;; does not fail -- it reads whatever was in the registers:
;;;;
;;;;     (objc:invoke "NSPredicate" "predicateWithFormat:" "name == %@" "Ada")
;;;;
;;;; is wrong, and quietly.  The send has to name how many arguments are fixed:
;;;;
;;;;     (objc:invoke "NSPredicate"
;;;;                  '("predicateWithFormat:" (objc:objc-object-pointer
;;;;                                            objc:objc-object-pointer)
;;;;                    :result-type objc:objc-object-pointer
;;;;                    :variadic-num-of-fixed 1)
;;;;                  "name == %@" "Ada")
;;;;
;;;; The extended selector form gives the whole signature: the argument types
;;;; after the receiver and selector, the result type, and the count of fixed
;;;; parameters -- one here, the format string itself.  LispWorks fails silently
;;;; in this situation; this library warns once per selector, which is how the
;;;; mistake announces itself the first time rather than as wrong answers later.
;;;;
;;;; PREDICATE below wraps that so it need only be written once, which is also
;;;; the honest advice: wrap a variadic selector where you use it, do not spread
;;;; the declaration across a codebase.

(in-package #:objc/examples)

;;; Variadic sends -----------------------------------------------------------------

(defun format-string (format &rest arguments)
  "+[NSString stringWithFormat:], the canonical variadic method, as a Lisp string.

    (format-string \"%@ is %d years old\" \"Ada\" 36)   ;; => \"Ada is 36 years old\"

Every argument is passed as an object or an int according to its Lisp type,
which is as far as a general wrapper can go: a %f wants a double and there is no
way to know that from the Lisp value alone.  Real code writes one wrapper per
format it uses, or uses CL:FORMAT and hands the result over as a plain string --
which is very often the better answer, and worth saying in an example about how
to do it the hard way."
  (objc:ensure-objc-initialized)
  (let ((types (mapcar (lambda (argument)
                         (if (integerp argument) :int 'objc:objc-object-pointer))
                       arguments)))
    (apply #'objc:invoke-into
           'string "NSString"
           `("stringWithFormat:" (objc:objc-object-pointer ,@types)
             :result-type objc:objc-object-pointer
             :variadic-num-of-fixed 1)
           format arguments)))

(defun predicate (format &rest arguments)
  "An NSPredicate from FORMAT, with %@ substitutions from ARGUMENTS.

    (predicate \"name BEGINSWITH %@\" \"A\")
    (predicate \"age > %@\" 30)

The variadic declaration lives here so callers never write it.  Numbers are
boxed: a %@ wants an object, and an unboxed integer would be read as a pointer."
  (objc:ensure-objc-initialized)
  (let ((objects (mapcar #'box arguments)))
    (apply #'objc:invoke "NSPredicate"
           `("predicateWithFormat:"
                   (objc:objc-object-pointer
                    ,@(make-list (length objects)
                                 :initial-element 'objc:objc-object-pointer))
                   :result-type objc:objc-object-pointer
                   :variadic-num-of-fixed 1)
                 format objects)))

(defun box (value)
  "VALUE as an object, for a %@ substitution."
  (typecase value
    (string value)
    (integer (objc:invoke "NSNumber" "numberWithLongLong:" value))
    (real (objc:invoke "NSNumber" "numberWithDouble:" (float value 1d0)))
    (t value)))

;;; Collections ---------------------------------------------------------------------

(defun ns-array (sequence)
  "An NSArray of the objects in SEQUENCE, boxing what needs boxing."
  (objc:invoke "NSArray" "arrayWithArray:"
               (map 'vector #'box sequence)))

(defun ns-dictionary (plist)
  "An NSDictionary from a plist, for building rows to query.

    (ns-dictionary '(\"name\" \"Ada\" \"age\" 36))"
  (let ((dictionary (objc:invoke (objc:alloc-init-object "NSMutableDictionary") "self")))
    (loop for (key value) on plist by #'cddr
          do (objc:invoke dictionary "setObject:forKey:" (box value) key))
    dictionary))

(defun filter (array predicate-or-format &rest arguments)
  "The members of ARRAY satisfying a predicate, as an NSArray.

PREDICATE-OR-FORMAT is an NSPredicate, or a format string and its arguments:

    (filter people \"age > %@\" 30)"
  (let ((predicate (if (stringp predicate-or-format)
                       (apply #'predicate predicate-or-format arguments)
                       predicate-or-format)))
    (objc:invoke array "filteredArrayUsingPredicate:" predicate)))

(defun sort-by (array key &key (ascending t))
  "ARRAY sorted by KEY, as an NSArray.

An NSSortDescriptor names a key path rather than a comparison, which is what
lets Cocoa sort rows it knows nothing about -- and what makes this different
from -sortedArrayUsingComparator:, which takes a block and appears in
block-tests."
  (let ((descriptor (objc:invoke "NSSortDescriptor"
                                 "sortDescriptorWithKey:ascending:" key
                                 (if ascending 1 0))))
    (objc:invoke array "sortedArrayUsingDescriptors:" (vector descriptor))))

(defun column (array key)
  "The value of KEY from every row of ARRAY, as Lisp values.

-valueForKey: on an array asks each element, which is the trick that makes a
Cocoa array behave like a column of a table."
  (let ((values (objc:invoke array "valueForKey:" key)))
    (loop for i below (objc:invoke values "count")
          collect (unwrap (objc:invoke values "objectAtIndex:" i)))))

;;; A worked example ------------------------------------------------------------------

(defparameter +people+
  '(("Ada Lovelace" 36) ("Charles Babbage" 79) ("Alan Turing" 41)
    ("Grace Hopper" 85) ("Alonzo Church" 92))
  "Name and age at death, for something to query.")

(defun people-array ()
  (ns-array (loop for (name age) in +people+
                  collect (ns-dictionary (list "name" name "age" age)))))

(defun test-predicates ()
  "Query and sort an NSArray, and check the variadic send did the right thing.

    (objc/examples:test-predicates)
    => (:FORMATTED \"Ada is 36\" :OVER-50 (\"Charles Babbage\" \"Grace Hopper\"
                                          \"Alonzo Church\")
        :BEGINNING-WITH-A (\"Ada Lovelace\" \"Alan Turing\" \"Alonzo Church\")
        :YOUNGEST \"Ada Lovelace\" :COLUMN 5)

:FORMATTED is the one that would catch a botched variadic send: the arguments
are read from the stack on Apple silicon and from registers otherwise, so a
missing :VARIADIC-NUM-OF-FIXED does not error, it formats garbage."
  (objc:ensure-objc-initialized)
  (objc:with-autorelease-pool ()
    (let ((people (people-array)))
      (list :formatted (format-string "%@ is %d" "Ada" 36)
            :over-50 (column (filter people "age > %@" 50) "name")
            :beginning-with-a (column (filter people "name BEGINSWITH %@" "A") "name")
            :youngest (first (column (sort-by people "age") "name"))
            :column (length (column people "name"))))))

(defun report-predicates ()
  "Print the queries and their answers."
  (let ((result (test-predicates)))
    (format t "~&stringWithFormat: gave ~S~%" (getf result :formatted))
    (format t "over 50: ~{~A~^, ~}~%" (getf result :over-50))
    (format t "names beginning with A: ~{~A~^, ~}~%" (getf result :beginning-with-a))
    (format t "youngest: ~A~%" (getf result :youngest))
    result))
