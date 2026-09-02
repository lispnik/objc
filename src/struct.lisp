;;;; src/struct.lisp -- DEFINE-OBJC-STRUCT and DEFINE-OBJC-TYPEDEF.

(in-package #:objc)

(defmacro define-objc-struct ((name &rest options) &body slots)
  "Define an Objective-C structure type NAME with the given SLOTS.

Each slot is (slot-name slot-type).  OPTIONS may include
(:FOREIGN-NAME string), which the Objective-C runtime needs to identify the
type and is therefore effectively required, and (:TYPEDEF-NAME symbol), which
lets that symbol be used in place of (:STRUCT name).

After this, (:struct name) is usable as a type in INVOKE, INVOKE-INTO,
DEFINE-OBJC-METHOD and DEFINE-OBJC-CLASS-METHOD.

    (define-objc-struct (pair (:foreign-name \"_Pair\"))
      (:first :float)
      (:second :float))"
  (let* ((foreign-name (second (assoc :foreign-name options)))
         (typedef-name (second (assoc :typedef-name options))))
    (unless foreign-name
      (error "DEFINE-OBJC-STRUCT needs a :FOREIGN-NAME for ~S: the Objective-C ~
runtime identifies a structure type by its name." name))
    `(progn
       ;; The registration has to happen at compile time as well as load time:
       ;; a DEFINE-OBJC-METHOD later in the same file names this type in its
       ;; signature, and that is resolved during macroexpansion.
       (eval-when (:compile-toplevel :load-toplevel :execute)
         (register-objc-struct ',name ,foreign-name ',typedef-name ',slots))
       ;; A CFFI struct too, so that slots can be read and written with the
       ;; ordinary foreign accessors.
       (cffi:defcstruct (,name :size ,(struct-definition-size slots))
         ,@(loop for (slot-name slot-type) in slots
                 collect (list (intern (string slot-name) '#:objc)
                               (cffi-type-for-fli-type slot-type))))
       ',name)))

(defun struct-definition-size (slots)
  (node-size-and-alignment
   (list :struct nil (loop for (nil slot-type) in slots
                           collect (node-for-fli-type slot-type)))))

(defun cffi-type-for-fli-type (type)
  (let ((node (node-for-fli-type type)))
    (case node
      (:char :int8) (:uchar :uint8)
      (:short :int16) (:ushort :uint16)
      ((:int :long) :int32) ((:uint :ulong) :uint32)
      (:long-long :int64) (:ulong-long :uint64)
      (:float :float) (:double :double)
      (:bool :uint8)
      (t :pointer))))

(defun register-objc-struct (name foreign-name typedef-name slots)
  "Record a structure type so it is usable everywhere a type is expected."
  (let* ((nodes (loop for (nil slot-type) in slots
                      collect (node-for-fli-type slot-type)))
         (encoding (unparse-type (list :struct foreign-name nodes))))
    (setf (struct-encoding-for-symbol name) encoding
          (gethash foreign-name *struct-symbols*) name
          (gethash foreign-name *struct-layout-overrides*) encoding)
    (when typedef-name
      (setf (struct-encoding-for-symbol typedef-name) encoding))
    name))

(defmacro define-objc-typedef ((name &rest options) &optional type)
  "Define an Objective-C typedef NAME for TYPE.

OPTIONS may include (:FOREIGN-NAME string) and (:C-TYPE type); when :C-TYPE is
given it is used as the definition and TYPE and :FOREIGN-NAME are ignored, as
the manual specifies."
  (let ((c-type (second (assoc :c-type options))))
    `(progn
       (eval-when (:compile-toplevel :load-toplevel :execute)
         (register-objc-typedef ',name ',(or c-type type)))
       ',name)))

(defun register-objc-typedef (name type)
  (let ((node (node-for-fli-type type)))
    (setf (gethash name *typedef-nodes*) node))
  name)


;;; A struct result variable carries its type ------------------------------
;;;
;;; DEFINE-OBJC-METHOD's result-style variable is bound to something the body
;;; fills in.  A bare pointer would be enough for us, but the manual's own
;;; example reaches into it by slot name:
;;;
;;;   (define-objc-method ("pair" (:struct pair) result-pair)
;;;       ((this my-object))
;;;     (setf (fli:foreign-slot-value result-pair :first) 1f0 ...))
;;;
;;; so the variable has to know which structure type it points at.

(defstruct (typed-pointer (:constructor make-typed-pointer (pointer type-name)))
  "A foreign pointer that remembers its structure type."
  pointer type-name)

(defun typed-pointer-slot (typed-pointer slot-name)
  (cffi:foreign-slot-value (typed-pointer-pointer typed-pointer)
                           (list :struct (typed-pointer-type-name typed-pointer))
                           (intern (string slot-name) '#:objc)))

(defun (setf typed-pointer-slot) (value typed-pointer slot-name)
  (setf (cffi:foreign-slot-value (typed-pointer-pointer typed-pointer)
                                 (list :struct (typed-pointer-type-name typed-pointer))
                                 (intern (string slot-name) '#:objc))
        value))
