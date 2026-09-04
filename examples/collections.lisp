;;;; examples/collections.lisp -- a Lisp object Cocoa treats as its own.
;;;;
;;;; Every other example here calls INTO Cocoa, or has Cocoa call a Lisp
;;;; function back.  This one is about a Lisp object being a first-class
;;;; participant in Cocoa's own data structures: an NSSet that deduplicates it,
;;;; an NSDictionary that uses it as a key, an NSArray that sorts it.  Which
;;;; means Cocoa asking it questions -- -hash, -isEqual:, -description -- and
;;;; getting Lisp answers.
;;;;
;;;; It exercises the half of this library the other examples ignore.  They are
;;;; about the calling machinery; this is about STANDARD-OBJC-OBJECT: the CLOS
;;;; integration, the identity map, and the two lifecycle hooks.
;;;;
;;;; AN NSDictionary COPIES ITS KEYS, which is the thing worth knowing.  It is
;;;; not an optimisation you can ignore: a key that cannot be copied raises, and
;;;; a key that copies badly gives a dictionary you cannot look anything up in.
;;;; The library installs -copyWithZone: on every Lisp-defined class for you and
;;;; copies the CLOS slots by default, so this works without being asked -- and
;;;; OBJC-OBJECT-COPIED is where you hook it when the default is not right.
;;;; Putting one object in a dictionary here fires it, which is how you can see
;;;; it happening at all.
;;;;
;;;; A WRONG -hash IS SILENT.  Two objects that are -isEqual: must have the same
;;;; hash, and if they do not, an NSSet simply contains both of them and a
;;;; dictionary lookup simply misses.  Nothing raises.  That is the failure this
;;;; example asserts against, because it is the one you would otherwise ship.
;;;;
;;;; -isEqual: returns a BOOL, which is worth a footnote: that argument path was
;;;; broken in this library until it was found by an example rather than by the
;;;; suite.  Everything below depends on it.

(in-package #:objc/examples)

;;; A point --------------------------------------------------------------------------

(objc:define-objc-class point ()
  ((x :initarg :x :initform 0 :accessor point-x)
   (y :initarg :y :initform 0 :accessor point-y))
  (:objc-class-name "LispPoint"))

;;; A class method implemented in Lisp.  Cocoa's convention for a name that does
;;; not begin with alloc, new, copy or mutableCopy is an autoreleased object, so
;;; that is what this returns.
;;;
;;; DEFINE-OBJC-METHOD and DEFINE-OBJC-CLASS-METHOD take a body, not a docstring:
;;; a leading string is an ordinary form there, and a DECLARE after one is then a
;;; declaration in the wrong place.  Hence comments rather than docstrings on
;;; every method in this file.
(objc:define-objc-class-method ("pointWithX:y:" objc:objc-object-pointer)
    ((class point) (x :long-long) (y :long-long))
  (declare (ignore class))
  (objc:invoke (make-instance 'point :x x :y y) "autorelease"))

;;; What Cocoa asks it ------------------------------------------------------------------

;;; Equal points must hash equally, or an NSSet holds both and no lookup finds
;;; either.  Nothing checks this and nothing complains; see the header.
(objc:define-objc-method ("hash" (:unsigned :long-long)) ((self point))
  (logand (+ (* 31 (point-x self)) (point-y self)) most-positive-fixnum))

(objc:define-objc-method ("isEqual:" objc:objc-bool)
    ((self point) (other objc:objc-object-pointer))
  ;; Cocoa hands us a pointer; OBJC-OBJECT-FROM-POINTER hands back the Lisp
  ;; object.  That round trip is the identity map, and it is what lets this
  ;; compare CLOS slots rather than reaching into instance variables.  A pointer
  ;; to something that is not one of ours simply is not EQUAL.
  (let ((object (objc:objc-object-from-pointer (objc:objc-object-pointer other))))
    (and (typep object 'point)
         (= (point-x self) (point-x object))
         (= (point-y self) (point-y object)))))

;;; What NSLog, the debugger and -[NSArray description] print.
(objc:define-objc-method ("description" objc:objc-object-pointer) ((self point))
  (objc:invoke "NSString" "stringWithUTF8String:"
               (format nil "(~D, ~D)" (point-x self) (point-y self))))

;;; The lifecycle hooks -------------------------------------------------------------------
;;;
;;; Not methods: generic functions the library calls from the -copyWithZone: and
;;; -dealloc it installs on every Lisp-defined class.  The primary method for
;;; OBJC-OBJECT-COPIED already copies the CLOS slots, which is what the manual
;;; specifies and what makes a point copy correctly with no work here -- so these
;;; are :AFTER methods that only observe.

(defvar *lifecycle* '()
  "A log of copies and deallocations, newest first.  For the example only.")

(defvar *lifecycle-lock* (bt:make-lock "point lifecycle"))

(defun note-lifecycle (event object)
  (bt:with-lock-held (*lifecycle-lock*)
    (push (list event (point-x object) (point-y object)) *lifecycle*)))

(defmethod objc:objc-object-copied :after ((old point) (new point))
  (note-lifecycle :copied new))

(defmethod objc:objc-object-destroyed :after ((object point))
  ;; -dealloc, from Lisp.  Note this runs while Cocoa is tearing the object
  ;; down, so it reads slots and does nothing clever.
  (note-lifecycle :destroyed object))

(defun clear-lifecycle ()
  (bt:with-lock-held (*lifecycle-lock*) (setf *lifecycle* '())))

(defun lifecycle-events ()
  (bt:with-lock-held (*lifecycle-lock*) (reverse *lifecycle*)))

;;; Using them ----------------------------------------------------------------------------

(defun make-point (x y)
  "A point, as an autoreleased Objective-C object with a Lisp side."
  (objc:ensure-objc-initialized)
  (objc:invoke "LispPoint" "pointWithX:y:" x y))

(defun points (&rest coordinates)
  "Points from a flat list of coordinates: (points 1 2 3 4) is two points."
  (loop for (x y) on coordinates by #'cddr collect (make-point x y)))

(defun point-set (points)
  "An NSSet of POINTS, deduplicated by Cocoa using our -hash and -isEqual:."
  (objc:invoke "NSSet" "setWithArray:" (coerce points 'vector)))

(defun point-sorted (points)
  "POINTS sorted by x then y, as a list, using a Lisp comparator.

Cocoa does the sorting and calls back for every comparison, which is the block
machinery and the object machinery meeting: the comparator is a Lisp closure and
the things being compared are Lisp objects."
  (objc:with-autorelease-pool ()
    (let ((array (objc:invoke "NSArray" "arrayWithArray:" (coerce points 'vector))))
      (objc:with-objc-block
          (comparator '(:long-long (objc:objc-object-pointer objc:objc-object-pointer))
                      (lambda (a b)
                        (let ((left (objc:objc-object-from-pointer
                                     (objc:objc-object-pointer a)))
                              (right (objc:objc-object-from-pointer
                                      (objc:objc-object-pointer b))))
                          (cond ((< (point-x left) (point-x right)) -1)
                                ((> (point-x left) (point-x right)) 1)
                                ((< (point-y left) (point-y right)) -1)
                                ((> (point-y left) (point-y right)) 1)
                                (t 0)))))
        (let ((sorted (objc:invoke array "sortedArrayUsingComparator:" comparator)))
          (loop for i below (objc:invoke sorted "count")
                collect (objc:objc-object-from-pointer
                         (objc:objc-object-pointer
                          (objc:invoke sorted "objectAtIndex:" i)))))))))

(defun point-keyed-table (pairs)
  "An NSDictionary keyed by points.  (point-keyed-table '(((1 2) \"a\")))

Every key is COPIED on the way in -- see the header -- so this is where
OBJC-OBJECT-COPIED fires."
  (let ((table (objc:invoke (objc:alloc-init-object "NSMutableDictionary") "self")))
    (loop for ((x y) value) in pairs
          do (objc:invoke table "setObject:forKey:" value (make-point x y)))
    table))

;;; A worked example -------------------------------------------------------------------------

(defun test-collections ()
  "Put Lisp objects into Cocoa's collections and check Cocoa treats them right.

    (objc/examples:test-collections)
    => (:SET-COUNT 2 :EQUAL-KEY-FOUND \"first\" :KEYS-WERE-COPIED T
        :SORTED ((1 2) (1 5) (3 4)) :DESCRIPTION \"(1, 2)\" :DESTROYED T
        :FOREIGN-NOT-EQUAL T)

:SET-COUNT is the assertion the whole file is for.  Three points go in and two
come out, because two of them are -isEqual: and hash alike -- and if the hash
were wrong the set would quietly hold all three.  Nothing raises in that case,
which is why it is asserted rather than trusted.

:KEYS-WERE-COPIED shows OBJC-OBJECT-COPIED firing, because an NSDictionary
copies its keys; :DESTROYED shows OBJC-OBJECT-DESTROYED firing when the pool
drains.  Those two hooks are the reason this example exists."
  (objc:ensure-objc-initialized)
  (clear-lifecycle)
  (let (set-count equal-key sorted description foreign-not-equal)
    (objc:with-autorelease-pool ()
      (let* ((a (make-point 1 2))
             (b (make-point 1 2))                ; equal to A, a different object
             (c (make-point 3 4)))
        (setf set-count (objc:invoke (point-set (list a b c)) "count"))
        (let ((table (point-keyed-table (list (list (list 1 2) "first")))))
          ;; Looked up with B, which is a different object that is EQUAL to the
          ;; key A -- so this only works if Cocoa asked our -hash and -isEqual:.
          (setf equal-key (objc:invoke-into 'string
                                            (objc:invoke table "objectForKey:" b)
                                            "self")))
        (setf sorted (mapcar (lambda (p) (list (point-x p) (point-y p)))
                             (point-sorted (list c (make-point 1 5) a))))
        (setf description (objc:invoke-into 'string a "description"))
        ;; An object that is not one of ours is not EQUAL to one that is.
        (setf foreign-not-equal
              (not (objc:invoke-bool a "isEqual:"
                                     (objc:invoke "NSString" "stringWithUTF8String:"
                                                  "(1, 2)"))))))
    ;; The pool has drained, so the points are gone.
    (let ((events (lifecycle-events)))
      (list :set-count set-count
            :equal-key-found equal-key
            :keys-were-copied (and (find :copied events :key #'first) t)
            :sorted sorted
            :description description
            :destroyed (and (find :destroyed events :key #'first) t)
            :foreign-not-equal foreign-not-equal))))

(defun report-collections ()
  "Print what TEST-COLLECTIONS found, and the lifecycle events behind it."
  (let ((result (test-collections)))
    (format t "~&three points, two distinct -> NSSet of ~D~%" (getf result :set-count))
    (format t "looked up by an equal-but-different key -> ~S~%"
            (getf result :equal-key-found))
    (format t "sorted by a Lisp comparator -> ~S~%" (getf result :sorted))
    (format t "-description answers ~S~%" (getf result :description))
    (format t "~%NSDictionary copied its key: ~A~%" (getf result :keys-were-copied))
    (format t "the points were deallocated: ~A~%" (getf result :destroyed))
    (format t "~%lifecycle:~%")
    (loop for (event x y) in (lifecycle-events)
          do (format t "  ~-10A (~D, ~D)~%" event x y))
    result))
