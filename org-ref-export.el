;;; org-ref-export.el --- org-ref-export library
;;
;; Copyright (C) 2021  John Kitchin

;; Author: John Kitchin <jkitchin@andrew.cmu.edu>
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
;;
;;; Commentary:
;; This is an export library that uses CSL to process the citations and bibliography.
;;
;; It is intended for non-LaTeX exports, but you can also use it with LaTeX if
;; you want to avoid using bibtex/biblatex for some reason.
;;
;; Note that citeproc does not do anything for cross-references, so if non-latex
;; export is your goal, you should be careful in how you do cross-references,
;; and rely exclusively on org-syntax for that, e.g. radio targets and fuzzy
;; links.
;;
;; TODO: write refproc to take care of cross-references? Should it just revert
;; to org-markup, maybe adding parentheses around equation refs?

;;; Code:

(require 'citeproc)

(defcustom org-ref-backend-csl-formats
  '((html . html)
    (latex . latex)
    (md . plain)
    (ascii . plain)
    (odt . org-odt))
  "Mapping of export backend to csl-backends.")


(defcustom org-ref-cite-internal-links 'auto
  "Should be on of
- 'bib-links :: link cites to bibliography entries
- 'no-links :: do not link cites to bibliography entries
- nil or 'auto :: add links based on the style.")


(defun org-ref-process-buffer (backend)
  "Process the citations and bibliography in the org-buffer.
Usually run on a copy of the buffer during export.
BACKEND is the org export backend."

  (let* ((csl-backend (or (cdr (assoc backend org-ref-backend-csl-formats)) 'plain))

	 (style (or (cadr (assoc "CSL-STYLE"
				 (org-collect-keywords
				  '("CSL-STYLE"))))
		    "chicago-author-date-16th-edition.csl"))
	 (locale (or (cadr (assoc "CSL-LOCALE"
				  (org-collect-keywords
				   '("CSL-LOCALE"))))
		     "en-US"))

	 (proc (citeproc-create (cond
				 ((file-exists-p style)
				  style)
				 ;; In a user-dir
				 ((file-exists-p (f-join org-cite-csl-styles-dir style))
				  (f-join org-cite-csl-styles-dir style))
				 ;; provided by org-ref
				 ((file-exists-p
				   (expand-file-name style (f-join (file-name-directory (locate-library "org-ref")) "csl-styles")))
				  (expand-file-name style (f-join (file-name-directory (locate-library "org-ref")) "csl-styles")))
				 (t
				  (error "%s not found" style)))
				(citeproc-itemgetter-from-bibtex (org-ref-find-bibliography))
				(citeproc-locale-getter-from-dir (cond
								  ((boundp 'org-cite-csl-locales-dir)
								   org-cite-csl-locales-dir)
								  (t
								   (f-join (file-name-directory (locate-library "org-ref")) "csl-locales"))))
				locale))

	 ;; list of links in the buffer
	 (cite-links (org-element-map (org-element-parse-buffer) 'link
		       (lambda (lnk)
			 (when (member (org-element-property :type lnk) org-ref-cite-types)
			   lnk))))

	 (cites (cl-loop for cl in cite-links collect
			 (let* ((cite-data (org-ref-parse-cite-path (org-element-property :path cl)))
				(common-prefix (or (plist-get cite-data :prefix) ""))
				(common-suffix (or (plist-get cite-data :suffix) ""))
				(refs (plist-get cite-data :references))

				(cites (cl-loop for ref in refs collect
						;; I believe the suffix contains "label locator suffix"
						;; where locator is a number
						;; label is something like page or chapter
						;; and the rest is the suffix text.
						;; For example: ch. 5, for example
						;; would be label = ch., locator=5, ",for example" as suffix.
						(let* ((full-suffix (or (plist-get ref :suffix) ""))
						       location label locator suffix)
						  (string-match "\\(?1:[^[:digit:]]*\\)?\\(?2:[[:digit:]]*\\)?\\(?3:.*\\)"
								full-suffix)
						  (setq label (match-string 1 full-suffix)
							locator (match-string 2 full-suffix)
							suffix (match-string 3 full-suffix))
						  ;; Let's assume if you have a locator but not a label, you mean page.
						  (when (and locator (string= "" (string-trim label)))
						    (setq label "page"))
						  `((id . ,(plist-get ref :key))
						    (prefix . ,(or (plist-get ref :prefix) ""))
						    (suffix . ,suffix)
						    (locator . ,locator)
						    (label . ,(string-trim label))

						    ;; TODO: proof of concept and not complete
						    (suppress-author . ,(not (null (member
										    (org-element-property :type cl)
										    '("citenum"
										      "citeyear"
										      "citeyear*"
										      "citedate"
										      "citedate*"
										      "citetitle"
										      "citetitle*"
										      "citeurl")))) ))))))
			   ;; TODO: confirm this is right.
			   ;; To handle common prefixes, suffixes, I just concat them with the first/last entries.
			   ;; I am not sure this is the right thing to do though.
			   (setf (cdr (assoc 'prefix (cl-first cites)))
				 (concat common-prefix (cdr (assoc 'prefix (cl-first cites)))))
			   (setf (cdr (assoc 'suffix (car (last cites))))
				 (concat (cdr (assoc 'suffix (car (last cites)))) common-suffix))

			   ;; https://github.com/andras-simonyi/citeproc-el#creating-citation-structures
			   (citeproc-citation-create :cites
						     ;; I am not sure why this
						     ;; should be reversed. The
						     ;; order is backwards
						     ;; without it though.
						     (reverse cites)

						     ;; TODO: proof of concept, incomplete
						     ;; if this is true, the citation is not parenthetical
						     :suppress-affixes (let ((type (org-element-property :type cl)))
									 (when (member type '("citet"
											      "citet*"
											      "citenum"))
									   t))

						     ;; TODO: this is proof of
						     ;; concept, and not
						     ;; complete mode is one of
						     ;; suppress-author,
						     ;; textual, author-only,
						     ;; year-only, or nil for
						     ;; default. These are not
						     ;; all clear to me.
						     :mode (let ((type (org-element-property :type cl)))
							     (cond
							      ((member type '("citet" "citet*"))
							       'textual)
							      ((member type '("citeauthor" "citeauthor*"))
							       'author-only)
							      ((member type '("citeyear" "citeyear*"))
							       'year-only)
							      ((member type '("citedate" "citedate*"))
							       'suppress-author)
							      (t
							       nil)))

						     ;; I think the capitalized styles are what this is for
						     :capitalize-first (string-match
									"[A-Z]"
									(substring (org-element-property :type cl) 0 1))
						     ;; I don't know where this information would come from.
						     :note-index nil
						     :ignore-et-al nil))))

	 (rendered-citations (progn (citeproc-append-citations cites proc)
				    (citeproc-render-citations proc csl-backend org-ref-cite-internal-links)))
	 (rendered-bib (car (citeproc-render-bib proc csl-backend)))
	 ;; The idea is we will wrap each citation and the bibliography in
	 ;; org-code so it exports appropriately.
	 (cite-formatters '((html . "@@html:%s@@")
			    (latex . "@@latex:%s@@")
			    (org-odt . "@@odt:%s@@")))
	 (bib-formatters '((html .  "\n#+BEGIN_EXPORT html\n%s\n#+END_EXPORT\n")
			   (latex .  "\n#+BEGIN_EXPORT latex\n%s\n#+END_EXPORT\n")
			   (org-odt . "\n#+BEGIN_EXPORT ODT\n%s\n#+END_EXPORT\n"))))

    ;; replace the cite links
    (cl-loop for cl in (reverse  cite-links) for rc in (reverse rendered-citations) do
	     (cl--set-buffer-substring (org-element-property :begin cl)
				       (org-element-property :end cl)
				       (format (or (cdr (assoc backend cite-formatters)) "%s") rc)))

    ;; replace the bibliography
    (org-element-map (org-element-parse-buffer) 'link
      (lambda (lnk)
	(when (string= (org-element-property :type lnk) "bibliography")
	  (cl--set-buffer-substring (org-element-property :begin lnk)
				    (org-element-property :end lnk)
				    (format (or (cdr (assoc backend bib-formatters)) "%s") rendered-bib)))))))


(defun org-ref-export-to (backend &optional async subtreep visible-only
				  body-only info)
  "Export buffer to BACKEND.
See `org-export-as' for the meaning of ASYNC SUBTREEP
VISIBLE-ONLY BODY-ONLY and INFO."
  (let* ((fname (buffer-file-name))
	 (extensions '((html . ".html")
		       (latex . ".tex")
		       (md . ".md")
		       (ascii . ".txt")
		       (odt . ".odf")))

	 (export-name (concat (file-name-sans-extension fname)
			      (or (cdr (assoc backend extensions)) ""))))

    (org-export-with-buffer-copy
     (org-ref-process-buffer backend)
     (pcase backend
       ;; odt is a little bit special, and is missing one argument
       ('odt (org-open-file (org-odt-export-to-odt async subtreep visible-only
						   info)
			    'system))
       (_
	(org-open-file (org-export-to-file backend export-name
			 async subtreep visible-only
			 body-only info)
		       'system))))))


(defun org-ref-export-to-html (&optional async subtreep visible-only
					 body-only info)
  "Export the buffer to HTML and open.
See `org-export-as' for the meaning of ASYNC SUBTREEP
VISIBLE-ONLY BODY-ONLY and INFO."
  (org-ref-export-to 'html async subtreep visible-only
		     body-only info))


(defun org-ref-export-to-md (&optional async subtreep visible-only
				       body-only info)
  "Export the buffer to Markdown and open.
See `org-export-as' for the meaning of ASYNC SUBTREEP
VISIBLE-ONLY BODY-ONLY and INFO."
  (org-ref-export-to 'md async subtreep visible-only
		     body-only info))


(defun org-ref-export-to-ascii (&optional async subtreep visible-only
					  body-only info)
  "Export the buffer to ascii and open.
See `org-export-as' for the meaning of ASYNC SUBTREEP
VISIBLE-ONLY BODY-ONLY and INFO."
  (org-ref-export-to 'ascii async subtreep visible-only
		     body-only info))


(defun org-ref-export-to-latex (&optional async subtreep visible-only
					  body-only info)
  "Export the buffer to LaTeX and open.
See `org-export-as' for the meaning of ASYNC SUBTREEP
VISIBLE-ONLY BODY-ONLY and INFO."
  (org-ref-export-to 'latex async subtreep visible-only
		     body-only info))


(defun org-ref-export-to-odt (&optional async subtreep visible-only
					body-only info)
  "Export the buffer to ODT and open.
See `org-export-as' for the meaning of ASYNC SUBTREEP
VISIBLE-ONLY BODY-ONLY and INFO."
  (require 'htmlfontify)
  (unless (boundp 'hfy-user-sheet-assoc) (setq  hfy-user-sheet-assoc nil))
  (org-ref-export-to 'odt async subtreep visible-only
		     body-only info))


(defun org-ref-export-as-org (&optional async subtreep visible-only
					body-only info)
  "Export the buffer to an ORG buffer and open.
We only make a buffer here to avoid overwriting the original file.
See `org-export-as' for the meaning of ASYNC SUBTREEP
VISIBLE-ONLY BODY-ONLY and INFO."
  (let* ((export-buf "*org-ref ORG Export*")
	 export)

    (org-export-with-buffer-copy
     (org-ref-process-buffer 'org)
     (setq export (org-export-as 'org))
     (with-current-buffer (get-buffer-create export-buf)
       (erase-buffer)
       (org-mode)
       (insert export)))
    (pop-to-buffer export-buf)))


(defun org-ref-export-to-message (&optional async subtreep visible-only
					    body-only info)
  "Export to ascii and insert"
  (let* ((backend 'md)
	 (content (org-export-with-buffer-copy
		   (org-ref-process-buffer backend)
		   (org-export-as backend))))
    (compose-mail)
    (message-goto-body)
    (insert content)
    (message-goto-to)))


(org-export-define-derived-backend 'org-ref 'org
  :menu-entry
  '(?r "Org-ref export"
       ((?a "to Ascii" org-ref-export-as-ascii)
	(?h "to html" org-ref-export-to-html)
	(?l "to LaTeX" org-ref-export-as-latex)
	(?m "to Markdown" org-ref-export-as-md)
	(?o "to ODT" org-ref-export-as-odt)
	(?O "to Org buffer" org-ref-export-as-org)
	(?e "to email" org-ref-export-to-message))))

;; An alternative to this exporter is to use an  `org-export-before-parsing-hook'
;; (add-hook 'org-export-before-parsing-hook 'org-ref-csl-preprocess-buffer)

(defun org-ref-csl-preprocess-buffer (backend)
  "Preprocess the buffer in BACKEND export"
  (org-ref-process-buffer backend))

(provide 'org-ref-export)

;;; org-ref-export.el ends here
