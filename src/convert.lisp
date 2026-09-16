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

(defvar *call-temporaries* :outside
  "Bound per send to a list of thunks that free this call's temporaries.
:OUTSIDE when no send is in progress, so a temporary made then -- packing a
value at the REPL, say -- is not filed where nothing will ever free it.")

(defmacro with-call-temporaries (&body body)
  `(let ((*call-temporaries* '()))
     (unwind-protect (locally ,@body)
       (dolist (thunk *call-temporaries*) (ignore-errors (funcall thunk))))))

(defun register-temporary (thunk)
  (unless (eq *call-temporaries* :outside)
    (push thunk *call-temporaries*)))

;;; Strings ------------------------------------------------------------------

(define-runtime-function ("CFStringCreateWithBytes" %cf-string-create-with-bytes) :pointer
  (allocator :pointer)
  (bytes :pointer)
  (length :long)
  (encoding :uint32)
  (external-representation :boolean))

(defconstant +cf-string-encoding-utf8+ #x08000100
  "kCFStringEncodingUTF8.")

(defun string-to-ns-string (string &optional autoreleasep)
  "Return an NSString containing the characters of STRING.

When AUTORELEASEP is true the result is autoreleased; otherwise YOU are
responsible for releasing it, which is what the manual specifies.

Made with CFStringCreateWithBytes on the string's UTF-8, which is one C call
and comes back at +1, rather than -[NSString alloc] and -initWithUTF8String:,
two sends: the sends were 394 of the 461 ns a string argument cost
(bench/RESULTS.md, 2026-09-16).  A CFString is an NSString -- toll-free
bridged, it is what +stringWithUTF8String: makes anyway -- and taking a byte
count rather than a C string means a NUL in the Lisp string survives."
  (check-type string string)
  (let* ((octets (babel:string-to-octets string :encoding :utf-8))
         (ns (cffi:with-pointer-to-vector-data (bytes octets)
               (%cf-string-create-with-bytes (cffi:null-pointer) bytes (length octets)
                                             +cf-string-encoding-utf8+ nil))))
    (when (cffi:null-pointer-p ns)
      (error "CFStringCreateWithBytes refused ~S." string))
    (if autoreleasep
        (pointer-of (send-raw ns "autorelease"))
        ns)))

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

;;; Any declared structure, from a sequence ------------------------------------
;;;
;;; The four Cocoa structures above have hand-written converters.  A structure
;;; declared with DEFINE-OBJC-STRUCT has a known layout too -- its fields and
;;; their types are the node -- so a sequence with one element per field can
;;; be written into it by the same rule, generalised: each element is coerced
;;; to its field's type and stored at its field's offset.  Before this, such a
;;; structure could only be returned from a Lisp method, or passed to a
;;; message, as a pointer to foreign memory filled in by hand.

(defun struct-field-offsets (node)
  "The byte offset of each field of NODE, laid out as NODE-SIZE-AND-ALIGNMENT
lays them out: each field aligned to its own alignment, a union's all at zero."
  (let* ((node (resolve-struct-layout node))
         (unionp (eq (first node) :union))
         (offset 0)
         (offsets '()))
    (dolist (field (third node) (nreverse offsets))
      (multiple-value-bind (size align) (node-size-and-alignment field)
        (if unionp
            (push 0 offsets)
            (progn
              (setf offset (* (ceiling offset align) align))
              (push offset offsets)
              (incf offset size)))))))

(defun struct-sequence-p (value)
  "A sequence that could stand for a structure: a vector or a list, not a string."
  (or (and (vectorp value) (not (stringp value)))
      (listp value)))

(defun write-struct-field (pointer node value)
  "Store VALUE as a field of type NODE at POINTER."
  (etypecase node
    (keyword
     (ecase node
       (:char (setf (cffi:mem-ref pointer :int8) value))
       (:uchar (setf (cffi:mem-ref pointer :uint8) value))
       (:short (setf (cffi:mem-ref pointer :int16) value))
       (:ushort (setf (cffi:mem-ref pointer :uint16) value))
       ((:int :long) (setf (cffi:mem-ref pointer :int32) value))
       ((:uint :ulong) (setf (cffi:mem-ref pointer :uint32) value))
       (:long-long (setf (cffi:mem-ref pointer :int64) value))
       (:ulong-long (setf (cffi:mem-ref pointer :uint64) value))
       (:float (setf (cffi:mem-ref pointer :float) (coerce value 'single-float)))
       (:double (setf (cffi:mem-ref pointer :double) (coerce value 'double-float)))
       ;; The manual's contract for a BOOL is the integer 1 or 0; a generalized
       ;; boolean is taken too, since a slot is where one is most tempting.
       (:bool (setf (cffi:mem-ref pointer :uint8)
                    (cond ((eql value 0) 0) ((null value) 0) (t 1))))
       ((:id :class :sel :cstring :block)
        (setf (cffi:mem-ref pointer :pointer) (or value (cffi:null-pointer))))))
    (cons
     (ecase (first node)
       (:pointer (setf (cffi:mem-ref pointer :pointer) (or value (cffi:null-pointer))))
       (:qualified (write-struct-field pointer (third node) value))
       (:vector (write-vector-elements pointer node value))
       (:matrix (let* ((column (matrix-column-node node))
                       (stride (vector-byte-size column))
                       (i 0))
                  (map nil (lambda (c)
                             (write-vector-elements (cffi:inc-pointer pointer (* i stride)) column c)
                             (incf i))
                       value)))
       ((:struct :union) (write-struct-from-sequence pointer node value))
       ((:array :bitfield)
        (error "A ~(~a~) field cannot be written from a sequence; fill the ~
                structure in foreign memory and pass the pointer instead."
               (first node)))))))

(defun write-struct-from-sequence (pointer node value)
  "Write VALUE, one element per field of NODE, into the structure at POINTER.
A nested structure field takes a sequence of its own."
  (let* ((node (resolve-struct-layout node))
         (fields (third node)))
    (unless (= (length value) (length fields))
      (error "~S has ~D element~:P, but ~A has ~D field~:P."
             value (length value)
             (or (second node) "the structure") (length fields)))
    (loop for field in fields
          for offset in (struct-field-offsets node)
          for element in (coerce value 'list)
          do (write-struct-field (cffi:inc-pointer pointer offset) field element))
    pointer))

(defun struct-readable-p (node)
  "Whether NODE's layout is known and every field is a scalar, a pointer, or a
structure of the same kind: what READ-STRUCT-TO-SEQUENCE can read."
  (let ((node (ignore-errors (resolve-struct-layout node))))
    (and node
         (eq (first node) :struct)
         (third node)
         (every (lambda (field)
                  (etypecase field
                    (keyword t)
                    (cons (case (first field)
                            ((:pointer :vector :matrix) t)
                            ((:qualified) (struct-readable-p (third field)))
                            ((:struct) (struct-readable-p field))
                            (t nil)))))
                (third node)))))

(defun read-struct-field (pointer node)
  (etypecase node
    (keyword
     (ecase node
       (:char (cffi:mem-ref pointer :int8))
       (:uchar (cffi:mem-ref pointer :uint8))
       (:short (cffi:mem-ref pointer :int16))
       (:ushort (cffi:mem-ref pointer :uint16))
       ((:int :long) (cffi:mem-ref pointer :int32))
       ((:uint :ulong) (cffi:mem-ref pointer :uint32))
       (:long-long (cffi:mem-ref pointer :int64))
       (:ulong-long (cffi:mem-ref pointer :uint64))
       (:float (cffi:mem-ref pointer :float))
       (:double (cffi:mem-ref pointer :double))
       (:bool (cffi:mem-ref pointer :uint8))
       ((:id :class :sel :cstring :block) (cffi:mem-ref pointer :pointer))))
    (cons
     (ecase (first node)
       (:pointer (cffi:mem-ref pointer :pointer))
       (:qualified (read-struct-field pointer (third node)))
       (:vector (read-vector-elements pointer node))
       (:matrix (let* ((column (matrix-column-node node))
                       (stride (vector-byte-size column)))
                  (coerce (loop for i below (third node)
                                collect (read-vector-elements (cffi:inc-pointer pointer (* i stride)) column))
                          'vector)))
       (:struct (read-struct-to-sequence pointer node))))))

(defun read-struct-to-sequence (pointer node)
  "The structure at POINTER as a vector with one element per field of NODE,
a nested structure as a vector of its own: the read side of
WRITE-STRUCT-FROM-SEQUENCE, and what INVOKE returns for a declared structure."
  (let ((node (resolve-struct-layout node)))
    (coerce (loop for field in (third node)
                  for offset in (struct-field-offsets node)
                  collect (read-struct-field (cffi:inc-pointer pointer offset) field))
            'vector)))

;;; SIMD vectors ---------------------------------------------------------------
;;;
;;; An eight-byte vector crosses as the double occupying the same bytes; see
;;; types.lisp for why a double and not a struct.  The lanes are assembled
;;; into the double's 64 bits arithmetically -- lane 0 lowest, as on the
;;; little-endian machines this runs on -- and the seam turns the bits into a
;;; double and back, which SBCL does without touching memory.  This went
;;; through a foreign buffer once, the obvious way to reinterpret bits and 240
;;; ns each way against 13 for the arithmetic (bench/RESULTS.md, 2026-09-16).
;;; Memory is still the path for a vector inside a struct, and for the wide
;;; vectors, where there is memory anyway.

(defun vector-element-cffi-type (element)
  (ecase element
    (:char :int8) (:uchar :uint8) (:short :int16) (:ushort :uint16)
    (:int :int32) (:uint :uint32) (:long-long :int64) (:ulong-long :uint64)
    (:float :float) (:double :double)))

(defun write-vector-elements (pointer node value)
  "Store VALUE, a sequence with one element per lane, at POINTER as NODE."
  (destructuring-bind (element count) (rest node)
    (unless (and (typep value 'sequence) (not (stringp value)) (= (length value) count))
      (error "Cannot pass ~S as a ~d-element SIMD vector of ~(~a~)." value count element))
    (let ((type (vector-element-cffi-type element))
          (i 0))
      (map nil (lambda (x)
                 (setf (cffi:mem-aref pointer type i)
                       (case element
                         (:float (coerce x 'single-float))
                         (:double (coerce x 'double-float))
                         (t x)))
                 (incf i))
           value))))

(defun read-vector-elements (pointer node)
  "The NODE vector at POINTER, as a Lisp vector with one element per lane."
  (destructuring-bind (element count) (rest node)
    (let ((type (vector-element-cffi-type element)))
      (coerce (loop for i below count collect (cffi:mem-aref pointer type i)) 'vector))))

(defun lane-bit-size (element)
  "Spelled out rather than asked of CFFI: FOREIGN-TYPE-SIZE folds to a constant
for a literal type and parses a variable one on every call, 53 ns against 6."
  (ecase element
    ((:char :uchar) 8)
    ((:short :ushort) 16)
    ((:int :uint :float) 32)
    ((:long-long :ulong-long :double) 64)))

(defun lane-bits (element value)
  "The bit pattern of VALUE as a lane of ELEMENT, an unsigned integer."
  (ecase element
    (:float (%single-float-bits (coerce value 'single-float)))
    ((:char :short :int :long-long) (ldb (byte (lane-bit-size element) 0) value))
    ((:uchar :ushort :uint :ulong-long) value)))

(defun lane-value (element bits)
  "The lane of ELEMENT whose bit pattern is BITS."
  (ecase element
    (:float (%single-float-from-bits bits))
    ((:char :short :int :long-long)
     (let ((size (lane-bit-size element)))
       (if (logbitp (1- size) bits) (- bits (ash 1 size)) bits)))
    ((:uchar :ushort :uint :ulong-long) bits)))

;;; The carrier's 64 bits are handled as two 32-bit words, HIGH and LOW, so
;;; that every intermediate is a fixnum: a float in the top lane sets bit 62
;;; or 63, and one 64-bit integer holding it would be a bignum on every send.

(defun pack-vector (node value)
  "VALUE, a Lisp sequence, as what carries it across the FFI: the double whose
eight bytes are its lanes, or for a sixteen-byte vector the backend's own
carrier -- see %PACK-WIDE-VECTOR in the seam file."
  (if (= 8 (vector-byte-size node))
      (destructuring-bind (element count) (rest node)
        (unless (and (typep value 'sequence) (not (stringp value)) (= (length value) count))
          (error "Cannot pass ~S as a ~d-element SIMD vector of ~(~a~)." value count element))
        (case element
          ;; One lane the width of the carrier: the double is the value, and
          ;; a 64-bit integer lane has no fixnum form to keep.
          (:double (coerce (elt value 0) 'double-float))
          ((:long-long :ulong-long)
           (let ((bits (lane-bits element (elt value 0))))
             (%double-float-from-words (ldb (byte 32 32) bits) (ldb (byte 32 0) bits))))
          (t
           (let ((width (lane-bit-size element))
                 (low 0) (high 0) (i 0))
             (map nil (lambda (x)
                        (let ((position (* i width)))
                          (if (< position 32)
                              (setf low (dpb (lane-bits element x) (byte width position) low))
                              (setf high (dpb (lane-bits element x) (byte width (- position 32)) high))))
                        (incf i))
                  value)
             (%double-float-from-words high low)))))
      (%pack-wide-vector node value)))

(defun unpack-vector (node carrier)
  "The lanes packed in CARRIER, as a Lisp vector."
  (if (= 8 (vector-byte-size node))
      (destructuring-bind (element count) (rest node)
        (let ((carrier (coerce carrier 'double-float)))
          (case element
            (:double (vector carrier))
            ((:long-long :ulong-long)
             (multiple-value-bind (high low) (%double-float-words carrier)
               (vector (lane-value element (logior (ash high 32) low)))))
            (t
             (multiple-value-bind (high low) (%double-float-words carrier)
               (let ((width (lane-bit-size element))
                     (lanes (make-array count)))
                 (dotimes (i count lanes)
                   (let ((position (* i width)))
                     (setf (aref lanes i)
                           (lane-value element
                                       (if (< position 32)
                                           (ldb (byte width position) low)
                                           (ldb (byte width (- position 32)) high))))))))))))
      (%unpack-wide-vector node carrier)))

(defun pack-matrix (node value)
  "VALUE, a sequence of column sequences, as what carries a matrix across the
FFI: the seam decides -- a vector of column carriers where the columns go in
registers one by one, a buffer of the whole thing where C loads it by value."
  (destructuring-bind (element columns rows) (rest node)
    (declare (ignore element rows))
    (unless (and (typep value 'sequence) (not (stringp value)) (= (length value) columns))
      (error "Cannot pass ~S as a matrix of ~d columns." value columns))
    (%pack-matrix node value)))

(defun unpack-matrix (node carrier)
  "The columns in CARRIER, as a vector of column vectors."
  (%unpack-matrix node carrier))

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
               ;; Any other structure, from a sequence with one element per
               ;; field; see WRITE-STRUCT-FROM-SEQUENCE.
               ((struct-sequence-p value)
                (write-struct-from-sequence buffer node value))
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

      ;; A SIMD vector, as the double that occupies its bytes.
      ((vector-node-p node) (pack-vector node value))
      ;; A matrix, as its columns, each a vector.
      ((matrix-node-p node) (pack-matrix node value))

      ((consp node) (marshal-argument value (third node))) ; :qualified

      ;; Plain numbers.
      ((member node '(:float)) (coerce value 'single-float))
      ((member node '(:double)) (coerce value 'double-float))
      (t value))))
