;;;; src/abi.lisp -- the implementation seam.
;;;;
;;;; THIS IS THE ONLY FILE ALLOWED TO MENTION sb-alien: OR sb-sys:.
;;;; test/seam-tests.lisp greps the sources to enforce that, because a seam
;;;; nobody checks stops being a seam.
;;;;
;;;; Why sb-alien and not CFFI.  CFFI's foreign-funcall, foreign-funcall-pointer
;;;; and defcallback are macros: the types are fixed when the form is
;;;; macroexpanded, which is exactly what dynamic dispatch cannot promise.  That
;;;; alone would be workable -- we compile the form at runtime anyway -- but
;;;; without libffi, CFFI cannot express a struct passed or returned by value at
;;;; all: FOREIGN-FUNCALL-POINTER signals COMPILED-PROGRAM-ERROR and DEFCALLBACK
;;;; signals CASE-FAILURE.  Struct returns are not an edge case here.
;;;; -[NSView frame], -[NSString rangeOfString:] and the manual's own "pair"
;;;; example all need them.  Pulling in cffi-libffi would fix that and break two
;;;; other things: it needs cffi-grovel and therefore a C toolchain at build
;;;; time, and it can never make an Apple arm64 variadic call, because CFFI only
;;;; ever calls ffi_prep_cif and never ffi_prep_cif_var.
;;;;
;;;; sb-alien does all three, in both directions, with one mechanism.  Measured
;;;; on this machine: CGRectInset (a 32-byte homogeneous float aggregate, passed
;;;; and returned in v0-v3) and CGAffineTransformMakeRotation (48 bytes, non-HFA,
;;;; returned indirectly through x8) both give correct results, as does an
;;;; alien callable that returns a struct by value.  SBCL's arm64 backend
;;;; implements AAPCS64 properly and we lean on that.
;;;;
;;;; This is also why there is no objc_msgSend_stret anywhere in this library:
;;;; it does not exist on arm64.  Large structs come back through x8 from plain
;;;; objc_msgSend, and SBCL sets x8 up when the return type says to.

(in-package #:objc)

;;; Floating point traps -----------------------------------------------------
;;;
;;; SBCL runs with :INVALID and :DIVIDE-BY-ZERO unmasked.  CoreGraphics does
;;; not: the very first NSWindow creation raises FLOATING-POINT-INVALID-OPERATION
;;; and takes the process out with SIGFPE.  Masking around the call fixes it,
;;; and this is almost certainly why earlier attempts at an SBCL Objective-C
;;; bridge reported that everything worked except that the window never showed.
;;;
;;; LispWorks has no equivalent and documents none, because it runs with FP
;;; exceptions masked by default and never had the problem.  There is no prior
;;; art to copy here.
;;;
;;; Masked per entry point, never globally: masking globally would change Lisp's
;;; own arithmetic, so that (/ 1d0 0d0) quietly returned infinity instead of
;;; signalling.

(defmacro with-fp-traps-masked (&body body)
  "Run BODY with the floating point traps Cocoa violates masked.
Wrapped around every message send and the body of every Lisp-implemented
method.  See the commentary above -- this is load bearing, not defensive."
  `(float-features:with-float-traps-masked (:invalid :divide-by-zero :overflow)
     ,@body))

;;; Encoding node -> alien type ---------------------------------------------

(defvar *alien-struct-types* (make-hash-table :test 'equal)
  "Canonical struct encoding -> the symbol naming its alien type.
Defining an alien type calls the compiler, so they are memoized; the table is
cleared on image restore because the types do not survive a dump.")

(defvar *alien-struct-counter* 0)

(defun alien-struct-type (node)
  "Return a symbol naming the alien struct type for NODE, defining it if needed."
  (let* ((node (resolve-struct-layout node))
         (key (canonical-encoding node)))
    (or (gethash key *alien-struct-types*)
        (setf (gethash key *alien-struct-types*)
              (let* ((name (intern (format nil "OBJC-STRUCT-~D" (incf *alien-struct-counter*))
                                   '#:objc))
                     (slots (loop for field in (third node)
                                  for i from 0
                                  collect (list (intern (format nil "S~D" i) '#:objc)
                                                (alien-type field)))))
                (eval `(sb-alien:define-alien-type ,name
                           (sb-alien:struct ,name ,@slots)))
                name)))))

(defun alien-type (node)
  "The sb-alien type specifier for encoding node NODE.

Every pointer-ish thing becomes SYSTEM-AREA-POINTER rather than a typed alien
pointer.  That keeps the trampoline's Lisp-level contract uniform -- callers
hand in and receive SAPs -- and means the marshalling code above never has to
know an alien type at all."
  (etypecase node
    (keyword
     (ecase node
       ;; SB-ALIEN:VOID, not the keyword :VOID.  The keyword macroexpands into
       ;; a COMPILED-PROGRAM-ERROR at the call site rather than failing here,
       ;; so every void-returning method -- -release among them -- breaks.
       (:void 'sb-alien:void)
       (:unknown 'sb-alien:void)
       (:char '(sb-alien:signed 8))
       (:uchar '(sb-alien:unsigned 8))
       (:short '(sb-alien:signed 16))
       (:ushort '(sb-alien:unsigned 16))
       (:int '(sb-alien:signed 32))
       (:uint '(sb-alien:unsigned 32))
       ;; 'l' and 'L' are 32 bits by definition of the encoding; see types.lisp.
       (:long '(sb-alien:signed 32))
       (:ulong '(sb-alien:unsigned 32))
       (:long-long '(sb-alien:signed 64))
       (:ulong-long '(sb-alien:unsigned 64))
       (:float 'sb-alien:single-float)
       (:double 'sb-alien:double-float)
       ;; C99 _Bool is one byte.  This is what BOOL is on Apple silicon.
       ;;
       ;; (UNSIGNED 8) and deliberately not (BOOLEAN 8), which is the obvious
       ;; spelling and is wrong here.  (BOOLEAN 8) converts on SBCL's side and
       ;; wants a generalized boolean, while everything above this line speaks
       ;; the manual's contract, in which a BOOL is the integer 1 or 0 --
       ;; MARSHAL-ARGUMENT produces those, ARGUMENT-CONVERSION-FORM reads them,
       ;; CONVERT-METHOD-RESULT returns them.  Mixing the two conventions is not
       ;; a type error, it is a silent wrong answer in one direction only:
       ;; measured, (BOOLEAN 8) given the integer 1 arrives at the callee as NO,
       ;; so every BOOL ARGUMENT this library ever sent was NO -- setHidden:,
       ;; setEnabled:, sortDescriptorWithKey:ascending: -- while BOOL results,
       ;; which SBCL converted on the way back, were right the whole time.  One
       ;; byte, 1 or 0, no conversion at either end.
       (:bool '(sb-alien:unsigned 8))
       ((:id :class :sel :cstring :block) 'sb-alien:system-area-pointer)))
    (cons
     (ecase (first node)
       ;; An eight-byte SIMD vector travels as a double: one SIMD register,
       ;; the same one.  A sixteen-byte one as the type made above.
       (:vector (if (= 8 (vector-byte-size node)) 'sb-alien:double-float 'objc-simd-128))
       ;; A matrix has no single alien type: a builder passes its columns as
       ;; separate arguments, returns them as VALUES from a call, and takes
       ;; the marked type of the right width for a callback's result.  See
       ;; NODE-ARGUMENT-TYPES and MATRIX-RESULT-TYPE.
       (:matrix (if (matrix-as-record-p)
                    (alien-struct-type (matrix-struct-node node))
                    (error "A matrix has no single alien type; the builders expand it.")))
       (:pointer 'sb-alien:system-area-pointer)
       (:qualified (alien-type (third node)))
       (:array 'sb-alien:system-area-pointer)
       (:bitfield '(sb-alien:signed 32))
       ((:struct :union) (alien-struct-type node))))))

(defun struct-node-p (node)
  (and (consp node) (member (first node) '(:struct :union))))

;;; 128-bit SIMD vectors ---------------------------------------------------------
;;;
;;; A sixteen-byte vector -- float4, float3 (sixteen bytes, not twelve),
;;; double2, int4 -- travels in one 128-bit register: the whole of v0 on
;;; arm64, xmm0 on x86-64.  sb-alien has no type for a value of that shape.
;;; It also has no way to add one: the alien type classes are a fixed table
;;; indexed by name, and ALIEN-TYPE is a sealed structure.  What it does have
;;; is a class whose methods are function slots, and a type object whose width
;;; is a slot.  So a second instance of the double-float type is made, marked
;;; 128 bits wide, and the double-float class's methods are replaced with
;;; dispatchers: a 128-bit instance gets a NEON register and a simd-pack, and
;;; an ordinary double goes to the method SBCL installed, untouched.
;;;
;;; The Lisp-side carrier is a (SIMD-PACK (UNSIGNED-BYTE 64)): two words,
;;; which is all a register full of lanes is until something reads it as
;;; floats.  Lanes are written and read through a foreign buffer.
;;;
;;; Measured before it was written, against GameplayKit's GKAgent3D, whose
;;; position is a vector_float3: setPosition: then position gives the lanes
;;; back, and a Lisp callback taking and returning a float4 does too, through
;;; the widened callback wrapper in abi-neon.lisp.  arm64 only for now: the
;;; register file names and the callback wrapper are per architecture, and
;;; the x86-64 half has not been written or measured.

(defun wide-vector-supported-p ()
  "Whether this build carries a sixteen-byte SIMD vector by value: on Apple
silicon in a NEON register, on Intel in an XMM register.  Darwin either way."
  (and (member :darwin *features*)
       (or (member :arm64 *features*) (member :x86-64 *features*))
       t))

(defun matrix-as-record-p ()
  "Whether a matrix crosses as one record of its elements -- a struct of
sixteen floats -- rather than as its columns in registers.  On x86-64 the ABI
classifies a 64-byte aggregate as memory, so a matrix argument is copied to
the stack and a matrix result comes back through a hidden pointer, which is
exactly what the record paths already do for CGRect."
  (and (member :x86-64 *features*) t))

(defun matrix-struct-node (node)
  "The struct node a matrix is, as a record: COLUMNS columns of the padded
column vector, column-major, which is the layout simd keeps -- a float3x3 is
three sixteen-byte columns, forty-eight bytes, not nine floats."
  (destructuring-bind (element columns rows) (rest node)
    (let ((lanes (if (= rows 3) 4 rows)))
      (list :struct (format nil "objc_matrix_~(~a~)_~dx~d" element columns rows)
            (make-list (* columns lanes) :initial-element element)))))

(defvar *wide-alien-type* nil
  "The double-float type instance marked 128 bits wide, once installed.")

(defparameter +wide-alien-widths+ '(128 256 384 512)
  "The widths a marked instance may have: one register, or two to four for a
matrix result coming back from a Lisp callback in v0-v3.  A matrix ARGUMENT
never needs one, since the callable takes its columns as separate wide
parameters; a matrix result of a call-out comes back as VALUES of them.")

(defun wide-alien-type-p (type)
  (and (sb-alien::alien-float-type-p type)
       (member (sb-alien::alien-type-bits type) +wide-alien-widths+)
       t))

(defun wide-alien-type-registers (type)
  (/ (sb-alien::alien-type-bits type) 128))

(defun wide-alien-type-name (bits)
  (ecase bits
    (128 'objc-simd-128) (256 'objc-simd-256) (384 'objc-simd-384) (512 'objc-simd-512)))

(defun %effective-alien-method (reader class)
  "The method CLASS would use for READER's slot, walking includes as
INVOKE-ALIEN-TYPE-METHOD does."
  (loop for c = class then (sb-alien::alien-type-class-include c)
        while c
        do (let ((method (funcall reader c)))
             (when method (return method)))))

(defmacro %override-alien-method (class slot (&rest args) &body wide-body)
  "Replace SLOT's method on CLASS with one that runs WIDE-BODY for a 128-bit
instance and the method that was there for anything else."
  (let ((reader (intern (format nil "ALIEN-TYPE-CLASS-~A" slot) :sb-alien)))
    `(let ((original (%effective-alien-method #',reader ,class)))
       (setf (,reader ,class)
             (lambda (type ,@args)
               (declare (ignorable ,@args))
               (if (wide-alien-type-p type)
                   (progn ,@wide-body)
                   (funcall original type ,@args)))))))

(defun %make-marked-double-type (bits)
  "A fresh instance of the double-float alien type marked BITS wide."
  (let* ((double (sb-alien::parse-alien-type 'sb-alien:double-float nil))
         (wide (copy-structure double))
         (dd (sb-kernel:find-defstruct-description
              'sb-alien::alien-double-float-type))
         (nbits (- sb-vm:n-positive-fixnum-bits 5)))
    (flet ((slot (name)
             (sb-kernel:dsd-index (find name (sb-kernel:dd-slots dd)
                                        :key #'sb-kernel:dsd-name))))
      (setf (sb-kernel:%instance-ref wide (slot 'sb-alien::bits)) bits
            (sb-kernel:%instance-ref wide (slot 'sb-alien::alignment)) 128
            ;; The top five bits of the hash are the class id; keep those
            ;; and give the rest a value of its own, so the fun-type cache
            ;; never files a wide signature under a double one.
            (sb-kernel:%instance-ref wide (slot 'sb-alien::hash))
            (logior (logand (sb-alien::alien-type-hash double) (ash 31 nbits))
                    (logand (sxhash (wide-alien-type-name bits)) (1- (ash 1 nbits))))))
    wide))

(defun install-wide-alien-type ()
  "Make OBJC-SIMD-128 an alien type -- a double-float marked 128 bits wide,
the double-float class taught to pass it in a NEON register -- and its
wider siblings for matrix results.  Once per image."
  (when (and (wide-vector-supported-p) (null *wide-alien-type*))
    (let ((wide (%make-marked-double-type 128)))
      ;; The NEON storage classes and the arm64 argument-state helpers are
      ;; arm64 symbols; on Intel they do not exist, and READING them there
      ;; would intern into the locked SB-VM package.  So they are found by
      ;; name, here, where only an arm64 build ever arrives.
      (let* ((class (sb-alien::alien-type-class wide))
             (vm-symbol (lambda (name) (or (find-symbol name :sb-vm)
                                           (error "SB-VM has no ~a on this build" name))))
             (intel (matrix-as-record-p))
             ;; The 128-bit register class and its stack alternative: NEON on
             ;; arm64, SSE on x86-64.  Both hold a simd-pack of two words.
             (wide-reg (sb-c:sc-number-or-lose (funcall vm-symbol (if intel "INT-SSE-REG" "INT-NEON-REG"))))
             (wide-stack (sb-c:sc-number-or-lose (funcall vm-symbol (if intel "INT-SSE-STACK" "INT-NEON-STACK"))))
             (pack-type (funcall vm-symbol "SIMD-PACK-UB64"))
             ;; How many floating-point registers a call has used so far, by
             ;; each backend's name for it; both allow eight.
             (fp-registers (funcall vm-symbol (if intel "ARG-STATE-XMM-ARGS" "ARG-STATE-FP-REGISTERS")))
             (float-arg (funcall vm-symbol "FLOAT-ARG"))
             (make-wired-tn (funcall vm-symbol "MAKE-WIRED-TN*"))
             (result-count (funcall vm-symbol "RESULT-STATE-NUM-RESULTS"))
             (set-result-count (fdefinition (list 'setf (funcall vm-symbol "RESULT-STATE-NUM-RESULTS")))))
        (%override-alien-method class unparse (state)
          (wide-alien-type-name (sb-alien::alien-type-bits type)))
        (%override-alien-method class type= (other)
          (and (wide-alien-type-p other)
               (= (sb-alien::alien-type-bits type) (sb-alien::alien-type-bits other))))
        ;; One register is a simd-pack; several are a vector of them.
        (%override-alien-method class lisp-rep ()
          (if (= 1 (wide-alien-type-registers type))
              '(sb-ext:simd-pack (unsigned-byte 64))
              'simple-vector))
        (%override-alien-method class alien-rep (context)
          (if (= 1 (wide-alien-type-registers type))
              '(sb-ext:simd-pack (unsigned-byte 64))
              'simple-vector))
        (%override-alien-method class naturalize-gen (alien) alien)
        (%override-alien-method class deport-gen (value)
          (if (= 1 (wide-alien-type-registers type))
              `(the (sb-ext:simd-pack (unsigned-byte 64)) ,value)
              `(the simple-vector ,value)))
        (%override-alien-method class extract-gen (sap offset)
          (let ((n (wide-alien-type-registers type)))
            (if (= n 1)
                `(sb-kernel:%make-simd-pack-ub64
                  (sb-sys:sap-ref-64 ,sap (/ ,offset 8))
                  (sb-sys:sap-ref-64 ,sap (+ (/ ,offset 8) 8)))
                `(let ((base (/ ,offset 8)))
                   (vector ,@(loop for i below n
                                   collect `(sb-kernel:%make-simd-pack-ub64
                                             (sb-sys:sap-ref-64 ,sap (+ base ,(* 16 i)))
                                             (sb-sys:sap-ref-64 ,sap (+ base ,(+ 8 (* 16 i)))))))))))
        (%override-alien-method class deposit-gen (sap offset value)
          (let ((n (wide-alien-type-registers type)))
            (if (= n 1)
                `(multiple-value-bind (lo hi) (sb-ext:%simd-pack-ub64s ,value)
                   (setf (sb-sys:sap-ref-64 ,sap (/ ,offset 8)) lo
                         (sb-sys:sap-ref-64 ,sap (+ (/ ,offset 8) 8)) hi))
                `(let ((base (/ ,offset 8)) (columns ,value))
                   ,@(loop for i below n
                           collect `(multiple-value-bind (lo hi)
                                        (sb-ext:%simd-pack-ub64s (svref columns ,i))
                                      (setf (sb-sys:sap-ref-64 ,sap (+ base ,(* 16 i))) lo
                                            (sb-sys:sap-ref-64 ,sap (+ base ,(+ 8 (* 16 i)))) hi)))))))
        (%override-alien-method class arg-tn (state)
          ;; One register only: a matrix argument is passed as its columns,
          ;; each a 128-bit argument of its own.  And the ninth floating-
          ;; point argument goes on the stack, through a VOP for word-sized
          ;; values the image no longer carries; no Objective-C method has
          ;; nine, so refuse rather than corrupt.
          (unless (= 1 (wide-alien-type-registers type))
            (error "A matrix is passed as its columns, not as one argument."))
          (when (>= (funcall fp-registers state) 8)
            (error "A 16-byte SIMD vector must be among the first eight ~
                    floating-point arguments of a call."))
          ;; arm64's FLOAT-ARG takes the argument's size as well; x86-64's
          ;; does not, every XMM argument being one register.
          (if intel
              (funcall float-arg state pack-type wide-reg wide-stack)
              (funcall float-arg state pack-type wide-reg wide-stack 16)))
        (%override-alien-method class result-tn (state)
          ;; The next vector register: v0, v1, ... or xmm0, xmm1, so that
          ;; VALUES of these take successive ones.
          (unless (= 1 (wide-alien-type-registers type))
            (error "A matrix result of a call is VALUES of its columns."))
          (let ((n (funcall result-count state)))
            (funcall set-result-count (1+ n) state)
            (funcall make-wired-tn pack-type wide-reg n)))
        ;; The VALUES class allows two results.  A matrix comes back in up
        ;; to four registers, so when every member is a column carrier the
        ;; limit is lifted and the members take successive registers: a
        ;; wide one asks the method above, a double -- a float2 column --
        ;; is placed here, since SBCL's own double method always says d0.
        (let* ((fun (sb-alien::parse-alien-type
                     '(function (sb-alien:values sb-alien:int sb-alien:int) sb-alien:int) nil))
               (values-class (sb-alien::alien-type-class (sb-alien::alien-fun-type-result-type fun)))
               (original (%effective-alien-method #'sb-alien::alien-type-class-result-tn values-class))
               (double-reg (sb-c:sc-number-or-lose (funcall vm-symbol "DOUBLE-REG"))))
          (setf (sb-alien::alien-type-class-result-tn values-class)
                (lambda (type state)
                  (let ((members (sb-alien::alien-values-type-values type)))
                    (if (and (<= (length members) 4)
                             (every (lambda (m)
                                      (or (wide-alien-type-p m)
                                          (and (sb-alien::alien-float-type-p m)
                                               (eql (sb-alien::alien-type-bits m) 64))))
                                    members))
                        (mapcar (lambda (m)
                                  (if (wide-alien-type-p m)
                                      (sb-alien::invoke-alien-type-method :result-tn m state)
                                      (let ((n (funcall result-count state)))
                                        (funcall set-result-count (1+ n) state)
                                        (funcall make-wired-tn 'double-float double-reg n))))
                                members)
                        (funcall original type state)))))))
      (dolist (bits +wide-alien-widths+)
        (let ((instance (if (= bits 128) wide (%make-marked-double-type bits)))
              (name (wide-alien-type-name bits)))
          (setf (sb-int:info :alien-type :kind name) :primitive
                (sb-int:info :alien-type :translator name)
                (lambda (type env) (declare (ignore type env)) instance))))
      (setf *wide-alien-type* wide))))

(install-wide-alien-type)

(defun matrix-spread-p (node)
  "Whether NODE is a matrix that crosses as its columns, one register each."
  (and (matrix-node-p node) (not (matrix-as-record-p))))

(defun record-like-node-p (node)
  "Whether NODE crosses the way a struct does: a struct, or a matrix where a
matrix is a record."
  (or (struct-node-p node) (and (matrix-node-p node) (matrix-as-record-p))))

(defun node-argument-types (node)
  "The alien types NODE occupies as an argument: one, or a spread matrix's
columns."
  (if (matrix-spread-p node)
      (make-list (third node) :initial-element (alien-type (matrix-column-node node)))
      (list (alien-type node))))

(defun matrix-call-result-type (node)
  "A matrix result of a call: VALUES of its columns, in successive registers;
or the record, where a matrix is one."
  (if (matrix-as-record-p)
      (alien-type node)
      `(sb-alien:values ,@(node-argument-types node))))

(defun matrix-callback-result-type (node)
  "A matrix result of a callback: the marked type as wide as all its columns,
which the widened wrapper loads into v0-v3; or the record, where a matrix is
one.  Spread only for sixteen-byte columns; a float2x2 result is two doubles
in d0 and d1, which nothing here places."
  (if (matrix-as-record-p)
      (alien-type node)
      (let ((column (matrix-column-node node)))
        (unless (= 16 (vector-byte-size column))
          (error "A matrix with eight-byte columns cannot be returned from a Lisp ~
                  method or block yet; ~a can be passed to one." (unparse-type node)))
        (wide-alien-type-name (* 128 (third node))))))

(defun %pack-matrix (node value)
  "A matrix's columns, each packed as a vector, for the builders to spread; or,
where a matrix is a record, a foreign buffer holding it, freed with the call's
temporaries, that the trampoline loads by value."
  (if (matrix-as-record-p)
      (let* ((size (node-size-and-alignment node))
             (buffer (cffi:foreign-alloc :uint8 :count (max 1 size) :initial-element 0)))
        (write-struct-field buffer node value)
        (register-temporary (lambda () (cffi:foreign-free buffer)))
        (sap-of buffer))
      (let ((column (matrix-column-node node)))
        (map 'vector (lambda (c) (pack-vector column c)) value))))

(defun %unpack-matrix (node carriers)
  "The matrix from what carried it: a vector of column carriers, or a pointer
to the record."
  (if (matrix-as-record-p)
      (read-struct-field (pointer-of carriers) node)
      (let ((column (matrix-column-node node)))
        (map 'vector (lambda (c) (unpack-vector column c)) carriers))))

(defun wide-vector-callbacks-supported-p ()
  "Whether a Lisp method or block may take or return a sixteen-byte vector or
a matrix: here, wherever the vectors themselves are carried."
  (wide-vector-supported-p))

(defun result-through-buffer-p (node)
  "Whether a result of type NODE is written through the OUT buffer rather than
returned as a value: structures, and a matrix where a matrix is a record; a
vector, and a spread matrix, is a value."
  (record-like-node-p node))

;;; Lane access ----------------------------------------------------------------
;;;
;;; ELEMENT is a literal keyword at every use; CFFI's typed access is a
;;; SAP-REF here and needs nothing more.

(defmacro %lane-ref (pointer element index)
  `(cffi:mem-aref ,pointer ,(vector-element-cffi-type element) ,index))

(defmacro %lane-set (pointer element index value)
  `(setf (cffi:mem-aref ,pointer ,(vector-element-cffi-type element) ,index) ,value))

;;; Strings ---------------------------------------------------------------------
;;;
;;; UTF-8 in and out.  SBCL's own converters, which is what CFFI's use anyway.

(defun %utf8-to-string (pointer)
  "The NUL-terminated UTF-8 at POINTER as a string."
  (cffi:foreign-string-to-lisp pointer :encoding :utf-8))

(defun %string-to-utf8 (string)
  "STRING as NUL-terminated UTF-8 in foreign memory; free it with FOREIGN-FREE."
  (cffi:foreign-string-alloc string :encoding :utf-8))

(defun %call-with-utf8 (string function)
  "Call FUNCTION with a pointer to STRING's UTF-8 and its byte count, for the
extent of the call: the octets are pinned, not copied."
  (let ((octets (sb-ext:string-to-octets string :external-format :utf-8)))
    (sb-sys:with-pinned-objects (octets)
      (funcall function (sb-sys:vector-sap octets) (length octets)))))

;;; Float bits ------------------------------------------------------------------
;;;
;;; An eight-byte vector's lanes are assembled into 64 bits in convert.lisp;
;;; these turn bits into the double that carries them and back, in registers.

(defun %single-float-bits (x)
  (ldb (byte 32 0) (sb-kernel:single-float-bits x)))

(defun %single-float-from-bits (bits)
  (sb-kernel:make-single-float (if (logbitp 31 bits) (- bits #x100000000) bits)))

(defun %double-float-words (x)
  "The high and low 32-bit words of X's bits, both unsigned."
  (values (ldb (byte 32 0) (sb-kernel:double-float-high-bits x))
          (sb-kernel:double-float-low-bits x)))

(defun %double-float-from-words (high low)
  (sb-kernel:make-double-float (if (logbitp 31 high) (- high #x100000000) high) low))

;;; Packing lanes into the carrier ---------------------------------------------
;;;
;;; The carrier is a simd-pack tagged as two 64-bit words, and SBCL's kernel
;;; builds and reads packs of singles, doubles and 32-bit lanes in registers
;;; -- the same primitives sb-simd's f32.4 and friends are made of -- so a
;;; float4 is made with one instruction and retagged in place, and never
;;; touches memory on the way to v0.  The tags are read from packs the kernel
;;; makes rather than assumed.  Lanes the kernel has no typed constructor for,
;;; shorts and bytes, still go through a buffer.
;;;
;;; A pack is also accepted as a value in its own right: an sb-simd f32.4
;;; passes straight through, retagged, so a transform built with sb-simd's
;;; arithmetic goes to SceneKit without a conversion.

(defvar *pack-tags*
  (list :single (sb-kernel:%simd-pack-tag (sb-kernel:%make-simd-pack-single 0.0 0.0 0.0 0.0))
        :double (sb-kernel:%simd-pack-tag (sb-kernel:%make-simd-pack-double 0d0 0d0))
        :ub32 (sb-kernel:%simd-pack-tag (sb-kernel:%make-simd-pack-ub32 0 0 0 0))
        :ub64 (sb-kernel:%simd-pack-tag (sb-kernel:%make-simd-pack-ub64 0 0)))
  "The kernel's tag for each pack shape, measured.")

(declaim (inline %retag-pack))
(defun %retag-pack (pack tag)
  "PACK's bits under TAG: the same register, read differently."
  (sb-kernel:%make-simd-pack tag (sb-kernel:%simd-pack-low pack) (sb-kernel:%simd-pack-high pack)))

(defun %pack-wide-vector-through-memory (node value)
  (cffi:with-foreign-object (p :uint64 2)
    (setf (cffi:mem-aref p :uint64 0) 0 (cffi:mem-aref p :uint64 1) 0)
    (write-vector-elements p node value)
    (sb-kernel:%make-simd-pack-ub64 (cffi:mem-aref p :uint64 0)
                                    (cffi:mem-aref p :uint64 1))))

(defun %unpack-wide-vector-through-memory (node pack)
  (cffi:with-foreign-object (p :uint64 2)
    (multiple-value-bind (lo hi) (sb-ext:%simd-pack-ub64s pack)
      (setf (cffi:mem-aref p :uint64 0) lo (cffi:mem-aref p :uint64 1) hi))
    (read-vector-elements p node)))

(defun %pack-wide-vector (node value)
  "VALUE's lanes as the simd-pack that travels in a 128-bit register.
VALUE is a sequence with one element per lane, or a simd-pack already."
  (unless (wide-vector-supported-p)
    (error 'unsupported-type-encoding
           :encoding node
           :detail "a 16-byte SIMD vector is carried on SBCL for Apple silicon only"))
  (when (sb-ext:simd-pack-p value)
    (return-from %pack-wide-vector (%retag-pack value (getf *pack-tags* :ub64))))
  (destructuring-bind (element count) (rest node)
    (unless (and (typep value 'sequence) (not (stringp value)) (= (length value) count))
      (error "Cannot pass ~S as a ~d-element SIMD vector of ~(~a~)." value count element))
    (let ((lanes (coerce value 'list)))
      (flet ((lane (i) (if (< i (length lanes)) (nth i lanes) 0)))
        (case element
          (:float
           (%retag-pack (sb-kernel:%make-simd-pack-single
                         (coerce (lane 0) 'single-float) (coerce (lane 1) 'single-float)
                         (coerce (lane 2) 'single-float) (coerce (lane 3) 'single-float))
                        (getf *pack-tags* :ub64)))
          (:double
           (%retag-pack (sb-kernel:%make-simd-pack-double
                         (coerce (lane 0) 'double-float) (coerce (lane 1) 'double-float))
                        (getf *pack-tags* :ub64)))
          ((:int :uint)
           (%retag-pack (sb-kernel:%make-simd-pack-ub32
                         (ldb (byte 32 0) (lane 0)) (ldb (byte 32 0) (lane 1))
                         (ldb (byte 32 0) (lane 2)) (ldb (byte 32 0) (lane 3)))
                        (getf *pack-tags* :ub64)))
          ((:long-long :ulong-long)
           (sb-kernel:%make-simd-pack-ub64 (ldb (byte 64 0) (lane 0)) (ldb (byte 64 0) (lane 1))))
          (t (%pack-wide-vector-through-memory node value)))))))

(defun %unpack-wide-vector (node pack)
  "The lanes of PACK, a simd-pack, as a Lisp vector."
  (destructuring-bind (element count) (rest node)
    (flet ((take (values) (coerce (subseq values 0 count) 'vector))
           (signed (x bits) (if (logbitp (1- bits) x) (- x (ash 1 bits)) x)))
      (case element
        (:float
         (take (multiple-value-list
                (sb-kernel:%simd-pack-singles (%retag-pack pack (getf *pack-tags* :single))))))
        (:double
         (take (multiple-value-list
                (sb-kernel:%simd-pack-doubles (%retag-pack pack (getf *pack-tags* :double))))))
        (:uint
         (take (multiple-value-list
                (sb-kernel:%simd-pack-ub32s (%retag-pack pack (getf *pack-tags* :ub32))))))
        (:int
         (take (mapcar (lambda (x) (signed x 32))
                       (multiple-value-list
                        (sb-kernel:%simd-pack-ub32s (%retag-pack pack (getf *pack-tags* :ub32)))))))
        (:ulong-long
         (take (multiple-value-list (sb-ext:%simd-pack-ub64s (%retag-pack pack (getf *pack-tags* :ub64))))))
        (:long-long
         (take (mapcar (lambda (x) (signed x 64))
                       (multiple-value-list (sb-ext:%simd-pack-ub64s (%retag-pack pack (getf *pack-tags* :ub64)))))))
        (t (%unpack-wide-vector-through-memory node pack))))))

;;; Dispatch entry points ----------------------------------------------------

(defvar *msgsend-address* nil)
(defvar *msgsend-super-address* nil)
(defvar *msgsend-stret-address* nil
  "objc_msgSend_stret, or NIL where it does not exist.

Its presence is the signal for whether this architecture returns large
structures through a separate entry point, and it is measured rather than
assumed: the symbol is simply absent from libobjc on arm64.  See
STRET-REQUIRED-P.")
(defvar *msgsend-super-stret-address* nil)

(defun ensure-dispatch-addresses ()
  "Resolve the objc_msgSend family once, as integers.

Integers rather than SAPs so they inline into a compiled trampoline as
immediates instead of being fetched through a closure cell on every call.  The
_stret pair is optional and stays NIL where the architecture has no such
function."
  (unless *msgsend-address*
    (let ((send (cffi:foreign-symbol-pointer "objc_msgSend"))
          (super (cffi:foreign-symbol-pointer "objc_msgSendSuper"))
          (stret (cffi:foreign-symbol-pointer "objc_msgSend_stret"))
          (super-stret (cffi:foreign-symbol-pointer "objc_msgSendSuper_stret")))
      (when (or (null send) (null super))
        (error 'library-not-found
               :name "objc_msgSend"
               :candidates +libobjc-candidates+))
      (setf *msgsend-address* (cffi:pointer-address send)
            *msgsend-super-address* (cffi:pointer-address super)
            *msgsend-stret-address* (and stret (cffi:pointer-address stret))
            *msgsend-super-stret-address* (and super-stret
                                               (cffi:pointer-address super-stret)))))
  (values *msgsend-address* *msgsend-super-address*))

(defparameter +max-register-returned-struct+ 16
  "Largest structure the x86-64 SysV ABI returns in registers.

Anything bigger is classified MEMORY and comes back through a hidden pointer,
which is what objc_msgSend_stret exists to arrange.  CGRect is 32 bytes, so
-[NSView frame] is on the wrong side of this line.")

(defun stret-required-p (node)
  "True when a structure result must go through the separate _stret entry.

Two conditions, both necessary.  The architecture has to have such an entry at
all -- on arm64 it does not, because a large structure comes back through x8
from plain objc_msgSend and objc_msgSend_stret is not even a symbol there.  And
the structure has to be one the ABI returns in memory rather than in registers.

Getting this wrong is not a graceful failure.  objc_msgSend cannot perform an
sret call: the hidden result pointer displaces the receiver into the wrong
register, so the receiver is read as garbage."
  (and *msgsend-stret-address*
       (record-like-node-p node)
       (> (node-size-and-alignment (if (struct-node-p node) (resolve-struct-layout node) node))
          +max-register-returned-struct+)))

;;; Trampolines --------------------------------------------------------------

(defun build-trampoline (kind result-node arg-nodes &optional n-fixed)
  "Compile a function that sends one exact call signature.

KIND is :SEND or :SUPER, and selects only the entry address -- objc_msgSend and
objc_msgSendSuper take a pointer first either way, so the alien signature is
byte identical and the generated code is the same shape.

The returned function's contract is uniform and struct free:

    (out-sap arg...) => scalar-or-NIL

Every pointer, struct and SEL is a SAP; every number is a Lisp number.  A struct
result is written through OUT-SAP and the function returns NIL, so that callers
never have to branch on whether a result came back in registers or through x8.
All the Cocoa flavoured conversion happens above this, outside the compiler.

N-FIXED, when non-NIL, is the number of arguments before the variadic ones.
Splicing &optional into an alien signature is what makes a genuine Darwin arm64
variadic call: with it, snprintf(\"%d\", 42) prints \"The integer 42\"; without
it, \"The integer 1232\", because arm64 passes variadic arguments on the stack
while a fixed signature passes them in registers."
  (ensure-dispatch-addresses)
  (let* ((structp (record-like-node-p result-node))
         (stretp (stret-required-p result-node))
         (entry (ecase kind
                  (:send (if stretp *msgsend-stret-address* *msgsend-address*))
                  (:super (if stretp
                              *msgsend-super-stret-address*
                              *msgsend-super-address*))))
         (result-node (if (struct-node-p result-node) (resolve-struct-layout result-node) result-node))
         (matrixp (matrix-spread-p result-node))
         (rtype (if (matrix-node-p result-node) (matrix-call-result-type result-node) (alien-type result-node)))
         (out (gensym "OUT"))
         (syms (loop for i from 0 below (length arg-nodes)
                     collect (gensym (format nil "A~D-" i))))
         ;; A matrix argument is its columns, one alien argument each.
         (atypes (mapcan #'node-argument-types arg-nodes))
         ;; A struct argument arrives as a SAP and is loaded by value here; a
         ;; scalar is passed straight through; a matrix, a vector of column
         ;; carriers, is spread.
         (args (loop for sym in syms
                     for node in arg-nodes
                     append (cond ((record-like-node-p node)
                                   (list `(sb-alien:deref
                                           (sb-alien:sap-alien ,sym (sb-alien:* ,(alien-type node))))))
                                  ((matrix-spread-p node)
                                   (loop for i below (third node) collect `(svref ,sym ,i)))
                                  (t (list sym)))))
         ;; N-FIXED counts nodes; a matrix among the fixed ones is several
         ;; alien arguments, so the split is found by walking the nodes.
         (n-fixed-types (and n-fixed
                             (loop for node in (subseq arg-nodes 0 (min n-fixed (length arg-nodes)))
                                   sum (length (node-argument-types node)))))
         (ftype `(sb-alien:function
                  ,rtype
                  ,@(if n-fixed
                        (append (subseq atypes 0 (min n-fixed-types (length atypes)))
                                (list '&optional)
                                (subseq atypes (min n-fixed-types (length atypes))))
                        atypes))))
    (compile
     nil
     `(lambda (,out ,@syms)
        (declare (optimize (speed 3) (safety 0))
                 (ignorable ,out)
                 (type sb-sys:system-area-pointer ,out)
                 ,@(loop for sym in syms
                         for node in arg-nodes
                         when (or (record-like-node-p node)
                                  (member node '(:id :class :sel :cstring :block))
                                  (and (consp node)
                                       (member (first node) '(:pointer :array))))
                           collect `(type sb-sys:system-area-pointer ,sym)))
        ,(let ((call `(sb-alien:alien-funcall
                       (sb-alien:sap-alien (sb-sys:int-sap ,entry) ,ftype)
                       ,@args)))
           (cond
             (structp
              `(progn
                 (setf (sb-alien:deref (sb-alien:sap-alien ,out (sb-alien:* ,rtype)))
                       ,call)
                 nil))
             ((eq result-node :void) `(progn ,call nil))
             ;; The columns come back as values; the contract wants one.
             (matrixp `(coerce (multiple-value-list ,call) 'simple-vector))
             (t call)))))))


(defun build-block-caller (result-node arg-nodes invoke-offset)
  "Compile a function that calls a block, and return it.

    (out-sap block-sap arg...) => scalar-or-NIL

The same contract as BUILD-TRAMPOLINE, and the same struct handling, with one
difference that is the whole point: a message send jumps to objc_msgSend, whose
address is known when the trampoline is compiled, while a block carries its own
function pointer in its invoke field.  So the entry is read out of the block at
call time rather than baked in as an immediate, and the block is passed back to
it as the first argument -- a block's invoke function takes the block where a
method takes self.

ARG-NODES includes the block as its first element.  INVOKE-OFFSET is where the
invoke field sits in the block literal; the caller passes it from the CFFI
struct definition so the layout has exactly one source of truth.

This works on any block, whoever made it: one built by MAKE-OBJC-BLOCK, or one
Cocoa handed us."
  (let* ((structp (record-like-node-p result-node))
         (result-node (if (struct-node-p result-node) (resolve-struct-layout result-node) result-node))
         (matrixp (matrix-spread-p result-node))
         (rtype (if (matrix-node-p result-node) (matrix-call-result-type result-node) (alien-type result-node)))
         (out (gensym "OUT"))
         (fn (gensym "INVOKE"))
         (syms (loop for i from 0 below (length arg-nodes)
                     collect (gensym (format nil "A~D-" i))))
         (atypes (mapcan #'node-argument-types arg-nodes))
         (args (loop for sym in syms
                     for node in arg-nodes
                     append (cond ((record-like-node-p node)
                                   (list `(sb-alien:deref
                                           (sb-alien:sap-alien ,sym (sb-alien:* ,(alien-type node))))))
                                  ((matrix-spread-p node)
                                   (loop for i below (third node) collect `(svref ,sym ,i)))
                                  (t (list sym)))))
         (ftype `(sb-alien:function ,rtype ,@atypes)))
    (compile
     nil
     `(lambda (,out ,@syms)
        (declare (optimize (speed 3) (safety 0))
                 (ignorable ,out)
                 (type sb-sys:system-area-pointer ,out ,(first syms))
                 ,@(loop for sym in (rest syms)
                         for node in (rest arg-nodes)
                         when (or (record-like-node-p node)
                                  (member node '(:id :class :sel :cstring :block))
                                  (and (consp node)
                                       (member (first node) '(:pointer :array))))
                           collect `(type sb-sys:system-area-pointer ,sym)))
        (let ((,fn (sb-sys:sap-ref-sap ,(first syms) ,invoke-offset)))
          ,(let ((call `(sb-alien:alien-funcall
                         (sb-alien:sap-alien ,fn ,ftype)
                         ,@args)))
             (cond
               (structp
                `(progn
                   (setf (sb-alien:deref (sb-alien:sap-alien ,out (sb-alien:* ,rtype)))
                         ,call)
                   nil))
               ((eq result-node :void) `(progn ,call nil))
               (matrixp `(coerce (multiple-value-list ,call) 'simple-vector))
               (t call))))))))


;;; Implementations -- the other direction ----------------------------------
;;;
;;; A Lisp-implemented Objective-C method needs a real function pointer with the
;;; method's exact C signature, because the runtime will call it with arguments
;;; in registers per the ABI.  SB-ALIEN:DEFINE-ALIEN-CALLABLE builds one, and it
;;; handles struct arguments and struct returns in this direction too -- which
;;; CFFI:DEFCALLBACK does not: a struct return there signals CASE-FAILURE.  That
;;; is what makes the manual's "pair" example, and -drawRect:, work.
;;;
;;; Plain function pointers rather than imp_implementationWithBlock: an IMP has
;;; no need of a Block literal, and LispWorks does not use blocks for this
;;; either.  Blocks themselves are built in blocks.lisp -- BUILD-BLOCK-INVOKE
;;; below is this same machinery with one hidden argument instead of two -- but
;;; a method is not where they earn anything.

(defvar *imp-registry* (make-hash-table :test 'equal)
  "(objc-class-name selector class-method-p) -> the alien callable's name.

Every IMP lives here forever.  SBCL recycles a callback's trampoline once the
callable becomes garbage, and a recycled IMP is a jump into freed memory the
next time Cocoa sends that message -- a crash arbitrarily far from the cause.
Redefining a method replaces the entry and keeps the old callable alive, which
leaks a few hundred bytes per redefinition and is the right trade against
crashing during interactive development.")

(defvar *imp-counter* 0)

(defun report-imp-error (condition selector &optional (noun "method"))
  "Report a condition that tried to escape a Lisp implementation into Objective-C.

NOUN is what the thing is called in the message -- a block is not a method, and
saying so is the difference between a diagnostic that locates the fault and one
that sends the reader to the wrong file."
  (format *error-output*
          "~&Error in Objective-C ~A ~A: ~A~%~
             Returning a zero value; the Objective-C caller has no handler.~%"
          noun selector condition)
  (finish-output *error-output*))

(defun zero-value-form (node)
  "A form for the value to return when a Lisp method body signals."
  (cond ((struct-node-p node) nil)
        ((member node '(:float)) 0.0)
        ((member node '(:double)) 0d0)
        ((vector-node-p node)
         (if (= 8 (vector-byte-size node)) 0d0 '(sb-kernel:%make-simd-pack-ub64 0 0)))
        ((matrix-node-p node)
         `(vector ,@(loop repeat (third node)
                          collect (zero-value-form (matrix-column-node node)))))
        ((member node '(:void :unknown)) nil)
        ;; 0, not NIL: the alien type is (UNSIGNED 8) and NIL is not one.
        ((eq node :bool) 0)
        ((or (member node '(:id :class :sel :cstring :block))
             (and (consp node) (member (first node) '(:pointer :array))))
         '(sb-sys:int-sap 0))
        (t 0)))

(defun build-callable (name result-node arg-nodes n-hidden body &optional (noun "method"))
  "Build an alien callable named NAME, and return (VALUES SAP NAME).

The generic form of what an Objective-C implementation needs: a real C function
pointer with an exact signature, calling into Lisp.  ARG-NODES describes every
C parameter, including the hidden leading ones.  N-HIDDEN says how many of those
are the calling convention's rather than the user's, and BODY is called as

    (funcall BODY hidden... result-sap user-args...)

An IMP has two hidden arguments, self and _cmd.  A block's invoke function has
one, the block itself.  That number is the only thing that differs between them,
which is why this is one function and not two.

Two things happen at the boundary and both are necessary.  The float traps Cocoa
violates are masked, because AppKit generates invalid operations freely and an
unmasked one here takes the process out.  And no Lisp condition is allowed to
escape: there is no handler on the Objective-C side, so an unwind past this
frame aborts.  LispWorks does the same thing, calling it a catch-all frame --
its message is \"Capturing attempt to throw out of Cocoa handler\"."
  (let* ((structp (record-like-node-p result-node))
         (result-node (if (struct-node-p result-node) (resolve-struct-layout result-node) result-node))
         (matrixp (matrix-spread-p result-node))
         (result-type (if (matrix-node-p result-node)
                          (matrix-callback-result-type result-node)
                          (alien-type result-node)))
         (syms (loop for i from 0 below (length arg-nodes)
                     collect (intern (format nil "A~D" i) '#:objc)))
         ;; A matrix parameter is its columns, one alien parameter each, and
         ;; the body is handed them gathered into a vector.
         (column-syms (loop for sym in syms
                            for node in arg-nodes
                            collect (and (matrix-spread-p node)
                                         (loop for i below (third node)
                                               collect (intern (format nil "~A-C~D" sym i) '#:objc)))))
         (params (loop for sym in syms
                       for node in arg-nodes
                       for columns in column-syms
                       append (if columns
                                  (loop for c in columns
                                        collect (list c (alien-type (matrix-column-node node))))
                                  (list (list sym (alien-type node))))))
         ;; A struct parameter arrives by value, and a callable's parameter is
         ;; not addressable -- (addr p) is rejected with "P is not a valid
         ;; L-value".  Copying it into a WITH-ALIEN local gives us something we
         ;; can take the address of, which keeps the contract above uniform:
         ;; everything non-scalar reaches the body as a SAP.
         (struct-temps (loop for sym in syms
                             for node in arg-nodes
                             when (record-like-node-p node)
                               collect (list (gensym (format nil "~A-COPY-" sym))
                                             sym (alien-type node))))
         (body-args (loop for sym in syms
                          for node in arg-nodes
                          for columns in column-syms
                          collect (cond ((record-like-node-p node)
                                         (let ((temp (first (find sym struct-temps
                                                                  :key #'second))))
                                           `(sb-alien:alien-sap (sb-alien:addr ,temp))))
                                        (columns `(vector ,@columns))
                                        (t sym))))
         (result-sym (gensym "RESULT")))
    (eval
     `(sb-alien:define-alien-callable ,name ,result-type ,params
        (with-fp-traps-masked
          (sb-alien:with-alien ,(loop for (temp nil type) in struct-temps
                                      collect (list temp type))
            ,@(loop for (temp sym) in struct-temps
                    collect `(setf ,temp ,sym))
          ,(if structp
               ;; A struct result is built in a local and returned by value; the
               ;; body fills it through a pointer, which is what
               ;; DEFINE-OBJC-METHOD's result-style variable binds to.
               `(sb-alien:with-alien ((,result-sym ,(alien-type result-node)))
                  (handler-case
                      (funcall ,body ,@(subseq body-args 0 n-hidden)
                               (sb-alien:alien-sap (sb-alien:addr ,result-sym))
                               ,@(nthcdr n-hidden body-args))
                    (serious-condition (c) (report-imp-error c ',name ,noun)))
                  ,result-sym)
               `(handler-case
                    (funcall ,body ,@(subseq body-args 0 n-hidden) (sb-sys:int-sap 0)
                             ,@(nthcdr n-hidden body-args))
                  (serious-condition (c)
                    (report-imp-error c ',name ,noun)
                    ,(zero-value-form result-node))))))))
    ;; ALIEN-CALLABLE-FUNCTION returns an ALIEN-VALUE; class_addMethod needs the
    ;; address, and passing the alien value is a type error.
    (values (sb-alien:alien-sap (sb-alien:alien-callable-function name)) name)))

(defun build-imp (result-node arg-nodes body)
  "Build a real IMP that calls BODY, and return (VALUES SAP CALLABLE-NAME).

BODY is a function of (self-sap cmd-sap result-sap . args).  ARG-NODES includes
self and _cmd, as every Objective-C method signature does -- the two hidden
arguments every Objective-C message send passes."
  (build-callable (intern (format nil "OBJC-IMP-~D" (incf *imp-counter*)) '#:objc)
                  result-node arg-nodes 2 body "method"))

(defvar *block-invoke-counter* 0)

(defun methods-as-blocks-p ()
  "Whether a Lisp-defined method is a block minted into an IMP by libobjc
rather than an alien callable of its own.  Yes here: on Apple silicon every
callable's trampoline costs about 7 KB of a fixed 1 MB static code space that
is never reclaimed, some 140 methods per image, and a block over one callable
per signature costs it nothing.  See \"Methods as blocks\" in blocks.lisp."
  t)

(defun build-block-invoke (result-node arg-nodes body &optional (noun "block"))
  "Build a block's invoke function that calls BODY, and return (VALUES SAP NAME).

BODY is a function of (block-sap result-sap . args).  ARG-NODES includes the
block pointer as its first element: a block's invoke function takes the block
where a method takes self, and there is no _cmd -- one hidden argument rather
than two, which is the whole of the difference from an IMP.  NOUN is what a
condition escaping BODY is reported as; a Lisp method is a block now, and its
report should still say method.

The SAP goes in the block literal's invoke field.  Like an IMP's, the callable
must be kept alive for as long as any block can reach it; see *BLOCK-MACHINERY*
in blocks.lisp, which is that root."
  (build-callable (intern (format nil "OBJC-BLOCK-INVOKE-~D" (incf *block-invoke-counter*))
                          '#:objc)
                  result-node arg-nodes 1 body noun))

(defvar *block-helper-counter* 0)

(defun build-block-helper (arg-count body)
  "Build a block copy or dispose helper, and return (VALUES SAP NAME).

libclosure calls these when it copies a block to the heap and when it finally
frees that copy: copy(dst, src) with ARG-COUNT 2, dispose(block) with 1.  Each
takes pointers and returns nothing, so unlike an invoke function there is no
signature to vary -- there are exactly two of them in the process, whatever
block types exist, which is why this takes an argument count rather than nodes.

BODY is a function of (result-sap . args); the result SAP is always null, since
these return void.  It reaches BUILD-CALLABLE with no hidden arguments at all:
neither a receiver nor a block, because libclosure passes the block as an
ordinary parameter here."
  (build-callable (intern (format nil "OBJC-BLOCK-HELPER-~D" (incf *block-helper-counter*))
                          '#:objc)
                  :void (make-list arg-count :initial-element '(:pointer :void))
                  0 body "block helper"))

;;; Small helpers the layers above need, kept here so they need not know sb-sys.

(declaim (inline sap-of pointer-of))

(defun sap-of (pointer)
  "The system area pointer for a CFFI pointer."
  (sb-sys:int-sap (cffi:pointer-address pointer)))

(defun pointer-of (sap)
  "The CFFI pointer for a system area pointer."
  (cffi:make-pointer (sb-sys:sap-int sap)))

(defun sb-sap-zero ()
  "A null system area pointer, for the OUT argument of a non-struct send."
  (sb-sys:int-sap 0))

(defun clear-abi-caches ()
  (clrhash *alien-struct-types*)
  (setf *msgsend-address* nil
        *msgsend-super-address* nil
        *msgsend-stret-address* nil
        *msgsend-super-stret-address* nil))

(add-image-restore-thunk 'clear-abi-caches)
