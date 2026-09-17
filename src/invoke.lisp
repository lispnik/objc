;;;; src/invoke.lisp -- INVOKE, INVOKE-BOOL, INVOKE-INTO.
;;;;
;;;; All three are one function with a DISPOSITION argument that only
;;;; UNMARSHAL-RESULT looks at.  Keeping it that way is the point: there is no
;;;; second path for struct returns, for super sends, or for booleans, so there
;;;; is nowhere for their behaviour to drift apart.

(in-package #:objc)

(defvar *traced-selectors* (make-hash-table :test 'equal)
  "Selector names being traced by TRACE-INVOKE.")

(defun trace-invoke (method)
  "Trace calls to the Objective-C method named METHOD.
Not CL:TRACE on INVOKE, which would fire on every send in the image and print
receivers as opaque pointers."
  (setf (gethash (selector-name method) *traced-selectors*) t)
  method)

(defun untrace-invoke (method)
  "Stop tracing METHOD."
  (remhash (selector-name method) *traced-selectors*)
  method)

;;; Method designators -------------------------------------------------------

(defun parse-method-designator (method)
  "Return (VALUES SELECTOR-NAME ARG-TYPES RESULT-TYPE N-FIXED EXPLICIT-P).

METHOD is either a selector string, or the list form the manual documents:

  (method-name arg-types &key result-type variadic-num-of-fixed)

The list form exists for signatures the runtime's encoding cannot express --
vector types -- and for variadic methods, where the ABI genuinely differs.
EXPLICIT-P is true for the list form, whose ARG-TYPES may well be empty: a
getter returning a SIMD vector, -[GKAgent2D position], takes nothing and
has a result the runtime encodes as nothing, so the empty list is the whole
point and must not read as \"use the runtime's view\"."
  (etypecase method
    (string (values method nil nil nil nil))
    (symbol (values (string method) nil nil nil nil))
    (cons
     (destructuring-bind (name arg-types &key (result-type :void)
                                              (variadic-num-of-fixed nil))
         method
       (values name arg-types result-type variadic-num-of-fixed t)))))

(defvar *warned-variadic* (make-hash-table :test 'equal))

(defun maybe-warn-variadic (selector-name n-fixed)
  (when (and (null n-fixed)
             (member selector-name +known-variadic-selectors+ :test #'string=)
             (not (gethash selector-name *warned-variadic*)))
    (setf (gethash selector-name *warned-variadic*) t)
    (warn "~S is a variadic method.  On Apple silicon a variadic call passes ~
its variable arguments on the stack, so calling it without ~
:VARIADIC-NUM-OF-FIXED reads garbage.  Use the list form of the method ~
designator, for example:~@
  (invoke \"NSString\" '(\"stringWithFormat:\" (objc:objc-object-pointer :int) ~
:result-type objc:objc-object-pointer :variadic-num-of-fixed 1) fmt 42)"
          selector-name)))

;;; Result conversion --------------------------------------------------------

(defun cstring-node-p (node)
  "True for a char * result, qualifiers and all: -[NSString UTF8String] encodes
as \"r*16@0:8\", a const char *."
  (or (eq node :cstring)
      (and (consp node) (eq (first node) :qualified) (cstring-node-p (third node)))))

(defun unmarshal-result (raw result-node out-sap disposition &optional selector)
  "Turn a trampoline's result into what the caller asked for.

DISPOSITION is :DEFAULT for INVOKE, :BOOLEAN for INVOKE-BOOL, or the RESULT
argument of INVOKE-INTO."
  ;; The common case first: a scalar result for INVOKE.  Nothing below applies
  ;; to a keyword node under the default disposition, and on ECL the checks it
  ;; would walk were 50 ns of a 600 ns send.
  (when (and (keywordp result-node) (eq disposition :default))
    (return-from unmarshal-result
      (if (eq result-node :void) (values) (unmarshal-scalar raw result-node))))
  (let ((kind (cocoa-struct-kind result-node)))
    (cond
      ;; A vector or matrix result the backend wrote through OUT-SAP rather
      ;; than returning: read out before the buffer goes.
      ((and (or (vector-node-p result-node) (matrix-node-p result-node))
            (result-through-buffer-p result-node))
       (read-struct-field (pointer-of out-sap) result-node))
      ;; Struct results were written through OUT-SAP, which belongs to the
      ;; caller's WITH-FOREIGN-OBJECT and is gone once this call returns.  So a
      ;; struct result may only leave here as a value copied OUT of that buffer:
      ;; a Cocoa structure, which becomes a vector or a cons, or a copy into a
      ;; destination the caller allocated.  Anything else would be a pointer
      ;; into freed memory, and reads back as plausible numbers.
      ((struct-node-p result-node)
       (cond
         ((or kind (cffi:pointerp disposition))
          (let ((value (if kind (read-cocoa-struct out-sap kind) (pointer-of out-sap))))
            (unmarshal-into value result-node out-sap disposition kind)))
         ;; Any other structure whose layout is known comes back as a vector
         ;; with one element per field, read out of the buffer before it
         ;; goes: the same shape WRITE-STRUCT-FROM-SEQUENCE takes going in.
         ((struct-readable-p result-node)
          (read-struct-to-sequence (pointer-of out-sap) result-node))
         (t
          ;; An opaque structure has no fields for UNPARSE-TYPE to write
          ;; either, and a report that cannot be printed is no report.
          (error 'unrepresentable-struct-result
                 :encoding (or (ignore-errors (unparse-type result-node))
                               (format nil "{~A=}" (or (second result-node) "?")))
                 :selector (and selector (string selector))))))
      ((eq result-node :void) (values))
      ;; The manual, for INVOKE-INTO with :POINTER: "If the result type of the
      ;; method is unsigned char *, then the value is returned as a pointer of
      ;; type objc-c-string."  So the disposition has to be consulted BEFORE
      ;; the ordinary char* to Lisp string conversion, not after it -- asking
      ;; for a pointer and being handed a string is the whole thing this
      ;; disposition exists to avoid.
      ((and (cstring-node-p result-node)
            (or (eq disposition :pointer)
                (and (consp disposition) (eq (first disposition) :pointer))))
       (pointer-of raw))
      (t
       (let ((value (unmarshal-scalar raw result-node)))
         (case disposition
           (:boolean (not (or (null raw) (eql raw 0))))
           (:default value)
           (t (unmarshal-into value result-node out-sap disposition kind))))))))

(defun unmarshal-scalar (raw node)
  ;; Unwrap qualifiers first.  Method argument and result types carry them
  ;; freely -- -[NSString UTF8String] encodes as "r*16@0:8", a CONST char * --
  ;; and a qualified node that falls through unrecognised returns the raw SAP
  ;; instead of a string, which then fails somewhere far from here.
  (when (and (consp node) (eq (first node) :qualified))
    (return-from unmarshal-scalar (unmarshal-scalar raw (third node))))
  ;; A SIMD vector came back as the double occupying its bytes; a matrix as
  ;; its columns.
  (when (vector-node-p node)
    (return-from unmarshal-scalar (unpack-vector node raw)))
  (when (matrix-node-p node)
    (return-from unmarshal-scalar (unpack-matrix node raw)))
  (case node
    ;; The manual says a BOOL result from INVOKE is 0 or 1, and LispWorks 8.1
    ;; does exactly that on Apple silicon -- verified, and worth stating,
    ;; because BOOL encodes as 'B' there and a genuine Lisp boolean would have
    ;; been the natural guess.  INVOKE-BOOL is what returns T and NIL.
    ;; RAW is already the byte, so this normalises rather than converts: any
    ;; non-zero is YES, which is what the runtime promises and not quite what it
    ;; always sends.
    (:bool (if (eql raw 0) 0 1))
    ((:id :class :block) (pointer-of raw))
    (:sel (pointer-of raw))
    (:cstring (let ((pointer (pointer-of raw)))
                (if (cffi:null-pointer-p pointer)
                    nil
                    (%utf8-to-string pointer))))
    (t (if (and (consp node) (member (first node) '(:pointer :array)))
           (pointer-of raw)
           raw))))

(defun unmarshal-into (value result-node out-sap disposition kind)
  "Apply INVOKE-INTO's RESULT argument to a converted result.
Anything the manual does not name a conversion for is returned unchanged --
'otherwise no special conversion is performed' appears in every clause."
  (cond
    ((eq disposition :default) value)
    ((eq disposition :boolean) value)
    ;; (invoke-into 'string obj "description")
    ((eq disposition 'string)
     (if (eq result-node :id) (ns-string-to-string value) value))
    ((eq disposition 'array)
     (if (eq result-node :id) (ns-array-to-vector value nil) value))
    ((and (consp disposition) (eq (first disposition) 'array))
     (if (eq result-node :id) (ns-array-to-vector value (second disposition)) value))
    ((eq disposition :pointer) value)
    ((and (consp disposition) (eq (first disposition) :pointer)) value)
    ;; Fill a caller-supplied cons: NSRange only.
    ((consp disposition)
     (if (eq kind :range)
         (progn (setf (car disposition) (car value) (cdr disposition) (cdr value))
                disposition)
         value))
    ;; Fill a caller-supplied vector.
    ((and (vectorp disposition) (not (stringp disposition)))
     (cond ((member kind '(:rect :size :point))
            (let ((n (ecase kind (:rect 4) (:size 2) (:point 2))))
              (dotimes (i n) (setf (aref disposition i) (aref value i)))
              disposition))
           ((eq result-node :id)
            (let ((source (ns-array-to-vector value nil)))
              (dotimes (i (length source)) (setf (aref disposition i) (aref source i)))
              disposition))
           (t value)))
    ;; Copy into a caller-supplied foreign struct.
    ((cffi:pointerp disposition)
     (if (struct-node-p result-node)
         (let ((size (node-size-and-alignment result-node)))
           (dotimes (i size)
             (setf (cffi:mem-aref disposition :uint8 i)
                   (cffi:mem-aref (pointer-of out-sap) :uint8 i)))
           disposition)
         value))
    (t value)))

;;; The one call path --------------------------------------------------------

(defun %invoke (receiver method args disposition)
  "One send, with an Objective-C exception raised inside it caught: the
uncaught-exception handler (exceptions.lisp) throws here, and what it threw
becomes an OBJC-EXCEPTION.  The RETURN-FROM keeps a void result's (VALUES)."
  (let ((exception (catch 'objc-exception
                     (return-from %invoke
                       (%invoke-unguarded receiver method args disposition)))))
    (signal-objc-exception exception receiver method)))

(defun signal-objc-exception (exception receiver method)
  "Signal OBJC-EXCEPTION for EXCEPTION, the object thrown during a send of
METHOD to RECEIVER.  Its name and reason are read here, after the catch, by
sends of their own."
  (let* ((null (cffi:null-pointer-p exception))
         (name (cond (null "nil")
                     ((can-invoke-p exception "name") (invoke-into 'string exception "name"))
                     (t (%class-get-name (%object-get-class exception)))))
         (reason (cond (null nil)
                       ((can-invoke-p exception "reason") (invoke-into 'string exception "reason"))
                       (t (invoke-into 'string exception "description")))))
    (error 'objc-exception :name name :reason reason :object exception
                           :selector (parse-method-designator method)
                           :receiver receiver)))

(defun %invoke-unguarded (receiver method args disposition)
  (with-fp-traps-masked
    (with-call-temporaries
      (multiple-value-bind (selector-name explicit-arg-types explicit-result n-fixed explicit-p)
          (parse-method-designator method)
        (let ((entry (selector-entry selector-name)))
          (when (and (selector-entry-variadic-p entry) (null n-fixed))
            (maybe-warn-variadic selector-name n-fixed))
          (when (and (plusp (hash-table-count *traced-selectors*))
                     (gethash selector-name *traced-selectors*))
            (format *trace-output* "~&Invoking Objective-C method ~S ~S.~%"
                    selector-name receiver))
        (multiple-value-bind (kind pointer class) (resolve-receiver receiver)
          (when (and (cffi:pointerp pointer) (cffi:null-pointer-p pointer))
            (return-from %invoke-unguarded nil))
          (multiple-value-bind (trampoline result-node arg-nodes)
              (if explicit-p
                  (explicit-signature kind method explicit-arg-types
                                      explicit-result n-fixed)
                  (resolve-signature kind class selector-name receiver entry))
            (let ((expected (- (length arg-nodes) 2)))
              (cond ((< (length args) expected)
                     (error "Too few arguments in ~S to method ~S, wanted ~D."
                            args selector-name expected))
                    ((> (length args) expected)
                     (error "Too many arguments in ~S to method ~S, wanted ~D."
                            args selector-name expected))))
            (let* ((marshalled (loop for value in args
                                     for node in (cddr arg-nodes)
                                     collect (marshal-argument value node)))
                   ;; A structure always; on a backend whose trampolines load
                   ;; aggregates from memory, a wide vector or matrix too.
                   (structp (result-through-buffer-p result-node))
                   (size (if structp (node-size-and-alignment result-node) 0)))
              (if structp
                  (cffi:with-foreign-object (out :uint8 (max 1 size))
                    (let ((raw (call-with-signature trampoline kind pointer
                                                    (selector-entry-sel entry)
                                                    marshalled (sap-of out))))
                      (unmarshal-result raw result-node (sap-of out) disposition
                                        selector-name)))
                  (let ((raw (call-with-signature trampoline kind pointer
                                                  (selector-entry-sel entry)
                                                  marshalled (sb-sap-zero))))
                    (unmarshal-result raw result-node (sb-sap-zero) disposition)))))))))))

(defun invoke (class-or-object-pointer method &rest args)
  "Call the Objective-C method METHOD on CLASS-OR-OBJECT-POINTER.

A string receiver names a class and calls its class method; a CURRENT-SUPER
value calls the superclass's method; a pointer calls an instance method, or a
class method when the pointer is a class object.

METHOD is the whole selector including its colons -- \"setWidth:height:\" --
or the list form (name arg-types &key result-type variadic-num-of-fixed).

Results convert as the manual specifies: NSRect to #(x y width height), NSSize
to #(width height), NSPoint to #(x y), NSRange to the cons (location . length),
char * to a string, and BOOL to 0 or 1.  Use INVOKE-BOOL for T and NIL, and
INVOKE-INTO for any other structure type."
  (%invoke class-or-object-pointer method args :default))

(defmacro invoke* (receiver &rest sends)
  "Send a chain of messages, each to the result of the one before.

    (invoke* \"CSSearchableIndex\"
             (\"defaultSearchableIndex\")
             (\"indexSearchableItems:completionHandler:\" items done))

is exactly

    (invoke (invoke \"CSSearchableIndex\" \"defaultSearchableIndex\")
            \"indexSearchableItems:completionHandler:\" items done)

and expands to it: nothing runs that INVOKE would not, and there is no
intermediate object to name.  Each send is a list of a method designator --
a selector string, or the list form INVOKE takes -- and its arguments; a
send with no arguments may be the bare selector string.  The receiver is
whatever INVOKE accepts.

Not a LispWorks interface: the manual's idiom is the nesting, and this is a
reading of it, added beside INVOKE the way the block API was."
  (reduce (lambda (form send)
            (let ((send (if (stringp send) (list send) send)))
              (destructuring-bind (method &rest args) send
                `(invoke ,form ,method ,@args))))
          sends
          :initial-value receiver))

(defun failure-value-p (value)
  "Whether VALUE is what a Cocoa method returns to say it failed: nil for an
object, NO for a BOOL, nothing for void."
  (or (null value) (eql value 0)
      (and (cffi:pointerp value) (cffi:null-pointer-p value))))

(defun signal-ns-error (error receiver method)
  "Signal NS-ERROR for the NSError ERROR written by a send of METHOD to RECEIVER.
Retained first: an error written through an out-parameter is autoreleased by
convention, and the condition may outlive the pool."
  (invoke error "retain")
  (error 'ns-error :domain (invoke-into 'string error "domain")
                   :code (invoke error "code")
                   :description (invoke-into 'string error "localizedDescription")
                   :object error
                   :selector (parse-method-designator method)
                   :receiver receiver))

(defun invoke-with-error (class-or-object-pointer method &rest args)
  "INVOKE for a method whose last parameter is an NSError **, which this
supplies and checks; ARGS are the others.

    (invoke-with-error task \"launchAndReturnError:\")
    (invoke-with-error \"NSString\" \"stringWithContentsOfFile:encoding:error:\" path 4)

The method's result is returned as INVOKE would return it -- an object
pointer, 1 for a BOOL, NIL for void -- unless it says the method failed (nil,
NO, or nothing) AND an error was written, in which case NS-ERROR is signalled
carrying the error's domain, code and localized description and the NSError
itself, retained once.  A success value is returned whatever the error slot
holds, since Cocoa promises the error only on failure; a failure value with no
error written is returned unchanged.  A method that reports through a status
code rather than nil or NO keeps its own check.  METHOD must end in \"error:\";
-[NSAppleScript executeAndReturnError:] takes an NSDictionary **, not an
NSError **, and is not for this.

Not a LispWorks interface: LispWorks has no NSError helper, and this is one
function beside INVOKE."
  (let ((selector (parse-method-designator method)))
    (unless (and (>= (length selector) 6)
                 (string= "rror:" selector :start2 (- (length selector) 5)))
      (error "~S does not end in \"error:\"; INVOKE-WITH-ERROR supplies the ~
NSError ** parameter, which is the last one, itself." selector)))
  (cffi:with-foreign-object (error-out :pointer)
    (setf (cffi:mem-ref error-out :pointer) (cffi:null-pointer))
    (let* ((result (%invoke class-or-object-pointer method
                            (append args (list error-out)) :default))
           (error (cffi:mem-ref error-out :pointer)))
      (if (and (not (cffi:null-pointer-p error)) (failure-value-p result))
          (signal-ns-error error class-or-object-pointer method)
          result))))

(defun invoke-bool (class-or-object-pointer method &rest args)
  "Like INVOKE, but a BOOL result of NO returns NIL and anything else T."
  (%invoke class-or-object-pointer method args :boolean))

(defun invoke-into (result class-or-object-pointer method &rest args)
  "Like INVOKE, but converts or stores the result as RESULT directs.

RESULT may be the symbol STRING or ARRAY, a list (ARRAY element-style), the
keyword :POINTER or a list (:POINTER element-type), a vector to fill, a cons to
fill from an NSRange, or a pointer to a foreign structure to copy into.  When
the result type does not match what RESULT asks for, no conversion is performed
and the ordinary INVOKE value is returned."
  (%invoke class-or-object-pointer method args result))

(defun alloc-init-object (class)
  "Allocate and initialize an instance of CLASS.
Equivalent to (invoke (invoke class \"alloc\") \"init\")."
  (invoke (invoke class "alloc") "init"))

(defun description (pointer)
  "Return the Objective-C -description of POINTER as a string."
  (invoke-into 'string pointer "description"))
