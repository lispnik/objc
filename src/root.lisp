;;;; src/root.lisp -- the three methods every Lisp-defined root class gets.
;;;;
;;;; LispWorks installs exactly three, and their names are visible in its heap
;;;; as foreign callables on STANDARD_OBJC_OBJECT: +allocWithZone:,
;;;; -copyWithZone: and -dealloc.  We install the same three, on the root of
;;;; each Lisp-defined hierarchy only; subclasses inherit them.
;;;;
;;;; Note that installing -copyWithZone: unconditionally makes every
;;;; Lisp-defined class answer YES to respondsToSelector:@selector(copyWithZone:)
;;;; whether or not it declares NSCopying.  LispWorks does the same.  It looks
;;;; like a bug and is not, which is exactly why it is written down here.

(in-package #:objc)

(defun install-root-methods (objc-class lisp-class)
  "Install +allocWithZone:, -copyWithZone: and -dealloc on OBJC-CLASS."
  (declare (ignorable lisp-class))
  (let ((class-name (%class-get-name objc-class)))

    ;; + (id)allocWithZone:(NSZone *)zone
    ;;
    ;; Everything that allocates goes through here, +alloc included, so this is
    ;; where a Lisp object comes into being for an Objective-C object that the
    ;; Objective-C side asked for.
    (install-imp objc-class "allocWithZone:" t
                 :id (list :id :sel (list :pointer :void))
                 "@@:^v"
                 (lambda (super-class)
                   (lambda (self cmd result zone)
                     (declare (ignore cmd result))
                     (let* ((class-pointer (pointer-of self))
                            (raw (pointer-of
                                  (send-raw (make-super-reference class-pointer
                                                                  super-class)
                                            "allocWithZone:" zone))))
                       (unless (cffi:null-pointer-p raw)
                         (let ((lisp-class (lisp-class-for-objc-name
                                            (%class-get-name class-pointer))))
                           (when lisp-class
                             (register-objc-object
                              (let ((instance (allocate-instance lisp-class)))
                                (setf (slot-value instance 'pointer) raw)
                                instance)
                              raw))))
                       (sap-of raw)))))

    ;; - (id)copyWithZone:(NSZone *)zone
    (install-imp objc-class "copyWithZone:" nil
                 :id (list :id :sel (list :pointer :void))
                 "@@:^v"
                 (lambda (super-class)
                   (declare (ignore super-class))
                   (lambda (self cmd result zone)
                     (declare (ignore cmd result))
                     (let* ((pointer (pointer-of self))
                            (class-pointer (%object-get-class pointer))
                            ;; +allocWithZone: has already made and registered
                            ;; the copy's Lisp object.
                            (copy (pointer-of
                                   (send-raw class-pointer "allocWithZone:" zone)))
                            (old (objc-object-from-pointer pointer))
                            (new (objc-object-from-pointer copy)))
                       (unless (cffi:null-pointer-p copy)
                         (send-raw copy "init")
                         (when (and old new)
                           (objc-object-copied old new)))
                       (sap-of copy)))))

    ;; - (void)dealloc
    ;;
    ;; The other half of the identity map's lifetime rule: the Lisp object is
    ;; held strongly until the Objective-C object's reference count reaches
    ;; zero, and released here.  That is also what makes keying the map on the
    ;; pointer address safe, since a reused address cannot collide with a stale
    ;; entry.
    (install-imp objc-class "dealloc" nil
                 :void (list :id :sel)
                 "v@:"
                 (lambda (super-class)
                   (lambda (self cmd result)
                     (declare (ignore cmd result))
                     (let* ((pointer (pointer-of self))
                            (object (objc-object-from-pointer pointer)))
                       (when (typep object 'standard-objc-object)
                         (ignore-errors (objc-object-destroyed object)))
                       (unregister-objc-object pointer)
                       (send-raw (make-super-reference pointer super-class) "dealloc")
                       nil))))
    class-name))
