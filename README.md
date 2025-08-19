# MRFI – Multi-Root File Index for Emacs

MRFI consolidates multiple directories into a single file index for fast searching and browsing.  
Think of it as a lightweight project-wide file finder across multiple roots.

## Features
- Multiple root directories with short aliases.
- Restrict indexing by file extensions.
- Uses `fd` if available (fast), otherwise falls back to Emacs Lisp.
- Minibuffer interface (Consult-supported) with aligned columns:
```
  Filename                   Alias     Size   ISO Date         /relative/path/
```
- ISO timestamps (`YYYY-MM-DDTHH:MM`).
- Tabulated list mode for a browsable buffer.

## Installation

Clone the repo and add to your `load-path`:

```elisp
(add-to-list 'load-path "~/path/to/mrfi/")
(require 'mrfi)
```

Or use straight.el:

```elisp
(use-package mrfi
  :straight (:host github :repo "micheledm/mrfi")
  :commands (mrfi-find-file mrfi-list mrfi-refresh-index))
```

## Configuration

```elisp
(setq mrfi-sources
      '(("~/notes/obsidian/" . "Obsidian")
        ("~/notes/org/"      . "Org")))

(setq mrfi-extensions '("md" "org" "txt"))
(setq mrfi-use-fd t)           ;; use fd if available
(setq mrfi-search-in-path t)   ;; search in alias+path as well as filename
```

## Usage

- `M-x mrfi-find-file` — search & open file from index.
- `M-x mrfi-list` — show all indexed files in a tabulated list.
- `M-x mrfi-refresh-index` — rebuild index.

In the list buffer:
- `RET` opens file at point.
- `g` refreshes the index.

## License

GPL-3.0-or-later