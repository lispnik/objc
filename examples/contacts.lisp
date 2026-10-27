;;;; examples/contacts.lisp -- the address book, one contact at a time.
;;;;
;;;; The Contacts framework hands you the address book through
;;;; -enumerateContactsWithFetchRequest:error:usingBlock:, which calls a block
;;;; once per contact with two arguments: the CNContact, and a pointer to a BOOL
;;;; the block may set to stop the enumeration early.
;;;;
;;;;     void (^)(CNContact *contact, BOOL *stop)
;;;;
;;;; This example exists for that second argument.  STOP is a raw pointer to a
;;;; byte the enumerator owns, and stopping means writing the integer 1 through
;;;; it -- not T, which is a Lisp object and not a byte.  It is the same on Intel
;;;; and on Apple silicon: BOOL is a signed char on one and a _Bool on the other,
;;;; but both are one byte, and 1 is YES in either.  So the block type below names
;;;; OBJC-C++-BOOL without a read-time conditional anywhere.
;;;;
;;;; PERMISSION IS THE GATE, as it is for accessibility.lisp.  Reading the user's
;;;; address book needs the user's consent, which a command-line SBCL starts out
;;;; without -- the status is "not determined" -- and which a CI runner never has.
;;;; So the example has two halves:
;;;;
;;;;   - vCards, which need no permission at all: PARSE-VCARDS turns text into
;;;;     CNContacts, and VISIT-CONTACTS plays CNContactStore's part, calling the
;;;;     very same CONTACT-VISITOR block over them and honouring STOP the way the
;;;;     store does.  That is what the test always runs.
;;;;
;;;;   - The real store, through MAP-CONTACTS, only when access has ALREADY been
;;;;     granted.  Nothing here asks for it on its own: a test that pops a
;;;;     consent dialog is a test that hangs on whoever is at the keyboard.
;;;;     REQUEST-CONTACTS-ACCESS asks, and is for the REPL.
;;;;
;;;; One more trap worth knowing: a CNContact only carries the properties its
;;;; fetch request named, and reading any other one raises
;;;; CNContactPropertyNotFetchedException.  +CONTACT-KEYS+ is the list fetched,
;;;; and CONTACT-PLIST reads exactly those.

(in-package #:objc/examples)

(defun ensure-contacts ()
  (objc:ensure-objc-initialized
   :modules '("/System/Library/Frameworks/Contacts.framework/Contacts")))

;;; The block signatures -------------------------------------------------------

(objc:define-objc-block-type contact-visitor :void
  (objc:objc-object-pointer (:pointer objc:objc-c++-bool)))

(objc:define-objc-block-type access-handler :void
  (objc:objc-bool objc:objc-object-pointer))

;;; Authorization --------------------------------------------------------------

(defparameter +authorization-statuses+
  '((0 . :not-determined) (1 . :restricted) (2 . :denied) (3 . :authorized)
    (4 . :limited))
  "CNAuthorizationStatus.  :LIMITED arrived with macOS 15's partial access.")

(defun contacts-authorization ()
  "Whether this process may read the address book: :AUTHORIZED, :DENIED,
:RESTRICTED, :LIMITED or :NOT-DETERMINED.  Asking does not prompt."
  (ensure-contacts)
  (let ((status (objc:invoke "CNContactStore" "authorizationStatusForEntityType:" 0)))
    (or (cdr (assoc status +authorization-statuses+)) status)))

(defun contacts-readable-p ()
  (member (contacts-authorization) '(:authorized :limited)))

(defun request-contacts-access (&key (timeout 60))
  "Ask the user for access to the address book, and wait for the answer.
Returns T if granted, NIL if refused, :TIMEOUT if nobody answered.

This PROMPTS, and the prompt names whatever macOS considers responsible for this
process -- usually the terminal application.  Once refused, asking again answers
NIL at once; the fix is then System Settings > Privacy & Security > Contacts.

The completion handler runs on a libdispatch worker thread, so the wait is the
two-step one from gcd.lisp: the semaphore, then the block leaving Lisp."
  (ensure-contacts)
  (let ((semaphore (bt:make-semaphore)) (granted :timeout))
    (objc:with-objc-block (handler 'access-handler
                                   (lambda (ok error)
                                     (declare (ignore error))
                                     ;; A BOOL argument arrives as 1 or 0.
                                     (setf granted (eql ok 1))
                                     (bt:signal-semaphore semaphore)))
      (objc:with-autorelease-pool ()
        (objc:invoke (objc:invoke* "CNContactStore" "alloc" "init" "autorelease")
                     "requestAccessForEntityType:completionHandler:" 0 handler))
      (wait-for-callback-signal semaphore :timeout timeout))
    granted))

;;; Reading a contact ------------------------------------------------------------

(defparameter +contact-keys+
  '("CNContactGivenNameKey" "CNContactFamilyNameKey" "CNContactOrganizationNameKey"
    "CNContactEmailAddressesKey" "CNContactPhoneNumbersKey")
  "The properties fetched, by the names of the constants that spell them.
The constants are read, not their values written in; see FOUNDATION-STRING-CONSTANT.")

(defun contact-keys ()
  "The keys to fetch: +CONTACT-KEYS+, plus whatever CNContactFormatter needs
for a full name, which is a descriptor rather than a string."
  (concatenate 'vector
               (mapcar #'foundation-string-constant +contact-keys+)
               (list (objc:invoke "CNContactFormatter"
                                  "descriptorForRequiredKeysForStyle:" 0))))

(defun labeled-values (array &optional (key nil))
  "The values of an NSArray of CNLabeledValue, as Lisp strings.
KEY, when given, is a selector to send each value first: a phone number is a
CNPhoneNumber, and its text is its -stringValue."
  (loop for i below (objc:invoke array "count")
        for value = (objc:invoke (objc:invoke array "objectAtIndex:" i) "value")
        collect (objc:ns-string-to-string (if key (objc:invoke value key) value))))

(defun non-empty (string)
  (unless (zerop (length string)) string))

(defun contact-plist (contact)
  "CONTACT as a plist.  Reads only the properties CONTACT-KEYS fetches."
  (let ((name (objc:invoke "CNContactFormatter" "stringFromContact:style:" contact 0)))
    (list :name (and (not (cffi:null-pointer-p (objc:objc-object-pointer name)))
                     (objc:ns-string-to-string name))
          :given (non-empty (objc:invoke-into 'string contact "givenName"))
          :family (non-empty (objc:invoke-into 'string contact "familyName"))
          :organization (non-empty (objc:invoke-into 'string contact "organizationName"))
          :emails (labeled-values (objc:invoke contact "emailAddresses"))
          :phones (labeled-values (objc:invoke contact "phoneNumbers") "stringValue"))))

;;; Visiting ---------------------------------------------------------------------

(defun stop-visiting (stop)
  "Tell the enumerator to stop after this contact: *STOP = YES.
The integer 1, written as a byte, on every architecture."
  (setf (cffi:mem-ref stop :uint8) 1))

(defun make-collector (limit)
  "A CONTACT-VISITOR function collecting contact plists, and a function returning
them.  Stops the enumeration once it holds LIMIT, when LIMIT is not NIL."
  (let ((found '()) (count 0))
    (values (lambda (contact stop)
              (push (contact-plist contact) found)
              (when (and limit (>= (incf count) limit))
                (stop-visiting stop)))
            (lambda () (reverse found)))))

(defun map-contacts (function &key (keys (contact-keys)))
  "Call FUNCTION with each contact in the user's address book and a STOP pointer.
FUNCTION is the body of a CONTACT-VISITOR block: (lambda (contact stop) ...),
calling STOP-VISITING to end early.

Needs access already granted; see CONTACTS-AUTHORIZATION.  Contacts calls the
block synchronously, on this thread, and returns when it is done, so nothing
here waits on another thread."
  (ensure-contacts)
  (unless (contacts-readable-p)
    (error "This process may not read Contacts (~(~A~)); ~
            see REQUEST-CONTACTS-ACCESS." (contacts-authorization)))
  (objc:with-autorelease-pool ()
    (let ((store (objc:invoke* "CNContactStore" "alloc" "init" "autorelease"))
          (request (objc:invoke* "CNContactFetchRequest" "alloc"
                                 ("initWithKeysToFetch:" keys) "autorelease")))
      (cffi:with-foreign-object (error :pointer)
        (setf (cffi:mem-ref error :pointer) (cffi:null-pointer))
        (objc:with-objc-block (visitor 'contact-visitor function)
          (when (zerop (objc:invoke store "enumerateContactsWithFetchRequest:error:usingBlock:"
                                    request error visitor))
            (error "Contacts refused the enumeration: ~A"
                   (objc:ns-string-to-string
                    (objc:invoke (cffi:mem-ref error :pointer) "localizedDescription")))))))))

(defun contacts (&key (limit 20))
  "Up to LIMIT contacts from the address book, as plists."
  (multiple-value-bind (visit found) (make-collector limit)
    (map-contacts visit)
    (funcall found)))

;;; vCards: contacts without the address book --------------------------------------

(defun parse-vcards (text)
  "The CNContacts in TEXT, one or more vCards, as a Lisp list.  No permission
needed: this is a parser, and the store is never involved."
  (ensure-contacts)
  (let* ((data (objc:invoke (objc:invoke "NSString" "stringWithString:" text)
                            "dataUsingEncoding:" 4)) ; NSUTF8StringEncoding
         (array (objc:invoke "CNContactVCardSerialization" "contactsWithData:error:"
                             data (cffi:null-pointer))))
    (when (cffi:null-pointer-p (objc:objc-object-pointer array))
      (error "Not a vCard: ~S" text))
    (loop for i below (objc:invoke array "count")
          collect (objc:invoke array "objectAtIndex:" i))))

(defun visit-contacts (contacts function)
  "Call FUNCTION over CONTACTS through a real CONTACT-VISITOR block, the way
CNContactStore does: one call per contact, a fresh STOP byte of 0 each time, and
no more calls once the block has set it.  Returns how many calls were made.

The point is that the block on the other end is the same block MAP-CONTACTS
hands Contacts, so a STOP written wrong -- T, say, or a word instead of a byte --
shows here, with no permission and no address book."
  (cffi:with-foreign-object (stop :uint8)
    (objc:with-objc-block (visitor 'contact-visitor function)
      (loop for contact in contacts
            for calls from 1
            do (setf (cffi:mem-ref stop :uint8) 0)
               (objc:call-objc-block 'contact-visitor visitor contact stop)
            until (= 1 (cffi:mem-ref stop :uint8))
            finally (return calls)))))

(defparameter +sample-vcards+
  "BEGIN:VCARD
VERSION:3.0
N:Lovelace;Ada;;;
FN:Ada Lovelace
ORG:Analytical Engines
EMAIL;TYPE=INTERNET:ada@example.com
TEL;TYPE=CELL:+44 20 7946 0001
END:VCARD
BEGIN:VCARD
VERSION:3.0
N:Hopper;Grace;;;
FN:Grace Hopper
EMAIL;TYPE=INTERNET:grace@example.com
EMAIL;TYPE=INTERNET:hopper@example.org
END:VCARD
BEGIN:VCARD
VERSION:3.0
N:Turing;Alan;;;
FN:Alan Turing
TEL;TYPE=WORK:+44 161 496 0002
END:VCARD
")

;;; A worked example -----------------------------------------------------------------

(defun test-contacts ()
  "Parse three vCards and visit them, then read the real store if allowed.

    (objc/examples:test-contacts)
    => (:AUTHORIZATION :NOT-DETERMINED
        :NAMES (\"Ada Lovelace\" \"Grace Hopper\" \"Alan Turing\")
        :ADA (:NAME \"Ada Lovelace\" :GIVEN \"Ada\" :FAMILY \"Lovelace\" ...)
        :VISITED 3 :STOPPED-AFTER 2 :COLLECTED-BEFORE-STOP 2
        :STORE NIL)

:STOPPED-AFTER is the assertion this file exists for: a visitor that sets STOP
on the second of three contacts is called exactly twice.  :STORE is NIL unless
this process may already read Contacts, and then it is how many contacts a
visitor limited to three collected -- at most three, whatever the book holds."
  (ensure-contacts)
  (objc:with-autorelease-pool ()
    (let* ((parsed (parse-vcards +sample-vcards+))
           (plists (mapcar #'contact-plist parsed)))
      (list :authorization (contacts-authorization)
            :names (mapcar (lambda (p) (getf p :name)) plists)
            :ada (first plists)
            :visited (visit-contacts parsed (lambda (contact stop)
                                              (declare (ignore contact stop))))
            :stopped-after (let ((seen 0))
                             (visit-contacts parsed (lambda (contact stop)
                                                      (declare (ignore contact))
                                                      (when (= 2 (incf seen))
                                                        (stop-visiting stop)))))
            :collected-before-stop (multiple-value-bind (visit found) (make-collector 2)
                                     (visit-contacts parsed visit)
                                     (length (funcall found)))
            :store (when (contacts-readable-p)
                     (length (contacts :limit 3)))))))

(defun report-contacts (&key (limit 10))
  "Print up to LIMIT contacts from the address book, or the sample vCards when
this process may not read it."
  (let ((plists (if (contacts-readable-p)
                    (contacts :limit limit)
                    (progn
                      (format t "~&Contacts access is ~(~A~); showing the sample vCards.~%"
                              (contacts-authorization))
                      (mapcar #'contact-plist (parse-vcards +sample-vcards+))))))
    (dolist (p plists plists)
      (format t "~&~A~@[ (~A)~]~{~%  ~A~}~%"
              (or (getf p :name) "(no name)") (getf p :organization)
              (append (getf p :emails) (getf p :phones))))))
