;;; snippet.el --- yasnippet's snippet engine distilled  -*- lexical-binding: t; -*-

;; Copyright (C) 2013  João Távora

;; Author: João Távora <joaotavora@gmail.com>
;; Keywords: convenience

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;;

;;; Code:

(eval-when-compile (require 'cl))


(cl-defstruct (snippet--field (:constructor snippet--make-field ()))
  name
  start end
  parent-field
  (mirrors '())
  next-field
  prev-field)

(defun snippet--init-field (object name start end parent-field mirrors next-field prev-field)
  (setf (snippet--field-name object) name
        (snippet--field-start object) start
        (snippet--field-end object) end
        (snippet--field-parent-field object) parent-field
        (snippet--field-mirrors object) mirrors
        (snippet--field-next-field object) next-field
        (snippet--field-prev-field object) prev-field))

(cl-defstruct (snippet--mirror (:constructor snippet--make-mirror ()))
  source
  start end
  (transform nil)
  parent-field)

(defun snippet--init-mirror (object source start end transform parent-field)
  (setf (snippet--mirror-source object) source
        (snippet--mirror-start object) start
        (snippet--mirror-end object) end
        (snippet--mirror-transform object) transform
        (snippet--mirror-parent-field object) parent-field))

(defgroup snippet nil
  "Customize snippet features"
  :group 'convenience)

(defface snippet-field-face
  '((t (:inherit 'region)))
  "Face used to highlight the currently active field of a snippet"
  :group 'snippet)

(defvar snippet-field-keymap
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "<tab>")       'snippet-next-field)
    (define-key map (kbd "S-<tab>")     'snippet-prev-field)
    map)
  "The active keymap while a snippet expansion is in progress.")

(defvar snippet--field-overlay nil)

(defun snippet-next-field (&optional prev)
  (interactive)
  (let ((field (overlay-get snippet--field-overlay 'snippet--field)))
    (cond (prev
           (if (snippet--field-prev-field field)
               (snippet--move-to-field (snippet--field-prev-field field))
             (goto-char (snippet--field-start field))
             (snippet-exit-snippet)))
          (t
            (if (snippet--field-next-field field)
                (snippet--move-to-field (snippet--field-next-field field))
              (goto-char (snippet--field-end field))
              (snippet-exit-snippet))))))

(defun snippet-prev-field ()
  (interactive)
  (snippet-next-field t))

(defun snippet-exit-snippet (&optional reason)
  (delete-overlay snippet--field-overlay)
  (message "snippet exited%s"
           (or (and reason
                    (format " (%s)" reason))
               "")))

(defun snippet--make-marker ()
  (let ((marker (make-marker)))
    (set-marker-insertion-type marker t)
    (set-marker marker (point))))

(defmacro snippet--with-current-object (object &rest body)
  (declare (indent defun) (debug t))
  `(snippet--call-with-current-object ,object #'(lambda () ,@body)))

(defun snippet--object-start-marker (field-or-mirror)
  (cond ((snippet--field-p field-or-mirror)
         (snippet--field-start field-or-mirror))
        ((snippet--mirror-p field-or-mirror)
         (snippet--mirror-start field-or-mirror))))

(defun snippet--object-end-marker (field-or-mirror)
  (cond ((snippet--field-p field-or-mirror)
         (snippet--field-end field-or-mirror))
        ((snippet--mirror-p field-or-mirror)
         (snippet--mirror-end field-or-mirror))))

(defun snippet--call-with-current-object (object fn)
  (let* ((start (snippet--object-start-marker object))
         (end (snippet--object-end-marker object)))
    (unwind-protect
        (progn
          (set-marker-insertion-type start nil)
          (set-marker-insertion-type end t)
          (funcall fn))
      (set-marker-insertion-type start t)
      (set-marker-insertion-type end nil))))

(defun snippet--insert-field (field text)
  (when text
    (snippet--with-current-object field
      (insert text))))

(defun snippet--insert-mirror (mirror)
  (snippet--update-mirror mirror))

(defun snippet--update-mirror (mirror)
  (snippet--with-current-object mirror
    (delete-region (snippet--object-start-marker mirror)
                   (snippet--object-end-marker mirror))
    (save-excursion
      (goto-char (snippet--object-start-marker mirror))
      (insert (funcall (snippet--mirror-transform mirror))))))

(defun snippet--move-to-field (field)
  (goto-char (snippet--object-start-marker field))
  (move-overlay snippet--field-overlay
                (point)
                (snippet--object-end-marker field))
  (overlay-put snippet--field-overlay 'snippet--field field))

(defun snippet--field-overlay-changed (overlay after? _beg _end &optional _length)
  (let* ((field (overlay-get overlay 'snippet--field))
         (inhibit-modification-hooks t))
    (cond (after?
           (set-marker-insertion-type (snippet--field-start field) t)
           (set-marker-insertion-type (snippet--field-end field) nil)
           (mapc #'snippet--update-mirror (snippet--field-mirrors field)))
          (t
           (set-marker-insertion-type (snippet--field-start field) nil)
           (set-marker-insertion-type (snippet--field-end field) t)))))

(defun snippet--field-text (field)
  (buffer-substring-no-properties (snippet--field-start field)
                                  (snippet--field-end field)))

(defvar snippet--debug nil)
;; (setq snippet--debug t)

(defun snippet--post-command-hook ()
  (cond ((and snippet--field-overlay
              (overlay-buffer snippet--field-overlay))
         (cond ((or (< (point)
                       (overlay-start snippet--field-overlay))
                    (> (point)
                       (overlay-end snippet--field-overlay)))
                (snippet-exit-snippet "point left snippet")
                (remove-hook 'post-command-hook 'snippet--post-command-hook t))
               (snippet--debug
                (snippet--debug-snippet snippet--field-overlay))))
        (snippet--field-overlay
         ;; snippet must have been exited for some other reason
         ;;
         (remove-hook 'post-command-hook 'snippet--post-command-hook t))))

(defun snippet--debug-snippet (field-overlay)
  (let ((buffer (current-buffer)))
    (cl-flet ((describe-field
               (field)
               (with-current-buffer buffer
                 (format "active field overlay %s from %s to %s covering \"%s\", with %s mirrors"
                         (snippet--field-name field)
                         (marker-position (snippet--field-start field))
                         (marker-position (snippet--field-end field))
                         (buffer-substring-no-properties (snippet--field-start field)
                                                         (snippet--field-end field))
                         (length (snippet--field-mirrors field)))))
              (describe-mirror
               (mirror)
               (with-current-buffer buffer
                   (format "  mirror from %s to %s covering \"%s\""
                           (marker-position (snippet--mirror-start mirror))
                           (marker-position (snippet--mirror-end mirror))
                           (buffer-substring-no-properties (snippet--mirror-start mirror)
                                                           (snippet--mirror-end mirror))))))
      (with-current-buffer (get-buffer-create "*snippet-debug*")
        (let ((inhibit-read-only t))
          (erase-buffer)
          (let ((active-field (overlay-get field-overlay 'snippet--field)))
            (loop for object in (overlay-get field-overlay 'snippet--objects)
                  when (snippet--field-p object)
                  do
                  (insert (describe-field object))
                  (when (eq object active-field) (insert "*ACTIVE*"))
                  (insert "\n")
                  (loop for mirror in (snippet--field-mirrors object)
                        do (insert (describe-mirror mirror)
                                   "\n")))))
        (display-buffer (current-buffer))))))



;;; the define-snippet macro and its helpers
;;;


(defun snippet--form-field-p (form)
  (and (consp form) (eq (car form) 'field)))
(defun snippet--form-mirror-p (form)
  (and (consp form) (eq (car form) 'mirror)))
(defun snippet--form-make-field-sym (field-name &optional parent-field-sym)
  (make-symbol (format "field-%s%s" field-name
                       (if parent-field-sym
                           (format "-son-of-%s" parent-field-sym)
                         ""))))
(defun snippet--form-make-mirror-sym (mirror-name source-field-name &optional parent-field-sym)
  (make-symbol (format "mirror-%s-of-%s%s" mirror-name source-field-name
                       (if parent-field-sym
                           (format "-son-of-%s" parent-field-sym)
                         ""))))

(defvar snippet--marker-sym-obarray (make-vector 100 nil))

(defun snippet--start-marker-name (sym)
  (intern (format "%s-beg" sym) snippet--marker-sym-obarray))

(defun snippet--end-marker-name (sym)
  (intern (format "%s-end" sym) snippet--marker-sym-obarray))

(defvar snippet--form-mirror-sym-idx nil)

(defun snippet--form-sym-tuples (forms &optional parent-field-sym)
  "Produce information for composing the snippet expansion function.

A tuple of 6 elements is created for each form in FORMS.

\(SYM FORM PARENT-FIELD-SYM ADJACENT-PREV-SYM PREV-FORM NEXT-FORM)

Forms representing fields with nested elements are recursively
iterated depth-first, resulting in a flattened list."
  (loop with snippet--form-mirror-sym-idx = (or snippet--form-mirror-sym-idx
                                                0)
        with adjacent-prev-sym

        for prev-form in (cons nil forms)
        for form in forms
        for next-form in (append (rest forms) (list nil))

        for (sym childrenp) = (cond ((snippet--form-field-p form)
                                     (list (snippet--form-make-field-sym (second form)
                                                                         parent-field-sym)
                                           (listp (third form))))
                                    ((snippet--form-mirror-p form)
                                     (incf snippet--form-mirror-sym-idx)
                                     (list (snippet--form-make-mirror-sym snippet--form-mirror-sym-idx
                                                                          (second form)
                                                                          parent-field-sym))))
        append (cond (sym
                      `((,sym
                         ,form
                         ,parent-field-sym
                         ,adjacent-prev-sym
                         ,prev-form
                         ,next-form)
                        ,@(when childrenp
                            (snippet--form-sym-tuples (third form) sym))))

                     ((or (stringp form)
                          (symbolp form)
                          (eq (car form) 'lambda))
                      `((ignore ,form ,parent-field-sym))))
        do (setq adjacent-prev-sym sym)))

(defun snippet--make-marker-init-forms (tuples)
  "Make marker init forms for the snippet objects in TUPLES.

Imagine this snippet:

 ff1 sss mm1 ff2         mm5
              |
              ff3 sss mm4

I would need these somewhere in the let* form

 ((ff1-beg (make-marker))
  (ff1-end (make-marker))
  (mm1-beg (make-marker))
  (mm1-end (make-marker))
  (ff2-beg mm1-end)
  (ff2-end (make-marker))
  (ff3-beg ff2-end)
  (ff3-end (make-marker))
  (mm4-beg (make-marker))
  (mm4-end ff2-end)
  (mm5-beg ff2-end)
  (mm5-end (make-marker)))
"
  (loop for (sym nil parent-sym adjacent-prev-sym prev next) in tuples
        unless (eq sym 'ignore)
        append `((,(snippet--start-marker-name sym)
                  ,(or (and adjacent-prev-sym
                            (snippet--end-marker-name adjacent-prev-sym))
                       (and parent-sym
                            (not prev)
                            (snippet--start-marker-name parent-sym))
                       `(snippet--make-marker)))
                 (,(snippet--end-marker-name sym)
                  ,(or (and parent-sym
                            (not next)
                            (snippet--end-marker-name parent-sym))
                       `(snippet--make-marker))))))


(defun snippet--first-field-sym (tuples)
  (first (cl-find-if #'snippet--form-field-p tuples :key #'second)))


(defun snippet--init-field-and-mirror-forms (tuples)
  (let* ((field-mirrors (make-hash-table))
         ;; we first collect `snippet--make-mirror' forms. When
         ;; collecting them, we populate the `field-mirrors' table...
         ;;
         (make-mirror-forms
          (loop for (sym form parent-sym) in tuples
                when (snippet--form-mirror-p form)
                collect (let ((source-sym nil))
                          (loop for (sym-b form-b) in tuples
                                when (and
                                      (snippet--form-field-p form-b)
                                      (eq (second form)
                                          (second form-b)))
                                do
                                (setq source-sym sym-b)
                                (puthash source-sym (cons sym (gethash source-sym field-mirrors)) field-mirrors))
                          (unless source-sym
                            (error "mirror definition %s mentions unknown field" form))
                          `((,sym (snippet--make-mirror))
                            (snippet--init-mirror ,sym
                                                  ,source-sym
                                                  ,(snippet--start-marker-name sym)
                                                  ,(snippet--end-marker-name sym)
                                                  ,(snippet--transform-lambda (third form) source-sym)
                                                  ,parent-sym)))))
         ;; so that we can now create `snippet--make-field' forms with
         ;; complete lists of mirror symbols.
         ;;
         (make-field-forms
          (loop with field-tuples = (cl-remove-if-not #'snippet--form-field-p tuples :key #'second)
                for (prev-sym) in (cons nil field-tuples)
                for (sym form parent-sym) in field-tuples
                for (next-sym) in (append (rest field-tuples) (list nil))
                collect `((,sym (snippet--make-field))
                          (snippet--init-field ,sym
                                               ,(second form)
                                               ,(snippet--start-marker-name sym)
                                               ,(snippet--end-marker-name sym)
                                               ,parent-sym
                                               (list ,@(gethash sym field-mirrors))
                                               ,next-sym
                                               ,prev-sym)))))

    (append make-field-forms
            make-mirror-forms)))

(defun snippet--transform-lambda (transform-form source-sym)
  `(lambda ()
     (funcall
      #'(lambda (field-text)
          ,(or transform-form
               'field-text))
      (snippet--field-text ,source-sym))))


(defmacro define-snippet (name _args &rest body)
  "Define NAME as a snippet.

NAME's function definition is set to a function with no arguments
that inserts the fields components at point.

Each form in BODY can be:

* A cons (field FIELD-NAME FIELD-VALUE FIELD-TRANSFORM)
  definining a snippet field. A snippet field can be navigated to
  using `snippet-next-field' and
  `snippet-prev-field'. FIELD-TRANSFORM is currently
  unimplemented.

* A cons (mirror FIELD-NAME MIRROR-TRANSFORM) defining a mirror
  of the field named FIELD-NAME. Each time the text under the
  field changes, the form MIRROR-TRANSFORM is invoked with the
  variable `field-text' set to the text under the field. The
  string produced become the text under the mirror.

* A string literal which is inserted as a literal part of the
  snippet and remains unchanged while the snippet is navigated.

* A symbol designating a function which is called when the
  snippet is inserted. The string produced is treated as a
  literal string.

* A lambda form taking no arguments, called when the snippet is
  inserted. Again, the string produced is treated as a literal
  snippet string.

ARGS is an even-numbered property list of (KEY VAL) pairs. KEY
can be:

* the symbol `:obarray', in which case the symbol NAME in
  interned in the obarray VAL instead of the global obarray. This
  options is currently unimplemented."
  (let* ((sym-tuples (snippet--form-sym-tuples body))
         (marker-init-forms (snippet--make-marker-init-forms sym-tuples))
         (init-object-forms (snippet--init-field-and-mirror-forms sym-tuples))
         (first-field-sym (snippet--first-field-sym sym-tuples)))
    `(let ((insert-snippet-fn
            #'(lambda ()
                (let* (,@(mapcar #'first init-object-forms)
                       ,@marker-init-forms)

                  ,@(mapcar #'second init-object-forms)

                  ,@(loop
                     for (sym form)           in sym-tuples
                     collect (cond ((snippet--form-field-p form)
                                    `(snippet--insert-field ,sym ,(if (stringp (third form))
                                                                      (third form))))
                                   ((snippet--form-mirror-p form)
                                    `(snippet--insert-mirror ,sym))
                                   ((stringp form)
                                    `(insert ,form))
                                   ((functionp form)
                                    `(insert (funcall ,form)))))

                  (setq snippet--field-overlay
                        (make-overlay (point) (point) nil nil nil))
                  (overlay-put snippet--field-overlay
                               'face
                               'snippet-field-face)
                  (overlay-put snippet--field-overlay
                               'modification-hooks
                               '(snippet--field-overlay-changed))
                  (overlay-put snippet--field-overlay
                               'insert-in-front-hooks
                               '(snippet--field-overlay-changed))
                  (overlay-put snippet--field-overlay
                               'insert-behind-hooks
                               '(snippet--field-overlay-changed))
                  (overlay-put snippet--field-overlay
                               'keymap
                               snippet-field-keymap)
                  (overlay-put snippet--field-overlay
                               'snippet--objects
                               (list ,@(remove 'ignore (mapcar #'first sym-tuples))))
                  ,(if first-field-sym
                       `(snippet--move-to-field ,first-field-sym))
                  (add-hook 'post-command-hook 'snippet--post-command-hook t t)
                  (snippet--post-command-hook)))))
       (defun ,name ()
         (funcall insert-snippet-fn)))))


;;; some basic test snippets

(define-snippet test ()
  "some string" buffer-file-name)


(define-snippet printf ()
  "printf (\""
  (field 1 "%s")
  (mirror 1 (if (string-match "%" field-text) "\"," "\);"))
  (field 2)
  (mirror 1 (if (string-match "%" field-text) "\);" "")))

(define-snippet foo ()
  (field 1 "bla")
  "ble"
  (mirror 1)
  (field 2
         ((field 3 "fonix")
          "fotrix"
          (mirror 1 (concat field-text "qqcoisa"))))
  "end")

(defun test ()
  (interactive)
  (with-current-buffer (switch-to-buffer (get-buffer-create "*test*"))
    (erase-buffer)
    (printf)))


(provide 'snippet)

;;; Local Variables:
;;; lexical-binding: t
;;; End:
;;; snippet.el ends here