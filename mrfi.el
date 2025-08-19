;;; mrfi.el --- Multi-root file index for Emacs -*- lexical-binding: t; -*-

;; Author: Michele Di Maio Fediverse: micheledm@mastodon.uno
;; Version: 0.4
;; Package-Requires: ((emacs "27.1"))
;; Keywords: files, convenience
;; URL: https://github.com/micheledm/emacs-mrfi
;; License: GPL-3.0-or-later

;;; Commentary:
;;
;; MRFI (Multi-Root File Index) lets you consolidate multiple directories
;; into a single file index, searchable via minibuffer or displayed in a
;; tabulated buffer. Useful when you want a unified view of notes, org files,
;; or any project spread across multiple roots.
;;
;; Features:
;; - Multiple root directories with short aliases.
;; - Index restricted by file extensions.
;; - Uses `fd` if available (fast), otherwise falls back to native Elisp.
;; - Minibuffer candidate view with aligned columns:
;;   Name · Alias · Size · ISO date · Relative path
;; - Consult integration if installed.
;;
;; Main commands:
;; - `mrfi-find-file`   : Fuzzy search & open file from the index.
;; - `mrfi-list`        : Show full index in a tabulated buffer.
;; - `mrfi-refresh-index`: Rebuild the index.

;;; Code:

(require 'tabulated-list)
(require 'cl-lib)
(eval-when-compile (require 'subr-x))

(defgroup mrfi nil
  "Multi-root file index."
  :group 'convenience)

;;; User options

(defcustom mrfi-sources nil
  "Alist of (ROOT . ALIAS).  
ROOT is a directory path, ALIAS is a short label.

Example:
  '((\"~/Sync/obsidian/\" . \"Obsidian\")
    (\"~/Sync/org/\"      . \"Org\"))"
  :type '(alist :key-type directory :value-type string))

(defcustom mrfi-extensions '("md" "org" "txt" "el")
  "File extensions to include (without dot).  
Nil or empty means all files are included."
  :type '(repeat string))

(defcustom mrfi-use-fd t
  "If non-nil, use external `fd` for indexing if available."
  :type 'boolean)

(defcustom mrfi-extra-fd-args '("--hidden" "--type" "f" "--color" "never")
  "Extra arguments passed to fd."
  :type '(repeat string))

(defcustom mrfi-search-in-path nil
  "If non-nil, completion also searches in alias + relative path.
If nil, only the filename is matched."
  :type 'boolean)

;;; Faces

(defface mrfi-name-face  '((t :inherit font-lock-keyword-face))  "Face for filenames.")
(defface mrfi-size-face  '((t :inherit font-lock-constant-face)) "Face for file size.")
(defface mrfi-date-face  '((t :inherit font-lock-string-face))   "Face for dates.")
(defface mrfi-alias-face '((t :inherit font-lock-type-face))     "Face for aliases.")
(defface mrfi-path-face  '((t :inherit font-lock-comment-face))  "Face for relative paths.")

;;; Internal state

(defvar mrfi--cache nil)
(defvar mrfi--last-built nil)
(defvar mrfi--list-buffer "*MRFI*")

;;; Root helpers

(defun mrfi--roots ()
  (mapcar (lambda (cell) (expand-file-name (car cell))) mrfi-sources))

(defun mrfi--fd-available-p () (and mrfi-use-fd (executable-find "fd")))

(defun mrfi--extensions-to-fd-args ()
  (if (null mrfi-extensions) '()
    (apply #'append (mapcar (lambda (e) (list "--extension" e)) mrfi-extensions))))

(defun mrfi--extensions-regexp ()
  "Return a regexp that matches allowed file extensions.
If `mrfi-extensions' is nil, return nil to match all files.
This forms a strict whitelist so files like `foo.org~' are ignored."
  (when mrfi-extensions
    (concat "\\." (regexp-opt (mapcar #'downcase mrfi-extensions)) "$")))

(defun mrfi--build-with-fd ()
  (let ((args (append mrfi-extra-fd-args (mrfi--extensions-to-fd-args)
                      (mrfi--roots))))
    (condition-case err
        (apply #'process-lines "fd" args)
      (error (message "[mrfi] fd error: %s → falling back to Elisp" (error-message-string err))
             nil))))

(defun mrfi--build-with-elisp ()
  (let (acc)
    (dolist (root (mrfi--roots))
      (when (file-directory-p root)
        (let* ((case-fold-search t)
               (regexp (or (mrfi--extensions-regexp) ".*")))
          (dolist (f (directory-files-recursively root regexp t))
            (when (file-regular-p f)
              (push f acc))))))
    (nreverse acc)))

;;; Index management

;;;###autoload
(defun mrfi-refresh-index (&optional quiet)
  "Rebuild the file index.  
If QUIET is non-nil, suppress messages."
  (interactive)
  (let ((files (or (and (mrfi--fd-available-p) (mrfi--build-with-fd))
                   (mrfi--build-with-elisp))))
    (setq mrfi--cache (mapcar #'expand-file-name files)
          mrfi--last-built (current-time))
    (unless quiet
      (message "[mrfi] Indexed %d files%s"
               (length mrfi--cache)
               (if (mrfi--fd-available-p) " (fd)" " (elisp)")))
    mrfi--cache))

(defun mrfi--ensure-index ()
  (unless (and mrfi--cache mrfi--last-built)
    (mrfi-refresh-index t)))

(defun mrfi--prune-cache ()
  "Remove vanished or unreadable files from the index."
  (setq mrfi--cache
        (cl-remove-if-not (lambda (f) (ignore-errors (file-attributes f)))
                          mrfi--cache)))

;;; Alias & relative path

(defun mrfi--root+alias-for (path)
  "Return (ROOT . ALIAS) for PATH, matching the most specific root."
  (let* ((p (file-name-as-directory (expand-file-name path)))
         (sorted (sort (copy-sequence mrfi-sources)
                       (lambda (a b) (> (length (car a)) (length (car b)))))))
    (seq-find (lambda (cell)
                (string-prefix-p (file-name-as-directory (expand-file-name (car cell))) p))
              sorted)))

(defun mrfi--alias-and-rel (path)
  "Return (ALIAS RELPATH) for PATH."
  (let* ((cell (mrfi--root+alias-for path)))
    (if (not cell)
        (list "" (abbreviate-file-name (directory-file-name (file-name-directory path))))
      (let* ((root (file-name-as-directory (expand-file-name (car cell))))
             (alias (cdr cell))
             (rel   (substring (expand-file-name path) (length root)))
             (reldir (file-name-directory rel)))
        (list alias (concat "/" (or reldir "")))))))

;;; File info

(defun mrfi--file-info (path)
  "Return plist with :name :size-str :date-str :alias :relpath for PATH.
Return nil if PATH cannot be statted."
  (when-let ((attrs (ignore-errors (file-attributes path))))
    (let* ((size  (file-attribute-size attrs))
           (mtime (file-attribute-modification-time attrs))
           (name  (file-name-nondirectory path))
           (ar    (mrfi--alias-and-rel path))
           (alias (car ar))
           (rel   (cadr ar))
           (size-str (cond ((> size 1048576) (format "%.1fM" (/ size 1048576.0)))
                           ((> size 1024)    (format "%.1fk" (/ size 1024.0)))
                           (t                (format "%d" size))))
           (date-str (format-time-string "%Y-%m-%dT%H:%M" mtime)))
      (list :name name :size-str size-str :date-str date-str :alias alias :rel rel))))

;;; Auto layout

(defun mrfi--alias-max-width ()
  (if (null mrfi-sources) 8
    (max 8 (apply #'max 0 (mapcar (lambda (c) (string-width (cdr c))) mrfi-sources)))))

(defun mrfi--current-window-width ()
  (let ((w (or (active-minibuffer-window) (minibuffer-selected-window) (selected-window))))
    (max 80 (window-body-width w))))

(defun mrfi--compute-widths ()
  "Return (W-NAME W-ALIAS W-SIZE W-DATE).  
- Name: max 50% of window width.
- Alias: width based on longest alias (capped at 18).
- Size: ~6 chars.
- Date: ISO format, 16 chars."
  (let* ((W (mrfi--current-window-width))
         (w-size 6)
         (w-date 16)
         (w-alias (min 18 (mrfi--alias-max-width)))
         (gaps (* 2 4))
         (fixed (+ w-alias w-size w-date gaps))
         (half (floor (/ W 2)))
         (w-name (min half (max 30 (- W fixed 10)))))
    (list w-name w-alias w-size w-date)))

(defun mrfi--pad (s w &optional right)
  (let* ((tr (truncate-string-to-width s w nil ?\s)))
    (if right
        (concat (make-string (max 0 (- w (string-width tr))) ?\s) tr)
      tr)))

;;; Reader minibuffer

(defun mrfi--read-file ()
  "Prompt user to select a file from the index.
Return the full path."
  (mrfi--ensure-index)
  (let* ((ws (mrfi--compute-widths))
         (w-name  (nth 0 ws))
         (w-alias (nth 1 ws))
         (w-size  (nth 2 ws))
         (w-date  (nth 3 ws))
         (candidates
          (mapcar
           (lambda (p)
             (let* ((fi   (mrfi--file-info p))
                    (name (plist-get fi :name))
                    (key  (if mrfi-search-in-path
                              (concat (plist-get fi :alias)
                                      (plist-get fi :rel)
                                      name)
                            name)))
               (propertize name
                           'face 'mrfi-name-face
                           'mrfi-path p
                           'mrfi-fi fi
                           'completion-search-key key
                           'display (mrfi--pad name w-name))))
           mrfi--cache))
         (annotation
          (lambda (cand)
            (let* ((fi    (get-text-property 0 'mrfi-fi cand))
                   (alias (mrfi--pad (plist-get fi :alias)    w-alias))
                   (size  (mrfi--pad (plist-get fi :size-str) w-size t))
                   (date  (mrfi--pad (plist-get fi :date-str) w-date))
                   (rel   (plist-get fi :rel)))
              (concat "  "
                      (propertize alias 'face 'mrfi-alias-face) "  "
                      (propertize size  'face 'mrfi-size-face)  "  "
                      (propertize date  'face 'mrfi-date-face)  "  "
                      (propertize rel   'face 'mrfi-path-face)))))
         (completion-extra-properties `(:annotation-function ,annotation)))
    (if (require 'consult nil t)
        (let ((choice (consult--read candidates :prompt "MRFI: "
                                     :require-match t :sort nil :category 'file)))
          (get-text-property 0 'mrfi-path choice))
      (let ((choice (completing-read "MRFI: " candidates nil t)))
        (get-text-property 0 'mrfi-path choice)))))

;;;###autoload
(defun mrfi-find-file ()
  "Pick a file from the consolidated index and open it."
  (interactive)
  (let ((f (mrfi--read-file)))
    (when (and f (file-exists-p f)) (find-file f))))

;;; Tabulated list

(defun mrfi--row (path)
  (let* ((fi (mrfi--file-info path)))
    (list path
          (vector (plist-get fi :name)
                  (plist-get fi :alias)
                  (plist-get fi :size-str)
                  (plist-get fi :date-str)
                  (plist-get fi :rel)))))

(defun mrfi--populate-list ()
  (mrfi--ensure-index)
  (setq tabulated-list-entries (delq nil (mapcar #'mrfi--row mrfi--cache))))

(defun mrfi--open-on-point ()
  (let ((id (tabulated-list-get-id)))
    (when (and id (file-exists-p id)) (find-file id))))

;;;###autoload
(defun mrfi-list ()
  "Show the consolidated index in a tabulated buffer."
  (interactive)
  (mrfi--ensure-index)
  (with-current-buffer (get-buffer-create "*MRFI*")
    (erase-buffer)
    (tabulated-list-mode)
    (cl-destructuring-bind (w-name w-alias _ws _wd) (mrfi--compute-widths)
      (setq-local tabulated-list-format
                  (vector
                   (list "Name"     w-name t)
                   (list "Alias"    w-alias t)
                   (list "Size"     8 'right)
                   (list "ISO Date" 16 t)
                   (list "Path"     60 t))))
    (setq-local tabulated-list-padding 2)
    (setq-local tabulated-list-sort-key (cons "Name" nil))
    (add-hook 'tabulated-list-revert-hook #'mrfi--populate-list nil t)
    (mrfi--populate-list)
    (tabulated-list-init-header)
    (tabulated-list-print)
    (use-local-map (copy-keymap tabulated-list-mode-map))
    (local-set-key (kbd "RET") #'mrfi--open-on-point)
    (display-buffer (current-buffer))))

(provide 'mrfi)

;;; mrfi.el ends here
