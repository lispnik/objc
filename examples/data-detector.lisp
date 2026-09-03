;;;; examples/data-detector.lisp -- pulling structure out of ordinary prose.
;;;;
;;;; NSDataDetector is the machinery behind the blue underlines in Mail: give it
;;;; a paragraph and it finds the dates, links, addresses, phone numbers and
;;;; flight numbers in it.  Foundation-level, so no window server, no
;;;; permissions and no network, and it pairs with natural-language.lisp -- that
;;;; one says what the words ARE, this one says which of them are things.
;;;;
;;;; Another real framework handing a block an NSRange by value, through
;;;; -enumerateMatchesInString:options:range:usingBlock:.  Same shape as the
;;;; tagger, different framework, which is worth having twice: the first time
;;;; something works it is evidence, the second time it is a pattern.
;;;;
;;;; The detector is built with a BITMASK of what to look for, and asking for
;;;; less is not an optimisation so much as the difference between an answer and
;;;; a pile.  DETECT takes keywords and does the arithmetic.

(in-package #:objc/examples)

(defparameter +checking-types+
  '((:date . 8) (:address . 16) (:link . 32) (:phone-number . 2048)
    (:transit . 4096))
  "The NSTextCheckingType bits NSDataDetector will accept.

The enumeration has more members -- spelling, grammar, quotes, dashes -- but a
data detector rejects those at construction: they belong to the spell checker,
not to this.  Listing only what works beats a longer list that fails at run
time.")

(defun checking-types-mask (types)
  (reduce #'logior types
          :key (lambda (type)
                 (or (cdr (assoc type +checking-types+))
                     (error "Unknown detector type ~S; expected one of ~{~S~^, ~}."
                            type (mapcar #'car +checking-types+))))
          :initial-value 0))

(defun mask-checking-type (mask)
  (or (car (rassoc mask +checking-types+)) mask))

;;; Detecting --------------------------------------------------------------------

(defun detect (text &key (types '(:date :address :link :phone-number :transit)))
  "Find the structured things in TEXT and return one plist per match.

    (detect \"Call 555-123-4567 or see https://example.com by 3 March 2027\")
    => ((:TYPE :PHONE-NUMBER :TEXT \"555-123-4567\" :RANGE (5 . 12)
         :PHONE-NUMBER \"555-123-4567\")
        (:TYPE :LINK :TEXT \"https://example.com\" :RANGE (25 . 19)
         :URL \"https://example.com\")
        (:TYPE :DATE :TEXT \"3 March 2027\" :RANGE (48 . 12) :DATE \"2027-03-03 ...\"))

Every match carries :TYPE, the :TEXT it matched and its :RANGE as (start .
length).  What else is there depends on the type: a link has a :URL, a date a
:DATE, a phone number a :PHONE-NUMBER, an address an :ADDRESS plist of
components."
  (objc:ensure-objc-initialized)
  (objc:with-autorelease-pool ()
    (let* ((detector (objc:invoke "NSDataDetector" "dataDetectorWithTypes:error:"
                                  (checking-types-mask types) (cffi:null-pointer)))
           (matches '()))
      (when (cffi:null-pointer-p (objc:objc-object-pointer detector))
        (error "NSDataDetector refused the types ~S." types))
      (objc:with-objc-block
          (block '(:void (objc:objc-object-pointer (:unsigned :long-long)
                          (:pointer objc:objc-bool)))
                 (lambda (result flags stop)
                   (declare (ignore flags stop))
                   (push (match-plist result text) matches)))
        (objc:invoke detector "enumerateMatchesInString:options:range:usingBlock:"
                     text 0 (cons 0 (length text)) block))
      (nreverse matches))))

(defun match-plist (result text)
  (let* ((range (objc:invoke result "range"))
         (type (mask-checking-type (objc:invoke result "resultType")))
         (base (list :type type
                     :text (subseq text (car range) (+ (car range) (cdr range)))
                     :range range)))
    (append base
            (case type
              (:link (let ((url (objc:invoke result "URL")))
                       (unless (cffi:null-pointer-p (objc:objc-object-pointer url))
                         (list :url (objc:invoke-into 'string url "absoluteString")))))
              (:date (let ((date (objc:invoke result "date")))
                       (unless (cffi:null-pointer-p (objc:objc-object-pointer date))
                         (list :date (objc:invoke-into 'string date "description")))))
              (:phone-number
               (let ((number (objc:invoke result "phoneNumber")))
                 (unless (cffi:null-pointer-p (objc:objc-object-pointer number))
                   (list :phone-number (objc:ns-string-to-string number)))))
              (:address
               (let ((components (objc:invoke result "addressComponents")))
                 (unless (cffi:null-pointer-p (objc:objc-object-pointer components))
                   (list :address (dictionary-plist components)))))
              (t nil)))))

(defun dictionary-plist (dictionary)
  "An NSDictionary of strings as a plist with keyword keys."
  (let ((keys (objc:invoke dictionary "allKeys")))
    (loop for i below (objc:invoke keys "count")
          for key = (objc:invoke keys "objectAtIndex:" i)
          append (list (intern (string-upcase (objc:ns-string-to-string key)) :keyword)
                       (objc:ns-string-to-string
                        (objc:invoke dictionary "objectForKey:" key))))))

;;; Conveniences -------------------------------------------------------------------

(defun links (text)
  "Just the URLs in TEXT, as strings."
  (loop for match in (detect text :types '(:link))
        for url = (getf match :url)
        when url collect url))

(defun dates (text)
  "Just the dates in TEXT, as the text that was matched."
  (loop for match in (detect text :types '(:date))
        collect (getf match :text)))

(defun phone-numbers (text)
  (loop for match in (detect text :types '(:phone-number))
        for number = (getf match :phone-number)
        when number collect number))

;;; A worked example -----------------------------------------------------------------

(defparameter +sample-text+
  "Ada will call +1 555-123-4567 on 3 March 2027 to discuss the notes at
https://example.com/notes before the meeting at 1 Infinite Loop, Cupertino CA 95014.")

(defun test-data-detector ()
  "Run the detector over a paragraph with one of everything in it.

    (objc/examples:test-data-detector)
    => (:TYPES (:PHONE-NUMBER :DATE :LINK :ADDRESS) :LINK \"https://example.com/notes\"
        :PHONE \"+1 555-123-4567\" :RANGES-LINE-UP T :NARROWED 1)

:RANGES-LINE-UP is the assertion worth having: every match's :TEXT is checked
against the substring its :RANGE names, so a range that arrived wrong -- which is
what a struct passed by value into a block gets wrong -- fails here rather than
looking plausible.

:NARROWED is the other: asking for only links finds exactly the link, which
proves the type mask is doing something and not being ignored."
  (objc:ensure-objc-initialized)
  (let* ((matches (detect +sample-text+))
         (link (find :link matches :key (lambda (m) (getf m :type))))
         (phone (find :phone-number matches :key (lambda (m) (getf m :type)))))
    (list :types (mapcar (lambda (m) (getf m :type)) matches)
          :link (getf link :url)
          :phone (getf phone :phone-number)
          :ranges-line-up
          (every (lambda (match)
                   (let ((range (getf match :range)))
                     (string= (getf match :text)
                              (subseq +sample-text+ (car range)
                                      (+ (car range) (cdr range))))))
                 matches)
          :narrowed (length (detect +sample-text+ :types '(:link))))))

(defun report-data-detector (&optional (text +sample-text+))
  "Print everything the detector finds in TEXT."
  (let ((matches (detect text)))
    (if (null matches)
        (format t "~&nothing found.~%")
        (loop for match in matches
              do (format t "~&~14A ~S~@[~%~15T~A~]~%"
                         (getf match :type) (getf match :text)
                         (or (getf match :url) (getf match :date)
                             (getf match :phone-number)
                             (let ((address (getf match :address)))
                               (when address (format nil "~S" address)))))))
    matches))
