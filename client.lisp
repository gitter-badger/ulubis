
(in-package :ulubis)

#|
(defclass surface-texture ()
  ((width :accessor width :initarg :width :initform 0)
   (height :accessor height :initarg :width :initform 0)))
|#

(defclass rect ()
  ((x :accessor x :initarg :x :initform 0)
   (y :accessor y :initarg :y :initform 0)
   (width :accessor width :initarg :width :initform 0)
   (height :accessor height :initarg :height :initform 0)
   (operation :accessor operation :initarg :operation :initform nil)))

(defclass region ()
  ((->region :accessor ->region :initarg :->region :initform nil)
   (rects :accessor rects :initarg :rects :initform nil)))

(defun find-region (->region client)
  (find-if (lambda (region)
	     (and (pointerp (->region region)) (pointer-eq (->region region) ->region)))
	   (regions client)))

(defclass surface ()
  ((client :accessor client :initarg :client :initform nil)
   (->surface :accessor ->surface :initarg :->surface :initform nil)
   (->frame-callback :accessor ->frame-callback :initarg :->frame-callback :initform nil)
   (->xdg-surface :accessor ->xdg-surface :initarg :->xdg-surface :initform nil)
   (->xdg-popup :accessor ->xdg-popup :initarg :->xdg-popup :initform nil)
   (->buffer :accessor ->buffer :initarg :->buffer :initform nil)
   (texture :accessor texture :initarg :texture :initform nil)
   (x :accessor x :initarg :x :initform 0)
   (y :accessor y :initarg :y :initform 0)
   (width :accessor width :initarg :width :initform 0)
   (height :accessor height :initarg :height :initform 0)
   (scale-x :accessor scale-x :initarg :scale-x :initform 1.0)
   (scale-y :accessor scale-y :initarg :scale-y :initform 1.0)
   (committed :accessor committed :initarg :committed :initform nil)
   (cursor? :accessor cursor? :initarg :cursor? :initform nil)
   (input-region :accessor input-region :initarg :input-region :initform nil)
   (opaque-region :accessor opaque-region :initarg :opaque-region :initform nil)))

(defclass client ()
  ((->client :accessor ->client :initarg :->client :initform nil)
   (regions :accessor regions :initarg :regions :initform nil)
   (->pointer :accessor ->pointer :initarg :->pointer :initform nil)
   (->keyboard :accessor ->keyboard :initarg :->keyboard :initform nil)))

(defun accepts-pointer-events? (surface)
  (and surface (not (cursor? surface)) (->pointer (client surface))))