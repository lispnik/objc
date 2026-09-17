;;;; src/method-def.lisp -- DEFINE-OBJC-METHOD, DEFINE-OBJC-CLASS-METHOD,
;;;; CURRENT-SUPER.
;;;;
;;;; The expansion builds a closure and hands it to BUILD-IMP, which wraps it in
;;;; a real function pointer with the method's exact C signature.  Argument and
;;;; result conversion is generated per argument at macroexpansion time, so
;;;; there is no runtime type dispatch inside the body of something like
;;;; -drawRect: that Cocoa calls on every frame.

(in-package #:objc)

;;; CURRENT-SUPER exists globally only to carry documentation and to give a
;;; useful error when it is used somewhere it means nothing.  Inside a method
;;; body the MACROLET in the expansion shadows this definition, which is what
;;; gives it the dynamic extent the manual specifies -- enforced by scoping
;;; rather than by convention.

(defmacro current-super ()
  "Return a value that INVOKE and CAN-INVOKE-P send to the superclass, like
super in Objective-C.

Valid only inside a DEFINE-OBJC-METHOD or DEFINE-OBJC-CLASS-METHOD body, where
a local macro definition shadows this one.  In DEFINE-OBJC-METHOD it reaches
the superclass's instance methods; in DEFINE-OBJC-CLASS-METHOD, its class
methods.

    (define-objc-method (\"areaOfWidth:height:\" (:unsigned :int))
        ((self my-special-object) (width (:unsigned :int)) (height (:unsigned :int)))
      (* 4 (invoke (current-super) \"areaOfWidth:height:\" width height)))"
  (error "CURRENT-SUPER is only meaningful inside a DEFINE-OBJC-METHOD or ~
DEFINE-OBJC-CLASS-METHOD body."))


(defstruct (method-definition (:constructor make-method-definition
                                  (lisp-class-name selector class-method-p
                                   result-node arg-nodes encoding body-maker)))
  lisp-class-name selector class-method-p result-node arg-nodes encoding body-maker)

;;; Conversion ---------------------------------------------------------------

(defun argument-conversion-form (raw node style)
  "The form that turns a raw incoming argument into what the body should see."
  (cond
    ;; :FOREIGN asks for the unconverted value: a number, or a pointer.
    ((eq style :foreign)
     (if (or (struct-node-p node)
             (member node '(:id :class :sel :cstring :block))
             (and (consp node) (member (first node) '(:pointer :array))))
         `(pointer-of ,raw)
         raw))
    ((struct-node-p node)
     (let ((kind (cocoa-struct-kind node)))
       (if kind
           `(read-cocoa-struct ,raw ,kind)
           `(pointer-of ,raw))))
    ((eq node :id)
     (cond ((eq style 'string) `(ns-string-to-string (pointer-of ,raw)))
           ((eq style 'array) `(ns-array-to-vector (pointer-of ,raw) nil))
           ((and (consp style) (eq (first style) 'array))
            `(ns-array-to-vector (pointer-of ,raw) ',(second style)))
           (t `(pointer-of ,raw))))
    ((eq node :cstring)
     (if (eq style 'string)
         `(let ((pointer (pointer-of ,raw)))
            (unless (cffi:null-pointer-p pointer)
              (%utf8-to-string pointer)))
         `(pointer-of ,raw)))
    ((eq node :bool) `(not (eql 0 ,raw)))
    ;; A SIMD vector arrives as the double occupying its bytes; a matrix as
    ;; a vector of its columns' carriers.
    ((vector-node-p node) `(unpack-vector ',node ,raw))
    ((matrix-node-p node) `(unpack-matrix ',node ,raw))
    ((member node '(:class :sel :block)) `(pointer-of ,raw))
    ((and (consp node) (member (first node) '(:pointer :array))) `(pointer-of ,raw))
    ((and (consp node) (eq (first node) :qualified))
     (argument-conversion-form raw (third node) style))
    (t raw)))

(defun write-method-struct-result (value node result-sap)
  "Store a Lisp method's structure result into the buffer the caller supplied.

The manual, for a result type of NSRect: \"If the value is a vector of four
elements of the form #(x y width height), the x, y, width and height are used to
form the returned rectangle.  Otherwise it is assumed to be a foreign pointer to
a cocoa:ns-rect and is copied.\"  The same for NSSize, NSPoint and NSRange, and
for any other structure a pointer is what the manual offers, and a sequence
with one element per field is taken here as well."
  (let ((kind (cocoa-struct-kind node)))
    (cond
      ((null value) nil)
      ((and kind (or (vectorp value) (consp value)))
       (write-cocoa-struct result-sap kind value))
      ;; Any other structure, from a sequence with one element per field.
      ((struct-sequence-p value)
       (write-struct-from-sequence (pointer-of result-sap) node value))
      ((cffi:pointerp value)
       (let ((size (node-size-and-alignment node))
             (target (pointer-of result-sap)))
         (dotimes (i size)
           (setf (cffi:mem-aref target :uint8 i) (cffi:mem-aref value :uint8 i)))))
      ((typed-pointer-p value)
       (let ((size (node-size-and-alignment node))
             (target (pointer-of result-sap))
             (source (typed-pointer-pointer value)))
         (dotimes (i size)
           (setf (cffi:mem-aref target :uint8 i) (cffi:mem-aref source :uint8 i)))))
      (t (error "Cannot return ~S as a ~A result." value (or kind "structure"))))
    nil))

(defun convert-method-result (value node)
  "Convert a Lisp method's return value to what its C signature needs.

An NSString or NSArray made here is RETAINED and the caller is expected to
release it, which is what the manual specifies for a string or vector returned
from a method body -- the opposite of the argument direction, where INVOKE
releases the temporary itself."
  (cond
    ((eq node :void) nil)
    ((eq node :id)
     (sap-of (cond ((null value) (cffi:null-pointer))
                   ((stringp value) (string-to-ns-string value))
                   ((and (vectorp value) (not (stringp value)))
                    (vector-to-ns-array value))
                   ((cffi:pointerp value) value)
                   (t (objc-object-pointer value)))))
    ((eq node :class)
     (sap-of (if (cffi:pointerp value) value (coerce-to-objc-class value))))
    ((eq node :sel) (sap-of (coerce-to-selector value)))
    ((eq node :cstring)
     (sap-of (cond ((null value) (cffi:null-pointer))
                   ((cffi:pointerp value) value)
                   (t (%string-to-utf8 value)))))
    ;; SBCL's (boolean 8) does its conversion on the CALLER's side: an alien
    ;; callable declared to return one wants a 1 or a 0, and returning T is a
    ;; type error against (unsigned-byte 8).  Measured, not assumed.
    ((eq node :bool) (cond ((eq value t) 1) ((null value) 0) ((eql value 0) 0) (t 1)))
    ;; The manual: for a char result NIL is NO and T is YES, and anything else
    ;; must be an appropriate integer.
    ((member node '(:char :uchar))
     (cond ((eq value t) 1) ((null value) 0) (t value)))
    ((eq node :float) (coerce value 'single-float))
    ((eq node :double) (coerce value 'double-float))
    ;; A SIMD vector leaves as the double occupying its bytes; a matrix as
    ;; its columns' carriers.
    ((vector-node-p node) (pack-vector node value))
    ((matrix-node-p node) (pack-matrix node value))
    ((or (member node '(:block))
         (and (consp node) (member (first node) '(:pointer :array))))
     (sap-of (cond ((null value) (cffi:null-pointer))
                   ((cffi:pointerp value) value)
                   (t (objc-object-pointer value)))))
    ((and (consp node) (eq (first node) :qualified))
     (convert-method-result value (third node)))
    (t value)))

;;; The macros ---------------------------------------------------------------

(defun expand-define-objc-method (name-spec object-argspec argspecs body class-method-p)
  (destructuring-bind (selector result-type &optional result-style) name-spec
    (destructuring-bind (object-var class-name &optional pointer-var) object-argspec
      (let* ((result-node (node-for-fli-type result-type))
             (arg-nodes (list* :id :sel
                               (loop for (nil arg-type) in argspecs
                                     collect (node-for-fli-type arg-type))))
             (encoding (method-type-encoding result-node (cddr arg-nodes)))
             (self (gensym "SELF"))
             (cmd (gensym "CMD"))
             (result-sap (gensym "RESULT"))
             (super (gensym "SUPER"))
             (raws (loop for i from 0 below (length argspecs)
                         collect (gensym (format nil "RAW~D-" i))))
             ;; A non-keyword result-style names a variable bound to a pointer
             ;; to the result structure, which the body fills in.
             (struct-result-var (and result-style
                                     (symbolp result-style)
                                     (not (keywordp result-style))
                                     result-style))
             (expected-args (selector-argument-count selector)))
        ;; A method body may open with declarations -- the manual's own
        ;; area-calculator example starts (declare (ignore sender)) -- and they
        ;; have to land inside the LET* that binds the arguments, not in front
        ;; of it where they would be evaluated as a form.
        (multiple-value-bind (body declarations) (alexandria:parse-body body)
        (unless (= expected-args (length argspecs))
          (error "The selector ~S takes ~D argument~:P but ~D ~:*~[are~;is~:;are~] ~
declared." selector expected-args (length argspecs)))
        `(record-method-definition
          (make-method-definition
           ',class-name ,selector ,class-method-p
           ',result-node ',arg-nodes ,encoding
           (lambda (,super)
             (declare (ignorable ,super))
             (lambda (,self ,cmd ,result-sap ,@raws)
               (declare (ignorable ,self ,cmd ,result-sap))
               (macrolet ((current-super ()
                            ;; A local macro, so it is simply unbound outside
                            ;; these two macros' bodies -- exactly the extent
                            ;; the manual documents, enforced at compile time
                            ;; rather than by convention.
                            '(make-super-reference (pointer-of ,self) ,super)))
                 (let* ((,object-var (or (objc-object-from-pointer (pointer-of ,self))
                                         (pointer-of ,self)))
                        ,@(when pointer-var
                            `((,pointer-var (pointer-of ,self))))
                        ,@(when struct-result-var
                            `((,struct-result-var
                               ,(if (and (consp result-type)
                                         (eq (first result-type) :struct))
                                    `(make-typed-pointer (pointer-of ,result-sap)
                                                         ',(second result-type))
                                    `(pointer-of ,result-sap)))))
                        ,@(loop for (arg-var arg-type arg-style) in argspecs
                                for raw in raws
                                for node in (cddr arg-nodes)
                                collect (list arg-var
                                              (argument-conversion-form
                                               raw node arg-style))
                                do (progn arg-type)))
                   (declare (ignorable ,object-var))
                   ,@declarations
                   ,(cond
                      ;; The body fills the result structure through the
                      ;; variable and its own value is ignored.
                      (struct-result-var `(progn ,@body nil))
                      ;; A structure result with no result variable: the body
                      ;; returns #(x y width height) or a pointer, and it has to
                      ;; be written into the buffer the caller gave us.
                      ((struct-node-p result-node)
                       `(write-method-struct-result (progn ,@body)
                                                    ',result-node ,result-sap))
                      (t `(convert-method-result (progn ,@body) ',result-node))))))))
          nil))))))

(defmacro define-objc-method ((name result-type &optional result-style)
                              (object-argspec &rest argspecs)
                              &body body)
  "Define an Objective-C instance method.

NAME is the whole selector including its colons.  OBJECT-ARGSPEC is
(object-var class-name [pointer-var]): OBJECT-VAR is bound to the Lisp object
for the receiver, and POINTER-VAR, if given, to the receiver's pointer.  Each
ARGSPEC is (arg-var arg-type [arg-style]).

ARG-STYLE :FOREIGN binds the raw value.  Otherwise, for an object argument the
style STRING converts an NSString to a Lisp string, ARRAY converts an NSArray to
a vector, and (ARRAY element-style) converts recursively.

RESULT-STYLE :FOREIGN passes the body's value through unconverted, :LISP or NIL
converts it, and a non-keyword symbol names a variable bound to a pointer to the
result structure for the body to fill in.

CURRENT-SUPER is available in the body and returns a value that INVOKE sends to
the superclass, like super in Objective-C.

    (define-objc-method (\"areaOfWidth:height:\" (:unsigned :int))
        ((self my-object) (width (:unsigned :int)) (height (:unsigned :int)))
      (* width height))"
  (expand-define-objc-method (list name result-type result-style)
                             object-argspec argspecs body nil))

(defmacro define-objc-class-method ((name result-type &optional result-style)
                                    (object-argspec &rest argspecs)
                                    &body body)
  "Define an Objective-C class method.

Exactly like DEFINE-OBJC-METHOD except that OBJECT-VAR is bound to the class
rather than an instance, POINTER-VAR to the class object, and CURRENT-SUPER
sends to the superclass's class methods."
  (expand-define-objc-method (list name result-type result-style)
                             object-argspec argspecs body t))

(defun method-type-encoding (result-node arg-nodes)
  "The type encoding string for a method, self and _cmd included.
This is what class_addMethod records, and what the runtime hands back to anyone
who asks for the method's signature later."
  (flet ((encoding (node)
           ;; A SIMD vector is written as Clang writes it, which is nothing:
           ;; the runtime and every introspecting consumer expect that, and
           ;; the hole it leaves is what the recorded signature fills.
           (cond ((vector-node-p node) "")
                 ((matrix-node-p node) (unparse-type node))
                 (t (canonical-encoding node)))))
    (if (or (vector-node-p result-node) (matrix-node-p result-node)
            (some #'vector-node-p arg-nodes) (some #'matrix-node-p arg-nodes))
        ;; With a hole, the frame offsets Clang writes go in too, because
        ;; they are what makes the hole visible: a leading offset says the
        ;; result is missing, and an argument written as nothing between two
        ;; offsets is one the parser can count against the selector.
        ;; Without them "@:" would read as an id result and a lone _cmd.
        (with-output-to-string (out)
          (let ((slots (+ 2 (length arg-nodes))))
            (format out "~a~d@0:8" (encoding result-node) (* 8 slots))
            (loop for node in arg-nodes
                  for offset from 16 by 8
                  do (format out "~a~d" (encoding node) offset))))
        (with-output-to-string (out)
          (write-string (encoding result-node) out)
          (write-string "@:" out)
          (dolist (node arg-nodes)
            (write-string (encoding node) out))))))

;;; Installation -------------------------------------------------------------

(defun record-method-definition (definition ignored)
  (declare (ignore ignored))
  (pushnew definition *all-method-definitions*)
  (let ((class (find-class (method-definition-lisp-class-name definition) nil)))
    (cond
      ((null class)
       (error "No class named ~S." (method-definition-lisp-class-name definition)))
      ((not *objc-initialized*)
       (push definition *pending-method-definitions*)
       definition)
      (t (install-method-definition definition nil)))))

(defun install-method-definition (definition target-class)
  "Install DEFINITION on TARGET-CLASS, or on whatever its own class implies.

A method defined on a mixin -- a class naming no Objective-C class and
inheriting none -- is recorded and installed on every subclass that does name
one, in either definition order."
  (let* ((lisp-class (find-class (method-definition-lisp-class-name definition)))
         (class (or target-class lisp-class)))
    (cond
      ((and (null target-class) (mixin-class-p lisp-class))
       (pushnew definition (gethash lisp-class *mixin-methods*))
       ;; Any subclass that already exists gets it now.
       (dolist (subclass (all-subclasses lisp-class))
         (unless (mixin-class-p subclass)
           (install-method-definition definition subclass)))
       definition)
      (t
       (let ((objc-class (objc-class-of-lisp-class class)))
         (unless objc-class
           (return-from install-method-definition definition))
         (install-imp objc-class
                      (method-definition-selector definition)
                      (method-definition-class-method-p definition)
                      (method-definition-result-node definition)
                      (method-definition-arg-nodes definition)
                      (method-definition-encoding definition)
                      (method-definition-body-maker definition))
         definition)))))

(defun all-subclasses (class)
  (let ((result '()))
    (labels ((walk (class)
               (dolist (subclass (c2mop:class-direct-subclasses class))
                 (pushnew subclass result)
                 (walk subclass))))
      (walk class))
    result))

(defun install-imp (objc-class selector class-method-p result-node arg-nodes
                    encoding body-maker)
  "Build and install an IMP for SELECTOR on OBJC-CLASS."
  ;; A method with a SIMD vector in its signature registers an encoding with
  ;; a hole in it, as Clang would; recording the signature here is what lets
  ;; INVOKE call the method back without being told it a second time.
  (when (or (vector-node-p result-node) (matrix-node-p result-node)
            (some #'vector-node-p arg-nodes) (some #'matrix-node-p arg-nodes))
    ;; ARG-NODES begins with self and _cmd here; the table holds the
    ;; declared arguments only.
    (setf (signature-override selector) (cons result-node (cddr arg-nodes))))
  ;; Whatever any class was recorded as answering this selector with may be
  ;; about to change: this is the one place that changes it.
  (forget-selector-sites selector)
  (let* ((target (if class-method-p (%object-get-class objc-class) objc-class))
         ;; The superclass to send to for CURRENT-SUPER, captured at install
         ;; time.  NOT object_getClass(self) at call time, which for a
         ;; sub-subclass would find this very method and recurse forever.
         (super-class (%class-get-superclass target))
         (body (funcall body-maker super-class))
         (key (list (%class-get-name objc-class) selector class-method-p))
         (previous (gethash key *imp-registry*))
         (imp nil))
    (if (methods-as-blocks-p)
        ;; The method is a block over one callable per signature, and libobjc
        ;; mints the entry point; see "Methods as blocks" in blocks.lisp.  The
        ;; registry keeps the block, whose closure is the method, for as long
        ;; as the method is installed, and the IMP so a redefinition can give
        ;; its trampoline back.
        (let ((block (make-imp-block result-node arg-nodes selector body)))
          (setf imp (%imp-implementation-with-block (objc-block-pointer block)))
          (when (cffi:null-pointer-p imp)
            (error "libobjc would not make an IMP for ~S." selector))
          (setf (gethash key *imp-registry*) (list block imp encoding)))
        ;; A callable of the method's own.  The registry keeps it alive
        ;; forever: the seam recycles a callback's trampoline once it becomes
        ;; garbage, and Cocoa would still be holding the old address.
        (multiple-value-bind (sap name) (build-imp result-node arg-nodes body)
          (setf imp (pointer-of sap))
          (setf (gethash key *imp-registry*) (list name sap encoding))))
    (let ((existing (if class-method-p
                        (%class-get-class-method objc-class (coerce-to-selector selector))
                        (%class-get-instance-method objc-class (coerce-to-selector selector)))))
      (if (objc-pointer-p existing)
          (%class-replace-method target (coerce-to-selector selector) imp encoding)
          (unless (%class-add-method target (coerce-to-selector selector) imp encoding)
            (error "Failed to add method ~S." selector))))
    ;; The definition this replaced, if any: libobjc releases its copy of the
    ;; block and frees the trampoline, and the literal goes with it.
    (when (and previous (objc-block-p (first previous)))
      (%imp-remove-block (second previous))
      (free-objc-block (first previous)))
    selector))
