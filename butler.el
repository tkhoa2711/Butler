;; -*- lexical-binding: t -*-
;;; butler.el --- Client for Jenkins

;; Copyright © 2012-2013 Ashton Kemerling
;;
;; Author: Ashton Kemerling <ashtonkemerling@gmail.com>
;; URL: http://www.github.com/AshtonKem/Butler.git
;; Version: 0.1.3
;; Keywords: Jenkins, Hudson, CI
;; Package-Requires: ((deferred) (json "1.2"))

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Provides an interface to connect to the Jenkins CI server


;;; Code:
(eval-when-compile (require 'cl))

(require 'json)
(require 'deferred)
(require 'url)
(require 'butler-servers)
(require 'butler-util)
(require 'widget)


(defun butler-buffer ()
  (get-buffer-create "*butler-status*"))

(defvar butler-mode-map
  (let ((map (make-keymap)))
    (define-key map (kbd "g") 'butler-refresh)
    (define-key map (kbd "t") 'trigger-butler-job)
    (define-key map (kbd "h") 'hide-butler-job)
    map))


(define-derived-mode butler-mode fundamental-mode "Butler"
  "A major mode for interacting with various CI servers"
  (use-local-map butler-mode-map))

(defun parse-job-parameters (job)
  "Return a hash containing all the parameters for a job"
  (let ((properties (cdr (assoc 'property job)))
        (parameters-hash (make-hash-table :test #'equal)))
    (when (> (length properties) 0)
      (mapc
       (lambda (property)
         (let ((parameter-definitions (cdr (assoc 'parameterDefinitions property))))
           (when parameter-definitions
               (mapc
                (lambda (parameter)
                  (let* ((working-hash (make-hash-table :test #'equal))
                         (description (cdr (assoc 'definition parameter)))
                         (name (cdr (assoc 'name parameter)))
                         (type (cdr (assoc 'type parameter)))
                         (choices (cdr (assoc 'choices parameter)))
                         (defaults (cdr (assoc 'defaultParameterValue parameter))))
                    (puthash 'name name working-hash)
                    (puthash 'description description working-hash)
                    (cond
                     ((equal type "ChoiceParameterDefinition")
                      (progn
                          (puthash 'default (cdr (assoc 'value defaults)) working-hash)
                          (puthash 'choices choices working-hash)
                          (puthash 'type 'choice working-hash)))
                     ((equal type "StringParameterDefinition")
                      (puthash 'type 'string working-hash))
                     ((equal type "TextParameterDefinition")
                      (puthash 'type 'text working-hash))
                     ((equal type "BooleanParameterDefinition")
                      (progn
                        (puthash 'type 'bool working-hash)
                        (unless (equal (cdr (assoc 'value defaults)) :json-false)
                            (puthash 'default t working-hash)))))
                    (puthash name working-hash parameters-hash)))
                parameter-definitions))))
       properties)
      parameters-hash)))

(defun refresh-butler-status (callback)
  (prepare-servers)
  (let ((count 0))
    (maphash (lambda (_server-name server)
               (let* ((url-request-method "GET")
                      (base-url (gethash 'url server))
                      (auth (gethash 'auth server))
                      (url-request-extra-headers
                       `(("Authorization" . ,auth)
                         ("Content-Type" . "application/json"))))
                 (incf count)
                 (if (not (gethash 'jobs server))
                     (puthash 'jobs (make-hash-table :test #'equal) server))
                           (deferred:$
                             (deferred:url-retrieve (concat
                                                     (if (string= "/" (substring base-url (- (length base-url) 1)))
                                                         (substring base-url 0 (- (length base-url) 1))
                                                       base-url)
                                                     "/api/json?tree=jobs[name,inQueue,color,url,property[parameterDefinitions[defaultParameterValue[name,value],name,choices,type]],lastBuild[building,duration,estimatedDuration,timestamp,executor[likelyStuck]]]"))
                             (deferred:nextc it
                               (lambda (buf)
                                 (with-current-buffer buf
                                   (beginning-of-buffer)
                                   (search-forward "{")
                                   (let* ((data (buffer-substring (- (point) 1) (point-max)))
                                          (parsed (json-read-from-string data)))
                                     (mapc (lambda (job)
                                             (let* ((hash (or (gethash (cdr (assoc 'name job))
                                                                       (gethash 'jobs server))
                                                              (make-hash-table :test #'equal)))
                                                    (last-build (cdr (assoc 'lastBuild job)))
                                                    (parameters (parse-job-parameters job))
                                                    (executor (cdr (assoc 'likelyStuck last-build))))
                                               (puthash 'parameters parameters
                                                        hash)
                                               (puthash 'color (cdr (assoc 'color job))
                                                        hash)
                                               (puthash 'name (cdr (assoc 'name job))
                                                        hash)
                                               (puthash 'in-queue (equal t (cdr (assoc 'inQueue job)))
                                                        hash)
                                               (puthash 'url (cdr (assoc 'url job))
                                                        hash)
                                               (puthash 'building (equal t (cdr (assoc 'building last-build)))
                                                        hash)
                                               (puthash 'likely-stuck (equal t (cdr (assoc 'likelyStuck executor)))
                                                        hash)
                                               (puthash 'timestamp (cdr (assoc 'timestamp last-build))
                                                        hash)
                                               (puthash 'expected-duration (cdr (assoc 'estimatedDuration last-build))
                                                        hash)
                                               (puthash (cdr (assoc 'name job))
                                                        hash
                                                        (gethash 'jobs server))))
                                           (cdr (assoc 'jobs parsed)))))
                                 (if (= count (hash-table-count butler-hash))
                                     (funcall callback))
                                 (kill-buffer buf))))))
             butler-hash)))




(defun parse-jobs (data)
  (let* ((parsed (json-read-from-string data))
	 (jobs (cdr (assoc 'jobs parsed))))
    jobs))


(defun find-current-job ()
  (with-current-buffer (butler-buffer)
    (condition-case nil
        (let* ((line-start (line-beginning-position))
               (line-end (line-end-position))
               (line (substring-no-properties (buffer-substring line-start line-end))))
          (if (string-match "^    ●\\(    Waiting   \\|              \\| |\\(\\+\\| \\)\\{10\\}| \\)\\(.*\\)$" line)
              (match-string 3 line))))))

(defun find-current-server (job-name)
  (let ((matches nil)
        (distances nil))
    (maphash (lambda (name server)
               (if (gethash job-name (gethash 'jobs server))
                   (push name matches)))
             butler-hash)
    (if (= 1 (length matches))
        (car matches)
      (with-current-buffer (butler-buffer)
        (setq distances
              (mapcar (lambda (name)
                        (let ((location (save-excursion
                                          (search-backward-regexp
                                           (concat "^" name) nil t))))
                          (if location
                              (- (point) location)
                            -1)))
                      matches))
        (let ((current-index 0)
              (best-index nil)
              (best-value nil))
          (mapc (lambda (value)
                  (if (and (> value 0)
                           (or (not best-value)
                               (< value best-value)))
                      (progn
                        (setq best-index current-index)
                        (setq best-value value)))
                  (incf current-index))
                distances)
          (if (integerp best-index)
              (nth best-index matches)))))))



(defun trigger-butler-job ()
  (interactive)
  (with-current-buffer (butler-buffer)
    (let* ((job-name (find-current-job))
           (server-name (find-current-server job-name))
           (server (get-server server-name))
           (job (get-job server job-name))
           (url (gethash 'url job))
           (auth (gethash 'auth server))
           (parameters (gethash 'parameters job))
           (url-request-extra-headers `(("Authorization" . ,auth))))
      (when (and url auth)
        (if (not parameters)
            (deferred:$
              (deferred:url-retrieve (concat url "build/"))
              (deferred:nextc it
                (lambda (buf)
                  (kill-buffer buf))))
          (let ((old-window (selected-window))
                (widgets (make-hash-table :test #'equal)))
            (select-window (minibuffer-window))
            (kill-all-local-variables)
            (make-local-variable 'widget-example-repeat)
            (let ((inhibit-read-only t))
              (erase-buffer))
            (remove-overlays)
            (widget-insert "Triggering a parameterized job\n")
            (maphash (lambda (key parameter)
                       (let ((type (gethash 'type parameter))
                             (name (gethash 'name parameter))
                             (default (gethash 'name parameter))
                             (choices (gethash 'choices parameter))
                             (description (gethash 'description parameter)))
                         (widget-insert (concat name ": "))
                         (puthash name (cond
                                        ((equal type 'choice)
                                         (progn
                                           (widget-insert "\n")
                                           (apply #'widget-create 'radio-button-choice
                                                  :name name
                                                  :value default
                                                  (mapcar (lambda (choice)
                                                            (list 'item choice))
                                                          choices))))
                                        ((equal type 'bool)
                                         (widget-create 'toggle
                                                        :name name))
                                        ((equal type 'string)
                                         (widget-create 'editable-field
                                                        :name name
                                                        (or default "")))
                                        ((equal type 'text)
                                         (widget-create 'text
                                                        (or default ""))))
                                  widgets)))
                     parameters)
            (widget-create 'push-button
                           :notify (lambda (&rest ignore)
                                     (print "hello")
                                     (let ((url-parameters '()))
                                       (maphash (lambda (name widget)
                                                   (push
                                                    (cond
                                                     ((equal (widget-value widget) t)
                                                      (concat name "=" "true"))
                                                     ((equal (widget-value widget) nil)
                                                      (concat name "=" "false"))
                                                     (t
                                                      (concat name "=" (url-hexify-string (widget-value widget)))))
                                                   url-parameters))
                                                widgets)
                                       (print (concat "Contacting " url "buildWithParameters?"  (join-string url-parameters "&")))
                                        (deferred:$
                                          (deferred:url-retrieve (concat url "buildWithParameters?" (join-string url-parameters "&")))
                                          (deferred:nextc it
                                            (lambda (buf)
                                              (kill-buffer buf))))
                                        (select-window (minibuffer-window))
                                        (let ((inhibit-read-only t))
                                          (erase-buffer))
                                        (select-window old-window)))
                           "Submit")
            (widget-insert " ")
            (widget-create 'push-button
                           :notify (lambda (&rest ignore)
                                     (select-window (minibuffer-window))
                                     (let ((inhibit-read-only t))
                                       (erase-buffer))
                                     )
                           "Cancel")
            (use-local-map widget-keymap)
            (widget-setup)))))))


(defun hide-butler-job ()
  (interactive)
  (with-current-buffer (butler-buffer)
    (let* ((job-name (find-current-job))
           (server-name (find-current-server job-name))
           (server (get-server server-name))
           (job (get-job server job-name)))
      (if job
          (progn (puthash 'hidden t job)
                 (butler-refresh))))))

(defun generate-progress-string (timestamp expected)
  (let* ((current-time (string-to-number (format-time-string "%s")))
         (milliseconds (* current-time 1000))
         (duration (- milliseconds timestamp))
         (percentage (min
                      (/ (float duration)
                         expected)
                      1.0))
         (rounded (floor (* 10 percentage))))
    (concat " |"
            (make-string rounded ?+)
            (make-string (- 10 rounded) ?\ )
            "| ")))



(defun draw-jobs (jobs target-buffer callback)
  (with-current-buffer target-buffer
    (maphash (lambda (name job)
               (let* ((inhibit-read-only t)
                      (color (gethash 'color job))
                      (building (gethash 'building job nil))
                      (likely-stuck (gethash 'likely-stuck job nil))
                      (in-queue (gethash 'in-queue job nil))
                      (timestamp (gethash 'timestamp job))
                      (expected-duration (gethash 'expected-duration job))
                      (hidden (gethash 'hidden job)))
                 (unless hidden
                   (insert "    ")
                   (insert (colorize-dot color) )
                   (if building
                       (if likely-stuck
                           (insert (propertize (generate-progress-string timestamp expected-duration)
                                               'face '(:foreground "res")))
                         (insert (generate-progress-string timestamp expected-duration) ))
                     (if in-queue
                         (insert "    Waiting   ")
                       (insert "              ")))
                   (insert name)
                   (insert "\n"))))
             jobs)
    (funcall callback)))






(defun draw-butler (buffer callback)
  (with-current-buffer buffer
    (let ((inhibit-read-only t)
          (count 0)
          (total-size (- (hash-table-count butler-hash) 1)))
      (maphash (lambda (_server-name server)
                 (let* ((name (gethash 'name server))
                        (inhibit-read-only t)
                        (address (gethash 'url server))
                        (auth (gethash 'auth server))
                        (jobs (gethash 'jobs server)))
                   (goto-char (point-max))
                   (insert (concat name " (" (org-link-unescape address) "): "))
                   (insert (propertize (concat "auth: "
                                               auth)
                                       'invisible t))
                   (insert "\n")
                   (draw-jobs jobs buffer
                              (if (= count total-size)
                                  callback
                                (lambda ())))
                   (incf count)))
               butler-hash))))


;;;###autoload
(defun butler-status ()
  (interactive)
  (butler-refresh)
  (switch-to-buffer (butler-buffer))
  (butler-mode))

(defun butler-refresh ()
  (interactive)
  (refresh-butler-status
   (lambda ()
     (let ((target-point nil)
           (target-buffer (generate-new-buffer "temp")))
       (with-current-buffer (butler-buffer)
         (setq target-point (or (point) 0)))
       (draw-butler target-buffer (lambda ()
                                    (let ((results (buffer-string))
                                          (inhibit-read-only t))
                                      (with-current-buffer (butler-buffer)
                                        (erase-buffer)
                                        (insert results)
                                        (goto-char target-point)
                                        (setq buffer-read-only t))
                                      (kill-buffer target-buffer))))))))


(provide 'butler)


;;; butler.el ends here
