;;;; src/encoding.lisp -- the Objective-C type encoding parser.
;;;;
;;;; Pure Lisp: no foreign calls, no runtime state.  That is deliberate, because
;;;; this is simultaneously the component most likely to be wrong and the
;;;; cheapest to test, so the whole of it is exercised by unit tests that need
;;;; no Objective-C runtime at all.
;;;;
;;;; A parsed type is a "node", one of:
;;;;
;;;;   a keyword          :char :uchar :short :ushort :int :uint :long :ulong
;;;;                      :long-long :ulong-long :float :double :bool :void
;;;;                      :id :class :sel :cstring :unknown :block
;;;;   (:pointer NODE)
;;;;   (:struct NAME FIELDS)   FIELDS is a list of nodes, or NIL when the
;;;;                           runtime elided the layout -- "{CGRect=}"
;;;;   (:union NAME FIELDS)
;;;;   (:array COUNT NODE)
;;;;   (:bitfield WIDTH)
;;;;   (:qualified QUALIFIERS NODE)
;;;;   (:vector ELEMENT COUNT)   a SIMD vector -- see the note below
;;;;   (:matrix ELEMENT COLUMNS ROWS)   a simd matrix: COLUMNS vectors of ROWS
;;;;   :unencodable            a type the encoding could not carry at all
;;;;
;;;; Clang writes NOTHING for a SIMD vector type: -[GKAgent2D setPosition:]
;;;; encodes as "v24@0:816", an empty type between two offsets, and its
;;;; getter as "16@0:8", a signature with no result.  So a vector node never
;;;; comes out of the parser; it comes from a signature spelled in Lisp -- the
;;;; list form of a method name, DECLARE-OBJC-SIGNATURE, DEFINE-OBJC-METHOD --
;;;; and UNPARSE-TYPE writes it back the way Clang would, as nothing.  What
;;;; the parser can do is notice the hole: a method encoding that starts with
;;;; an offset has no result type, and one with fewer argument types than its
;;;; selector has colons is missing some, and those become :UNENCODABLE nodes
;;;; so that INVOKE can say what happened rather than miscount arguments.
;;;; A matrix is a struct of an array of vectors, and Clang writes the array
;;;; with its count and no element -- "{?=[4]}" for simd_float4x4 -- which the
;;;; parser reads as an array of :UNENCODABLE inside an anonymous struct; and
;;;; a quaternion, one vector in a struct, is "{?=}", an anonymous struct with
;;;; no fields at all.  Both count as holes.
;;;;
;;;; Five things here are load-bearing, and each is a real bug if missed:
;;;;
;;;;  1. method_getTypeEncoding appends decimal frame offsets -- "Q16@0:8" is
;;;;     three types, not a type named Q16.  They are a 32-bit-era artefact and
;;;;     are meaningless on arm64, so they are skipped wherever they appear.
;;;;  2. "@?" is a block, and must be tested before a bare "@".
;;;;  3. '@"NSString"' carries a quoted class name that must be consumed, or the
;;;;     parse desynchronises and every following argument is wrong.
;;;;  4. 'l' and 'L' mean exactly 32 bits even on LP64.  NSInteger encodes as
;;;;     'q', not 'l'.  Reading 'l' as a C long silently truncates.
;;;;  5. A struct encoding may be name-only ("{CGRect=}", "^{example}").  Those
;;;;     get looked up in the override table by TYPES; guessing a size instead
;;;;     would corrupt every argument after it.

(in-package #:objc)

(defparameter +primitive-encodings+
  '((#\c . :char)     (#\C . :uchar)
    (#\s . :short)    (#\S . :ushort)
    (#\i . :int)      (#\I . :uint)
    ;; 'l' and 'L' are 32-bit by definition of the encoding, regardless of the
    ;; platform's sizeof(long).  See note 4 in the file header.
    (#\l . :long)     (#\L . :ulong)
    (#\q . :long-long)(#\Q . :ulong-long)
    (#\f . :float)    (#\d . :double)
    (#\B . :bool)     (#\v . :void)
    (#\* . :cstring)
    (#\# . :class)    (#\: . :sel)
    (#\? . :unknown))
  "Single-character type encodings.  '@' is handled separately because of the
'@?' and '@\"ClassName\"' forms.")

(defparameter +qualifier-encodings+
  '((#\r . :const)  (#\n . :in)     (#\N . :inout)
    (#\o . :out)    (#\O . :bycopy) (#\R . :byref)
    (#\V . :oneway))
  "Method argument qualifiers.  They prefix a type and none of them collide
with a type character: the uppercase type letters are C I S L Q B.")

(defun %digit-char-p (char) (and char (char<= #\0 char #\9)))

(defun skip-offsets (string index)
  "Skip the decimal frame offset that method_getTypeEncoding writes after a
complete type.  See note 1 in the file header."
  (loop while (and (< index (length string))
                   (%digit-char-p (char string index)))
        do (incf index))
  index)

(defun parse-type (string &optional (start 0))
  "Parse one type from STRING at START.
Returns (VALUES NODE NEXT-INDEX).  Signals UNSUPPORTED-TYPE-ENCODING on
anything it does not understand rather than returning a plausible guess."
  (let ((length (length string)))
    (when (>= start length)
      (error 'unsupported-type-encoding
             :encoding string :position start
             :detail "encoding ended where a type was expected"))
    (let ((char (char string start)))
      (cond
        ;; Qualifiers stack: "rn^v" is const in pointer-to-void.
        ((assoc char +qualifier-encodings+)
         (let ((quals '()))
           (loop for entry = (and (< start length)
                                  (assoc (char string start) +qualifier-encodings+))
                 while entry
                 do (push (cdr entry) quals) (incf start))
           (multiple-value-bind (node next) (parse-type string start)
             (values (list :qualified (nreverse quals) node) next))))

        ;; '@' is object, '@?' is a block, '@"NSString"' is an object whose
        ;; class the runtime happened to record.  See notes 2 and 3.
        ((char= char #\@)
         (let ((next (1+ start)))
           (cond ((and (< next length) (char= (char string next) #\?))
                  (values :block (1+ next)))
                 ((and (< next length) (char= (char string next) #\"))
                  (let ((close (position #\" string :start (1+ next))))
                    (unless close
                      (error 'unsupported-type-encoding
                             :encoding string :position next
                             :detail "unterminated class name after @"))
                    (values :id (1+ close))))
                 (t (values :id next)))))

        ;; Pointer.  "^?" is a function pointer: pointer to unknown.
        ((char= char #\^)
         (multiple-value-bind (node next) (parse-type string (1+ start))
           (values (list :pointer node) next)))

        ;; Array: [COUNT TYPE]
        ((char= char #\[)
         (let ((index (1+ start)))
           (unless (%digit-char-p (and (< index length) (char string index)))
             (error 'unsupported-type-encoding
                    :encoding string :position index
                    :detail "array encoding with no element count"))
           (let ((count 0))
             (loop while (%digit-char-p (and (< index length) (char string index)))
                   do (setf count (+ (* count 10)
                                     (- (char-code (char string index)) (char-code #\0))))
                      (incf index))
             ;; "[4]" -- a count and no element -- is an array of a type
             ;; Clang could not write: a SIMD vector.  See the file header.
             (if (and (< index length) (char= (char string index) #\]))
                 (values (list :array count :unencodable) (1+ index))
                 (multiple-value-bind (node next) (parse-type string index)
                   (unless (and (< next length) (char= (char string next) #\]))
                     (error 'unsupported-type-encoding
                            :encoding string :position next
                            :detail "unterminated array encoding"))
                   (values (list :array count node) (1+ next)))))))

        ;; Struct {name=fields} and union (name=fields).  The body is optional:
        ;; "{CGRect=}" and "{CGRect}" both name a struct whose layout the
        ;; runtime did not record.  See note 5.
        ((or (char= char #\{) (char= char #\())
         (let* ((unionp (char= char #\())
                (close-char (if unionp #\) #\}))
                (index (1+ start))
                (name-start index))
           (loop while (and (< index length)
                            (char/= (char string index) #\=)
                            (char/= (char string index) close-char))
                 do (incf index))
           (when (>= index length)
             (error 'unsupported-type-encoding
                    :encoding string :position start
                    :detail "unterminated struct or union encoding"))
           (let ((name (subseq string name-start index))
                 (fields '())
                 (bodyp nil))
             (when (char= (char string index) #\=)
               (setf bodyp t)
               (incf index)
               (loop while (and (< index length)
                                (char/= (char string index) close-char))
                     do (multiple-value-bind (node next) (parse-type string index)
                          (push node fields)
                          ;; Offsets can appear between struct fields too.
                          (setf index (skip-offsets string next)))))
             (unless (and (< index length) (char= (char string index) close-char))
               (error 'unsupported-type-encoding
                      :encoding string :position index
                      :detail "unterminated struct or union encoding"))
             (values (list (if unionp :union :struct)
                           (if (string= name "?") nil name)
                           ;; NIL fields means "layout not recorded".  An empty
                           ;; body with an explicit '=' is a genuinely empty
                           ;; struct, which the runtime writes as "{foo=}" too;
                           ;; both are treated as unknown, because a zero-slot
                           ;; struct never appears in a real method signature.
                           (and bodyp (nreverse fields)))
                     (1+ index)))))

        ;; Bitfield: bWIDTH
        ((char= char #\b)
         (let ((index (1+ start)) (width 0))
           (unless (%digit-char-p (and (< index length) (char string index)))
             (error 'unsupported-type-encoding
                    :encoding string :position index
                    :detail "bitfield encoding with no width"))
           (loop while (%digit-char-p (and (< index length) (char string index)))
                 do (setf width (+ (* width 10)
                                   (- (char-code (char string index)) (char-code #\0))))
                    (incf index))
           (values (list :bitfield width) index)))

        (t
         (let ((entry (assoc char +primitive-encodings+)))
           (unless entry
             (error 'unsupported-type-encoding
                    :encoding string :position start
                    :detail (format nil "unknown type character ~C" char)))
           (values (cdr entry) (1+ start))))))))

(defun parse-method-encoding (string &optional selector-name)
  "Parse a whole method type encoding.
Returns (VALUES RESULT-NODE ARGUMENT-NODES), where ARGUMENT-NODES always begins
with the receiver and the selector -- every Objective-C method takes self and
_cmd before its declared arguments, and the encoding says so.

A type Clang could not encode -- a SIMD vector -- is written as nothing, and
the two places that shows are marked :UNENCODABLE: a string that begins with
a frame offset has no result type, and, given SELECTOR-NAME, fewer declared
arguments than the selector has colons means that many are missing.  Which
of the arguments is the missing one the encoding cannot say, so the marks go
at the end and the caller is told to spell the whole signature."
  (let ((index 0)
        (length (length string))
        (nodes '())
        (no-result (and (plusp (length string)) (%digit-char-p (char string 0)))))
    (setf index (skip-offsets string index))
    (loop while (< index length)
          do (multiple-value-bind (node next) (parse-type string index)
               (push node nodes)
               (setf index (skip-offsets string next))))
    (let ((nodes (nreverse nodes)))
      (when (null nodes)
        (error 'unsupported-type-encoding
               :encoding string :detail "empty method encoding"))
      (multiple-value-bind (result args)
          (if no-result
              (values :unencodable nodes)
              (values (first nodes) (rest nodes)))
        (when selector-name
          (let ((missing (- (selector-argument-count selector-name)
                            (max 0 (- (length args) 2)))))
            (when (plusp missing)
              (setf args (append args (make-list missing :initial-element :unencodable))))))
        (values result args)))))

(defun vector-node-p (node)
  (and (consp node) (eq (first node) :vector)))

(defun matrix-node-p (node)
  (and (consp node) (eq (first node) :matrix)))

(defun unencodable-node-p (node)
  "Whether NODE is a hole, or has one inside: an array of nothing, a struct
with such a field, or an anonymous struct with no fields at all, which is
what Clang writes for one SIMD vector wrapped in a struct."
  (cond ((eq node :unencodable) t)
        ((atom node) nil)
        (t (case (first node)
             (:array (unencodable-node-p (third node)))
             (:qualified (unencodable-node-p (third node)))
             (:pointer nil)
             ((:struct :union)
              (or (and (null (second node)) (null (third node)))
                  (some #'unencodable-node-p (third node))))
             (t nil)))))

(defun signature-unencodable-p (result-node arg-nodes)
  "Whether the runtime's encoding left a hole anywhere in this signature."
  (or (unencodable-node-p result-node) (some #'unencodable-node-p arg-nodes)))

(defun unparse-type (node)
  "Serialise NODE back to an Objective-C type encoding string.
Round-trips: for any fully specified node, Foundation's NSGetSizeAndAlignment
gives the same size and alignment for this string as for the one it was parsed
from.  A struct whose layout was not recorded cannot be serialised faithfully
and signals instead."
  (etypecase node
    (keyword
     (case node
       (:id "@") (:block "@?")
       ;; What Clang writes for a type it cannot encode: nothing.
       (:unencodable "")
       (t (let ((entry (rassoc node +primitive-encodings+)))
            (unless entry
              (error 'unsupported-type-encoding
                     :encoding node :detail "no encoding for this node"))
            (string (car entry))))))
    (cons
     (ecase (first node)
       ;; A SIMD vector, as Clang writes it: nothing.  See the file header.
       (:vector "")
       ;; A matrix, as Clang writes it: an anonymous struct holding an array
       ;; of COLUMNS of nothing.
       (:matrix (format nil "{?=[~d]}" (third node)))
       (:pointer (concatenate 'string "^" (unparse-type (second node))))
       (:array (format nil "[~D~A]" (second node) (unparse-type (third node))))
       (:bitfield (format nil "b~D" (second node)))
       (:qualified
        (concatenate 'string
                     (map 'string
                          (lambda (q) (car (rassoc q +qualifier-encodings+)))
                          (second node))
                     (unparse-type (third node))))
       ((:struct :union)
        (destructuring-bind (name fields) (rest node)
          (unless fields
            (error 'unsupported-type-encoding
                   :encoding (or name "?")
                   :detail "struct layout was not recorded, cannot serialise"))
          (format nil "~A~A=~{~A~}~A"
                  (if (eq (first node) :union) "(" "{")
                  (or name "?")
                  (mapcar #'unparse-type fields)
                  (if (eq (first node) :union) ")" "}"))))))))

(defun canonical-encoding (node)
  "A stable string key for NODE, used to share one compiled trampoline between
every method that has the same call shape.

Unlike UNPARSE-TYPE this never signals: a struct with no recorded layout still
needs a distinct key, and it gets one from its name.  Two different structs with
identical layouts keep distinct keys, which costs an extra trampoline and buys
not having to reason about whether that is safe."
  (with-output-to-string (out)
    (labels ((emit (node)
               (etypecase node
                 (keyword (write-string (cond ((eq node :block) "@?")
                                              ((eq node :id) "@")
                                              ;; A hole needs a key of its own:
                                              ;; nothing at all would make a
                                              ;; two-argument signature key the
                                              ;; same as a one-argument one.
                                              ((eq node :unencodable) "<?>")
                                              (t (string (car (rassoc node +primitive-encodings+)))))
                                        out))
                 (cons
                  (ecase (first node)
                    ;; Distinct from the double it travels as, on purpose: the
                    ;; key is also what a Lisp method's own signature would
                    ;; be canonicalised to, and two methods that take a
                    ;; float2 and a double are not the same method.
                    (:vector (format out "<~a~d>"
                                     (car (rassoc (second node) +primitive-encodings+))
                                     (third node)))
                    (:matrix (format out "<~a~dx~d>"
                                     (car (rassoc (second node) +primitive-encodings+))
                                     (third node) (fourth node)))
                    (:pointer (write-char #\^ out) (emit (second node)))
                    (:array (format out "[~D" (second node)) (emit (third node))
                            (write-char #\] out))
                    (:bitfield (format out "b~D" (second node)))
                    ;; Qualifiers do not change the ABI, so they are dropped
                    ;; from the key: "oI" and "I" share a trampoline correctly.
                    (:qualified (emit (third node)))
                    ((:struct :union)
                     (destructuring-bind (name fields) (rest node)
                       (write-char (if (eq (first node) :union) #\( #\{) out)
                       (write-string (or name "?") out)
                       (when fields
                         (write-char #\= out)
                         (mapc #'emit fields))
                       (write-char (if (eq (first node) :union) #\) #\}) out))))))))
      (emit node))))

(defun selector-argument-count (selector-name)
  "Number of arguments SELECTOR-NAME takes, which is its number of colons.
\"close\" takes none, \"setWidth:height:\" takes two.  Nothing else in the API
conveys arity, so this is what argument count checks are made of."
  (count #\: selector-name))
