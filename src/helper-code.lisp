;;;; src/helper-code.lisp -- the block copy and dispose helpers, as machine code.
;;;;
;;;; libclosure calls a block's copy helper when it first copies the block to
;;;; the heap, and its dispose helper when it frees the last copy.  Those two
;;;; calls are the only reason this library knows how long an escaped block's
;;;; closure must live.  They used to be Lisp callables, and the cost of that
;;;; is not the arithmetic: Cocoa runs them on whichever thread it happens to
;;;; be releasing on, usually a libdispatch worker, and a callable entered
;;;; from a thread the Lisp did not create has to adopt that thread first.
;;;; Measured (bench/RESULTS.md, the `worker:` rows): about 22 us an entry on
;;;; SBCL and 50 on ECL, paid twice for every block Cocoa copies and releases.
;;;;
;;;; Worse than slow, on a stock SBCL it is dangerous.  A collection stops the
;;;; world by signalling every other thread, Darwin refuses to signal a
;;;; libdispatch worker, and a worker inside Lisp is therefore a thread that
;;;; cannot be stopped -- so a dispose helper entering Lisp at a moment nobody
;;;; chose is the one remaining way for an ordinary program to die.  Every
;;;; other entry has a shape a caller can wait out (objc:wait-for-callbacks);
;;;; this one does not, because it happens after everything else is over.
;;;;
;;;; So the helpers here never enter Lisp.  Each is a handful of instructions
;;;; that loads a pointer out of the block literal and atomically adds one to
;;;; the word it points at.  The count lives outside the literal because
;;;; _Block_copy copies the literal: a field inside it would give every copy
;;;; its own count, and what has to be shared is one count per closure.  Lisp
;;;; reads that word later, at times it chooses, and reaps the records whose
;;;; count has reached zero (REAP-RELEASED-BLOCKS in blocks.lisp).
;;;;
;;;; The bytes below are what clang assembles from the source in the comment
;;;; beside them, and the offset of the cell pointer within the literal is
;;;; compiled into them.  MACHINE-CODE-BLOCK-HELPERS checks that offset
;;;; against the structure definition, and checks the code by running it, and
;;;; answers NIL rather than guessing if either is wrong.  Then blocks.lisp
;;;; falls back to the Lisp callables, which is also what happens where no
;;;; page can be made executable at all -- a hardened macOS binary without the
;;;; JIT entitlement refuses the mprotect, and says so.
;;;;
;;;; An iOS app is not asked.  There the mprotect succeeds and the first jump
;;;; into the page is a SIGKILL from code signing ("Invalid Page") -- in any
;;;; build without get-task-allow, which is to say every TestFlight and App
;;;; Store build and none of the development ones.  Nothing survives to answer
;;;; NIL, so a UIKit process takes the fallback without trying, simulator
;;;; included, so that what runs there is what runs on the phone.

(in-package #:objc)

(defconstant +helper-cell-offset+ 40
  "The offset of REFCOUNT-CELL in a block literal, as compiled into the code
below.  Checked against the structure rather than trusted.")

;;; The code -------------------------------------------------------------------
;;;
;;; arm64, assembled from:
;;;
;;;     ldr   x8, [x0, #40]      ; the cell pointer, out of the literal
;;;   1:ldaxr x9, [x8]
;;;     add   x9, x9, #1         ; sub, in the dispose helper
;;;     stlxr w10, x9, [x8]
;;;     cbnz  w10, 1b
;;;     ret
;;;
;;; Load-exclusive and store-exclusive rather than the one-instruction LDADDAL,
;;; because that instruction is ARMv8.1 and this loop is every ARMv8.  It costs
;;; nothing worth measuring: 3.6 ns a call against the 22 us it replaces.

(defparameter +arm64-copy-words+
  '(#xf9401408 #xc85ffd09 #x91000529 #xc80afd09 #x35ffffaa #xd65f03c0))

(defparameter +arm64-dispose-words+
  '(#xf9401408 #xc85ffd09 #xd1000529 #xc80afd09 #x35ffffaa #xd65f03c0))

;;; x86-64, assembled from:
;;;
;;;     movq  40(%rdi), %rax
;;;     lock incq (%rax)         ; decq, in the dispose helper
;;;     ret

(defparameter +x86-64-copy-bytes+
  '(#x48 #x8b #x47 #x28 #xf0 #x48 #xff #x00 #xc3))

(defparameter +x86-64-dispose-bytes+
  '(#x48 #x8b #x47 #x28 #xf0 #x48 #xff #x08 #xc3))

(defun helper-code-bytes (which)
  "The bytes of the copy or dispose helper for this architecture, or NIL where
none has been written.  WHICH is :COPY or :DISPOSE."
  (flet ((words-to-bytes (words)
           (loop for word in words
                 append (loop for shift in '(0 8 16 24)
                              collect (ldb (byte 8 shift) word)))))
    (cond ((member :arm64 *features*)
           (words-to-bytes (if (eq which :copy) +arm64-copy-words+ +arm64-dispose-words+)))
          ((member :x86-64 *features*)
           (if (eq which :copy) +x86-64-copy-bytes+ +x86-64-dispose-bytes+))
          (t nil))))

;;; Executable memory ----------------------------------------------------------

(defconstant +prot-read+ 1)
(defconstant +prot-write+ 2)
(defconstant +prot-exec+ 4)
(defconstant +map-private+ 2)
(defconstant +map-anon+ #x1000)

(defun map-executable-code (bytes)
  "Copy BYTES into a fresh page and return a pointer to it, executable, or NIL.

Writable first and executable afterwards, never both at once.  Two things this
deliberately does not do:

MAP_JIT with `pthread_jit_write_protect_np', which is the documented way to
hold a page both writable and executable on Apple silicon, must not be used
from inside a Lisp.  That flag is per thread and covers every MAP_JIT mapping
the thread can see, and SBCL maps its own dynamic space that way on this
platform and toggles the flag itself; setting it here makes SBCL's heap
read-only under it, and the next write to Lisp memory is a fatal fault in the
collector.  Measured, the first time this was written that way.

And it does not keep a pool.  There are exactly two of these in the process,
so a page apiece, allocated once, is the whole of the accounting."
  (let* ((length 4096)
         (page (cffi:foreign-funcall "mmap"
                                     :pointer (cffi:null-pointer)
                                     :unsigned-long length
                                     :int (logior +prot-read+ +prot-write+)
                                     :int (logior +map-private+ +map-anon+)
                                     :int -1 :int64 0
                                     :pointer)))
    ;; mmap answers MAP_FAILED, which is -1 rather than a null pointer.
    (when (or (cffi:null-pointer-p page)
              (eql (cffi:pointer-address page) (1- (ash 1 64))))
      (return-from map-executable-code nil))
    (loop for byte in bytes
          for index from 0
          do (setf (cffi:mem-aref page :uint8 index) byte))
    (unless (zerop (cffi:foreign-funcall "mprotect"
                                         :pointer page :unsigned-long length
                                         :int (logior +prot-read+ +prot-exec+)
                                         :int))
      ;; A hardened binary without the JIT entitlement refuses here, and an
      ;; iOS process refuses here always.  Give the page back and say so.
      (cffi:foreign-funcall "munmap" :pointer page :unsigned-long length :int)
      (return-from map-executable-code nil))
    ;; Written as data, about to be run as code.
    (when (member :arm64 *features*)
      (cffi:foreign-funcall "sys_icache_invalidate"
                            :pointer page :unsigned-long length :void))
    page))

;;; The pair, checked ----------------------------------------------------------

(defun %uikit-process-p ()
  "Whether this is an iOS-family app, where running a page we wrote is not
refused but fatal.  Asked of the runtime, not *FEATURES*: an iOS build is
cross-compiled, and the features at compile time are the Mac's."
  (not (cffi:null-pointer-p (%objc-get-class "UIApplication"))))

(defun %helpers-work-p (copy dispose)
  "Run COPY and DISPOSE against a literal made for the purpose and say whether
they counted.  The only honest test of a page of bytes this file believes it
assembled correctly: two increments and three decrements must leave the cell
where it started minus one."
  (let ((literal (cffi:foreign-alloc :uint8 :count (max 64 (1+ +helper-cell-offset+))
                                            :initial-element 0))
        (cell (cffi:foreign-alloc :uint64 :count 1)))
    (unwind-protect
         (progn
           (setf (cffi:mem-aref cell :uint64 0) 1)
           (setf (cffi:mem-ref literal :pointer +helper-cell-offset+) cell)
           (cffi:foreign-funcall-pointer copy () :pointer literal :pointer literal :void)
           (cffi:foreign-funcall-pointer copy () :pointer literal :pointer literal :void)
           (and (eql 3 (cffi:mem-aref cell :uint64 0))
                (progn
                  (dotimes (i 3)
                    (cffi:foreign-funcall-pointer dispose () :pointer literal :void))
                  (eql 0 (cffi:mem-aref cell :uint64 0)))))
      (cffi:foreign-free literal)
      (cffi:foreign-free cell))))

(defun machine-code-block-helpers ()
  "The copy and dispose helpers as machine code, as (VALUES COPY DISPOSE), or
NIL where they cannot be had -- no code written for this architecture, a
literal whose layout no longer matches the code, a platform that will not
make a page executable, or an iOS app, where it will and then kills the
process for running it.  The caller falls back to Lisp callables."
  (let ((copy-bytes (helper-code-bytes :copy))
        (dispose-bytes (helper-code-bytes :dispose)))
    (when (and (not (%uikit-process-p))
               copy-bytes
               dispose-bytes
               (eql +helper-cell-offset+
                    (cffi:foreign-slot-offset '(:struct block-literal) 'refcount-cell)))
      (let ((copy (map-executable-code copy-bytes))
            (dispose (map-executable-code dispose-bytes)))
        (when (and copy dispose (%helpers-work-p copy dispose))
          (values copy dispose))))))
