;;;; src/dispatch.lisp -- the single call path.
;;;;
;;;; There is exactly one place in this library that calls a trampoline, and it
;;;; is CALL-WITH-SIGNATURE below.  INVOKE, INVOKE-BOOL and INVOKE-INTO all
;;;; funnel through it and differ only in what they do with the result; a super
;;;; send differs only in which entry address its trampoline was built for.  The
;;;; alternative -- separate paths for struct returns, for super, for forwarding
;;;; -- is how a bridge accumulates cases that behave subtly differently from
;;;; the main one.
;;;;
;;;; Two caches, both of which earn their place:
;;;;
;;;;   L1 is keyed on (kind . method-address), an EQUAL hash over a fixnum.  It
;;;;      hits on the second and every later send of a given selector to a given
;;;;      class, and costs one probe with no parsing.
;;;;
;;;;   L2 is keyed on the canonical signature.  Most Cocoa methods share a small
;;;;      number of shapes -- "v@:@" and "@@:" alone cover an enormous fraction
;;;;      -- so this is what keeps the number of COMPILE calls in the low
;;;;      hundreds instead of the tens of thousands.

(in-package #:objc)

(defvar *allow-null-pointer-invoke* nil
  "When true, sending to a null pointer returns NIL instead of signalling.
Objective-C treats a message to nil as a no-op returning zero, so this exists
for code that relies on that; it is off by default because the usual cause is a
mistake.  LispWorks has the same switch, also undocumented.")

(defvar *trampoline-by-method* (make-hash-table :test 'equal)
  "(kind . method-address) -> trampoline.  The fast path.")

(defvar *trampoline-by-signature* (make-hash-table :test 'equal)
  "(kind canonical-signature n-fixed) -> trampoline.  The sharing path.")

(defvar *signature-by-method* (make-hash-table :test 'equal)
  "(kind . method-address) -> (result-node . arg-nodes), so a cache hit need not
re-parse the encoding to know how to marshal.")

(defstruct (super-reference (:constructor make-super-reference (receiver class)))
  "What CURRENT-SUPER returns: the receiver, and the class to start the method
search in.

An ordinary heap object rather than a stack-allocated struct objc_super.  The
manual gives super-value dynamic extent; ours outlives the form, which is
strictly more permissive and cannot break conforming code.  The real 16-byte
struct objc_super is built per call in CALL-WITH-SIGNATURE, which is what keeps
its extent honest whatever the caller does with the reference."
  receiver
  class)

(defun resolve-receiver (receiver)
  "Return (VALUES KIND RECEIVER-POINTER LOOKUP-CLASS).

A string names a class and its class methods are called; a CURRENT-SUPER value
sends to the superclass; a pointer sends to an instance, or to a class when the
pointer is itself a class object.  Both objc_msgSend and objc_msgSendSuper take
a pointer first, so KIND selects only the entry address and the generated
trampoline is otherwise identical."
  (cond
    ((super-reference-p receiver)
     (values :super receiver (super-reference-class receiver)))
    ((stringp receiver)
     (let ((class (coerce-to-objc-class receiver)))
       ;; A message to a class runs its CLASS methods, which live on the
       ;; metaclass.
       (values :send class (%object-get-class class))))
    (t
     (let ((pointer (receiver-pointer receiver)))
       (when (cffi:null-pointer-p pointer)
         (unless *allow-null-pointer-invoke*
           (error "Invoking a method on a null pointer.")))
       (values :send pointer (%object-get-class pointer))))))

;;; Signature resolution -----------------------------------------------------

(defun canonical-signature (result-node arg-nodes)
  (with-output-to-string (out)
    (write-string (canonical-encoding result-node) out)
    (dolist (node arg-nodes)
      (write-string (canonical-encoding node) out))))

(defun trampoline-for (kind result-node arg-nodes n-fixed)
  (let ((key (list kind (canonical-signature result-node arg-nodes) n-fixed)))
    (or (gethash key *trampoline-by-signature*)
        (setf (gethash key *trampoline-by-signature*)
              (build-trampoline kind result-node arg-nodes n-fixed)))))

(defun resolve-signature (kind class selector-name receiver)
  "Return (VALUES TRAMPOLINE RESULT-NODE ARG-NODES) for a send.

Signals NO-SUCH-METHOD when the class does not implement the selector.  That
check is not a convenience: resolving the Method is how the call signature is
discovered in the first place, and it means an unimplemented selector fails
here, in Lisp, instead of reaching the runtime and raising an Objective-C
exception that would abort the process."
  (let ((method (and (objc-pointer-p class) (find-method-for class selector-name))))
    (unless method
      (error 'no-such-method
             :selector selector-name
             :receiver receiver
             :class-name (and (objc-pointer-p class) (%class-get-name class))
             :superclass-name (when (eq kind :super)
                                (and (objc-pointer-p class) (%class-get-name class)))))
    (let* ((key (cons kind (cffi:pointer-address method)))
           (cached (gethash key *trampoline-by-method*)))
      (if cached
          (let ((signature (gethash key *signature-by-method*)))
            (values cached (car signature) (cdr signature)))
          (multiple-value-bind (result args)
              (parse-method-encoding (method-encoding method))
            (let ((trampoline (trampoline-for kind result args nil)))
              (setf (gethash key *trampoline-by-method*) trampoline
                    (gethash key *signature-by-method*) (cons result args))
              (values trampoline result args)))))))

;;; The call -----------------------------------------------------------------

(defun call-with-signature (trampoline kind receiver selector args out-sap)
  "Perform one send and return whatever the trampoline returned.

ARGS are already marshalled: SAPs for pointers and structs, Lisp numbers for
scalars.  A struct result has been written through OUT-SAP and the value here is
NIL; the caller knows which case it is from the result node."
  (if (eq kind :super)
      ;; struct objc_super { id receiver; Class super_class; } -- 16 bytes.
      ;; Built per call, so a super reference that outlived its form still
      ;; cannot leave a dangling pointer behind.
      (cffi:with-foreign-object (super :pointer 2)
        (setf (cffi:mem-aref super :pointer 0)
              (receiver-pointer (super-reference-receiver receiver))
              (cffi:mem-aref super :pointer 1)
              (super-reference-class receiver))
        (apply trampoline out-sap (sap-of super) (sap-of selector) args))
      (apply trampoline out-sap (sap-of receiver) (sap-of selector) args)))

;;; A minimal sender for the conversion layer, which needs to talk to NSString
;;; and NSArray before INVOKE exists.  Same path, no conversion.

(defun send-raw (receiver selector-name &rest args)
  "Send SELECTOR-NAME to RECEIVER with already-marshalled ARGS.
Used by CONVERT, which cannot call INVOKE without circularity."
  (multiple-value-bind (kind pointer class) (resolve-receiver receiver)
    (multiple-value-bind (trampoline result-node arg-nodes)
        (resolve-signature kind class selector-name receiver)
      (declare (ignore arg-nodes))
      (let ((null-sap (sb-sap-zero)))
        (values (call-with-signature trampoline kind pointer
                                     (coerce-to-selector selector-name)
                                     args null-sap)
                result-node)))))

(defun can-invoke-p (class-or-object-pointer method)
  "True when METHOD can be invoked for CLASS-OR-OBJECT-POINTER.

The receiver follows the same rule as INVOKE: a string names a class and its
class methods are checked; a CURRENT-SUPER value checks the superclass; a
pointer checks the instance or class methods as appropriate."
  (let ((class (if (super-reference-p class-or-object-pointer)
                   (super-reference-class class-or-object-pointer)
                   (lookup-class-for-receiver class-or-object-pointer))))
    (and (objc-pointer-p class)
         (not (null (find-method-for class (selector-name method))))
         t)))

(defun clear-dispatch-caches ()
  (clrhash *trampoline-by-method*)
  (clrhash *trampoline-by-signature*)
  (clrhash *signature-by-method*))

(add-image-restore-thunk 'clear-dispatch-caches)
