;;;; src/abi-neon.lisp -- a 128-bit SIMD vector through a callback, on arm64.
;;;;
;;;; SBCL's own callback wrapper -- the assembler stub that copies a C caller's
;;;; argument registers into a frame for ENTER-ALIEN-CALLBACK and loads the
;;;; result back into a register -- knows integers, floats and structs.  A
;;;; float it stores as the d register, eight bytes, and a 128-bit vector
;;;; arrives in the whole of v0-v7 and goes back in the whole of v0.  So this
;;;; is that wrapper, from SBCL 2.6.8's src/compiler/arm64/c-call.lisp, with
;;;; two branches added: a 128-bit float type is stored and loaded as a q
;;;; register with a sixteen-byte slot.  Nothing else in it is changed.
;;;;
;;;; It is installed as a dispatcher over SBCL's function, not in place of it:
;;;; a signature with no 128-bit type in it goes to SBCL's wrapper untouched,
;;;; so an ordinary callback is exactly what it was on every SBCL, and only a
;;;; callback that takes or returns a vector depends on this copy agreeing
;;;; with the runtime's callback_wrapper_trampoline about the frame -- which
;;;; is the contract SBCL's own copy relies on too.
;;;;
;;;; The 128-bit type itself is made in abi.lisp: SBCL's alien type classes
;;;; are a fixed table and ALIEN-TYPE is sealed, so a new class cannot be
;;;; added, and instead a second instance of the double-float type is marked
;;;; 128 bits wide and that class's methods dispatch on the width.  This file
;;;; recognises the mark the same way.
;;;;
;;;; SB-VM, because everything here is SB-VM's: the assembler, the register
;;;; TNs, the struct classifier.  The seam test lists this file by name.

(in-package :sb-vm)

;;; Build-time constants of c-call.lisp that the image does not keep.
(unless (boundp '+number-stack-alignment-mask+)
  (defconstant +number-stack-alignment-mask+ (1- (* n-word-bytes 2))))
(unless (boundp '+max-register-args+)
  (defconstant +max-register-args+ 8))

(defun objc-wide-alien-type-p (type)
  "The mark abi.lisp puts on its 128-bit vector type, and on the wider ones a
matrix result takes: 256, 384 or 512 bits, two to four registers."
  (and (alien-float-type-p type)
       (member (alien-type-bits type) '(128 256 384 512))
       t))

(defun objc-wide-callback-wrapper (index result-type argument-types)
  (labels ((make-tn (offset &optional (sc-name 'any-reg))
             (make-random-tn (sc-or-lose sc-name) offset))
           (argument-byte-size (type)
             "Return the number of bytes this argument occupies in the callback vector."
             (ceiling (sb-alien::alien-type-bits type) n-byte-bits))
           (round-up-to-word (bytes)
             (* n-word-bytes (ceiling bytes n-word-bytes))))
    ;; Check for struct return type and classify it
    (let* ((result-classification
             (when (alien-record-type-p result-type)
               (classify-struct result-type)))
           (large-struct-return-p
             (and result-classification
                  (sb-alien::struct-classification-memory-p result-classification))))
      ;; Calculate frame size: sum of all argument sizes
      (let* ((segment (make-segment))
             ;; Current byte offset in the argument frame
             (frame-offset 0)
             ;; How many bytes have been read from the stack argument area
             (stack-argument-bytes 0)
             (r0-tn (make-tn 0))
             (r1-tn (make-tn 1))
             (r2-tn (make-tn 2))
             (r3-tn (make-tn 3))
             (temp-tn (make-tn 9))
             (nsp-save-tn (make-tn 10))
             ;; x8 is used for large struct return pointer
             (x8-tn (make-tn 8))
             ;; x12 used to save x8 across the call (x11 is used for ptr-tn in struct arg processing)
             (x8-save-tn (make-tn 12))
             (gprs (loop for i below 8
                         collect (make-tn i)))
             (fp-registers 0)
             ;; Calculate frame size from argument types (word-aligned)
             (frame-size (loop for type in argument-types
                               sum (round-up-to-word (argument-byte-size type))))
             ;; Return value slot count - enough for large struct if needed
             (return-slot-count
               (cond (large-struct-return-p
                      (ceiling (sb-alien::struct-classification-size result-classification) n-word-bytes))
                     ;; objc: a wide result is as many words as its registers hold.
                     ((objc-wide-alien-type-p result-type)
                      (/ (alien-type-bits result-type) n-word-bits))
                     (t 2))))
      (setf frame-size (logandc2 (+ frame-size +number-stack-alignment-mask+)
                                 +number-stack-alignment-mask+))
      ;; Return value allocation size - must be 16-byte aligned for stack alignment
      (let ((return-bytes (logandc2 (+ (* n-word-bytes return-slot-count) 15) 15)))
      (assemble (segment 'nil)
        (inst mov-sp nsp-save-tn nsp-tn)
        (inst str lr-tn (@ nsp-tn -16 :pre-index))
        ;; Save x8 (hidden struct return pointer) to stack if returning large struct
        ;; We save to stack because x8-15 are caller-saved and would be clobbered by the call
        ;; After the str above, nsp points to saved LR, and [nsp+8] is free space
        (when large-struct-return-p
          (inst str x8-tn (@ nsp-tn 8)))
        ;; Make room on the stack for arguments.
        (when (plusp frame-size)
          (inst sub nsp-tn nsp-tn frame-size))
        ;; Copy arguments
        (dolist (type argument-types)
          (let ((target-tn (@ nsp-tn frame-offset))
                (size #+darwin (truncate (sb-alien::alien-type-bits type) n-byte-bits)
                      #-darwin n-word-bytes))
            (cond ((or (alien-integer-type-p type)
                       (alien-pointer-type-p type)
                       (alien-type-= #.(parse-alien-type 'system-area-pointer nil)
                                     type))
                   (let ((gpr (pop gprs)))
                     (cond (gpr
                            (inst str gpr target-tn))
                           (t
                            (setf stack-argument-bytes
                                  (align-up stack-argument-bytes size))
                            (let ((addr (@ nsp-save-tn stack-argument-bytes)))
                              (cond #+darwin
                                    ((/= size 8)
                                     (let ((signed (and (alien-integer-type-p type)
                                                        (alien-integer-type-signed type))))
                                       (ecase size
                                         (1
                                          (if signed
                                              (inst ldrsb temp-tn addr)
                                              (inst ldrb temp-tn addr)))
                                         (2
                                          (if signed
                                              (inst ldrsh temp-tn addr)
                                              (inst ldrh temp-tn addr)))
                                         (4
                                          (if signed
                                              (inst ldrsw temp-tn addr)
                                              (inst ldr (32-bit-reg temp-tn) addr))))))
                                    (t
                                     (inst ldr temp-tn addr)))
                              (inst str temp-tn target-tn))
                            (incf stack-argument-bytes size))))
                   (incf frame-offset n-word-bytes))
                  ;; objc: a 128-bit SIMD vector, marked as a 128-bit float
                  ;; type.  It arrives in a full v register, so the whole
                  ;; register is stored, and its frame slot is sixteen bytes.
                  ((and (objc-wide-alien-type-p type) (eql (alien-type-bits type) 128))
                   (cond ((< fp-registers 8)
                          (inst str (make-tn fp-registers 'int-neon-reg) target-tn))
                         (t
                          (setf stack-argument-bytes (align-up stack-argument-bytes 16))
                          (inst ldr temp-tn (@ nsp-save-tn stack-argument-bytes))
                          (inst str temp-tn target-tn)
                          (inst ldr temp-tn (@ nsp-save-tn (+ stack-argument-bytes 8)))
                          (inst str temp-tn (@ nsp-tn (+ frame-offset 8)))
                          (incf stack-argument-bytes 16)))
                   (incf fp-registers)
                   (incf frame-offset 16))
                  ((alien-float-type-p type)
                   (cond ((< fp-registers 8)
                          (inst str (make-tn fp-registers
                                             (if (alien-single-float-type-p type)
                                                 'single-reg
                                                 'double-reg))
                                target-tn))
                         (t
                          (setf stack-argument-bytes
                                (align-up stack-argument-bytes size))
                          (case size
                            #+darwin
                            (4
                             (let ((reg (32-bit-reg temp-tn)))
                               (inst ldr reg (@ nsp-save-tn stack-argument-bytes))
                               (inst str reg target-tn)))
                            (t
                             (inst ldr temp-tn (@ nsp-save-tn stack-argument-bytes))
                             (inst str temp-tn target-tn)))
                          (incf stack-argument-bytes size)))
                   (incf fp-registers)
                   (incf frame-offset n-word-bytes))
                  ;; Handle struct-by-value arguments
                  ((sb-alien::alien-record-type-p type)
                   (let* ((struct-bytes (argument-byte-size type))
                          (struct-bytes-aligned (round-up-to-word struct-bytes))
                          (classification (classify-struct type))
                          ;; Use r11 as additional temp for struct pointer
                          (ptr-tn (make-tn 11)))
                     (cond
                       ;; Large struct (>16 bytes): passed by pointer in register
                       ((sb-alien::struct-classification-memory-p classification)
                        ;; The struct pointer is in a GPR; copy struct data to frame
                        (let ((gpr (pop gprs)))
                          (cond (gpr
                                 ;; Move pointer from argument register to ptr-tn
                                 (inst mov ptr-tn gpr))
                                (t
                                 ;; Pointer is on stack
                                 (setf stack-argument-bytes (align-up stack-argument-bytes 8))
                                 (inst ldr ptr-tn (@ nsp-save-tn stack-argument-bytes))
                                 (incf stack-argument-bytes 8)))
                          ;; Copy struct data from pointer to frame
                          ;; Use temp-tn (r9) for copying, ptr-tn (r11) has source address
                          (loop for off from 0 below struct-bytes by 8
                                for remaining = (- struct-bytes off)
                                do (cond ((>= remaining 8)
                                          (inst ldr temp-tn (@ ptr-tn off))
                                          (inst str temp-tn (@ nsp-tn (+ frame-offset off))))
                                         (t
                                          (when (>= remaining 4)
                                            (inst ldr (32-bit-reg temp-tn) (@ ptr-tn off))
                                            (inst str (32-bit-reg temp-tn) (@ nsp-tn (+ frame-offset off)))
                                            (decf remaining 4)
                                            (incf off 4))
                                          ;; Copy remaining bytes one by one
                                          (loop for b from 0 below remaining
                                                do (inst ldrb (32-bit-reg temp-tn) (@ ptr-tn (+ off b)))
                                                   (inst strb (32-bit-reg temp-tn) (@ nsp-tn (+ frame-offset off b))))
                                          (return))))))
                       ;; HFA: passed in floating-point registers
                       ((multiple-value-bind (hfa-type hfa-count) (hfa-base-type type)
                          (when hfa-type
                            (let ((fp-size (if (eq hfa-type 'single-float) 4 8)))
                              (cond ((<= (+ fp-registers hfa-count) 8)
                                     (dotimes (i hfa-count)
                                       (inst str (make-tn fp-registers
                                                          (if (eq hfa-type 'single-float)
                                                              'single-reg
                                                              'double-reg))
                                             (@ nsp-tn (+ frame-offset (* i fp-size))))
                                       (incf fp-registers)))
                                    (t
                                     (setf fp-registers 8)
                                     (setf stack-argument-bytes (align-up stack-argument-bytes 8))
                                     (loop for off below struct-bytes by 8
                                           for remaining = (- struct-bytes off)
                                           do (cond ((>= remaining 8)
                                                     (inst ldr temp-tn (@ nsp-save-tn (+ stack-argument-bytes off)))
                                                     (inst str temp-tn (@ nsp-tn (+ frame-offset off))))
                                                    (t
                                                     (inst ldr (32-bit-reg temp-tn) (@ nsp-save-tn (+ stack-argument-bytes off)))
                                                     (inst str (32-bit-reg temp-tn) (@ nsp-tn (+ frame-offset off))))))
                                     (incf stack-argument-bytes (align-up struct-bytes 8)))))
                            t)))
                       ;; Small non-HFA struct (<=16 bytes): passed in GPRs
                       (t
                        (let ((num-regs (ceiling struct-bytes 8)))
                          ;; Don't mix stack/registers
                          (when (< (length gprs) num-regs)
                            (setf gprs nil))
                          (dotimes (i num-regs)
                            (let ((gpr (pop gprs)))
                              (cond (gpr
                                     (inst str gpr (@ nsp-tn (+ frame-offset (* i 8)))))
                                    (t
                                     (setf stack-argument-bytes (align-up stack-argument-bytes 8))
                                     (inst ldr temp-tn (@ nsp-save-tn stack-argument-bytes))
                                     (inst str temp-tn (@ nsp-tn (+ frame-offset (* i 8))))
                                     (incf stack-argument-bytes 8))))))))
                     ;; Use word-aligned size for frame offset to match Lisp side
                     (incf frame-offset struct-bytes-aligned)))
                  (t
                   (bug "Unknown alien type: ~S" type)))))
        ;; arg0 to ENTER-ALIEN-CALLBACK (trampoline index)
        (inst mov r0-tn (fixnumize index))
        ;; arg1 to ENTER-ALIEN-CALLBACK (pointer to argument vector)
        (inst mov-sp r1-tn nsp-tn)
        ;; add room on stack for return value
        (inst sub nsp-tn nsp-tn return-bytes)
        ;; arg2 to ENTER-ALIEN-CALLBACK (pointer to return value)
        (inst mov-sp r2-tn nsp-tn)

        ;; Call
        (load-immediate-word r3-tn (sb-sys:find-foreign-symbol-address "callback_wrapper_trampoline"))
        (inst blr r3-tn)

        ;; Result now on top of stack, put it in the right register
        (cond
          ((or (alien-integer-type-p result-type)
               (alien-pointer-type-p result-type)
               (alien-type-= #.(parse-alien-type 'system-area-pointer nil)
                             result-type))
           (loadw r0-tn nsp-tn))
          ;; objc: a 128-bit SIMD vector result comes back in the whole of v0;
          ;; a matrix result, one register per column, in v0 onwards.
          ((objc-wide-alien-type-p result-type)
           (dotimes (i (/ (alien-type-bits result-type) 128))
             (inst ldr (make-tn i 'int-neon-reg) (@ nsp-tn (* 16 i)))))
          ((alien-float-type-p result-type)
           (loadw (make-tn 0
                           (if (alien-single-float-type-p result-type)
                               'single-reg
                               'double-reg))
                 nsp-tn))
          ((alien-void-type-p result-type))
          ;; Struct return types
          ((alien-record-type-p result-type)
           (cond
             ;; Large struct: copy result to x8 pointer location, return pointer in x0
             (large-struct-return-p
              (let ((struct-size (sb-alien::struct-classification-size result-classification))
                    ;; x8 was saved at [original - 8]
                    ;; After call: nsp = original - 16 - frame-size - return-bytes
                    ;; So x8 is at [nsp + 8 + frame-size + return-bytes]
                    (x8-offset (+ 8 frame-size return-bytes)))
                ;; Load saved x8 from stack into x8-save-tn (x12)
                ;; We can't use nsp-save-tn as it may have been clobbered by the call
                (inst ldr x8-save-tn (@ nsp-tn x8-offset))
                (loop for off from 0 below struct-size by 8
                      for remaining = (- struct-size off)
                      do (cond ((>= remaining 8)
                                (inst ldr temp-tn (@ nsp-tn off))
                                (inst str temp-tn (@ x8-save-tn off)))
                               (t
                                (when (>= remaining 4)
                                  (inst ldr (32-bit-reg temp-tn) (@ nsp-tn off))
                                  (inst str (32-bit-reg temp-tn) (@ x8-save-tn off))
                                  (decf remaining 4)
                                  (incf off 4))
                                (loop for b from 0 below remaining
                                      do (inst ldrb (32-bit-reg temp-tn) (@ nsp-tn (+ off b)))
                                         (inst strb (32-bit-reg temp-tn) (@ x8-save-tn (+ off b))))
                                (return))))
                ;; Return the pointer in x0
                (inst mov r0-tn x8-save-tn)))
             ;; HFA: load into floating-point registers
             ((multiple-value-bind (hfa-type hfa-count) (hfa-base-type result-type)
                (when hfa-type
                  (let ((fp-size (if (eq hfa-type 'single-float) 4 8))
                        (sc-name (if (eq hfa-type 'single-float) 'single-reg 'double-reg)))
                    (dotimes (i hfa-count)
                      (inst ldr (make-tn i sc-name) (@ nsp-tn (* i fp-size)))))
                  t)))
             ;; Small non-HFA struct (<=16 bytes): load into x0/x1
             (t
              (let* ((struct-size (sb-alien::struct-classification-size result-classification))
                     (num-regs (ceiling struct-size 8)))
                (when (>= num-regs 1)
                  (inst ldr r0-tn (@ nsp-tn 0)))
                (when (>= num-regs 2)
                  (inst ldr r1-tn (@ nsp-tn 8)))))))
          (t
           (error "Unrecognized alien type: ~A" result-type)))
        (inst add nsp-tn nsp-tn (+ frame-size return-bytes))
        (inst ldr lr-tn (@ nsp-tn 16 :post-index))
        (inst ret))
      (finalize-segment segment)
      ;; Now that the segment is done, convert it to a static
      ;; vector we can point foreign code to.
      (let* ((buffer (sb-assem:segment-buffer segment))
             (vector (if (fboundp 'make-static-code-vector)
                         (funcall 'make-static-code-vector (length buffer) buffer)
                         (make-static-vector (length buffer)
                                             :element-type '(unsigned-byte 8)
                                             :initial-contents buffer)))
             (sap (vector-sap vector)))
        (alien-funcall
         (extern-alien "os_flush_icache"
                       (function void
                                 system-area-pointer
                                 unsigned-long))
         sap (length buffer))
        vector))))))


(defvar *sbcl-callback-wrapper*
  (fdefinition 'sb-alien-internals:alien-callback-assembler-wrapper)
  "SBCL's own wrapper, kept: every signature without a vector goes to it.")

(sb-ext:without-package-locks
  (defun sb-alien-internals:alien-callback-assembler-wrapper (index result-type argument-types)
    (if (or (objc-wide-alien-type-p result-type)
            (some #'objc-wide-alien-type-p argument-types))
        (objc-wide-callback-wrapper index result-type argument-types)
        (funcall *sbcl-callback-wrapper* index result-type argument-types))))
