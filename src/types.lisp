;;;; src/types.lisp -- FLI type descriptors, and the bridge between them and
;;;; parsed encoding nodes.
;;;;
;;;; Three jobs:
;;;;
;;;;  1. Define the eight type descriptor symbols the OBJC package exports.
;;;;     LispWorks calls these "FLI type descriptors"; there is no FLI here, so
;;;;     they are symbols that are meaningful in exactly the positions the
;;;;     Objective-C manual uses them -- method argument and result types,
;;;;     OBJC-CLASS-METHOD-SIGNATURE results, DEFINE-OBJC-STRUCT slot types.
;;;;
;;;;  2. Translate between those descriptors and the nodes ENCODING produces,
;;;;     in both directions.  The reverse direction is not incidental: it is
;;;;     what OBJC-CLASS-METHOD-SIGNATURE returns, and it has to match LispWorks
;;;;     shape for shape.  Verified against LispWorks 8.1 on this machine:
;;;;
;;;;       -[NSString length]             -> (:UNSIGNED :LONG-LONG)
;;;;       -[NSString rangeOfString:]     -> (:STRUCT COCOA:NS-RANGE)
;;;;       -[NSObject description]        -> OBJC:OBJC-OBJECT-POINTER
;;;;
;;;;  3. Carry the struct layout table for the cases where the runtime elided a
;;;;     struct body, and name the Cocoa structs.
;;;;
;;;; On integer widths, which are a trap: in an encoding 'l' and 'L' mean
;;;; exactly 32 bits, but the C type "long" on LP64 encodes as 'q'.  So the node
;;;; :LONG is a 32-bit thing while the FLI type :LONG is a 64-bit one, and the
;;;; mapping between them is deliberately not the identity.  NSInteger is 'q'
;;;; and NSUInteger is 'Q'.

(in-package #:objc)

;;; The exported type descriptors -------------------------------------------
;;;
;;; These have no value or function binding; they are names.  Documentation is
;;; attached so DESCRIBE says something useful, since that is how someone
;;; porting LispWorks code will ask what they are.

(setf (documentation 'objc-object-pointer 'type)
      "The Objective-C \"id\" type: a pointer to an Objective-C object.
Also names the reader that returns an instance's pointer; the manual documents
the two roles on separate pages, but it is one symbol.")
(setf (documentation 'objc-class 'type)
      "The Objective-C \"Class\" type: a pointer to a class object.")
(setf (documentation 'sel 'type)
      "The Objective-C \"SEL\" type: an opaque method selector.
Obtain one from a string with COERCE-TO-SELECTOR.")
(setf (documentation 'objc-c-string 'type)
      "The Objective-C \"char *\" type, converted to and from a Lisp string.")
(setf (documentation 'objc-bool 'type)
      "The Objective-C \"BOOL\" type, converting between NIL/T and NO/YES.
Its width is architecture dependent -- a signed char on Intel, C99 _Bool on
Apple silicon -- so it is measured from the runtime at initialization rather
than chosen by a read-time conditional.")
(setf (documentation 'objc-c++-bool 'type)
      "The C99 _Bool / C++ bool type, the 'B' encoding.
On Apple silicon this is what BOOL actually is, which is why the manual
mentions seeing it in error messages there.")
(setf (documentation 'objc-unknown 'type)
      "The '?' encoding: a type the runtime could not describe.  An alias for :VOID.")
(setf (documentation 'objc-at-question-mark 'type)
      "The '@?' encoding, used by Apple for a pointer to a block.
Undocumented by Apple and therefore not something to rely on.  An alias for a
pointer type.")

;;; BOOL is measured, not assumed ------------------------------------------

(defvar *bool-encoding-char* #\B
  "The character the runtime uses to encode BOOL on this machine.
Set at initialization by reading a known BOOL-returning method's encoding, so
the difference between Intel (a signed char, 'c') and Apple silicon (C99 _Bool,
'B') is discovered rather than declared.  Defaults to the Apple silicon answer
so the table is usable before initialization.")

(defun %measure-bool-encoding ()
  "Read the BOOL encoding from -[NSObject isProxy] and record it."
  (let* ((class (%objc-get-class "NSObject"))
         (method (unless (cffi:null-pointer-p class)
                   (%class-get-instance-method class (%sel-register-name "isProxy")))))
    (when (and method (not (cffi:null-pointer-p method)))
      (let ((encoding (%method-get-type-encoding method)))
        (when (plusp (length encoding))
          (setf *bool-encoding-char* (char encoding 0)))))
    *bool-encoding-char*))

;;; Struct layouts -----------------------------------------------------------
;;;
;;; method_getTypeEncoding sometimes writes a struct with no body -- "{CGRect=}"
;;; or "^{example}" -- when the layout was not needed to compile the caller.
;;; Passing a struct of the wrong size by value corrupts the argument registers
;;; of every parameter after it and returns plausible garbage, so an unknown
;;; layout is an error, not a guess.  This table is what makes the common ones
;;; known.
;;;
;;; Hand-written rather than groveled, per the no-C-toolchain rule, but not
;;; unchecked: Foundation's NSGetSizeAndAlignment parses this exact notation, so
;;; test/types-tests.lisp asserts every entry against it.

(defparameter *struct-layout-overrides*
  (let ((table (make-hash-table :test 'equal)))
    (flet ((add (encoding &rest names)
             (dolist (name names) (setf (gethash name table) encoding))))
      ;; CGFloat is a double on 64-bit, so every geometry struct is doubles.
      (add "{CGPoint=dd}"                      "CGPoint" "_NSPoint" "NSPoint")
      (add "{CGSize=dd}"                       "CGSize" "_NSSize" "NSSize")
      (add "{CGVector=dd}"                     "CGVector")
      (add "{CGRect={CGPoint=dd}{CGSize=dd}}"  "CGRect" "_NSRect" "NSRect")
      (add "{_NSRange=QQ}"                     "_NSRange" "NSRange" "CFRange")
      (add "{CGAffineTransform=dddddd}"        "CGAffineTransform")
      (add "{NSEdgeInsets=dddd}"               "NSEdgeInsets" "NSDirectionalEdgeInsets")
      (add "{NSOperatingSystemVersion=qqq}"    "NSOperatingSystemVersion")
      (add "{CLLocationCoordinate2D=dd}"       "CLLocationCoordinate2D")
      (add "{CATransform3D=dddddddddddddddd}"  "CATransform3D"))
    table)
  "Full encodings for structs the runtime is prone to describe by name only.
Keyed by struct name; see the file header for why guessing is not an option.")

;;; Cocoa struct names -------------------------------------------------------
;;;
;;; The manual's reference pages say ns-point and ns-size have :FLOAT slots and
;;; ns-range has (:UNSIGNED :INT) slots.  That is stale 32-bit text.  Measured
;;; in LispWorks 8.1 on this machine: ns-point 16 bytes, ns-size 16, ns-rect 32,
;;; ns-range 16 -- doubles and 64-bit integers, matching the {_NSPoint=dd} and
;;; _NSRange=QQ encodings found in its own heap.  We follow the implementation.

(defparameter *cocoa-struct-symbols*
  '(("CGPoint" . cocoa:ns-point) ("_NSPoint" . cocoa:ns-point) ("NSPoint" . cocoa:ns-point)
    ("CGSize"  . cocoa:ns-size)  ("_NSSize"  . cocoa:ns-size)  ("NSSize"  . cocoa:ns-size)
    ("CGRect"  . cocoa:ns-rect)  ("_NSRect"  . cocoa:ns-rect)  ("NSRect"  . cocoa:ns-rect)
    ("_NSRange" . cocoa:ns-range) ("NSRange" . cocoa:ns-range))
  "Struct names that map onto the COCOA package's documented type descriptors.")

(defvar *struct-symbols* (make-hash-table :test 'equal)
  "Struct name -> the symbol naming its type, for both the Cocoa structs and
anything DEFINE-OBJC-STRUCT registers.")

(dolist (entry *cocoa-struct-symbols*)
  (setf (gethash (car entry) *struct-symbols*) (cdr entry)))

(defun struct-symbol (name)
  (and name (gethash name *struct-symbols*)))

(defun resolve-struct-layout (node)
  "Fill in a (:STRUCT NAME NIL) node from *STRUCT-LAYOUT-OVERRIDES*.
Returns NODE unchanged when it already has fields.  Signals when the layout is
unknown, because the alternative is silently miscompiling the call."
  (if (and (consp node) (member (first node) '(:struct :union)) (null (third node)))
      (let* ((name (second node))
             (encoding (and name (gethash name *struct-layout-overrides*))))
        (unless encoding
          (error 'unsupported-type-encoding
                 :encoding (or name "?")
                 :detail "struct layout not recorded by the runtime and not in *STRUCT-LAYOUT-OVERRIDES*"))
        (parse-type encoding))
      node))

;;; Struct symbol -> encoding ------------------------------------------------

(defvar *struct-encodings* (make-hash-table :test 'eq)
  "Symbol naming a struct type -> its full encoding string.
Populated for the Cocoa structs here and by DEFINE-OBJC-STRUCT later.")

(defun struct-encoding-for-symbol (symbol)
  (and (symbolp symbol) (gethash symbol *struct-encodings*)))

(defun (setf struct-encoding-for-symbol) (encoding symbol)
  (setf (gethash symbol *struct-encodings*) encoding))

(setf (struct-encoding-for-symbol 'cocoa:ns-point) "{CGPoint=dd}"
      (struct-encoding-for-symbol 'cocoa:ns-size)  "{CGSize=dd}"
      (struct-encoding-for-symbol 'cocoa:ns-rect)  "{CGRect={CGPoint=dd}{CGSize=dd}}"
      (struct-encoding-for-symbol 'cocoa:ns-range) "{_NSRange=QQ}")

(defvar *typedef-nodes* (make-hash-table :test 'eq)
  "Typedef symbol -> the node it stands for, as registered by
DEFINE-OBJC-TYPEDEF.  Consulted by NODE-FOR-FLI-TYPE.")

(defun typedef-node (symbol)
  (and (symbolp symbol) (gethash symbol *typedef-nodes*)))

;;; Node -> FLI type descriptor ---------------------------------------------

(defparameter +node-fli-types+
  '((:void        . :void)
    (:char        . (:signed :char))
    (:uchar       . (:unsigned :char))
    (:short       . :short)
    (:ushort      . (:unsigned :short))
    (:int         . :int)
    (:uint        . (:unsigned :int))
    (:long        . :long)
    (:ulong       . (:unsigned :long))
    (:long-long   . :long-long)
    (:ulong-long  . (:unsigned :long-long))
    (:float       . :float)
    (:double      . :double))
  "Scalar nodes and the FLI type specs LispWorks reports for them.
Verified against LispWorks 8.1: -[NSString length] reports (:UNSIGNED :LONG-LONG).")

(defun fli-type-for-node (node)
  "The LispWorks FLI type descriptor for NODE.
This is what OBJC-CLASS-METHOD-SIGNATURE hands back, so its shape is part of the
public API and matches LispWorks exactly."
  (etypecase node
    (keyword
     (case node
       (:id 'objc-object-pointer)
       (:class 'objc-class)
       (:sel 'sel)
       (:cstring 'objc-c-string)
       (:bool 'objc-c++-bool)
       (:unknown 'objc-unknown)
       (:block 'objc-at-question-mark)
       (t (let ((entry (assoc node +node-fli-types+)))
            (unless entry
              (error 'unsupported-type-encoding
                     :encoding node :detail "no FLI type for this node"))
            (cdr entry)))))
    (cons
     (ecase (first node)
       (:pointer (list :pointer (fli-type-for-node (second node))))
       (:array (list :c-array (fli-type-for-node (third node)) (second node)))
       (:bitfield (list :bitfield (second node)))
       ;; Qualifiers are not part of the type LispWorks reports.
       (:qualified (fli-type-for-node (third node)))
       ((:struct :union)
        (let* ((name (second node))
               (symbol (struct-symbol name)))
          (list (if (eq (first node) :union) :union :struct)
                (or symbol (and name (intern (string-upcase name) '#:objc)) '#:anonymous))))))))

(defun node-for-fli-type (type)
  "The encoding node for a LispWorks FLI type descriptor.
Accepts what DEFINE-OBJC-METHOD and INVOKE's explicit arg-types list accept."
  (cond
    ((null type) :void)
    ((symbolp type)
     (case type
       ((:void) :void)
       ((:int) :int)
       ((:short) :short)
       ;; The C type "long" is 64 bits on LP64 and encodes as 'q'.  The node
       ;; :LONG is the 32-bit 'l' encoding and is deliberately NOT what an FLI
       ;; :LONG maps to.  See the file header.
       ((:long) :long-long)
       ((:long-long) :long-long)
       ((:char) :char)
       ((:float) :float)
       ((:double) :double)
       ((:pointer) (list :pointer :void))
       ((:boolean) :bool)
       (t
        (cond
          ((eq type 'objc-object-pointer) :id)
          ((eq type 'objc-class) :class)
          ((eq type 'sel) :sel)
          ((eq type 'objc-c-string) :cstring)
          ((eq type 'objc-bool) (if (char= *bool-encoding-char* #\B) :bool :char))
          ((eq type 'objc-c++-bool) :bool)
          ((eq type 'objc-unknown) :void)
          ((eq type 'objc-at-question-mark) :block)
          ;; A bare symbol naming a registered struct, which is what
          ;; DEFINE-OBJC-STRUCT's :TYPEDEF-NAME allows.
          ((struct-encoding-for-symbol type) (parse-type (struct-encoding-for-symbol type)))
          ;; ...or one defined by DEFINE-OBJC-TYPEDEF.  Consulting this table is
          ;; what makes that macro do anything at all; without it a typedef
          ;; registered fine and then failed as an unknown type at the first use.
          ((typedef-node type))
          (t (error 'unsupported-type-encoding
                    :encoding type :detail "not a known FLI type descriptor"))))))
    ((consp type)
     (case (first type)
       (:signed (case (second type)
                  ((:char) :char) ((:short) :short) ((:int) :int)
                  ((:long) :long-long) ((:long-long) :long-long)
                  (t (error 'unsupported-type-encoding :encoding type))))
       (:unsigned (case (second type)
                    ((:char) :uchar) ((:short) :ushort) ((:int) :uint)
                    ((:long) :ulong-long) ((:long-long) :ulong-long)
                    (t (error 'unsupported-type-encoding :encoding type))))
       (:pointer (list :pointer (node-for-fli-type (second type))))
       (:c-array (list :array (third type) (node-for-fli-type (second type))))
       ((:struct :union)
        (let ((encoding (struct-encoding-for-symbol (second type))))
          (unless encoding
            (error 'unsupported-type-encoding
                   :encoding type :detail "unknown struct type"))
          (parse-type encoding)))
       (t (error 'unsupported-type-encoding :encoding type))))
    (t (error 'unsupported-type-encoding :encoding type))))

;;; Sizes without Foundation -------------------------------------------------
;;;
;;; NSGetSizeAndAlignment is the oracle used in tests, but dispatch cannot
;;; depend on Foundation being loaded, so sizes are also computed directly from
;;; nodes.  The two must agree, and a test asserts that they do.

(defun node-size-and-alignment (node)
  "Return (VALUES SIZE ALIGNMENT) for NODE, computed from the node alone."
  (etypecase node
    (keyword
     (ecase node
       ((:char :uchar :bool) (values 1 1))
       ((:short :ushort) (values 2 2))
       ((:int :uint :long :ulong :float) (values 4 4))
       ((:long-long :ulong-long :double) (values 8 8))
       ((:id :class :sel :cstring :block) (values 8 8))
       ((:void :unknown) (values 0 1))))
    (cons
     (ecase (first node)
       (:pointer (values 8 8))
       (:qualified (node-size-and-alignment (third node)))
       (:bitfield (values 0 1))
       (:array (multiple-value-bind (size align)
                   (node-size-and-alignment (third node))
                 (values (* size (second node)) align)))
       ((:struct :union)
        (let ((node (resolve-struct-layout node)))
          (let ((size 0) (align 1) (unionp (eq (first node) :union)))
            (dolist (field (third node))
              (multiple-value-bind (fsize falign) (node-size-and-alignment field)
                (setf align (max align falign))
                (if unionp
                    (setf size (max size fsize))
                    (setf size (+ (* (ceiling size falign) falign) fsize)))))
            (values (* (ceiling size align) align) align))))))))
