;;;; examples/spotlight.lisp -- Core Spotlight: the app's own items in the system search.
;;;;
;;;; Core Spotlight lets an application index what it owns -- documents,
;;;; records, anything with a title -- so that Spotlight finds them and hands
;;;; the application back an identifier to open.  Indexing and querying are
;;;; both asynchronous, and both report through blocks: the index takes a
;;;; completion handler, and a CSSearchQuery calls one block per batch of
;;;; results and another when it is done.  All Lisp closures here.
;;;;
;;;; INDEXING MAY BE OFF.  CSSearchableIndex says so through
;;;; +isIndexingAvailable, and it is off on a machine with Spotlight disabled
;;;; and on a CI runner; the test skips then, since a search that finds nothing
;;;; because there is no index is not a property of this library.  Items go in
;;;; under a domain of our own and are removed again at the end, so that a run
;;;; leaves the user's Spotlight as it found it.

(in-package #:objc/examples)

(defparameter +domain+ "org.lispnik.objc.examples")

(defun ensure-spotlight ()
  (objc:ensure-objc-initialized
   :modules '("/System/Library/Frameworks/CoreSpotlight.framework/CoreSpotlight"
              "/System/Library/Frameworks/UniformTypeIdentifiers.framework/UniformTypeIdentifiers")))

(defun indexing-available-p ()
  (ensure-spotlight)
  (objc:invoke-bool "CSSearchableIndex" "isIndexingAvailable"))

(objc:define-objc-block-type index-completion :void (objc:objc-object-pointer))
(objc:define-objc-block-type found-items :void (objc:objc-object-pointer))

(defun searchable-item (identifier title text &key (keywords '()))
  "A CSSearchableItem under our domain: a title, a description, keywords."
  (let* ((type (objc:invoke "UTType" "typeWithIdentifier:" "public.text"))
         (attributes (objc:invoke* "CSSearchableItemAttributeSet"
                                   "alloc"
                                   ("initWithContentType:" type)
                                   "autorelease")))
    (objc:invoke attributes "setTitle:" title)
    (objc:invoke attributes "setContentDescription:" text)
    (objc:invoke attributes "setKeywords:" (coerce keywords 'vector))
    (objc:invoke* "CSSearchableItem"
                  "alloc"
                  ("initWithUniqueIdentifier:domainIdentifier:attributeSet:" identifier +domain+ attributes)
                  "autorelease")))

(defun index-items (items &key (timeout 10))
  "Index ITEMS, a list of CSSearchableItems, and wait for the index to say so.
Returns T, or the error's description."
  (let ((semaphore (bt:make-semaphore)) (outcome :timeout))
    (objc:with-objc-block (done 'index-completion
                                (lambda (error)
                                  (setf outcome (if (cffi:null-pointer-p error)
                                                    t
                                                    (objc:ns-string-to-string (objc:invoke error "localizedDescription"))))
                                  (bt:signal-semaphore semaphore)))
      (objc:invoke* "CSSearchableIndex"
                    "defaultSearchableIndex"
                    ("indexSearchableItems:completionHandler:" (coerce items 'vector) done))
      (bt:wait-on-semaphore semaphore :timeout timeout))
    outcome))

(defun delete-our-items (&key (timeout 10))
  (let ((semaphore (bt:make-semaphore)))
    (objc:with-objc-block (done 'index-completion
                                (lambda (error) (declare (ignore error)) (bt:signal-semaphore semaphore)))
      (objc:invoke* "CSSearchableIndex"
                    "defaultSearchableIndex"
                    ("deleteSearchableItemsWithDomainIdentifiers:completionHandler:" (vector +domain+) done))
      (bt:wait-on-semaphore semaphore :timeout timeout))))

(defun spotlight-search (query-string &key (timeout 10))
  "The unique identifiers of items matching QUERY-STRING, a Spotlight query
such as \"title == \\\"*Lisp*\\\"cd\", found through CSSearchQuery's two blocks."
  (ensure-spotlight)
  (let ((semaphore (bt:make-semaphore)) (found '()))
    (objc:with-objc-block (batch 'found-items
                                 (lambda (items)
                                   (loop for i below (objc:invoke items "count")
                                         do (push (objc:ns-string-to-string
                                                   (objc:invoke* items ("objectAtIndex:" i) "uniqueIdentifier"))
                                                  found))))
      (objc:with-objc-block (done 'index-completion
                                  (lambda (error) (declare (ignore error)) (bt:signal-semaphore semaphore)))
        (let ((query (objc:invoke* "CSSearchQuery"
                                   "alloc"
                                   ("initWithQueryString:attributes:" query-string (vector "title"))
                                   "autorelease")))
          (objc:invoke query "setFoundItemsHandler:" batch)
          (objc:invoke query "setCompletionHandler:" done)
          (objc:invoke query "start")
          (bt:wait-on-semaphore semaphore :timeout timeout))))
    (nreverse found)))

(defun test-spotlight ()
  "Index three items, find one by title, and remove them again."
  (if (not (indexing-available-p))
      (list :available nil)
      (unwind-protect
           (let ((indexed (index-items
                           (list (searchable-item "lisp-1" "Lisp on the Mac" "The objc bridge" :keywords '("lisp" "objc"))
                                 (searchable-item "lisp-2" "Lisp on the phone" "asdf-ios-app" :keywords '("lisp" "ios"))
                                 (searchable-item "other-1" "Something else" "not ours")))))
             ;; The index catches up in a moment; ask a few times.
             (let ((found (loop repeat 5
                                for hits = (spotlight-search (format nil "title == \"*Lisp*\"cd && domainIdentifier == \"~a\"" +domain+))
                                when hits return hits
                                do (sleep 1))))
               (list :available t :indexed indexed :found found)))
        (delete-our-items))))
