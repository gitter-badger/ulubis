
(in-package :ulubis)

(defparameter *compositor* nil)

(defun run-program (string)
  #+sbcl
  (sb-ext:run-program string '() :wait nil)
  #+ccl
  (ccl:run-program string '() :wait nil))

(defclass compositor ()
  ((running :accessor running :initarg :running :initform t)
   (backend :accessor backend :initarg :backend :initform nil)
   (display :accessor display :initarg :display :initform nil)
   (devices :accessor devices :initarg :devices :initform nil)
   (->output :accessor ->output :initarg :->output :initform nil)
   (event-loop :accessor event-loop :initarg :event-loop :initform nil)
   (screen-width :accessor screen-width :initarg :screen-width :initform 640)
   (screen-height :accessor screen-height :initarg :screen-height :initform 480)
   (views :accessor views :initarg :views :initform nil) ;; e.g. virtual desktops
   (current-view :accessor current-view :initarg current-view :initform nil)
   (surfaces :accessor surfaces :initarg :surfaces :initform nil)
   (clients :accessor clients :initarg :clients :initform nil)
   (moving-surface :accessor moving-surface :initarg :moving-surface :initform nil)
   (resizing-surface :accessor resizing-surface :initarg :resizing-surface :initform nil)
   (pointer-surface :accessor pointer-surface :initarg :pointer-surface :initform nil)
   (cursor-surface :accessor cursor-surface :initarg :cursor-surface :initform nil)
   (show-cursor :accessor show-cursor :initarg :show-cursor :initform t)
   (pointer-x :accessor pointer-x :initarg :pointer-x :initform 0)
   (pointer-y :accessor pointer-y :initarg :pointer-y :initform 0)
   (data-devices :accessor data-devices :initarg :data-devices :initform nil)
   (render-needed :accessor render-needed :initarg :render-needed :initform nil)
   (xkb-context :accessor xkb-context :initarg :xkb-context :initform nil)
   (xkb-state :accessor xkb-state :initarg :xkb-state :initform nil)
   (xkb-keymap :accessor xkb-keymap :initarg :xkb-keymap :initform nil)
   (mods-depressed :accessor mods-depressed :initarg :mods-depressed :initform 0)
   (mods-latched :accessor mods-latched :initarg :mods-latched :initform 0)
   (mods-locked :accessor mods-locked :initarg :mods-locked :initform 0)
   (mods-group :accessor mods-group :initarg :mods-group :initform 0)))

(defmethod initialize-instance :after ((compositor compositor) &key)
  (setf (xkb-context compositor) (xkb:xkb-context-new 0))
  (setf (xkb-keymap compositor) (xkb:new-keymap-from-names (xkb-context compositor) "evdev" "apple" "gb" "" ""))
  (setf (xkb-state compositor) (xkb:xkb-state-new (xkb-keymap compositor))))
	   
(defun set-keymap (compositor r m l v o)
  (setf (xkb-context compositor) (xkb:xkb-context-new 0))
  (setf (xkb-keymap compositor) (xkb:new-keymap-from-names (xkb-context compositor) r m l v o))
  (setf (xkb-state compositor) (xkb:xkb-state-new (xkb-keymap compositor))))

(defun new-xkb-state (compositor)
  (when (xkb-state compositor)
    (xkb:xkb-state-unref (xkb-state compositor)))
  (setf (xkb-state compositor) (xkb:xkb-state-new (xkb-keymap compositor))))

(defun get-keymap (compositor)
  (let* ((string (xkb:xkb-keymap-get-as-string (xkb-keymap compositor) 1)) ;; 1 == XKB_KEYMAP_FORMAT_TEXT_V!
	 (size (+ (length string) 1))
	 (xdg-runtime-dir (nix:getenv "XDG_RUNTIME_DIR"))
	 (fd (nix:mkstemp (concatenate 'string xdg-runtime-dir "/XXXXXXXX"))))
;;    (multiple-value-bind (fd name) (nix:mkstemp (concatenate 'string xdg-runtime-dir "/XXXXXXXX"))
    (nix:ftruncate fd size)
    (let ((map (nix:mmap (null-pointer) size (logior nix:prot-read nix:prot-write) nix:map-shared fd 0)))
      (lisp-string-to-foreign string map size)
      (nix:munmap map size)
      (values fd size))))

(defun find-client (client-pointer compositor)
  (find-if (lambda (client)
	     (and (pointerp (->client client)) (pointer-eq (->client client) client-pointer)))
	   (clients compositor)))

(defun find-surface (surface-pointer compositor)
  (find-if (lambda (surface)
	     (and (pointerp (->surface surface)) (pointer-eq (->surface surface) surface-pointer)))
	   (surfaces compositor)))

(defun find-region-of-client (->client ->region compositor)
  (find-region ->region (find-client ->client compositor)))

(defun find-client-with-surface (surface-pointer compositor)
  (find-if (lambda (client)
	     (find-if (lambda (surface)
			(and (pointerp (->surface surface)) (pointer-eq (->surface surface) surface-pointer)))
		      (surfaces client)))
	   (clients compositor)))

(defun remove-client (client-pointer compositor)
  (let ((client (find-client client-pointer compositor)))
    (setf (clients compositor) (remove-if (lambda (client)
					    (and (pointerp (->client client)) (pointer-eq (->client client) client-pointer)))
					  (clients compositor)))))

(defun view-has-surface? (surface view)
  (when (find surface (surfaces view))
    view))

(defun views-with-surface (surface)
  (loop :for view :in (views *compositor*)
     :when (view-has-surface? surface view) :collect it))

(defun remove-surface-from-view (surface view)
  (when (equalp (active-surface view) surface)
    (setf (active-surface view) nil))
  (setf (surfaces view) (remove surface (surfaces view))))

(defun remove-surface (surface-pointer compositor)
  (let* ((surface (find-surface surface-pointer compositor))
	 (views (views-with-surface surface)))
    (loop :for view :in views :do (remove-surface-from-view surface view))
    ;; TODO do we need to do the same for MOVING-SURFACE and RESIZING-SURFACE
    (when (equalp surface (pointer-surface *compositor*))
      (setf (pointer-surface *compositor*) nil))
    (setf (surfaces compositor) (remove surface (surfaces compositor)))))

(defun raise-surface (surface view)
  (when surface
    (setf (surfaces view) (cons surface (remove surface (surfaces view))))))

(defstruct move-op
  surface
  surface-x
  surface-y
  pointer-x
  pointer-y)

(defstruct resize-op
  surface
  pointer-x
  pointer-y
  surface-width
  surface-height)

;; Check pointer is over client
;; If it is and there is no input-region return true
;; It it is and there is an input-region

(defun pointer-over-p (pointer-x pointer-y x y width height)
  "Return true if pointer is within rect defined by x y width and height. pointer-x and pointer-y are local to the client surface"
  (and (>= pointer-x x) (<= pointer-x (+ x width))
       (>= pointer-y y) (<= pointer-y (+ y height))))

(defun pointer-over-input-region-p (pointer-x pointer-y surface-w/input-region)
  (let ((global-x (x surface-w/input-region))
	(global-y (y surface-w/input-region))
	(rects (rects (input-region surface-w/input-region))))
    (loop :for rect :in rects
       :do (with-slots (x y width height operation) rect
	     (case operation
	       (:add (when (pointer-over-p (- pointer-x global-x) (- pointer-y global-y) x y width height)
		       (return-from pointer-over-input-region-p t)))
	       (:subtract (when (pointer-over-p (- pointer-x global-x) (- pointer-y global-y) x y width height)
			    (return-from pointer-over-input-region-p nil))))))
    nil))

(defun pointer-over-surface-p (pointer-x pointer-y surface)
  (with-slots (x y width height) surface
    (pointer-over-p pointer-x pointer-y x y width height)))

(defun surface-under-pointer (x y view)
  (find-if (lambda (surface)
	     (or (and (pointer-over-surface-p x y surface) ;; pointer is over client and has no input-region
		      (not (input-region surface)))
		 (and (pointer-over-surface-p x y surface) ;; or pointer is over client, has an input-region, and pointer is over input-region
		      (input-region surface)
		      (pointer-over-input-region-p x y surface))))
	   (surfaces view)))      

;; TODO: support input-region
(defun surface-quadrant (pointer-x pointer-y surface)
  (with-slots (x y width height input-region) surface
    (let ((half-width (round (/ width 2)))
	  (half-height (round (/ height 2))))
      (cond
	((and (<= pointer-x (+ x half-width)) (<= pointer-y (+ y half-height)))
	 :top-left)
	((and (>= pointer-x (+ x half-width)) (<= pointer-y (+ y half-height)))
	 :top-right)
	((and (>= pointer-x (+ x half-width)) (>= pointer-y (+ y half-height)))
	 :bottom-right)
	((and (<= pointer-x (+ x half-width)) (>= pointer-y (+ y half-height)))
	 :bottom-left)))))
      
