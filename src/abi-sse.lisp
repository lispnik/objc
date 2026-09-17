;;;; src/abi-sse.lisp -- the SBCL seam's x86-64 annex: a callback wrapper that
;;;; knows a 128-bit vector.
;;;;
;;;; SBCL's alien callback wrapper stores every floating-point argument as a
;;;; double -- MOVQ, sixty-four bits -- and loads a floating-point result the
;;;; same way.  A float4 arrives in the whole of an XMM register and a float4
;;;; result leaves in the whole of xmm0, so a method or block taking one needs
;;;; a wrapper that moves all sixteen bytes.  This is SBCL 2.6.8's x86-64
;;;; ALIEN-CALLBACK-ASSEMBLER-WRAPPER (src/compiler/x86-64/c-call.lisp) with
;;;; two branches added, marked "objc:", and it is installed as a dispatcher
;;;; over SBCL's own: a signature with no vector in it goes to SBCL's wrapper
;;;; unchanged.  The arm64 annex, abi-neon.lisp, is the same idea for NEON.
;;;; The wrapper's own size helper reads the type's bits, so the marked type
;;;; already occupies sixteen bytes of the argument vector.
;;;;
;;;; A matrix does not come here: on x86-64 it is a record of its padded
;;;; columns, which SBCL's own struct classification handles as memory.
;;;;
;;;; In SB-VM, because it is assembler.  Loaded on x86-64 Darwin only.

(in-package :sb-vm)

(defun objc-wide-alien-type-p (type)
  "The mark abi.lisp puts on its 128-bit vector type."
  (and (alien-float-type-p type)
       (= 128 (alien-type-bits type))))

(defun objc-wide-callback-wrapper (index result-type argument-types)
  ;; Windows x64 struct-by-value callback rules:
  ;;   1. Struct arguments >8 bytes: caller passes pointer in register
  ;;   2. Struct arguments <=8 bytes: passed in integer register as value
  ;;   3. Struct returns >8 bytes: hidden pointer in RCX (first arg register)
  ;;   4. Struct returns <=8 bytes: returned in RAX
  (labels ((make-tn (sc-name offset)
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
                  (sb-alien::struct-classification-memory-p result-classification)))
           (segment (make-segment))
           (rax rax-tn)
           #+win32 (rcx rcx-tn)
           #-(and win32 sb-thread) (rdi rdi-tn)
           #-(and win32 sb-thread) (rsi rsi-tn)
           (rdx rdx-tn)
           (rbp rbp-tn)
           (rsp rsp-tn)
           #+(and win32 sb-thread) (r8 r8-tn)
           #+win32 (r11 r11-tn)  ; scratch register for struct copy (not an arg register)
           (xmm0 (make-tn 'double-reg 0))
           #-win32
           (xmm1 (make-tn 'double-reg 1))
           ([rsp] (ea rsp))
           ;; Calculate total argument vector size in bytes
           (total-arg-bytes
             (loop for type in argument-types
                   sum (round-up-to-word (argument-byte-size type))))
           ;; How many arguments have been copied from the C stack
           (stack-argument-count #-win32 0 #+win32 4)
           ;; Byte offset into argument vector
           (arg-offset 0)
           ;; Count of 8-byte slots consumed (for stack offset calculation)
           (arg-slot-count (ceiling total-arg-bytes n-word-bytes))
           ;; For large struct returns, the hidden pointer is in the first arg register
           ;; (RCX on Windows, RDI on SysV). Skip it in the GPR list.
           ;; On Windows, this also consumes argument slot 0, so skip XMM0 too.
           (gprs (let ((all-gprs (mapcar (lambda (offset)
                                           (make-tn 'any-reg offset))
                                         *c-call-register-arg-offsets*)))
                   (if large-struct-return-p
                       (rest all-gprs)  ; Skip RCX (win32) or RDI (SysV)
                       all-gprs)))
           (fprs (let ((all-fprs ;; Only 8 first XMM registers are used for
                         ;; passing arguments
                         (loop for i to (+ 7 #+win32 -4)
                               collect (make-tn 'double-reg i))))
                   ;; On Windows, when there's a hidden return pointer in RCX (slot 0),
                   ;; the float arguments shift: XMM0 is "consumed" by slot 0, so
                   ;; actual float args start at XMM1.
                   #+win32
                   (if large-struct-return-p
                       (rest all-fprs)
                       all-fprs)
                   #-win32
                   all-fprs))
           ;; Calculate return value slot count (in 8-byte words)
           ;; For large struct returns, we need enough space for the entire struct
           ;; For small structs and primitives, 2 slots (16 bytes) is enough
           (return-slot-count
             (if large-struct-return-p
                 (ceiling (sb-alien::struct-classification-size result-classification) n-word-bytes)
                 2))
           ;; Adjust for alignment (must be even for 16-byte stack alignment)
           (return-slot-count-aligned
             (if (evenp (+ arg-slot-count return-slot-count
                           (if large-struct-return-p
                               1 ;; hidden pointer register saved on the stack
                               0)))
                 return-slot-count
                 (1+ return-slot-count))))
      (symbol-macrolet ((stack-args-offset (* (+ 1 arg-slot-count stack-argument-count
                                                 (if large-struct-return-p 1 0))
                                              n-word-bytes)))
        (assemble (segment 'nil)
          ;; For large struct returns, save the hidden pointer before using it
          ;; Windows: RCX (first arg register), SysV: RDI (first arg register)
          (when large-struct-return-p
            #+win32 (inst push rcx)
            #-win32 (inst push rdi))
          ;; Make room on the stack for argument vector.
          (when (plusp total-arg-bytes)
            (inst sub rsp total-arg-bytes))
          ;; Copy arguments from registers/stack to argument vector
          (dolist (type argument-types)
            (let* ((arg-size (round-up-to-word (argument-byte-size type)))
                   ;; A TN pointing to the stack location where the
                   ;; current argument should be stored for the purposes
                   ;; of ENTER-ALIEN-CALLBACK.
                   (target-tn (ea arg-offset rsp))
                   ;; Offset to C stack args (past return address and our arg vector)
                   (stack-arg-tn (ea stack-args-offset rsp)))
              (cond
                ;; Struct types
                ((sb-alien::alien-record-type-p type)
                 (let* ((classification (classify-struct type))
                        (memory-p (sb-alien::struct-classification-memory-p classification))
                        (struct-size (sb-alien::struct-classification-size classification))
                        (slots (sb-alien::struct-classification-register-slots classification))
                        (n-int (count :integer slots))
                        (n-fp (count :double slots))
                        ;; Don't mix stack/registers
                        (use-registers (and (<= n-int (length gprs))
                                            (<= n-fp (length fprs)))))
                   #+win32
                   (cond
                     ;; Large struct: pointer passed in register
                     (memory-p
                      (let ((gpr (pop gprs)))
                        (pop fprs)  ; Windows: consume paired FPR slot
                        (unless gpr
                          (incf stack-argument-count)
                          (setf gpr rax)
                          (inst mov gpr stack-arg-tn))
                        ;; gpr now contains pointer to struct; copy struct data to arg vector
                        ;; Use r11 as scratch (not an arg register) to avoid clobbering other args
                        (let ((num-words (ceiling struct-size n-word-bytes)))
                          (loop for i from 0 below num-words
                                for dst-off from arg-offset by n-word-bytes
                                do (inst mov r11 (ea (* i n-word-bytes) gpr))
                                   (inst mov (ea dst-off rsp) r11)))))
                     ;; Small struct: single integer register
                     (t
                      (let ((gpr (and use-registers
                                      (pop gprs))))
                        (cond (gpr
                               (pop fprs))
                              (t
                               (incf stack-argument-count)
                               (setf gpr rax)
                               (inst mov gpr stack-arg-tn)))
                        (inst mov (ea arg-offset rsp) gpr))))
                   #-win32
                   (cond
                     ;; Large struct (MEMORY class): passed directly on the C stack
                     ;; The caller copies the struct to its stack frame
                     (memory-p
                      (let ((num-words (ceiling struct-size n-word-bytes)))
                        ;; Copy struct data from C stack to our argument vector
                        (loop for i from 0 below num-words
                              for src-off = (+ stack-args-offset (* i n-word-bytes))
                              for dst-off from arg-offset by n-word-bytes
                              do (inst mov rax (ea src-off rsp))
                                 (inst mov (ea dst-off rsp) rax))
                        ;; Account for the stack slots consumed
                        (incf stack-argument-count num-words)))
                     ;; Small struct: passed in up to 2 registers per eightbyte
                     (t
                      (loop for class in slots
                            for slot-offset from arg-offset by n-word-bytes
                            do (ecase class
                                 (:integer
                                  (let ((gpr (and use-registers
                                                  (pop gprs))))
                                    (unless gpr
                                      (incf stack-argument-count)
                                      (setf gpr rax)
                                      (inst mov gpr (ea (- stack-args-offset n-word-bytes) rsp)))
                                    (inst mov (ea slot-offset rsp) gpr)))
                                 (:double
                                  (let ((fpr (and use-registers
                                                  (pop fprs))))
                                    (cond (fpr
                                           (inst movq (ea slot-offset rsp) fpr))
                                          (t
                                           (incf stack-argument-count)
                                           (inst mov rax (ea (- stack-args-offset n-word-bytes) rsp))
                                           (inst mov (ea slot-offset rsp) rax)))))))))))

                ;; Integer/pointer types
                ;; objc: a 128-bit SIMD vector arrives in the whole of an XMM
                ;; register, or as sixteen bytes on the C stack past the eight.
                ((objc-wide-alien-type-p type)
                 (let ((fpr (pop fprs)))
                   (cond (fpr
                          (inst movups target-tn fpr))
                         (t
                          (inst mov rax stack-arg-tn)
                          (inst mov target-tn rax)
                          (incf stack-argument-count)
                          (inst mov rax (ea stack-args-offset rsp))
                          (inst mov (ea (+ arg-offset n-word-bytes) rsp) rax)
                          (incf stack-argument-count)))))

                ((not (alien-float-type-p type))
                 (let ((gpr (pop gprs)))
                   #+win32 (pop fprs)
                   ;; Argument not in register, copy it from the old
                   ;; stack location to a temporary register.
                   (unless gpr
                     (incf stack-argument-count)
                     (setf gpr rax)
                     (inst mov gpr stack-arg-tn))
                   ;; Copy from either argument register or temporary
                   ;; register to target.
                   (inst mov target-tn gpr)))

                ;; Float types
                ((or (alien-single-float-type-p type)
                     (alien-double-float-type-p type))
                 (let ((fpr (pop fprs)))
                   #+win32 (pop gprs)
                   (cond (fpr
                          ;; Copy from float register to target location.
                          (inst movq target-tn fpr))
                         (t
                          ;; Not in float register. Copy from stack to
                          ;; temporary (general purpose) register, and
                          ;; from there to the target location.
                          (incf stack-argument-count)
                          (inst mov rax stack-arg-tn)
                          (inst mov target-tn rax)))))

                (t
                 (bug "Unknown alien callback argument type: ~S" type)))
              ;; Advance to next argument slot
              (incf arg-offset arg-size)))

          (macrolet
              ((call-wrapper ()
                 ;; Technically this fixup should have an optional arg of
                 ;;  (- (ASH SYMBOL-VALUE-SLOT WORD-SHIFT) OTHER-POINTER-LOWTAG)
                 ;; but as the fixup is hand-crafted anyway, it doesn't matter.
                 `(inst call (rip-relative-ea
                              (make-fixup 'callback-wrapper-trampoline
                                          :immobile-symbol))))) ; arbitraryish flavor
            #-sb-thread
            (progn
              ;; arg0 to ENTER-ALIEN-CALLBACK (trampoline index)
              (inst mov rdi (fixnumize index))
              ;; arg1 to ENTER-ALIEN-CALLBACK (pointer to argument vector)
              (inst mov rsi rsp)
              ;; add room on stack for return value
              (inst sub rsp (* return-slot-count-aligned n-word-bytes))
              ;; arg2 to ENTER-ALIEN-CALLBACK (pointer to return value)
              (inst mov rdx rsp)

              ;; Make new frame
              (inst push rbp)
              (inst mov  rbp rsp)

              ;; Call
              (call-wrapper)

              ;; Back! Restore frame
              (inst leave))

            #+sb-thread
            (progn
              ;; arg0 to ENTER-ALIEN-CALLBACK (trampoline index)
              (inst mov #-win32 rdi #+win32 rcx (fixnumize index))
              ;; arg1 to ENTER-ALIEN-CALLBACK (pointer to argument vector)
              (inst mov #-win32 rsi #+win32 rdx rsp)
              ;; add room on stack for return value
              (inst sub rsp (* return-slot-count-aligned n-word-bytes))
              ;; arg2 to ENTER-ALIEN-CALLBACK (pointer to return value)
              (inst mov #-win32 rdx #+win32 r8 rsp)
              ;; Make new frame
              (inst push rbp)
              (inst mov  rbp rsp)
              #+win32 (inst sub rsp #x20)
              #+win32 (inst and rsp #x-20)
              ;; Call
              (call-wrapper)

              ;; Back! Restore frame
              (inst leave)))

          ;; Result now on top of stack, put it in the right register
          (cond
            ((or (alien-integer-type-p result-type)
                 (alien-pointer-type-p result-type)
                 (alien-type-= #.(parse-alien-type 'system-area-pointer nil)
                               result-type))
             (inst mov rax [rsp]))
            ;; objc: a 128-bit SIMD vector result leaves in the whole of xmm0.
            ((objc-wide-alien-type-p result-type)
             (inst movups xmm0 [rsp]))
            ((or (alien-single-float-type-p result-type)
                 (alien-double-float-type-p result-type))
             (inst movq xmm0 [rsp]))
            ((alien-void-type-p result-type))
            ;; Struct return types
            ((alien-record-type-p result-type)
             #+win32
             ;; Windows: large structs via hidden pointer (from RCX), small structs in RAX
             (cond
               ;; Large struct: copy result to hidden pointer location, return pointer
               (large-struct-return-p
                (let ((struct-size (sb-alien::struct-classification-size result-classification)))
                  ;; Retrieve saved hidden pointer (was pushed at start from RCX)
                  (inst mov rax (ea (* (+ arg-slot-count return-slot-count-aligned) n-word-bytes) rsp))
                  ;; Copy struct data from stack to hidden pointer destination
                  (emit-sret-copy struct-size rsp rax rdx)))
               ;; Small struct (<=8 bytes): just load into RAX
               (t
                (inst mov rax [rsp])))
             #-win32
             ;; SysV: large structs via hidden pointer (from RDI), small structs in RAX/RDX/XMM0/XMM1
             (cond
               (large-struct-return-p
                (let ((struct-size (sb-alien::struct-classification-size result-classification)))
                  (inst mov rax (ea (* (+ arg-slot-count return-slot-count-aligned) n-word-bytes) rsp))
                  (emit-sret-copy struct-size rsp rax rdx)))
               ;; Small struct: copy to registers based on classification
               (t
                (let ((slots (sb-alien::struct-classification-register-slots result-classification))
                      (int-reg-idx 0)
                      (sse-reg-idx 0))
                  (loop for slot in slots
                        for offset from 0 by 8
                        do (ecase slot
                             (:integer
                              (let ((target (case int-reg-idx
                                              (0 rax)
                                              (1 rdx))))
                                (inst mov target (ea offset rsp)))
                              (incf int-reg-idx))
                             (:double
                              (let ((target (case sse-reg-idx
                                              (0 xmm0)
                                              (1 xmm1))))
                                (inst movq target (ea offset rsp)))
                              (incf sse-reg-idx))))))))
            (t
             (error "Unrecognized alien type: ~A" result-type)))

          ;; Pop the arguments and the return value from the stack to get
          ;; the return address at top of stack.

          (inst add rsp (* (+ arg-slot-count return-slot-count-aligned
                              (if large-struct-return-p
                                  1
                                  0))
                           n-word-bytes))
          ;; Return
          (inst ret)))
      (finalize-segment segment)
      ;; Now that the segment is done, convert it to a static
      ;; vector we can point foreign code to.
      (let* ((buffer (sb-assem:segment-buffer segment))
             (result (make-static-vector (length buffer)
                                         :element-type '(unsigned-byte 8)
                                         :initial-contents buffer)))
        ;; This is an ad-hoc substitute for the general fixup logic, due to
        ;; absence of a code component. Even the machine-dependent part is not
        ;; useful since it wants to call CODE-INSTRUCTIONS.
        (let* ((notes (sb-assem::segment-fixup-notes segment))
               (note (car notes)))
          (when note
            (aver (eq (fixup-note-kind note) :rel32))
            ;; +4 is because RIP-relative EA is relative to following instruction
            (let* ((pc (sap+ (vector-sap result) (+ (fixup-note-position note) 4)))
                   (fixup (fixup-note-fixup note))
                   (ea (+ nil-value (ea-disp (static-symbol-value-ea (fixup-name fixup)))))
                   (disp (sap- (int-sap ea) pc)))
              (setf (signed-sap-ref-32  (vector-sap result) (fixup-note-position note))
                    disp))))
        result))))

(defvar *sbcl-callback-wrapper*
  (fdefinition 'sb-alien-internals:alien-callback-assembler-wrapper)
  "SBCL's own wrapper, kept: every signature without a vector goes to it.")

(sb-ext:without-package-locks
  (defun sb-alien-internals:alien-callback-assembler-wrapper (index result-type argument-types)
    (if (or (objc-wide-alien-type-p result-type)
            (some #'objc-wide-alien-type-p argument-types))
        (objc-wide-callback-wrapper index result-type argument-types)
        (funcall *sbcl-callback-wrapper* index result-type argument-types))))
