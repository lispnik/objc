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
;;;;   L1 is keyed on the selector name and then on the receiver's class: an
;;;;      EQUAL hash over the string to a SELECTOR-ENTRY, then an EQL hash over
;;;;      the class address to a SEND-SITE holding the trampoline and the parsed
;;;;      signature.  It hits on the second and every later send of a selector
;;;;      to a class, and costs two probes with no parsing and -- this is the
;;;;      point -- no runtime call.  It used to be keyed on the Method, which
;;;;      meant class_getInstanceMethod on every send to find the key; libobjc
;;;;      does not cache that walk, and it measured 34 ns for a method on the
;;;;      receiver's own class and 1.1 µs for -self inherited through the
;;;;      NSString cluster (bench/RESULTS.md, 2026-09-16).  The entry also
;;;;      carries the SEL and whether the selector is a known variadic, so a
;;;;      send registers nothing and scans nothing.
;;;;
;;;;      Keying on the class is sound because a miss is never cached: a
;;;;      selector the class does not answer today is looked up again
;;;;      tomorrow.  What is cached is the signature the class answered with,
;;;;      and Objective-C requires that to stay the same for a selector on a
;;;;      class -- the runtime's own dispatch assumes it.  The one party that
;;;;      changes a class's methods from here is DEFINE-OBJC-METHOD, and it
;;;;      forgets the selector's sites when it installs.
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

(defvar *trampoline-by-signature* (make-hash-table :test 'equal)
  "(kind canonical-signature n-fixed) -> trampoline.  The sharing path.")

(defparameter +known-variadic-selectors+
  '("stringWithFormat:" "initWithFormat:" "localizedStringWithFormat:"
    "stringByAppendingFormat:" "appendFormat:" "arrayWithObjects:"
    "initWithObjects:" "dictionaryWithObjectsAndKeys:" "raise:format:"
    "predicateWithFormat:")
  "Selectors that are variadic in Cocoa.

On Apple arm64 a variadic call passes its variable arguments on the stack while
a fixed-arity call passes them in registers, so calling one of these without
:VARIADIC-NUM-OF-FIXED reads garbage.  MAYBE-WARN-VARIADIC in invoke.lisp says
so, once per selector; the check itself is made once, when the selector's
entry is created.")

(defstruct (send-site (:constructor make-send-site (trampoline result-node arg-nodes)))
  "What one class answers one selector with: the trampoline for its signature
and the parsed signature itself, so a hit marshals without re-parsing."
  trampoline result-node arg-nodes)

(defstruct (selector-entry (:constructor %make-selector-entry (name sel variadic-p)))
  "Everything a send needs to know about a selector name, found once per name.
SITES maps a class address to its SEND-SITE for a plain send; SUPER-SITES the
same for a super send, whose trampolines enter objc_msgSendSuper instead."
  name sel variadic-p
  (sites (make-hash-table :test 'eql))
  (super-sites (make-hash-table :test 'eql)))

(defvar *selector-entries* (make-hash-table :test 'equal)
  "Selector name -> SELECTOR-ENTRY.  The fast path.")

(defvar *explicit-sites* (make-hash-table :test 'eq)
  "List-form method designator -> SEND-SITE, keyed on the list itself.  A
quoted literal is the same object on every send and hits; a freshly consed
designator misses and is parsed, which is correct and merely slower.")

(defun selector-entry (selector-name)
  (or (gethash selector-name *selector-entries*)
      (setf (gethash selector-name *selector-entries*)
            (%make-selector-entry selector-name
                                  (coerce-to-selector selector-name)
                                  (and (member selector-name +known-variadic-selectors+
                                               :test #'string=)
                                       t)))))

(defun forget-selector-sites (selector-name)
  "Drop what every class was recorded as answering SELECTOR-NAME with.
Called when a method is installed from Lisp, the one change to a class's
methods this library makes itself."
  (let ((entry (gethash selector-name *selector-entries*)))
    (when entry
      (clrhash (selector-entry-sites entry))
      (clrhash (selector-entry-super-sites entry)))))

(defun send-site-count ()
  "How many (class, selector) pairs have a cached signature.  For the tests."
  (let ((count 0))
    (maphash (lambda (name entry)
               (declare (ignore name))
               (incf count (+ (hash-table-count (selector-entry-sites entry))
                              (hash-table-count (selector-entry-super-sites entry)))))
             *selector-entries*)
    (+ count (hash-table-count *explicit-sites*))))


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

;;; Signatures the runtime cannot encode ---------------------------------------
;;;
;;; Clang writes nothing for a SIMD vector, so a method that takes or returns
;;; one has a signature with a hole in it -- see the note in encoding.lisp.
;;; This table is where such a signature is spelled once, by selector, and it
;;; is consulted only when the runtime's own signature has a hole: a method the
;;; runtime describes completely is never second-guessed.

(defvar *signature-overrides* (make-hash-table :test 'equal)
  "Selector name -> (RESULT-NODE . ARG-NODES), the declared arguments only.")

(defun signature-override (selector-name)
  (gethash selector-name *signature-overrides*))

(defun (setf signature-override) (signature selector-name)
  (setf (gethash selector-name *signature-overrides*) signature))

(defun declare-objc-signature (selector arg-types &key (result-type :void))
  "Declare the signature of SELECTOR, for methods whose encoding has a hole.

Clang cannot encode a SIMD vector type, so -[GKAgent2D setPosition:] is
recorded by the runtime as taking no arguments and -[GKAgent2D position] as
returning nothing.  ARG-TYPES and RESULT-TYPE are what the list form of a
method name takes -- FLI type descriptors, (:VECTOR :FLOAT 2) among them --
and after

  (declare-objc-signature \"setPosition:\" '((:vector :float 2)))
  (declare-objc-signature \"position\" '() :result-type '(:vector :float 2))

plain INVOKE passes and returns a Lisp vector.  The declaration is consulted
only for a selector whose runtime signature is incomplete; a method the
runtime describes fully is never affected.  Returns SELECTOR."
  (let ((selector (string selector)))
    (setf (signature-override selector)
          (cons (node-for-fli-type result-type)
                (mapcar #'node-for-fli-type arg-types)))
    selector))

(defun resolve-signature (kind class selector-name receiver
                          &optional (entry (selector-entry selector-name)))
  "Return (VALUES TRAMPOLINE RESULT-NODE ARG-NODES) for a send.

Signals NO-SUCH-METHOD when the class does not implement the selector.  That
check is not a convenience: resolving the Method is how the call signature is
discovered in the first place, and it means an unimplemented selector fails
here, in Lisp, instead of reaching the runtime and raising an Objective-C
exception that would abort the process."
  (let* ((sites (if (eq kind :super)
                    (selector-entry-super-sites entry)
                    (selector-entry-sites entry)))
         (address (and (objc-pointer-p class) (cffi:pointer-address class)))
         (site (and address (gethash address sites))))
    (when site
      (return-from resolve-signature
        (values (send-site-trampoline site)
                (send-site-result-node site)
                (send-site-arg-nodes site))))
    ;; The Method is asked for only here, on the first send of this selector
    ;; to this class.  A forwarded selector has no Method and the same site.
    (let* ((method (and address (find-method-for class selector-name)))
           (encoding (cond (method (method-encoding method))
                          ((eq kind :send) (forwarded-encoding receiver selector-name)))))
      (unless encoding
        (error 'no-such-method
               :selector selector-name
               :receiver receiver
               :class-name (and (objc-pointer-p class) (%class-get-name class))
               :superclass-name (when (eq kind :super)
                                  (and (objc-pointer-p class) (%class-get-name class)))))
      (multiple-value-bind (result args) (parse-method-encoding encoding selector-name)
        ;; A hole in the signature means a type the runtime could not write
        ;; down.  Either it was declared, and the declaration is the
        ;; signature, or the call cannot be made and says why.
        (when (signature-unencodable-p result args)
          (let ((override (signature-override selector-name)))
            (unless override
              (error 'unencodable-signature
                     :selector selector-name :encoding encoding))
            (setf result (car override)
                  args (list* :id :sel (cdr override)))))
        (let ((trampoline (trampoline-for kind result args nil)))
          (when address
            (setf (gethash address sites) (make-send-site trampoline result args)))
          (values trampoline result args))))))

(defun explicit-signature (kind method arg-types result-type n-fixed)
  "Return (VALUES TRAMPOLINE RESULT-NODE ARG-NODES) for the list-form
designator METHOD, whose types replace the runtime's view entirely -- even
when its argument list is empty.  Self and _cmd are prepended because the
caller does not write them.  Cached on the designator itself for a plain
send, so the canonical signature is not rebuilt per call."
  (let ((site (and (eq kind :send) (gethash method *explicit-sites*))))
    (when site
      (return-from explicit-signature
        (values (send-site-trampoline site)
                (send-site-result-node site)
                (send-site-arg-nodes site))))
    (let* ((result (node-for-fli-type result-type))
           (nodes (list* :id :sel (mapcar #'node-for-fli-type arg-types)))
           (trampoline (trampoline-for kind result nodes (and n-fixed (+ n-fixed 2)))))
      (when (eq kind :send)
        (setf (gethash method *explicit-sites*) (make-send-site trampoline result nodes)))
      (values trampoline result nodes))))

;;; Forwarded selectors -------------------------------------------------------
;;;
;;; Not every message an object answers has a Method behind it.  A class may
;;; implement -forwardInvocation: and answer for selectors it never declared:
;;; NSUndoManager's -prepareWithInvocationTarget: proxy, NSXPCConnection's
;;; remote object, and -- the one that made this necessary -- UITextField,
;;; which answers the UITextInputTraits setters by forwarding, so that
;;; class_getInstanceMethod finds nothing for -setAutocorrectionType: on a
;;; class that plainly takes it.
;;;
;;; What such an object does have is a signature: -forwardInvocation: cannot
;;; work without -methodSignatureForSelector:, so a forwarding class always
;;; implements it.  The NSMethodSignature it returns is the same information a
;;; Method's type encoding carries, and is read back into one here.  The
;;; refusal for a selector nobody answers is unchanged: an object that neither
;;; implements nor forwards a selector has no signature either, and the send
;;; fails in Lisp rather than raising an Objective-C exception.

(defun forwarded-encoding (receiver selector-name)
  "The type encoding of SELECTOR-NAME as RECEIVER would forward it, or NIL."
  (multiple-value-bind (kind pointer) (ignore-errors (resolve-receiver receiver))
    (when (and (eq kind :send) (objc-pointer-p pointer))
      (let ((signature (send-raw pointer "methodSignatureForSelector:"
                                 (coerce-to-selector selector-name))))
        (when (objc-pointer-p signature)
          (let ((count (send-raw signature "numberOfArguments")))
            (with-output-to-string (out)
              (write-string (cffi:foreign-string-to-lisp
                             (send-raw signature "methodReturnType"))
                            out)
              (dotimes (i count)
                (write-string (cffi:foreign-string-to-lisp
                               (send-raw signature "getArgumentTypeAtIndex:" i))
                              out)))))))))

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
         (or (find-method-for class (selector-name method))
             ;; No Method, but perhaps forwarded -- see FORWARDED-ENCODING.
             (and (not (super-reference-p class-or-object-pointer))
                  (forwarded-encoding class-or-object-pointer (selector-name method))))
         t)))

(defun clear-dispatch-caches ()
  "Class and selector addresses do not survive an image restart, and neither
do the compiled trampolines."
  (clrhash *selector-entries*)
  (clrhash *explicit-sites*)
  (clrhash *trampoline-by-signature*))

(add-image-restore-thunk 'clear-dispatch-caches)
