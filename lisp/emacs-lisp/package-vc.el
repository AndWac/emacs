;;; package-vc.el --- Manage packages from VC checkouts     -*- lexical-binding: t; -*-

;; Copyright (C) 2022 Free Software Foundation, Inc.

;; Author: Philip Kaludercic <philipk@posteo.net>
;; Keywords: tools

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; While packages managed by package.el use tarballs for distributing
;; the source code, this extension allows for packages to be fetched
;; and updated directly from a version control system.

;;; Code:

(require 'package)
(require 'lisp-mnt)
(require 'vc)

(defgroup package-vc nil
  "Manage packages from VC checkouts."
  :group 'package
  :version "29.1")

(defun package-vc-commit (pkg)
  "Extract the commit of a development package PKG."
  (cl-assert (eq (package-desc-kind pkg) 'vc))
  ;; FIXME: vc should be extended to allow querying the commit of a
  ;; directory (as is possible when dealing with git repositores).
  ;; This should be a fallback option.
  (cl-loop with dir = (package-desc-dir pkg)
           for file in (directory-files dir t "\\.el\\'" t)
           when (vc-working-revision file) return it
           finally return "unknown"))

(defun package-vc-version (pkg)
  "Extract the commit of a development package PKG."
  (cl-assert (eq (package-desc-kind pkg) 'vc))
  (cl-loop with dir = (package-desc-dir pkg) ;FIXME: dir is nil
           for file in (sort (directory-files dir t "\\.el\\'")
                             (lambda (s1 s2)
                               (< (length s1) (length s2))))
           when (with-temp-buffer
                  (insert-file-contents file)
                  (package-strip-rcs-id
                   (or (lm-header "package-version")
                       (lm-header "version"))))
           return it
           finally return "0"))

(defun package-vc-generate-description-file (pkg-desc pkg-file)
  "Generate a package description file for PKG-DESC.
The output is written out into PKG-FILE."
  (let* ((name (package-desc-name pkg-desc)))
    (let ((print-level nil)
          (print-quoted t)
          (print-length nil))
      (write-region
       (concat
        ";;; Generated package description from "
        (replace-regexp-in-string
         "-pkg\\.el\\'" ".el"
         (file-name-nondirectory pkg-file))
        "  -*- no-byte-compile: t -*-\n"
        (prin1-to-string
         (nconc
          (list 'define-package
                (symbol-name name)
                (cons 'vc (package-vc-version pkg-desc))
                (package-desc-summary pkg-desc)
                (let ((requires (package-desc-reqs pkg-desc)))
                  (list 'quote
                        ;; Turn version lists into string form.
                        (mapcar
                         (lambda (elt)
                           (list (car elt)
                                 (package-version-join (cadr elt))))
                         requires))))
          (package--alist-to-plist-args
           (package-desc-extras pkg-desc))))
        "\n")
       nil pkg-file nil 'silent))))

(defun package-vc-unpack (pkg-desc)
  "Install the package described by PKG-DESC."
  (let* ((name (package-desc-name pkg-desc))
         (dirname (package-desc-full-name pkg-desc))
         (pkg-dir (expand-file-name dirname package-user-dir)))
    (setf (package-desc-dir pkg-desc) pkg-dir)
    (when (file-exists-p pkg-dir)
      (if (yes-or-no-p "Overwrite previous checkout?")
          (delete-directory pkg-dir t)
        (error "There already exists a checkout for %s" name)))
    (pcase-let* ((attr (package-desc-extras pkg-desc))
                 (`(,backend ,repo ,dir ,branch)
                  (or (alist-get :upstream attr)
                      (error "Source package has no repository"))))
      (make-directory (file-name-directory pkg-dir) t)
      (unless (setf (car (alist-get :upstream attr))
                    (vc-clone backend repo pkg-dir))
        (error "Failed to clone %s from %s" name repo))
      (when-let ((rev (or (alist-get :rev attr) branch)))
        (vc-retrieve-tag pkg-dir rev))
      (when dir (setq pkg-dir (file-name-concat pkg-dir dir)))

      ;; In case the package was installed directly from source, the
      ;; dependency list wasn't know beforehand, and they might have
      ;; to be installed explicitly.
      (let (deps)
        (dolist (file (directory-files pkg-dir t "\\.el\\'" t))
          (with-temp-buffer
            (insert-file-contents file)
            (when-let* ((require-lines (lm-header-multiline "package-requires")))
              (thread-last
                (mapconcat #'identity require-lines " ")
                package-read-from-string
                package--prepare-dependencies
                (nconc deps)
                (setq deps)))))
        (dolist (dep deps)
          (cl-callf version-to-list (cadr dep)))
        (package-download-transaction
         (package-compute-transaction nil (delete-dups deps)))))

    (package-vc-generate-description-file
     pkg-desc (file-name-concat pkg-dir (package--description-file pkg-dir)))
    ;; Update package-alist.
    (let ((new-desc (package-load-descriptor pkg-dir)))
      ;; Activation has to be done before compilation, so that if we're
      ;; upgrading and macros have changed we load the new definitions
      ;; before compiling.
      (when (package-activate-1 new-desc :reload :deps)
        ;; FIXME: Compilation should be done as a separate, optional, step.
        ;; E.g. for multi-package installs, we should first install all packages
        ;; and then compile them.
        (package--compile new-desc)
        (when package-native-compile
          (package--native-compile-async new-desc))
        ;; After compilation, load again any files loaded by
        ;; `activate-1', so that we use the byte-compiled definitions.
        (package--reload-previously-loaded new-desc)))))

(defun package-vc-fetch (name-or-url &optional name rev)
  "Fetch the source of NAME-OR-URL.
If NAME-OR-URL is a URL, then the package will be downloaded from
the repository indicated by the URL.  The function will try to
guess the name of the package using `file-name-base'.  This can
be overridden by manually passing the optional NAME.  Otherwise
NAME-OR-URL is taken to be a package name, and the package
metadata will be consulted for the URL.  An explicit revision can
be requested using REV."
  (interactive
   (progn
     ;; Initialize the package system to get the list of package
     ;; symbols for completion.
     (package--archives-initialize)
     (let* ((input (completing-read
                    "Fetch package source (name or URL): "
                    package-archive-contents))
            (name (file-name-base input)))
       (list input (intern (string-remove-prefix "emacs-" name))))))
  (package--archives-initialize)
  (package-vc-unpack
   (cond
    ((and (stringp name-or-url)
          (url-type (url-generic-parse-url name-or-url)))
     (package-desc-create
      :name (or name (intern (file-name-base name-or-url)))
      :kind 'vc
      :extras `((:upstream . ,(list nil name-or-url nil nil))
                (:rev . ,rev))))
    ((when-let* ((desc (cadr (assoc name-or-url package-archive-contents
                                    #'string=)))
                 (spec (or (alist-get :vc (package-desc-extras desc))
                           (user-error "Package has no VC header"))))
       (unless (string-match
                (rx bos
                    (group (+ alnum))
                    (+ blank) (group (+ (not blank)))
                    (? (+ blank) (group (+ (not blank)))
                       (? (+ blank) (group (+ (not blank)))))
                    eos)
                spec)
         (user-error "Invalid repository specification %S" spec))
       (package-desc-create
        :name (if (stringp name-or-url)
                  (intern name-or-url)
                name-or-url)
        :kind 'vc
        :extras `((:upstream . ,(list (intern (match-string 1 spec))
                                      (match-string 2 spec)
                                      (match-string 3 spec)
                                      (match-string 4 spec)))
                  (:rev . ,rev)))))
    ((user-error "Unknown package to fetch: %s" name-or-url)))))

;;;###autoload
(defalias 'package-checkout #'package-vc-fetch)

(provide 'package-vc)
;;; package-vc.el ends here
