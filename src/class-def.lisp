;;;; src/class-def.lisp -- DEFINE-OBJC-CLASS.
;;;;
;;;; The macro expands to a DEFCLASS plus a registration call.  The foreign work
;;;; is deferred, because the manual is explicit that "it is safe to use the
;;;; defining macros such as define-objc-class and define-objc-method before
;;;; calling ensure-objc-initialized" -- so anything that needs the runtime goes
;;;; on a queue that ENSURE-OBJC-INITIALIZED drains.

(in-package #:objc)

(defvar *all-class-definitions* '()
  "Every class defined by DEFINE-OBJC-CLASS, oldest first.")

(defvar *all-method-definitions* '()
  "Every method defined by DEFINE-OBJC-METHOD, oldest first.")

(defvar *pending-class-definitions* '()
  "Class definitions waiting for ENSURE-OBJC-INITIALIZED, oldest first.")

(defvar *pending-method-definitions* '()
  "Method definitions waiting for ENSURE-OBJC-INITIALIZED, oldest first.")

(defvar *objc-initialized* nil)

(defvar *mixin-methods* (make-hash-table :test 'eq)
  "Lisp class -> method definitions recorded on it.

A class with no :OBJC-CLASS-NAME anywhere in its precedence list has no
Objective-C class of its own, and its methods belong to whichever subclasses do.
Keeping them here is what lets DEFINE-OBJC-METHOD and DEFINE-OBJC-CLASS work in
either order, which manual.lisp requires: it defines the mixin, then the mixin's
method, then two subclasses.")

(defvar *class-options* (make-hash-table :test 'eq)
  "Lisp class -> the plist of Objective-C options it was defined with.")

(defmacro define-objc-class (name superclasses slots &rest options)
  "Define a Lisp class NAME that implements an Objective-C class.

Ordinary DEFCLASS inheritance applies.  STANDARD-OBJC-OBJECT is the default
superclass, and must appear somewhere in the class precedence list.

In addition to the DEFCLASS options:

  (:objc-class-name name)       the Objective-C class name to create.  With no
                                such option anywhere in the precedence list, no
                                Objective-C class is made and the class is a
                                mixin whose methods are inherited by subclasses
                                that do name one.
  (:objc-superclass-name name)  the Objective-C superclass; defaults to the one
                                inherited, or \"NSObject\".
  (:objc-instance-vars (name type)...)  instance variables, reachable with
                                OBJC-OBJECT-VAR-VALUE.
  (:objc-protocols name...)     protocols the class conforms to."
  (let ((objc-class-name (second (assoc :objc-class-name options)))
        (objc-superclass-name (second (assoc :objc-superclass-name options)))
        (instance-vars (rest (assoc :objc-instance-vars options)))
        (protocols (rest (assoc :objc-protocols options)))
        (defclass-options (remove-if (lambda (option)
                                       (member (first option)
                                               '(:objc-class-name
                                                 :objc-superclass-name
                                                 :objc-instance-vars
                                                 :objc-protocols)))
                                     options)))
    `(progn
       (defclass ,name ,(or superclasses '(standard-objc-object))
         ,slots
         ,@defclass-options)
       (ensure-objc-class ',name ,objc-class-name ,objc-superclass-name
                          ',instance-vars ',protocols)
       ',name)))

(defun ensure-objc-class (name objc-class-name objc-superclass-name
                          instance-vars protocols)
  "Record NAME's Objective-C options and create the class, or queue it."
  (let ((class (find-class name)))
    (setf (gethash class *class-options*)
          (list :objc-class-name objc-class-name
                :objc-superclass-name objc-superclass-name
                :instance-vars instance-vars
                :protocols protocols))
    (pushnew class *all-class-definitions*)
    (if *objc-initialized*
        (realize-objc-class class)
        (progn (pushnew class *pending-class-definitions*) class))))

(defun class-option (class key)
  (getf (gethash class *class-options*) key))

(defun inherited-objc-class-name (class)
  "The Objective-C class name CLASS inherits, or NIL.
The first class in the precedence list that names one wins, which is the rule
the manual states."
  (c2mop:ensure-finalized class)
  (loop for super in (rest (c2mop:class-precedence-list class))
        for name = (and (gethash super *class-options*)
                        (class-option super :objc-class-name))
        when name return name))

(defun objc-class-name-of (class)
  (class-option class :objc-class-name))

(defun mixin-class-p (class)
  "True when CLASS names no Objective-C class and inherits none.
Such a class creates nothing foreign; its methods are installed on the
subclasses that do name one."
  (and (null (objc-class-name-of class))
       (null (inherited-objc-class-name class))))

(defun realize-objc-class (class)
  "Create CLASS's Objective-C class, if it has one."
  (let ((objc-name (objc-class-name-of class)))
    (cond
      ((null objc-name)
       ;; Either a mixin, or a Lisp subclass that inherits an Objective-C class
       ;; without naming a new one.  Neither creates anything.
       (let ((inherited (inherited-objc-class-name class)))
         (when inherited
           (setf (gethash class *objc-name-by-lisp-class*) inherited))
         class))
      (t
       (let* ((declared-super (class-option class :objc-superclass-name))
              (inherited-super (inherited-objc-class-name class))
              (super-name (or inherited-super declared-super "NSObject")))
         (when (and declared-super inherited-super
                    (string/= declared-super inherited-super))
           (error "Class ~S inherits Objective-C class ~A but ~A was specified ~
in the definition."
                  (class-name class) inherited-super declared-super))
         (let* ((existing (%objc-look-up-class objc-name))
                (freshp (cffi:null-pointer-p existing))
                (objc-class
                  (if freshp
                      (let ((super (coerce-to-objc-class super-name)))
                        (%objc-allocate-class-pair super objc-name 0))
                      ;; Recompiling a file re-runs DEFINE-OBJC-CLASS, and
                      ;; objc_allocateClassPair returns NULL for a name that
                      ;; already exists.  Reuse it instead.  Note that ivars
                      ;; CANNOT be added to a registered class, so changing
                      ;; :objc-instance-vars needs a fresh image.
                      existing)))
           (when (cffi:null-pointer-p objc-class)
             (error "Cannot define Objective-C class ~S." objc-name))
           (when freshp
             ;; Every ivar must be added before objc_registerClassPair; the
             ;; runtime silently refuses afterwards.
             (loop for (var-name var-type) in (class-option class :instance-vars)
                   do (add-objc-ivar objc-class var-name var-type))
             (%objc-register-class-pair objc-class)
             ;; Only a root -- one whose Objective-C superclass is not itself
             ;; Lisp defined -- installs the three lifecycle methods; the rest
             ;; inherit them.
             (unless inherited-super
               (install-root-methods objc-class class)))
           (setf (gethash objc-name *lisp-class-by-objc-name*) class
                 (gethash class *objc-name-by-lisp-class*) objc-name)
           (dolist (protocol-name (class-option class :protocols))
             (let ((protocol (find-objc-protocol protocol-name)))
               (if protocol
                   (%class-add-protocol objc-class protocol)
                   (warn "No Objective-C protocol named ~S; ignoring." protocol-name))))
           ;; Pull in every method recorded on a mixin ancestor.  This is what
           ;; makes -size exist on both MyData and MyOtherData in the manual's
           ;; example.
           (c2mop:ensure-finalized class)
           (dolist (super (c2mop:class-precedence-list class))
             (dolist (definition (reverse (gethash super *mixin-methods*)))
               (install-method-definition definition class)))
           class))))))

(defun add-objc-ivar (objc-class var-name var-type)
  (let* ((node (node-for-fli-type var-type))
         (encoding (canonical-encoding node)))
    (multiple-value-bind (size alignment) (node-size-and-alignment node)
      (unless (%class-add-ivar objc-class var-name size
                               (floor (log (max 1 alignment) 2))
                               encoding)
        (error "Failed to add ivar ~S type ~S to class ~S."
               var-name var-type (%class-get-name objc-class))))))

;;; Surviving SAVE-LISP-AND-DIE ---------------------------------------------
;;;
;;; Objective-C classes created with objc_allocateClassPair are foreign runtime
;;; state.  They do not survive a dump: the restarted image gets a fresh libobjc
;;; that has never heard of them.  Neither do the IMPs, which are sb-alien
;;; callables, nor the trampolines, which embed objc_msgSend's address as an
;;; immediate.
;;;
;;; So everything is remembered in definition order and simply built again on
;;; the way back in.  The failure this prevents is not a missing class -- it is
;;; a jump into freed memory the first time Cocoa calls a delegate method in a
;;; dumped application.

(defun reset-for-image-restore ()
  "Forget the foreign side of every Lisp-defined class and queue it to be
rebuilt by the next ENSURE-OBJC-INITIALIZED."
  (setf *objc-initialized* nil)
  (clrhash *lisp-class-by-objc-name*)
  (clrhash *objc-name-by-lisp-class*)
  (clrhash *mixin-methods*)
  (clrhash *imp-registry*)
  (setf *pending-class-definitions* (reverse *all-class-definitions*)
        *pending-method-definitions* (reverse *all-method-definitions*))
  (values))

(defun drain-pending-definitions ()
  "Create every class and install every method that was defined before
ENSURE-OBJC-INITIALIZED ran."
  (let ((classes (reverse *pending-class-definitions*))
        (methods (reverse *pending-method-definitions*)))
    (setf *pending-class-definitions* '()
          *pending-method-definitions* '())
    (dolist (class classes) (realize-objc-class class))
    (dolist (definition methods) (install-method-definition definition nil))))
