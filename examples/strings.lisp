;;;; examples/strings.lisp -- NSString, and the two ways it disagrees with Lisp.
;;;;
;;;; Strings cross the bridge constantly and mostly invisibly: INVOKE takes a
;;;; Lisp string wherever an NSString is wanted and hands one back as a Lisp
;;;; string.  This file is about the two places that stops being true, both of
;;;; which fail quietly.
;;;;
;;;; A FAILED SEARCH RETURNS NSNotFound, WHICH IS NOT -1.  It is NSIntegerMax,
;;;; 9223372036854775807, and it arrives as the location of a range whose length
;;;; is zero.  Test it with COCOA:NS-NOT-FOUND.  Test it with MINUSP and you have
;;;; a program that indexes a string at nine quintillion -- and because the
;;;; length is 0, a (subseq s location (+ location length)) is not even out of
;;;; bounds by an obvious amount.
;;;;
;;;; AN NSString COUNTS UTF-16 CODE UNITS, AND A LISP STRING COUNTS CHARACTERS.
;;;; They agree until a character outside the basic plane appears, and then they
;;;; do not, silently and by exactly one per such character.  Measured:
;;;;
;;;;   "a<emoji>b tail and more"   Lisp LENGTH 17, -length 18
;;;;   -rangeOfString: "tail"      location 5
;;;;   POSITION of "tail"          4
;;;;   (subseq lisp 5 9)           "ail " -- no error, wrong answer
;;;;
;;;; That is the whole hazard: an NSRange is an offset into a string Lisp is not
;;;; holding.  The rule is to keep ranges on the Cocoa side --
;;;; -substringWithRange: is right because Cocoa is being consistent with itself
;;;; -- and to search Lisp strings with Lisp functions.  Mixing the two is fine
;;;; for as long as nobody types an emoji.
;;;;
;;;; STRING-TO-NS-STRING is here because it is exported and had no example.  It
;;;; is rarely what you want: INVOKE converts a Lisp string argument for you, and
;;;; the explicit call matters only when you need the OBJECT -- to keep, to put
;;;; in a collection, or to send a message to.
;;;;
;;;; And OBJC-C-STRING, the type descriptor for char *.  You will not often
;;;; write it either: -UTF8String is declared as char * in the runtime, so the
;;;; conversion happens without being asked.  It is needed when you are the one
;;;; declaring the signature -- a Lisp method returning a C string, or INVOKE's
;;;; list form when you want to override what the runtime says.

(in-package #:objc/examples)

;;; Making and reading -----------------------------------------------------------------

(defun ns-string (text)
  "TEXT as an NSString object.

    (ns-string \"hello\")   => an NSString

STRING-TO-NS-STRING, which is the exported name for this.  Worth knowing that
you rarely need it: (objc:invoke something \"foo:\" \"hello\") converts the
argument itself.  Reach for this when you want the object -- to hold, to store,
or to message."
  (objc:ensure-objc-initialized)
  (objc:string-to-ns-string text))

(defun lisp-string (ns-string)
  "An NSString back as a Lisp string."
  (objc:ns-string-to-string ns-string))

(defun utf8-bytes (text)
  "TEXT's UTF-8 length in bytes, via -[NSString UTF8String].

Reads the C string through the OBJC-C-STRING descriptor explicitly, using
INVOKE's list form.  The plain (objc:invoke s \"UTF8String\") gives the same
answer without being told, because the runtime already declares the result as
char * -- so this is the shape to copy when you are declaring a signature the
runtime does not have, not a thing to write every day."
  (objc:ensure-objc-initialized)
  (let ((string (objc:invoke (ns-string text)
                             '("UTF8String" () :result-type objc:objc-c-string))))
    (values (babel-length string) string)))

(defun babel-length (string)
  "The number of bytes STRING takes in UTF-8."
  (length (sb-ext:string-to-octets string :external-format :utf-8)))

;;; Searching, and where the offsets live ---------------------------------------------------

(defun find-substring (haystack needle)
  "Where NEEDLE occurs in HAYSTACK, as (location . length), or NIL.

    (find-substring \"hello, world\" \"world\")   => (7 . 5)
    (find-substring \"hello, world\" \"zzz\")     => NIL

The NIL is the point.  -rangeOfString: reports a miss as a range located at
NSNotFound, and every caller that forgets is a caller that indexes a string at
NSIntegerMax.  Compare against COCOA:NS-NOT-FOUND, which is what that constant
is called."
  (objc:ensure-objc-initialized)
  (objc:with-autorelease-pool ()
    (let ((range (objc:invoke (ns-string haystack) "rangeOfString:" needle)))
      (unless (= (car range) cocoa:ns-not-found)
        range))))

(defun substring-by-range (text range)
  "The substring of TEXT at RANGE, done on the Cocoa side.

Correct for any string, including one with astral characters, because the range
and the string are both Cocoa's and agree about what an index means.  This is
the safe way to use a range that came from -rangeOfString:."
  (objc:ensure-objc-initialized)
  (objc:with-autorelease-pool ()
    (objc:invoke-into 'string (ns-string text) "substringWithRange:" range)))

(defun index-disagreement (text needle)
  "How far apart Cocoa and Lisp are about where NEEDLE starts in TEXT.

    (index-disagreement \"hello\" \"llo\")            => 0
    (index-disagreement \"a<emoji>b tail\" \"tail\")   => 1

Zero for anything in the basic plane, and one per astral character before the
match otherwise -- because an NSString index counts UTF-16 code units and a
surrogate pair is two of them.  A non-zero answer means any Lisp SUBSEQ using
the Cocoa offset is wrong, usually without erroring."
  (let ((cocoa-range (find-substring text needle))
        (lisp-position (search needle text)))
    (when (and cocoa-range lisp-position)
      (- (car cocoa-range) lisp-position))))

(defun ns-length (text)
  "-[NSString length] for TEXT: UTF-16 code units, not characters."
  (objc:ensure-objc-initialized)
  (objc:with-autorelease-pool ()
    (objc:invoke (ns-string text) "length")))

;;; A Lisp method that returns a C string ---------------------------------------------------
;;;
;;; The other side of OBJC-C-STRING: here we are declaring the signature, so the
;;; descriptor is doing real work rather than agreeing with the runtime.

(objc:define-objc-class labeller ()
  ((label :initarg :label :initform "unnamed" :accessor labeller-label))
  (:objc-class-name "LispStringLabeller"))

(objc:define-objc-method ("labelCString" objc:objc-c-string) ((self labeller))
  (labeller-label self))

(defun make-labeller (label)
  "An object whose -labelCString returns LABEL as a char *."
  (objc:ensure-objc-initialized)
  (make-instance 'labeller :label label))

;;; A worked example ---------------------------------------------------------------------------

(defparameter +astral-example+
  (format nil "a~Cb tail and more" (code-char #x1F600))
  "A string with one astral character, which is where the two lengths part.

Built with CODE-CHAR rather than written literally so the file stays ASCII and
the reader can see exactly which character is meant.")

(defun test-strings ()
  "Search, convert, and measure where Cocoa and Lisp stop agreeing.

    (objc/examples:test-strings)
    => (:HIT (7 . 5) :MISS NIL :ROUND-TRIP \"made by hand\"
        :UTF8-BYTES 5 :C-STRING-METHOD \"from Lisp\"
        :LISP-LENGTH 17 :NS-LENGTH 18 :DISAGREEMENT 1
        :LISP-SUBSEQ-IS-WRONG T :COCOA-SUBSTRING \"tail\")

:LISP-SUBSEQ-IS-WRONG is the assertion with teeth, and it is deliberately not an
error: SUBSEQ at the Cocoa offset returns \"ail \" rather than \"tail\".  It is in
bounds, it is a string, and it is the wrong one.  Anything that pairs an NSRange
with a Lisp string has this bug and will not be told about it.

:MISS is NIL rather than a range located at 9223372036854775807, which is the
only reason FIND-SUBSTRING is safe to use as a predicate."
  (objc:ensure-objc-initialized)
  (objc:with-autorelease-pool ()
    (let* ((text +astral-example+)
           (cocoa-range (find-substring text "tail"))
           (lisp-position (search "tail" text)))
      (list :hit (find-substring "hello, world" "world")
            :miss (find-substring "hello, world" "zzz")
            :round-trip (lisp-string (ns-string "made by hand"))
            :utf8-bytes (utf8-bytes "hello")
            :c-string-method (objc:invoke-into 'string (make-labeller "from Lisp")
                                              "labelCString")
            :lisp-length (length text)
            :ns-length (ns-length text)
            :disagreement (index-disagreement text "tail")
            :lisp-subseq-is-wrong
            (not (string= "tail" (subseq text (car cocoa-range)
                                         (+ (car cocoa-range) (cdr cocoa-range)))))
            :cocoa-substring (substring-by-range text cocoa-range)
            :lisp-substring-with-lisp-index
            (subseq text lisp-position (+ lisp-position 4))))))

(defun report-strings ()
  "Print the disagreement, side by side."
  (objc:ensure-objc-initialized)
  (objc:with-autorelease-pool ()
    (format t "~&a miss is ~S, and NSNotFound is ~D~%"
            (find-substring "hello" "zzz") cocoa:ns-not-found)
    (let* ((text +astral-example+)
           (range (find-substring text "tail"))
           (position (search "tail" text)))
      (format t "~&~S~%" text)
      (format t "  Lisp LENGTH ~D, -[NSString length] ~D~%" (length text) (ns-length text))
      (format t "  -rangeOfString: ~S, Lisp POSITION ~D~%" range position)
      (format t "  subseq at the Cocoa offset:  ~S~%"
              (subseq text (car range) (+ (car range) (cdr range))))
      (format t "  -substringWithRange:         ~S~%" (substring-by-range text range))
      (format t "  subseq at the Lisp position: ~S~%"
              (subseq text position (+ position 4))))))
