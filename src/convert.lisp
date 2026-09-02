;;;; src/convert.lisp -- marshalling between Lisp values and the foreign world.
;;;;
;;;; The trampolines below dispatch.lisp speak only SAPs and numbers.  Everything
;;;; Cocoa-flavoured happens here: strings become NSStrings, vectors become
;;;; NSArrays, #(x y w h) becomes an NSRect and (location . length) becomes an
;;;; NSRange.
;;;;
;;;; Ownership follows the manual exactly, and it is asymmetric in a way worth
;;;; stating plainly:
;;;;
;;;;   * A string or vector passed as an argument is converted to a temporary
;;;;     NSString or NSArray that is RELEASED when INVOKE returns.  A char *
;;;;     argument is likewise freed on return.  Callers keep nothing.
;;;;
;;;;   * A string or vector RETURNED from a Lisp-implemented method becomes an
;;;;     NSString or NSArray that the CALLER is expected to release.
;;;;
;;;; Every conversion copies into freshly allocated foreign memory rather than
;;;; pinning a Lisp object.  SBCL's collector moves objects, and pinning across
;;;; a message send that may block or re-enter Lisp is a worse bet than a copy.

(in-package #:objc)

;;; Per-call temporaries -----------------------------------------------------
;;;
;;; LispWorks calls this *DYNAMIC-OBJC-DATA*; same idea.  Anything allocated to
;;; make one call happen is registered here and released when the call unwinds,
;;; including on a non-local exit.

(defvar *call-temporaries* nil
  "Bound per send to a list of thunks that free this call's temporaries.")

(defmacro with-call-temporaries (&body body)
  `(let ((*call-temporaries* '()))
     (unwind-protect (progn ,@body)
       (dolist (thunk *call-temporaries*) (ignore-errors (funcall thunk))))))

(defun register-temporary (thunk)
  (push thunk *call-temporaries*))

;;; Strings ------------------------------------------------------------------

(defun string-to-ns-string (string &optional autoreleasep)
  "Return an NSString containing the characters of STRING.

When AUTORELEASEP is true the result is autoreleased; otherwise YOU are
responsible for releasing it, which is what the manual specifies.  The
non-autoreleased case therefore uses -[NSString initWithUTF8String:] rather than
+stringWithUTF8String:, so the +1 belongs to the caller and not to some pool
that may not exist on this thread."
  (check-type string string)
  (let ((bytes (cffi:foreign-string-alloc string :encoding :utf-8)))
    (unwind-protect
         (let ((ns (if autoreleasep
                       (pointer-of (send-raw "NSString" "stringWithUTF8String:" bytes))
                       (pointer-of
                        (send-raw (pointer-of (send-raw "NSString" "alloc"))
                                  "initWithUTF8String:" bytes)))))
           ns)
      (cffi:foreign-string-free bytes))))

(defun ns-string-to-string (ns-string &optional preserve-line-terminators)
  "Return a Lisp string with the characters of NS-STRING.

When PRESERVE-LINE-TERMINATORS is NIL, the default, a carriage return is
dropped after a linefeed and any other carriage return becomes a newline, so
that lines terminated by LF, CR or CRLF all read the same.  Otherwise a
carriage return is preserved as #\\Return."
  (when (or (null ns-string)
            (and (cffi:pointerp ns-string) (cffi:null-pointer-p ns-string)))
    (return-from ns-string-to-string nil))
  (let* ((pointer (if (cffi:pointerp ns-string) ns-string (objc-object-pointer ns-string)))
         (utf8 (pointer-of (send-raw pointer "UTF8String")))
         (raw (if (cffi:null-pointer-p utf8)
                  ""
                  (cffi:foreign-string-to-lisp utf8 :encoding :utf-8))))
    (if preserve-line-terminators
        raw
        (normalize-line-terminators raw))))

(defun normalize-line-terminators (string)
  "CRLF and CR both become a single #\\Newline."
  (if (not (find #\Return string))
      string
      (with-output-to-string (out)
        (loop with length = (length string)
              for i from 0 below length
              for char = (char string i)
              do (cond ((char/= char #\Return) (write-char char out))
                       ;; CRLF: let the LF speak for the pair.
                       ((and (< (1+ i) length) (char= (char string (1+ i)) #\Newline)))
                       (t (write-char #\Newline out)))))))

;;; Arrays -------------------------------------------------------------------

(defun ns-array-to-vector (ns-array &optional element-style)
  "Convert an NSArray to a simple vector, converting elements per ELEMENT-STYLE.
ELEMENT-STYLE is NIL, the symbol STRING, the symbol ARRAY, or (ARRAY sub-style),
matching INVOKE-INTO's vocabulary."
  (when (or (null ns-array)
            (and (cffi:pointerp ns-array) (cffi:null-pointer-p ns-array)))
    (return-from ns-array-to-vector nil))
  (let* ((pointer (if (cffi:pointerp ns-array) ns-array (objc-object-pointer ns-array)))
         (count (send-raw pointer "count"))
         (result (make-array count)))
    (dotimes (i count result)
      (let ((element (pointer-of (send-raw pointer "objectAtIndex:" i))))
        (setf (aref result i) (convert-element element element-style))))))

(defun convert-element (element style)
  (cond ((null style) element)
        ((eq style 'string) (ns-string-to-string element))
        ((eq style 'array) (ns-array-to-vector element nil))
        ((and (consp style) (eq (first style) 'array))
         (ns-array-to-vector element (second style)))
        (t element)))

(defun vector-to-ns-array (vector &optional autoreleasep)
  "Convert a Lisp sequence to an NSArray, recursively converting elements.
Strings become NSStrings and nested vectors become nested NSArrays, which is
what INVOKE's argument conversion promises."
  (let* ((length (length vector))
         (temporaries '()))
    (unwind-protect
         (cffi:with-foreign-object (buffer :pointer (max 1 length))
           (dotimes (i length)
             (let* ((element (elt vector i))
                    (object (cond ((stringp element)
                                   (let ((ns (string-to-ns-string element)))
                                     (push ns temporaries)
                                     ns))
                                  ((and (vectorp element) (not (stringp element)))
                                   (let ((ns (vector-to-ns-array element)))
                                     (push ns temporaries)
                                     ns))
                                  ((null element) (cffi:null-pointer))
                                  (t (objc-object-pointer element)))))
               (setf (cffi:mem-aref buffer :pointer i) object)))
           (let ((array (pointer-of
                         (send-raw "NSArray" "arrayWithObjects:count:" (sap-of buffer) length))))
             ;; arrayWithObjects:count: retains its elements, so the temporaries
             ;; can go now.
             (if autoreleasep
                 array
                 (pointer-of (send-raw array "retain")))))
      (dolist (object temporaries)
        (ignore-errors (send-raw object "release"))))))

;;; Cocoa structs ------------------------------------------------------------
;;;
;;; NSRect is #(x y width height), NSSize is #(width height), NSPoint is #(x y)
;;; -- and NSRange is the CONS (location . length), not a vector.  That
;;; inconsistency is the manual's, and it is load bearing for source
;;; compatibility.

(defun cocoa-struct-kind (node)
  "Which Cocoa struct NODE is, or NIL: :RECT, :SIZE, :POINT or :RANGE."
  (when (and (consp node) (eq (first node) :struct))
    (let ((symbol (struct-symbol (second node))))
      (case symbol
        (cocoa:ns-rect :rect)
        (cocoa:ns-size :size)
        (cocoa:ns-point :point)
        (cocoa:ns-range :range)))))

(defun write-cocoa-struct (sap kind value)
  "Write VALUE into the struct at SAP."
  (let ((pointer (pointer-of sap)))
    (ecase kind
      (:point (setf (cffi:mem-aref pointer :double 0) (coerce (elt value 0) 'double-float)
                    (cffi:mem-aref pointer :double 1) (coerce (elt value 1) 'double-float)))
      (:size  (setf (cffi:mem-aref pointer :double 0) (coerce (elt value 0) 'double-float)
                    (cffi:mem-aref pointer :double 1) (coerce (elt value 1) 'double-float)))
      (:rect  (dotimes (i 4)
                (setf (cffi:mem-aref pointer :double i) (coerce (elt value i) 'double-float))))
      (:range (setf (cffi:mem-aref pointer :uint64 0) (car value)
                    (cffi:mem-aref pointer :uint64 1) (cdr value))))))

(defun read-cocoa-struct (sap kind)
  "Read the struct at SAP into its documented Lisp representation."
  (let ((pointer (pointer-of sap)))
    (ecase kind
      (:point (vector (cffi:mem-aref pointer :double 0) (cffi:mem-aref pointer :double 1)))
      (:size  (vector (cffi:mem-aref pointer :double 0) (cffi:mem-aref pointer :double 1)))
      (:rect  (vector (cffi:mem-aref pointer :double 0) (cffi:mem-aref pointer :double 1)
                      (cffi:mem-aref pointer :double 2) (cffi:mem-aref pointer :double 3)))
      ;; A cons, not a vector.  See the note above.
      (:range (cons (cffi:mem-aref pointer :uint64 0) (cffi:mem-aref pointer :uint64 1))))))

;;; Argument marshalling -----------------------------------------------------

(defun marshal-argument (value node)
  "Convert VALUE to what a trampoline expects for a parameter of type NODE.
Temporaries are registered for release when the call unwinds."
  (let ((node (if (struct-node-p node) (resolve-struct-layout node) node)))
    (cond
      ;; Structs are passed as a pointer to a filled-in buffer; the trampoline
      ;; loads them by value at the call.
      ((struct-node-p node)
       (let* ((size (node-size-and-alignment node))
              (buffer (cffi:foreign-alloc :uint8 :count (max 1 size)))
              (kind (cocoa-struct-kind node)))
         (register-temporary (lambda () (cffi:foreign-free buffer)))
         (cond ((and kind (or (vectorp value) (consp value)))
                (write-cocoa-struct (sap-of buffer) kind value))
               ((cffi:pointerp value)
                ;; "Otherwise it is assumed to be a foreign pointer ... and is copied."
                (dotimes (i size)
                  (setf (cffi:mem-aref buffer :uint8 i)
                        (cffi:mem-aref value :uint8 i))))
               (t (error "Cannot pass ~S as a ~A argument." value
                         (or kind "structure"))))
         (sap-of buffer)))

      ((eq node :id)
       (cond ((null value) (sap-of (cffi:null-pointer)))
             ((stringp value)
              ;; Released when INVOKE returns, per the manual.
              (let ((ns (string-to-ns-string value)))
                (register-temporary (lambda () (send-raw ns "release")))
                (sap-of ns)))
             ((and (vectorp value) (not (stringp value)))
              (let ((ns (vector-to-ns-array value)))
                (register-temporary (lambda () (send-raw ns "release")))
                (sap-of ns)))
             ((cffi:pointerp value) (sap-of value))
             (t (sap-of (objc-object-pointer value)))))

      ((eq node :class)
       (sap-of (if (cffi:pointerp value) value (coerce-to-objc-class value))))

      ((eq node :sel)
       (sap-of (coerce-to-selector value)))

      ((eq node :cstring)
       (cond ((null value) (sap-of (cffi:null-pointer)))
             ((stringp value)
              ;; Freed when INVOKE returns, per the manual.
              (let ((bytes (cffi:foreign-string-alloc value :encoding :utf-8)))
                (register-temporary (lambda () (cffi:foreign-string-free bytes)))
                (sap-of bytes)))
             (t (sap-of value))))

      ((eq node :bool)
       ;; NIL is NO and T is YES; an integer passes through, because the
       ;; encoding cannot distinguish BOOL from a signed char.
       (cond ((eq value t) 1) ((null value) 0) (t value)))

      ((or (eq node :block) (and (consp node) (member (first node) '(:pointer :array))))
       (sap-of (cond ((null value) (cffi:null-pointer))
                     ((cffi:pointerp value) value)
                     (t (objc-object-pointer value)))))

      ((eq node :char)
       (cond ((eq value t) 1) ((null value) 0) (t value)))

      ((consp node) (marshal-argument value (third node))) ; :qualified

      ;; Plain numbers.
      ((member node '(:float)) (coerce value 'single-float))
      ((member node '(:double)) (coerce value 'double-float))
      (t value))))
