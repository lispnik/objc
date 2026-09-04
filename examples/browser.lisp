;;;; examples/browser.lisp -- asking the runtime what a class can do.
;;;;
;;;; The other examples call frameworks; this one interrogates them.  Point it
;;;; at a class name and it prints the methods, their signatures and where they
;;;; came from -- which is the thing you actually want at a REPL when the
;;;; documentation is a header you have not got.
;;;;
;;;; It exists because the library's own introspection was the part no example
;;;; used.  CAN-INVOKE-P, OBJC-CLASS-METHOD-SIGNATURE, OBJC-CLASS-NAME,
;;;; COERCE-TO-SELECTOR and TRACE-INVOKE are all exported, all documented, and
;;;; all appeared only in the test suite -- while natural-language.lisp
;;;; hand-rolled its own CLASS-SELECTORS out of class_copyMethodList rather than
;;;; reaching for what was already there.  This is the amends.
;;;;
;;;; The division of labour is worth understanding, because it is not arbitrary:
;;;;
;;;;   class_copyMethodList is the only way to ENUMERATE, and the library does
;;;;   not wrap it.  Nothing in the LispWorks manual does either, which is why
;;;;   it is not in OBJC -- so the raw call stays here, in an example.
;;;;
;;;;   OBJC-CLASS-METHOD-SIGNATURE is the library's own, and answers the harder
;;;;   question: given a class and a selector, what does the call look like?
;;;;   Argument types, result type, and the raw encoding, parsed rather than
;;;;   handed back as a string.
;;;;
;;;;   CAN-INVOKE-P answers "will this send work", which is a different question
;;;;   from "is this that kind of object" -- see RESPONSE-STATUS in
;;;;   url-session.lisp for the case where confusing them gives a wrong answer.

(in-package #:objc/examples)

;;; Enumerating ---------------------------------------------------------------------

(cffi:defcfun ("class_copyMethodList" %class-copy-methods) :pointer
  (class :pointer) (count :pointer))
(cffi:defcfun ("class_getSuperclass" %class-superclass) :pointer (class :pointer))
(cffi:defcfun ("method_getName" %method-name) :pointer (method :pointer))
(cffi:defcfun ("sel_getName" %selector-name) :string (selector :pointer))
(cffi:defcfun ("object_getClass" %object-class) :pointer (object :pointer))

(defun class-selectors (class &key containing (class-methods nil))
  "Every method CLASS implements itself, as selector strings.

    (class-selectors \"NSString\" :containing \"substring\")
    (class-selectors \"NSString\" :class-methods t)

Its OWN methods: nothing inherited.  CLASS-CHAIN below is how you see the rest.

class_copyMethodList rather than anything in OBJC, because enumerating a class's
methods is not something the LispWorks manual provides and so not something this
library exports.  An example is the right place for it."
  (objc:ensure-objc-initialized)
  (let ((class (if class-methods
                   (%object-class (objc:coerce-to-objc-class class))
                   (objc:coerce-to-objc-class class))))
    (cffi:with-foreign-object (count :uint)
      (let ((methods (%class-copy-methods class count)))
        (unwind-protect
             (sort (loop for i below (cffi:mem-ref count :uint)
                         for name = (%selector-name
                                     (%method-name (cffi:mem-aref methods :pointer i)))
                         when (or (null containing) (search containing name))
                           collect name)
                   #'string<)
          (unless (cffi:null-pointer-p methods) (cffi:foreign-free methods)))))))

(defun class-chain (class)
  "CLASS and everything it inherits from, as names, most derived first."
  (objc:ensure-objc-initialized)
  (loop for pointer = (objc:coerce-to-objc-class class)
          then (%class-superclass pointer)
        until (cffi:null-pointer-p pointer)
        collect (objc:objc-class-name pointer)))

;;; Describing ------------------------------------------------------------------------

(defun describe-selector (class selector)
  "What a call to SELECTOR on CLASS looks like, as a plist.

    (describe-selector \"NSString\" \"substringFromIndex:\")
    => (:SELECTOR \"substringFromIndex:\" :ARGUMENTS (OBJC-OBJECT-POINTER SEL
        (:UNSIGNED :LONG-LONG)) :RESULT OBJC-OBJECT-POINTER
        :ENCODING \"@24@0:8Q16\")

The argument list always begins with the receiver and the selector, because
every Objective-C method takes those two hidden arguments -- which is the single
most useful thing to see when a send is not doing what you expect."
  (objc:ensure-objc-initialized)
  (multiple-value-bind (arguments result encoding)
      (objc:objc-class-method-signature class selector)
    (list :selector selector
          :arguments arguments
          :result result
          :encoding encoding)))

(defun describe-objc-class (class &key containing (limit 40) (class-methods nil))
  "Print CLASS's methods and their signatures.  Returns the class name.

    (describe-objc-class \"NSDate\")
    (describe-objc-class \"CIImage\" :containing \"crop\")
    (describe-objc-class \"NSString\" :class-methods t)

The one function this file is for.  Everything it prints comes from the runtime,
so it is accurate for the system you are on rather than for the documentation
you found."
  (objc:ensure-objc-initialized)
  (let* ((name (objc:objc-class-name (objc:coerce-to-objc-class class)))
         (selectors (class-selectors class :containing containing
                                           :class-methods class-methods))
         (shown (subseq selectors 0 (min limit (length selectors)))))
    (format t "~&~A~@[ : ~{~A~^ : ~}~]~%" name (rest (class-chain class)))
    (format t "~D ~:[instance~;class~] method~:P~@[ matching ~S~]~@[, showing ~D~]~%"
            (length selectors) class-methods containing
            (when (< (length shown) (length selectors)) (length shown)))
    (dolist (selector shown name)
      (let ((description (ignore-errors (describe-selector class selector))))
        (if description
            (format t "  ~A~%      ~{~A~^ ~} -> ~A~%"
                    selector
                    ;; Drop the receiver and selector: they are on every method
                    ;; and saying so once at the top is enough.
                    (or (cddr (getf description :arguments)) '("(no arguments)"))
                    (getf description :result))
            (format t "  ~A~%      (signature unavailable)~%" selector))))))

;;; Answering questions about an object -------------------------------------------------

(defun responds-p (object selector)
  "Whether sending SELECTOR to OBJECT will work.

CAN-INVOKE-P, which resolves the method rather than guessing.  Note what it does
NOT tell you: that OBJECT is a particular kind of thing.  Plenty of classes
answer a selector without being what answering it would suggest -- a plain
NSURLResponse answers -statusCode -- so this is the right question before a send
and the wrong one before a decision."
  (objc:can-invoke-p object selector))

(defun class-of-object (object)
  "The name of OBJECT's class, from the runtime rather than from what you
expected it to be."
  (objc:objc-class-name (objc:invoke object "class")))

(defmacro with-traced (selectors &body body)
  "Run BODY with SELECTORS traced, reporting every send to *TRACE-OUTPUT*.

    (with-traced (\"length\" \"substringFromIndex:\")
      (objc:invoke (objc:invoke \"NSString\" \"stringWithUTF8String:\" \"hello\")
                   \"substringFromIndex:\" 2))

TRACE-INVOKE is per selector, not per class, so this is a wide net -- which is
what you want when the question is \"is that send even happening\"."
  `(let ((selectors (list ,@selectors)))
     (mapc #'objc:trace-invoke selectors)
     (unwind-protect (locally ,@body)
       (mapc #'objc:untrace-invoke selectors))))

;;; A worked example ------------------------------------------------------------------------

(defun test-browser ()
  "Interrogate a class or two and check the answers are the real ones.

    (objc/examples:test-browser)
    => (:CHAIN (\"NSString\" \"NSObject\") :FOUND-SUBSTRING T
        :LENGTH-SIGNATURE ((OBJC-OBJECT-POINTER SEL) (:UNSIGNED :LONG-LONG))
        :RESPONDS T :DOES-NOT-RESPOND T :CLASS-OF \"__NSCFConstantString\"
        :TRACED T)

:LENGTH-SIGNATURE is the assertion with teeth: -[NSString length] takes the two
hidden arguments and nothing else, and returns an NSUInteger.  That is read from
the runtime, so if the parse of an encoding ever drifted, this notices."
  (objc:ensure-objc-initialized)
  (objc:with-autorelease-pool ()
    (let* ((string (objc:invoke "NSString" "stringWithUTF8String:" "hello"))
           (length-description (describe-selector "NSString" "length"))
           (traced (with-output-to-string (stream)
                     (let ((*trace-output* stream))
                       (with-traced ("length")
                         (objc:invoke string "length"))))))
      (list :chain (class-chain "NSString")
            :found-substring (and (class-selectors "NSString" :containing "substring") t)
            :length-signature (list (getf length-description :arguments)
                                    (getf length-description :result))
            :responds (responds-p string "length")
            :does-not-respond (not (responds-p string "noSuchSelectorHere"))
            :class-of (class-of-object string)
            :traced (and (search "length" traced) t)))))

(defun report-browser (&optional (class "NSDate"))
  "Describe CLASS, as the tool would be used."
  (describe-objc-class class :limit 12))
