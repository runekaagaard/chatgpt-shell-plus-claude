;;; claude-shell.el --- Anthropic Claude shell + buffer insert commands  -*- lexical-binding: t -*-

;; Copyright (C) 2023 Alvaro Ramirez

;; Author: Alvaro Ramirez https://xenodium.com
;; URL: https://github.com/xenodium/chatgpt-shell
;; Version: 1.0.18
;; Package-Requires: ((emacs "27.1") (shell-maker "0.50.5"))

;; This package is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This package is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; `claude-shell' is a comint-based Anthropic Claude shell for Emacs.
;;
;; You must set `claude-shell-anthropic-key' to your key before using.
;;
;; Run `claude-shell' to get a Anthropic Claude shell.
;;
;; Note: This is young package still.  Please report issues or send
;; patches to https://github.com/xenodium/chatgpt-shell
;;
;; Support the work https://github.com/sponsors/xenodium

;;; Code:

(require 'cl-lib)
(require 'dired)
(require 'esh-mode)
(require 'eshell)
(require 'find-func)
(require 'flymake)
(require 'ielm)
(require 'shell-maker)

(defcustom claude-shell-anthropic-key nil
  "Anthropic key as a string or a function that loads and returns it."
  :type '(choice (function :tag "Function")
                 (string :tag "String"))
  :group 'claude-shell)

(defcustom claude-shell-additional-curl-options nil
  "Additional options for `curl' command."
  :type '(repeat (string :tag "String"))
  :group 'claude-shell)

(defcustom claude-shell-auth-header
  (lambda ()
    (concat (format "x-api-key: %s" (claude-shell-anthropic-key))
            "\nanthropic-version: 2023-06-01"))
  "Function to generate the request's header string for Claude."
  :type '(function :tag "Function")
  :group 'chatgpt-shell)

(defcustom claude-shell-request-timeout 600
  "How long to wait for a request to time out in seconds."
  :type 'integer
  :group 'claude-shell)

(defcustom claude-shell-default-prompts
  '("Write a unit test for the following code:"
    "Refactor the following code so that "
    "Summarize the output of the following command:"
    "What's wrong with this command?"
    "Explain what the following code does:")
  "List of default prompts to choose from."
  :type '(repeat string)
  :group 'claude-shell)

(defcustom claude-shell-prompt-header-describe-code
  "What does the following code do?"
  "Prompt header of `describe-code`."
  :type 'string
  :group 'claude-shell)

(defcustom claude-shell-prompt-header-write-git-commit
  "Please help me write a git commit message for the following commit:"
  "Prompt header of `git-commit`."
  :type 'string
  :group 'claude-shell)

(defcustom claude-shell-prompt-header-refactor-code
  "Please help me refactor the following code.
   Please reply with the refactoring explanation in English, refactored code, and diff between two versions.
   Please ignore the comments and strings in the code during the refactoring.
   If the code remains unchanged after refactoring, please say 'No need to refactor'."
  "Prompt header of `refactor-code`."
  :type 'string
  :group 'claude-shell)

(defcustom claude-shell-prompt-header-generate-unit-test
  "Please help me generate unit-test following function:"
  "Prompt header of `generate-unit-test`."
  :type 'string
  :group 'claude-shell)

(defcustom claude-shell-prompt-header-proofread-region
  "Please help me proofread the following text with English:"
  "Promt header of `proofread-region`."
  :type 'string
  :group 'claude-shell)

(defcustom claude-shell-prompt-header-whats-wrong-with-last-command
  "What's wrong with this command?"
  "Prompt header of `whats-wrong-with-last-command`."
  :type 'string
  :group 'claude-shell)

(defcustom claude-shell-prompt-header-eshell-summarize-last-command-output
  "Summarize the output of the following command:"
  "Prompt header of `eshell-summarize-last-command-output`."
  :type 'string
  :group 'claude-shell)

(defcustom claude-shell-prompt-query-response-style 'other-buffer
  "Determines the prompt style when invoking from other buffers.

`'inline' inserts responses into current buffer.
`'other-buffer' inserts responses into a transient buffer.
`'shell' inserts responses and focuses the shell

Note: in all cases responses are written to the shell to keep context."
  :type '(choice (const :tag "Inline" inline)
                 (const :tag "Other Buffer" other-buffer)
                 (const :tag "Shell" shell))
  :group 'claude-shell)

(defcustom claude-shell-after-command-functions nil
  "Abnormal hook (i.e. with parameters) invoked after each command.

This is useful if you'd like to automatically handle or suggest things
post execution.

For example:

\(add-hook `claude-shell-after-command-functions'
   (lambda (command output)
     (message \"Command: %s\" command)
     (message \"Output: %s\" output)))"
  :type 'hook
  :group 'shell-maker)

(defvaralias 'claude-shell-display-function 'shell-maker-display-function)

(defvaralias 'claude-shell-read-string-function 'shell-maker-read-string-function)

(defvaralias 'claude-shell-logging 'shell-maker-logging)

(defvaralias 'claude-shell-root-path 'shell-maker-root-path)

(defalias 'claude-shell-save-session-transcript #'shell-maker-save-session-transcript)

(defvar claude-shell--prompt-history nil)

(defcustom claude-shell-language-mapping '(("elisp" . "emacs-lisp")
                                            ("objective-c" . "objc")
                                            ("objectivec" . "objc")
                                            ("cpp" . "c++"))
  "Maps external language names to Emacs names.

Use only lower-case names.

For example:

                  lowercase      Emacs mode (without -mode)
Objective-C -> (\"objective-c\" . \"objc\")"
  :type '(alist :key-type (string :tag "Language Name/Alias")
                :value-type (string :tag "Mode Name (without -mode)"))
  :group 'claude-shell)

(defcustom claude-shell-babel-headers '(("dot" . ((:file . "<temp-file>.png")))
                                         ("plantuml" . ((:file . "<temp-file>.png")))
                                         ("ditaa" . ((:file . "<temp-file>.png")))
                                         ("objc" . ((:results . "output")))
                                         ("python" . ((:python . "python3")))
                                         ("swiftui" . ((:results . "file")))
                                         ("c++" . ((:results . "raw")))
                                         ("c" . ((:results . "raw"))))
  "Additional headers to make babel blocks work.

Entries are of the form (language . headers).  Headers should
conform to the types of `org-babel-default-header-args', which
see.

Please submit contributions so more things work out of the box."
  :type '(alist :key-type (string :tag "Language")
                :value-type (alist :key-type (restricted-sexp :match-alternatives (keywordp) :tag "Argument Name")
                                   :value-type (string :tag "Value")))
  :group 'claude-shell)

(defcustom claude-shell-source-block-actions
  nil
  "Block actions for known languages.

Can be used compile or run source block at point."
  :type '(alist :key-type (string :tag "Language")
                :value-type (list (cons (const 'primary-action-confirmation) (string :tag "Confirmation Prompt:"))
                                  (cons (const 'primary-action) (function :tag "Action:"))))
  :group 'claude-shell)

(defcustom claude-shell-model-versions
  '("claude-3-5-sonnet-20240620"
    "claude-3-opus-20240229"
    "claude-3-sonnet-20240229"
    "claude-3-haiku-20240307")
  "The list of Anthropic models to swap from.

The list of models supported by /v1/chat/completions endpoint is
documented at
https://docs.anthropic.com/en/docs/about-claude/models."
  :type '(repeat string)
  :group 'claude-shell)

(defcustom claude-shell-model-version 0
  "The active Claude model index.

See `claude-shell-model-versions' for available model versions.

Swap using `claude-shell-swap-model-version'.

The list of models supported by /v1/chat/completions endpoint is
documented at
https://docs.anthropic.com/en/docs/about-claude/models."
  :type '(choice (string :tag "String")
                 (integer :tag "Integer")
                 (const :tag "Nil" nil))
  :group 'claude-shell)

(defcustom claude-shell-model-temperature nil
  "What sampling temperature to use, between 0 and 2, or nil.

Higher values like 0.8 will make the output more random, while
lower values like 0.2 will make it more focused and
deterministic.  Value of nil will not pass this configuration to
the model.

See
https://docs.anthropic.com/en/api/messages
for details."
  :type '(choice (float :tag "Float")
                 (const :tag "Nil" nil))
  :group 'claude-shell)

(defun claude-shell--append-system-info (text)
  "Append system info to TEXT."
  (cl-labels ((claude-shell--get-system-info-command
               ()
               (cond ((eq system-type 'darwin) "sw_vers")
                     ((or (eq system-type 'gnu/linux)
                          (eq system-type 'gnu/kfreebsd)) "uname -a")
                     ((eq system-type 'windows-nt) "ver")
                     (t (format "%s" system-type)))))
    (let ((system-info (string-trim
                        (shell-command-to-string
                         (claude-shell--get-system-info-command)))))
      (concat text
              "\n# System info\n"
              "\n## OS details\n"
              system-info
              "\n## Editor\n"
              (emacs-version)))))

(defcustom claude-shell-system-prompts
  `(("tl;dr" . "Be as succint but informative as possible and respond in tl;dr form to my queries")
    ("General" . "You use markdown liberally to structure responses. Always show code snippets in markdown blocks with language labels.")
    ;; Based on https://github.com/benjamin-asdf/dotfiles/blob/8fd18ff6bd2a1ed2379e53e26282f01dcc397e44/mememacs/.emacs-mememacs.d/init.el#L768
    ("Programming" . ,(claude-shell--append-system-info
                       "The user is a programmer with very limited time.
                        You treat their time as precious. You do not repeat obvious things, including their query.
                        You are as concise as possible in responses.
                        You never apologize for confusions because it would waste their time.
                        You use markdown liberally to structure responses.
                        Always show code snippets in markdown blocks with language labels.
                        Don't explain code snippets.
                        Whenever you output updated code for the user, only show diffs, instead of entire snippets."))
    ("Positive Programming" . ,(claude-shell--append-system-info
                                "Your goal is to help the user become an amazing computer programmer.
                                 You are positive and encouraging.
                                 You love see them learn.
                                 You do not repeat obvious things, including their query.
                                 You are as concise in responses. You always guide the user go one level deeper and help them see patterns.
                                 You never apologize for confusions because it would waste their time.
                                 You use markdown liberally to structure responses. Always show code snippets in markdown blocks with language labels.
                                 Don't explain code snippets. Whenever you output updated code for the user, only show diffs, instead of entire snippets."))
    ("Japanese" . ,(claude-shell--append-system-info
                    "The user is a beginner Japanese language learner with very limited time.
                     You treat their time as precious. You do not repeat obvious things, including their query.
                     You are as concise as possible in responses.
                     You never apologize for confusions because it would waste their time.
                     You use markdown liberally to structure responses.")))

  "List of system prompts to choose from.

If prompt is a cons, its car will be used as a title to display.

For example:

\(\"Translating\" . \"You are a helpful English to Spanish assistant.\")\"
\(\"Programming\" . \"The user is a programmer with very limited time...\")"
  :type '(alist :key-type (string :tag "Title")
                :value-type (string :tag "Prompt value"))
  :group 'claude-shell)

(defcustom claude-shell-system-prompt 1 ;; Concise
  "The system prompt `claude-shell-system-prompts' index.

Or nil if none."
  :type '(choice (string :tag "String")
                 (integer :tag "Integer")
                 (const :tag "No Prompt" nil))
  :group 'claude-shell)

(defun claude-shell-model-version ()
  "Return active model version."
  (cond ((stringp claude-shell-model-version)
         claude-shell-model-version)
        ((integerp claude-shell-model-version)
         (nth claude-shell-model-version
              claude-shell-model-versions))
        (t
         nil)))

(defun claude-shell-system-prompt ()
  "Return active system prompt."
  (cond ((stringp claude-shell-system-prompt)
         claude-shell-system-prompt)
        ((integerp claude-shell-system-prompt)
         (let ((prompt (nth claude-shell-system-prompt
                            claude-shell-system-prompts)))
           (if (consp prompt)
               (cdr prompt)
             prompt)))
        (t
         nil)))

(defun claude-shell-duplicate-map-keys (map)
  "Return duplicate keys in MAP."
  (let ((keys (map-keys map))
        (seen '())
        (duplicates '()))
    (dolist (key keys)
      (if (member key seen)
          (push key duplicates)
        (push key seen)))
    duplicates))

(defun claude-shell-swap-system-prompt ()
  "Swap system prompt from `claude-shell-system-prompts'."
  (interactive)
  (unless (eq major-mode 'claude-shell-mode)
    (user-error "Not in a shell"))
  (when-let ((duplicates (claude-shell-duplicate-map-keys claude-shell-system-prompts)))
    (user-error "Duplicate prompt names found %s. Please remove" duplicates))
  (let* ((choices (append (list "None")
                          (map-keys claude-shell-system-prompts)))
         (choice (completing-read "System prompt: " choices))
         (choice-pos (seq-position choices choice)))
    (if (or (string-equal choice "None")
            (string-empty-p (string-trim choice))
            (not choice-pos))
        (setq-local claude-shell-system-prompt nil)
      (setq-local claude-shell-system-prompt
                  ;; -1 to disregard None
                  (1- (seq-position choices choice)))))
  (claude-shell--update-prompt t)
  (claude-shell-interrupt nil))

(defun claude-shell-load-awesome-prompts ()
  "Load `claude-shell-system-prompts' from awesome-claude-prompts.

Downloaded from https://github.com/f/awesome-claude-prompts."
  (interactive)
  (unless (fboundp 'pcsv-parse-file)
    (user-error "Please install pcsv"))
  (require 'pcsv)
  (let ((csv-path (concat (temporary-file-directory) "awesome-claude-prompts.csv")))
    (url-copy-file "https://raw.githubusercontent.com/f/awesome-claude-prompts/main/prompts.csv"
                   csv-path t)
    (setq claude-shell-system-prompts
         (map-merge 'list
                    claude-shell-system-prompts
                    ;; Based on Daniel Gomez's parsing code from
                    ;; https://github.com/xenodium/claude-shell/issues/104
                    (seq-sort (lambda (rhs lhs)
                                (string-lessp (car rhs)
                                              (car lhs)))
                              (cdr
                               (mapcar
                                (lambda (row)
                                  (cons (car row)
                                        (cadr row)))
                                (pcsv-parse-file csv-path))))))
    (message "Loaded awesome-claude-prompts")
    (setq claude-shell-system-prompt nil)
    (claude-shell--update-prompt t)
    (claude-shell-interrupt nil)
    (claude-shell-swap-system-prompt)))

(defun claude-shell-swap-model-version ()
  "Swap model version from `claude-shell-model-versions'."
  (interactive)
  (unless (eq major-mode 'claude-shell-mode)
    (user-error "Not in a shell"))
  (setq-local claude-shell-model-version
              (completing-read "Model version: "
                               (if (> (length claude-shell-model-versions) 1)
                                   (seq-remove
                                    (lambda (item)
                                      (string-equal item (claude-shell-model-version)))
                                    claude-shell-model-versions)
                                 claude-shell-model-versions) nil t))
  (claude-shell--update-prompt t)
  (claude-shell-interrupt nil))

(defcustom claude-shell-streaming nil
  "Whether or not to stream responses (show chunks as they arrive)."
  :type 'boolean
  :group 'claude-shell)

(defcustom claude-shell-highlight-blocks t
  "Whether or not to highlight source blocks."
  :type 'boolean
  :group 'claude-shell)

(defcustom claude-shell-insert-dividers nil
  "Whether or not to display a divider between requests and responses."
  :type 'boolean
  :group 'claude-shell)

(defcustom claude-shell-transmitted-context-length
  #'claude-shell--approximate-context-length
  "Controls the amount of context provided to Claude.

This context needs to be transmitted to the API on every request.
Claude reads the provided context on every request, which will
consume more and more prompt tokens as your conversation grows.
Models do have a maximum token limit, however.

A value of nil will send full chat history (the full contents of
the comint buffer), to Claude.

A value of 0 will not provide any context.  This is the cheapest
option, but Claude can't look back on your conversation.

A value of 1 will send only the latest prompt-completion pair as
context.

A Value > 1 will send that amount of prompt-completion pairs to
Claude.

A function `(lambda (tokens-per-message tokens-per-name messages))'
returning length.  Can use custom logic to enable a shifting context
window."
  :type '(choice (integer :tag "Integer")
                 (const :tag "Not set" nil)
                 (function :tag "Function"))
  :group 'claude-shell)

(defcustom claude-shell-api-url-base "https://api.anthropic.com"
  "Anthropic API's base URL.

`claude-shell--api-url' =
   `claude-shell--api-url-base' + `claude-shell--api-url-path'

If you use Claude through a proxy service, change the URL base."
  :type 'string
  :safe #'stringp
  :group 'claude-shell)

(defcustom claude-shell-api-url-path "/v1/messages"
  "Anthropic API's URL path.

`claude-shell--api-url' =
   `claude-shell--api-url-base' + `claude-shell--api-url-path'"
  :type 'string
  :safe #'stringp
  :group 'claude-shell)

(defcustom claude-shell-welcome-function #'shell-maker-welcome-message
  "Function returning welcome message or nil for no message.

See `shell-maker-welcome-message' as an example."
  :type 'function
  :group 'claude-shell)

(defvar claude-shell--config
  (make-shell-maker-config
   :name "Claude"
   :validate-command
   (lambda (_command)
     (unless claude-shell-anthropic-key
       "Variable `claude-shell-anthropic-key' needs to be set to your key.

Try M-x set-variable claude-shell-anthropic-key

or

(setq claude-shell-anthropic-key \"my-key\")"))
   :execute-command
   (lambda (_command history callback error-callback)
     (shell-maker-async-shell-command
      (claude-shell--make-curl-request-command-list
       (claude-shell--make-payload history))
      claude-shell-streaming
      #'claude-shell--extract-claude-response
      callback
      error-callback))
   :on-command-finished
   (lambda (command output)
     (claude-shell--put-source-block-overlays)
     (run-hook-with-args 'claude-shell-after-command-functions
                         command output))
   :redact-log-output
   (lambda (output)
     (if (claude-shell-anthropic-key)
         (replace-regexp-in-string (regexp-quote (claude-shell-anthropic-key))
                                   "SK-REDACTED-ANTHROPIC-KEY"
                                   output)
       output))))

(defalias 'claude-shell-clear-buffer #'comint-clear-buffer)

(defalias 'claude-shell-explain-code #'claude-shell-describe-code)

;; Aliasing enables editing as text in babel.
(defalias 'claude-shell-mode #'text-mode)

(shell-maker-define-major-mode claude-shell--config)

;;;###autoload
(defun claude-shell (&optional new-session)
  "Start a Claude shell interactive command.

With NEW-SESSION, start a new session."
  (interactive "P")
  (when (boundp 'claude-shell-history-path)
    (error Variable "claude-shell-history-path no longer exists. Please migrate to claude-shell-root-path and then (makunbound 'claude-shell-history-path)"))
  (claude-shell-start nil new-session))

(defun claude-shell-start (&optional no-focus new-session)
  "Start a Claude shell programmatically.

Set NO-FOCUS to start in background.

Set NEW-SESSION to start a separate new session."
  (let* ((claude-shell--config
          (let ((config (copy-sequence claude-shell--config)))
            (setf (shell-maker-config-prompt config)
                  (car (claude-shell--prompt-pair)))
            (setf (shell-maker-config-prompt-regexp config)
                  (cdr (claude-shell--prompt-pair)))
            config))
         (shell-buffer
          (shell-maker-start claude-shell--config
                             no-focus
                             claude-shell-welcome-function
                             new-session
                             (if (claude-shell--primary-buffer)
                                 (buffer-name (claude-shell--primary-buffer))
                               (claude-shell--make-buffer-name)))))
    (unless (claude-shell--primary-buffer)
      (claude-shell--set-primary-buffer shell-buffer))
    (let ((version claude-shell-model-version)
          (system-prompt claude-shell-system-prompt))
      (with-current-buffer shell-buffer
        (setq-local claude-shell-model-version version)
        (setq-local claude-shell-system-prompt system-prompt)
        (claude-shell--update-prompt t)
        (claude-shell--add-menus)))
    ;; Disabling advice for now. It gets in the way.
    ;; (advice-add 'keyboard-quit :around #'claude-shell--adviced:keyboard-quit)
    (define-key claude-shell-mode-map (kbd "C-M-h")
      #'claude-shell-mark-at-point-dwim)
    (define-key claude-shell-mode-map (kbd "C-c C-c")
      #'claude-shell-ctrl-c-ctrl-c)
    (define-key claude-shell-mode-map (kbd "C-c C-v")
      #'claude-shell-swap-model-version)
    (define-key claude-shell-mode-map (kbd "C-c C-s")
      #'claude-shell-swap-system-prompt)
    (define-key claude-shell-mode-map (kbd "C-c C-p")
      #'claude-shell-previous-item)
    (define-key claude-shell-mode-map (kbd "C-c C-n")
      #'claude-shell-next-item)
    (define-key claude-shell-mode-map (kbd "C-c C-e")
      #'claude-shell-prompt-compose)
    shell-buffer))

(defun claude-shell--shrink-model-version (model-version)
  "Shrink MODEL-VERSION.  gpt-3.5-turbo -> 3.5t."
  (replace-regexp-in-string
   "-turbo" "t"
   (string-remove-prefix
    "gpt-" (string-trim model-version))))

(defun claude-shell--shrink-system-prompt (prompt)
  "Shrink PROMPT."
  (if (consp prompt)
      (claude-shell--shrink-system-prompt (car prompt))
    (if (> (length (string-trim prompt)) 15)
        (format "%s..."
                (substring (string-trim prompt) 0 12))
      (string-trim prompt))))

(defun claude-shell--shell-info ()
  "Generate shell info for display."
  (concat
   (claude-shell--shrink-model-version
    (claude-shell-model-version))
   (cond ((and (integerp claude-shell-system-prompt)
               (nth claude-shell-system-prompt
                    claude-shell-system-prompts))
          (concat "/" (claude-shell--shrink-system-prompt (nth claude-shell-system-prompt
                                                                claude-shell-system-prompts))))
         ((stringp claude-shell-system-prompt)
          (concat "/" (claude-shell--shrink-system-prompt claude-shell-system-prompt)))
         (t
          ""))))

(defun claude-shell--prompt-pair ()
  "Return a pair with prompt and prompt-regexp."
  (cons
   (format "Claude(%s)> " (claude-shell--shell-info))
   (rx (seq bol "Claude" (one-or-more (not (any "\n"))) ">" (or space "\n")))))

(defun claude-shell--shell-buffers ()
  "Return a list of all shell buffers."
  (seq-filter
   (lambda (buffer)
     (eq (buffer-local-value 'major-mode buffer)
         'claude-shell-mode))
   (buffer-list)))

(defun claude-shell-set-as-primary-shell ()
  "Set as primary shell when there are multiple sessions."
  (interactive)
  (unless (eq major-mode 'claude-shell-mode)
    (user-error "Not in a shell"))
  (claude-shell--set-primary-buffer (current-buffer)))

(defun claude-shell--set-primary-buffer (primary-shell-buffer)
  "Set PRIMARY-SHELL-BUFFER as primary buffer."
  (unless primary-shell-buffer
    (error "No primary shell available"))
  (mapc (lambda (shell-buffer)
          (with-current-buffer shell-buffer
            (setq claude-shell--is-primary-p nil)))
        (claude-shell--shell-buffers))
  (with-current-buffer primary-shell-buffer
    (setq claude-shell--is-primary-p t)))

(defun claude-shell--primary-buffer ()
  "Return the primary shell buffer.

This is used for sending a prompt to in the background."
  (let* ((shell-buffers (claude-shell--shell-buffers))
         (primary-shell-buffer (seq-find
                                (lambda (shell-buffer)
                                  (with-current-buffer shell-buffer
                                    claude-shell--is-primary-p))
                                shell-buffers)))
    (unless primary-shell-buffer
      (setq primary-shell-buffer
            (or (seq-first shell-buffers)
                (shell-maker-start claude-shell--config
                                   t
                                   claude-shell-welcome-function
                                   t
                                   (claude-shell--make-buffer-name))))
      (claude-shell--set-primary-buffer primary-shell-buffer))
    primary-shell-buffer))

(defun claude-shell--make-buffer-name ()
  "Generate a buffer name using current shell config info."
  (format "%s %s"
          (shell-maker-buffer-default-name
           (shell-maker-config-name claude-shell--config))
          (claude-shell--shell-info)))

(defun claude-shell--add-menus ()
  "Add Claude shell menu items."
  (unless (eq major-mode 'claude-shell-mode)
    (user-error "Not in a shell"))
  (when-let ((duplicates (claude-shell-duplicate-map-keys claude-shell-system-prompts)))
    (user-error "Duplicate prompt names found %s. Please remove.?" duplicates))
  (easy-menu-define claude-shell-system-prompts-menu (current-local-map) "Claude"
    `("Claude"
      ("Versions"
       ,@(mapcar (lambda (version)
                   `[,version
                     (lambda ()
                       (interactive)
                       (setq-local claude-shell-model-version
                                   (seq-position claude-shell-model-versions ,version))
                       (claude-shell--update-prompt t)
                       (claude-shell-interrupt nil))])
                 claude-shell-model-versions))
      ("Prompts"
       ,@(mapcar (lambda (prompt)
                   `[,(car prompt)
                     (lambda ()
                       (interactive)
                       (setq-local claude-shell-system-prompt
                                   (seq-position (map-keys claude-shell-system-prompts) ,(car prompt)))
                       (claude-shell--update-prompt t)
                       (claude-shell-interrupt nil))])
                 claude-shell-system-prompts))))
  (easy-menu-add claude-shell-system-prompts-menu))

(defun claude-shell--update-prompt (rename-buffer)
  "Update prompt and prompt regexp from `claude-shell-model-versions'.

Set RENAME-BUFFER to also rename the buffer accordingly."
  (unless (eq major-mode 'claude-shell-mode)
    (user-error "Not in a shell"))
  (shell-maker-set-prompt
   (car (claude-shell--prompt-pair))
   (cdr (claude-shell--prompt-pair)))
  (when rename-buffer
    (shell-maker-set-buffer-name
     (current-buffer)
     (claude-shell--make-buffer-name))))

(defun claude-shell--adviced:keyboard-quit (orig-fun &rest args)
  "Advice around `keyboard-quit' interrupting active shell.

Applies ORIG-FUN and ARGS."
  (claude-shell-interrupt nil)
  (apply orig-fun args))

(defun claude-shell-interrupt (ignore-item)
  "Interrupt `claude-shell' from any buffer.

With prefix IGNORE-ITEM, do not mark as failed."
  (interactive "P")
  (with-current-buffer
      (cond
       ((eq major-mode 'claude-shell-mode)
        (current-buffer))
       (t
        (shell-maker-buffer-name claude-shell--config)))
    (shell-maker-interrupt ignore-item)))

(defun claude-shell-ctrl-c-ctrl-c (ignore-item)
  "If point in source block, execute it.  Otherwise interrupt.

With prefix IGNORE-ITEM, do not use interrupted item in context."
  (interactive "P")
  (cond ((claude-shell-block-action-at-point)
         (claude-shell-execute-block-action-at-point))
        ((claude-shell-markdown-block-at-point)
         (user-error "No action available"))
        ((and shell-maker--busy
              (eq (line-number-at-pos (point-max))
                  (line-number-at-pos (point))))
         (shell-maker-interrupt ignore-item))
        (t
         (shell-maker-interrupt ignore-item))))

(defun claude-shell-mark-at-point-dwim ()
  "Mark source block if at point.  Mark all output otherwise."
  (interactive)
  (if-let ((block (claude-shell-markdown-block-at-point)))
      (progn
        (set-mark (map-elt block 'end))
        (goto-char (map-elt block 'start)))
    (shell-maker-mark-output)))

(defun claude-shell-markdown-block-language (text)
  "Get the language label of a Markdown TEXT code block."
  (when (string-match (rx bol "```" (0+ space) (group (+ (not (any "\n"))))) text)
    (match-string 1 text)))

(defun claude-shell-markdown-block-at-point ()
  "Markdown start/end cons if point at block.  nil otherwise."
  (save-excursion
    (save-restriction
      (when (eq major-mode 'claude-shell-mode)
        (shell-maker-narrow-to-prompt))
      (let* ((language)
             (language-start)
             (language-end)
             (start (save-excursion
                      (when (re-search-backward "^```" nil t)
                        (setq language (claude-shell-markdown-block-language (thing-at-point 'line)))
                        (save-excursion
                          (forward-char 3) ; ```
                          (setq language-start (point))
                          (end-of-line)
                          (setq language-end (point)))
                        language-end)))
             (end (save-excursion
                    (when (re-search-forward "^```" nil t)
                      (forward-line 0)
                      (point)))))
        (when (and start end
                   (> (point) start)
                   (< (point) end))
          (list (cons 'language language)
                (cons 'language-start language-start)
                (cons 'language-end language-end)
                (cons 'start start)
                (cons 'end end)))))))

;; TODO: Move to shell-maker.
(defun claude-shell--markdown-headers (&optional avoid-ranges)
  "Extract markdown headers with AVOID-RANGES."
  (let ((headers '())
        (case-fold-search nil))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward
              (rx bol (group (one-or-more "#"))
                  (one-or-more space)
                  (group (one-or-more (not (any "\n")))) eol)
              nil t)
        (when-let ((begin (match-beginning 0))
                   (end (match-end 0)))
          (unless (seq-find (lambda (avoided)
                              (and (>= begin (car avoided))
                                   (<= end (cdr avoided))))
                            avoid-ranges)
            (push
             (list
              'start begin
              'end end
              'level (cons (match-beginning 1) (match-end 1))
              'title (cons (match-beginning 2) (match-end 2)))
             headers)))))
    (nreverse headers)))

;; TODO: Move to shell-maker.
(defun claude-shell--markdown-links (&optional avoid-ranges)
  "Extract markdown links with AVOID-RANGES."
  (let ((links '())
        (case-fold-search nil))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward
              (rx (seq "["
                       (group (one-or-more (not (any "]"))))
                       "]"
                       "("
                       (group (one-or-more (not (any ")"))))
                       ")"))
              nil t)
        (when-let ((begin (match-beginning 0))
                   (end (match-end 0)))
          (unless (seq-find (lambda (avoided)
                              (and (>= begin (car avoided))
                                   (<= end (cdr avoided))))
                            avoid-ranges)
            (push
             (list
              'start begin
              'end end
              'title (cons (match-beginning 1) (match-end 1))
              'url (cons (match-beginning 2) (match-end 2)))
             links)))))
    (nreverse links)))

;; TODO: Move to shell-maker.
(defun claude-shell--markdown-bolds (&optional avoid-ranges)
  "Extract markdown bolds with AVOID-RANGES."
  (let ((bolds '())
        (case-fold-search nil))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward
              (rx (or (group "**" (group (one-or-more (not (any "\n*")))) "**")
                      (group "__" (group (one-or-more (not (any "\n_")))) "__")))
              nil t)
        (when-let ((begin (match-beginning 0))
                   (end (match-end 0)))
          (unless (seq-find (lambda (avoided)
                              (and (>= begin (car avoided))
                                   (<= end (cdr avoided))))
                            avoid-ranges)
            (push
             (list
              'start begin
              'end end
              'text (cons (or (match-beginning 2)
                              (match-beginning 4))
                          (or (match-end 2)
                              (match-end 4))))
             bolds)))))
    (nreverse bolds)))

;; TODO: Move to shell-maker.
(defun claude-shell--markdown-strikethroughs (&optional avoid-ranges)
  "Extract markdown strikethroughs with AVOID-RANGES."
  (let ((strikethroughs '())
        (case-fold-search nil))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward
              (rx "~~" (group (one-or-more (not (any "\n~")))) "~~")
              nil t)
        (when-let ((begin (match-beginning 0))
                   (end (match-end 0)))
          (unless (seq-find (lambda (avoided)
                              (and (>= begin (car avoided))
                                   (<= end (cdr avoided))))
                            avoid-ranges)
            (push
             (list
              'start begin
              'end end
              'text (cons (match-beginning 1)
                          (match-end 1)))
             strikethroughs)))))
    (nreverse strikethroughs)))

;; TODO: Move to shell-maker.
(defun claude-shell--markdown-italics (&optional avoid-ranges)
  "Extract markdown italics with AVOID-RANGES."
  (let ((italics '())
        (case-fold-search nil))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward
              (rx (or (group (or bol (one-or-more (any "\n \t")))
                             (group "*")
                             (group (one-or-more (not (any "\n*")))) "*")
                      (group (or bol (one-or-more (any "\n \t")))
                             (group "_")
                             (group (one-or-more (not (any "\n_")))) "_")))
              nil t)
        (when-let ((begin (match-beginning 0))
                   (end (match-end 0)))
          (unless (seq-find (lambda (avoided)
                              (and (>= begin (car avoided))
                                   (<= end (cdr avoided))))
                            avoid-ranges)
            (push
             (list
              'start (or (match-beginning 2)
                         (match-beginning 5))
              'end end
              'text (cons (or (match-beginning 3)
                              (match-beginning 6))
                          (or (match-end 3)
                              (match-end 6))))
             italics)))))
    (nreverse italics)))

;; TODO: Move to shell-maker.
(defun claude-shell--markdown-inline-codes (&optional avoid-ranges)
  "Get a list of all inline markdown code in buffer with AVOID-RANGES."
  (let ((codes '())
        (case-fold-search nil))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward
              "`\\([^`\n]+\\)`"
              nil t)
        (when-let ((begin (match-beginning 0))
                   (end (match-end 0)))
          (unless (seq-find (lambda (avoided)
                              (and (>= begin (car avoided))
                                   (<= end (cdr avoided))))
                            avoid-ranges)
            (push
             (list
              'body (cons (match-beginning 1) (match-end 1))) codes)))))
    (nreverse codes)))

;; TODO: Move to shell-maker.
(defvar claude-shell--source-block-regexp
  (rx  bol (zero-or-more whitespace) (group "```") (zero-or-more whitespace) ;; ```
       (group (zero-or-more (or alphanumeric "-" "+"))) ;; language
       (zero-or-more whitespace)
       (one-or-more "\n")
       (group (*? anychar)) ;; body
       (one-or-more "\n")
       (group "```") (or "\n" eol)))

(defvar-local claude-shell--is-primary-p nil)

(defun claude-shell-next-source-block ()
  "Move point to previous source block."
  (interactive)
  (when-let
      ((next-block
        (save-excursion
          (when-let ((current (claude-shell-markdown-block-at-point)))
            (goto-char (map-elt current 'end))
            (end-of-line))
          (when (re-search-forward claude-shell--source-block-regexp nil t)
            (claude-shell--match-source-block)))))
    (goto-char (car (map-elt next-block 'body)))))

(defun claude-shell-previous-item ()
  "Go to previous item.

Could be a prompt or a source block."
  (interactive)
  (unless (eq major-mode 'claude-shell-mode)
    (user-error "Not in a shell"))
  (let ((prompt-pos (save-excursion
                      (when (comint-next-prompt (- 1))
                        (point))))
        (block-pos (save-excursion
                     (when (claude-shell-previous-source-block)
                       (point)))))
    (cond ((and block-pos prompt-pos)
           (goto-char (max prompt-pos
                           block-pos)))
          (block-pos
           (goto-char block-pos))
          (prompt-pos
           (goto-char prompt-pos)))))

(defun claude-shell-next-item ()
  "Go to next item.

Could be a prompt or a source block."
  (interactive)
  (unless (eq major-mode 'claude-shell-mode)
    (user-error "Not in a shell"))
  (let ((prompt-pos (save-excursion
                      (when (comint-next-prompt 1)
                        (point))))
        (block-pos (save-excursion
                     (when (claude-shell-next-source-block)
                       (point)))))
    (cond ((and block-pos prompt-pos)
           (goto-char (min prompt-pos
                           block-pos)))
          (block-pos
           (goto-char block-pos))
          (prompt-pos
           (goto-char prompt-pos)))))

(defun claude-shell-previous-source-block ()
  "Move point to previous source block."
  (interactive)
  (when-let
      ((previous-block
        (save-excursion
          (when-let ((current (claude-shell-markdown-block-at-point)))
            (goto-char (map-elt current 'start))
            (forward-line 0))
          (when (re-search-backward claude-shell--source-block-regexp nil t)
            (claude-shell--match-source-block)))))
    (goto-char (car (map-elt previous-block 'body)))))

;; TODO: Move to shell-maker.
(defun claude-shell--match-source-block ()
  "Return a matched source block by the previous search/regexp operation."
  (list
   'start (cons (match-beginning 1)
                (match-end 1))
   'end (cons (match-beginning 4)
              (match-end 4))
   'language (when (and (match-beginning 2)
                        (match-end 2))
               (cons (match-beginning 2)
                     (match-end 2)))
   'body (cons (match-beginning 3) (match-end 3))))

;; TODO: Move to shell-maker.
(defun claude-shell--source-blocks ()
  "Get a list of all source blocks in buffer."
  (let ((markdown-blocks '())
        (case-fold-search nil))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward
              claude-shell--source-block-regexp
              nil t)
        (when-let ((begin (match-beginning 0))
                   (end (match-end 0)))
          (push (claude-shell--match-source-block)
                markdown-blocks))))
    (nreverse markdown-blocks)))

(defun claude-shell--minibuffer-prompt ()
  "Construct a prompt for the minibuffer."
  (if (claude-shell--primary-buffer)
      (concat (buffer-name (claude-shell--primary-buffer)) "> ")
    (shell-maker-prompt
     claude-shell--config)))

(defun claude-shell-prompt ()
  "Make a Claude request from the minibuffer.

If region is active, append to prompt."
  (interactive)
  (unless claude-shell--prompt-history
    (setq claude-shell--prompt-history
          claude-shell-default-prompts))
  (let ((overlay-blocks (derived-mode-p 'prog-mode))
        (prompt (funcall shell-maker-read-string-function
                         (concat
                          (if (region-active-p)
                              "[appending region] "
                            "")
                          (claude-shell--minibuffer-prompt))
                         'claude-shell--prompt-history)))
    (when (string-empty-p (string-trim prompt))
      (user-error "Nothing to send"))
    (when (region-active-p)
      (setq prompt (concat prompt "\n\n"
                           (if overlay-blocks
                               (format "``` %s\n"
                                       (string-remove-suffix "-mode" (format "%s" major-mode)))
                             "")
                           (buffer-substring (region-beginning) (region-end))
                           (if overlay-blocks
                               "\n```"
                             ""))))
    (claude-shell-send-to-buffer prompt nil)))

(defun claude-shell-prompt-appending-kill-ring ()
  "Make a Claude request from the minibuffer appending kill ring."
  (interactive)
  (unless claude-shell--prompt-history
    (setq claude-shell--prompt-history
          claude-shell-default-prompts))
  (let ((prompt (funcall shell-maker-read-string-function
                         (concat
                          "[appending kill ring] "
                          (claude-shell--minibuffer-prompt))
                         'claude-shell--prompt-history)))
    (claude-shell-send-to-buffer
     (concat prompt "\n\n"
             (current-kill 0)) nil)))

(defun claude-shell-describe-code ()
  "Describe code from region using Claude."
  (interactive)
  (unless (region-active-p)
    (user-error "No region active"))
  (let ((overlay-blocks (derived-mode-p 'prog-mode)))
    (claude-shell-send-to-buffer
     (concat claude-shell-prompt-header-describe-code
             "\n\n"
             (if overlay-blocks
                 (format "``` %s\n"
                         (string-remove-suffix "-mode" (format "%s" major-mode)))
               "")
             (buffer-substring (region-beginning) (region-end))
             (if overlay-blocks
                 "\n```"
               "")) nil)
    (when overlay-blocks
      (with-current-buffer
          (claude-shell--primary-buffer)
        (claude-shell--put-source-block-overlays)))))

(defun claude-shell-send-region-with-header (header)
  "Send text with HEADER from region using Claude."
  (unless (region-active-p)
    (user-error "No region active"))
  (let ((question (concat header "\n\n" (buffer-substring (region-beginning) (region-end)))))
    (claude-shell-send-to-buffer question nil)))

;;;###autoload
(defun claude-shell-refactor-code ()
  "Refactor code from region using Claude."
  (interactive)
  (claude-shell-send-region-with-header claude-shell-prompt-header-refactor-code))

;;;###autoload
(defun claude-shell-write-git-commit ()
  "Write commit from region using Claude."
  (interactive)
  (claude-shell-send-region-with-header claude-shell-prompt-header-write-git-commit))

;;;###autoload
(defun claude-shell-generate-unit-test ()
  "Generate unit-test for the code from region using Claude."
  (interactive)
  (claude-shell-send-region-with-header claude-shell-prompt-header-generate-unit-test))

;;;###autoload
(defun claude-shell-proofread-region ()
  "Proofread English from region using Claude."
  (interactive)
  (claude-shell-send-region-with-header claude-shell-prompt-header-proofread-region))

;;;###autoload
(defun claude-shell-eshell-whats-wrong-with-last-command ()
  "Ask Claude what's wrong with the last eshell command."
  (interactive)
  (let ((claude-shell-prompt-query-response-style 'other-buffer))
    (claude-shell-send-to-buffer
     (concat claude-shell-prompt-header-whats-wrong-with-last-command
             "\n\n"
             (buffer-substring-no-properties eshell-last-input-start eshell-last-input-end)
             "\n\n"
             (buffer-substring-no-properties (eshell-beginning-of-output) (eshell-end-of-output))))))

;;;###autoload
(defun claude-shell-eshell-summarize-last-command-output ()
  "Ask Claude to summarize the last command output."
  (interactive)
  (let ((claude-shell-prompt-query-response-style 'other-buffer))
    (claude-shell-send-to-buffer
     (concat claude-shell-prompt-header-eshell-summarize-last-command-output
             "\n\n"
             (buffer-substring-no-properties eshell-last-input-start eshell-last-input-end)
             "\n\n"
             (buffer-substring-no-properties (eshell-beginning-of-output) (eshell-end-of-output))))))

;;;###autoload
(defun claude-shell-send-region (review)
  "Send region to Claude.
With prefix REVIEW prompt before sending to Claude."
  (interactive "P")
  (unless (region-active-p)
    (user-error "No region active"))
  (let ((claude-shell-prompt-query-response-style 'shell)
        (region-text (buffer-substring (region-beginning) (region-end))))
    (claude-shell-send-to-buffer
     (if review
         (concat "\n\n" region-text)
       region-text) review)))

;;;###autoload
(defun claude-shell-send-and-review-region ()
  "Send region to Claude, review before submitting."
  (interactive)
  (claude-shell-send-region t))

(defun claude-shell-command-line-from-prompt-file (file-path)
  "Send prompt in FILE-PATH and output to standard output."
  (let ((prompt (with-temp-buffer
                  (insert-file-contents file-path)
                  (buffer-string))))
    (if (string-empty-p (string-trim prompt))
        (princ (format "Could not read prompt from %s" file-path)
               #'external-debugging-output)
      (claude-shell-command-line prompt))))

(defun claude-shell-command-line (prompt)
  "Send PROMPT and output to standard output."
  (let ((claude-shell-prompt-query-response-style 'shell)
        (worker-done nil)
        (buffered ""))
    (claude-shell-send-to-buffer
     prompt nil
     (lambda (_command output _error finished)
       (setq buffered (concat buffered output))
       (when finished
         (setq worker-done t))))
    (while buffered
      (unless (string-empty-p buffered)
        (princ buffered #'external-debugging-output))
      (setq buffered "")
      (when worker-done
        (setq buffered nil))
      (sleep-for 0.1))
    (princ "\n")))

(defun claude-shell--eshell-last-last-command ()
  "Get second to last eshell command."
  (save-excursion
    (if (string= major-mode "eshell-mode")
        (let ((cmd-start)
              (cmd-end))
          ;; Find command start and end positions
          (goto-char eshell-last-output-start)
          (re-search-backward eshell-prompt-regexp nil t)
          (setq cmd-start (point))
          (goto-char eshell-last-output-start)
          (setq cmd-end (point))

          ;; Find output start and end positions
          (goto-char eshell-last-output-start)
          (forward-line 1)
          (re-search-forward eshell-prompt-regexp nil t)
          (forward-line -1)
          (concat "What's wrong with this command?\n\n"
                  (buffer-substring-no-properties cmd-start cmd-end)))
      (message "Current buffer is not an eshell buffer."))))

;; Based on https://emacs.stackexchange.com/a/48215
(defun claude-shell--source-eshell-string (string)
  "Execute eshell command in STRING."
  (let ((orig (point))
        (here (point-max))
        (inhibit-point-motion-hooks t))
    (goto-char (point-max))
    (with-silent-modifications
      ;; FIXME: Use temporary buffer and avoid insert/delete.
      (insert string)
      (goto-char (point-max))
      (throw 'eshell-replace-command
             (prog1
                 (list 'let
                       (list (list 'eshell-command-name (list 'quote "source-string"))
                             (list 'eshell-command-arguments '()))
                       (eshell-parse-command (cons here (point))))
               (delete-region here (point))
               (goto-char orig))))))

(defun claude-shell-add-??-command-to-eshell ()
  "Add `??' command to `eshell'."

  (defun eshell/?? (&rest _args)
    "Implements `??' eshell command."
    (interactive)
    (let ((prompt (concat
                   "What's wrong with the following command execution?\n\n"
                   (claude-shell--eshell-last-last-command)))
          (prompt-file (concat temporary-file-directory
                               "claude-shell-command-line-prompt")))
      (when (file-exists-p prompt-file)
        (delete-file prompt-file))
      (with-temp-file prompt-file nil nil t
                      (insert prompt))
      (claude-shell--source-eshell-string
       (concat
        (file-truename (expand-file-name invocation-name invocation-directory)) " "
        "--quick --batch --eval "
        "'"
        (prin1-to-string
         `(progn
            (interactive)
            (load ,(find-library-name "shell-maker") nil t)
            (load ,(find-library-name "claude-shell") nil t)
            (require (intern "claude-shell") nil t)
            (setq claude-shell-model-temperature 0)
            (setq claude-shell-anthropic-key ,(claude-shell-anthropic-key))
            (claude-shell-command-line-from-prompt-file ,prompt-file)))
        "'"))))

  (add-hook 'eshell-post-command-hook
            (defun claude-shell--eshell-post-??-execution ()
              (when (string-match (symbol-name #'claude-shell-command-line-from-prompt-file)
                                  (string-join eshell-last-arguments " "))
                (save-excursion
                  (save-restriction
                    (narrow-to-region (eshell-beginning-of-output)
                                      (eshell-end-of-output))
                    (claude-shell--put-source-block-overlays))))))

  (require 'esh-cmd)

  (add-to-list 'eshell-complex-commands "??"))

(define-derived-mode claude-shell-prompt-other-buffer-response-mode
  fundamental-mode "Claude response"
  "Major mode for buffers created by `other-buffer' `claude-shell-prompt-query-response-style'.")

(defun claude-shell-send-to-buffer (text &optional review handler on-finished)
  "Send TEXT to *claude* buffer.
Set REVIEW to make changes before submitting to Claude.

If HANDLER function is set, ignore `claude-shell-prompt-query-response-style'

ON-FINISHED is invoked when the entire interaction is finished."
  (if (eq claude-shell-prompt-query-response-style 'other-buffer)
      (let ((buffer (claude-shell-prompt-compose-show-buffer text)))
        (unless review
          (with-current-buffer buffer
            (claude-shell-prompt-compose-send-buffer))))
    (let* ((buffer (cond (handler
                          nil)
                         ((eq claude-shell-prompt-query-response-style 'inline)
                          (current-buffer))
                         (t
                          nil)))
           (point (point))
           (marker (copy-marker (point)))
           (orig-region-active (region-active-p))
           (no-focus (or (eq claude-shell-prompt-query-response-style 'inline)
                         handler)))
      (when (region-active-p)
        (setq marker (copy-marker (max (region-beginning)
                                       (region-end)))))
      (if (claude-shell--primary-buffer)
          (with-current-buffer (claude-shell--primary-buffer)
            (claude-shell-start no-focus))
        (claude-shell-start no-focus t))
      (cl-flet ((send ()
                  (when shell-maker--busy
                    (shell-maker-interrupt nil))
                  (goto-char (point-max))
                  (if review
                      (save-excursion
                        (insert text))
                    (insert text)
                    (shell-maker--send-input
                     (if (eq claude-shell-prompt-query-response-style 'inline)
                         (lambda (_command output error finished)
                           (setq output (or output ""))
                           (when (buffer-live-p buffer)
                             (with-current-buffer buffer
                               (if error
                                   (unless (string-empty-p (string-trim output))
                                     (message "%s" output))
                                 (let ((inhibit-read-only t))
                                   (save-excursion
                                     (if orig-region-active
                                         (progn
                                           (goto-char marker)
                                           (when (eq (marker-position marker)
                                                     point)
                                             (insert "\n\n")
                                             (set-marker marker (+ 2 (marker-position marker))))
                                           (insert output)
                                           (set-marker marker (+ (length output)
                                                                 (marker-position marker))))
                                       (goto-char marker)
                                       (insert output)
                                       (set-marker marker (+ (length output)
                                                             (marker-position marker))))))))
                             (when (and finished on-finished)
                               (funcall on-finished))))
                       (or handler (lambda (_command _output _error _finished))))
                     t))))
        (if (or (eq claude-shell-prompt-query-response-style 'inline)
                handler)
            (with-current-buffer (claude-shell--primary-buffer)
              (goto-char (point-max))
              (send))
          (with-selected-window (get-buffer-window (claude-shell--primary-buffer))
            (send)))))))

(defun claude-shell-send-to-ielm-buffer (text &optional execute save-excursion)
  "Send TEXT to *ielm* buffer.
Set EXECUTE to automatically execute.
Set SAVE-EXCURSION to prevent point from moving."
  (ielm)
  (with-current-buffer (get-buffer-create "*ielm*")
    (goto-char (point-max))
    (if save-excursion
        (save-excursion
          (insert text))
      (insert text))
    (when execute
      (ielm-return))))

(defun claude-shell-parse-elisp-code (code)
  "Parse emacs-lisp CODE and return a list of expressions."
  (with-temp-buffer
    (insert code)
    (goto-char (point-min))
    (let (sexps)
      (while (not (eobp))
        (condition-case nil
            (push (read (current-buffer)) sexps)
          (error nil)))
      (reverse sexps))))

(defun claude-shell-split-elisp-expressions (code)
  "Split emacs-lisp CODE into a list of stringified expressions."
  (mapcar
   (lambda (form)
     (prin1-to-string form))
   (claude-shell-parse-elisp-code code)))


(defun claude-shell-make-request-data (messages &optional version temperature other-params)
  "Make request data from MESSAGES, VERSION, TEMPERATURE, and OTHER-PARAMS."
  (let ((request-data `((model . ,(or version
                                      (claude-shell-model-version)))
                        (messages . ,(vconcat ;; Vector for json
                                      messages)))))
    (when (or temperature claude-shell-model-temperature)
      (push `(temperature . ,(or temperature claude-shell-model-temperature))
            request-data))
    (when other-params
      (push other-params
            request-data))
    request-data))

(defun claude-shell-post-messages (messages response-extractor &optional version callback error-callback temperature other-params)
  "Make a single Claude request with MESSAGES and RESPONSE-EXTRACTOR.

`claude-shell--extract-claude-response' typically used as extractor.

Optionally pass model VERSION, CALLBACK, ERROR-CALLBACK, TEMPERATURE
and OTHER-PARAMS.

OTHER-PARAMS are appended to the json object at the top level.

If CALLBACK or ERROR-CALLBACK are missing, execute synchronously.

For example:

\(claude-shell-post-messages
 `(((role . \"user\")
    (content . \"hello\")))
 \"gpt-3.5-turbo\"
 (lambda (response)
   (message \"%s\" response))
 (lambda (error)
   (message \"%s\" error)))"
  (if (and callback error-callback)
      (progn
        (unless (boundp 'shell-maker--current-request-id)
          (defvar-local shell-maker--current-request-id 0))
        (with-temp-buffer
          (setq-local shell-maker--config
                      claude-shell--config)
          (shell-maker-async-shell-command
           (claude-shell--make-curl-request-command-list
            (claude-shell-make-request-data messages version temperature other-params))
           nil ;; streaming
           (or response-extractor #'claude-shell--extract-claude-response)
           callback
           error-callback)))
    (with-temp-buffer
      (setq-local shell-maker--config
                  claude-shell--config)
      (let* ((buffer (current-buffer))
             (command
              (claude-shell--make-curl-request-command-list
               (let ((request-data `((model . ,(or version
                                                   (claude-shell-model-version)))
                                     (messages . ,(vconcat ;; Vector for json
                                                   messages)))))
                 (when (or temperature claude-shell-model-temperature)
                   (push `(temperature . ,(or temperature claude-shell-model-temperature))
                         request-data))
                 (when other-params
                   (push other-params
                         request-data))
                 request-data)))
             (config claude-shell--config)
             (status (progn
                       (shell-maker--write-output-to-log-buffer "// Request\n\n" config)
                       (shell-maker--write-output-to-log-buffer (string-join command " ") config)
                       (shell-maker--write-output-to-log-buffer "\n\n" config)
                       (apply #'call-process (seq-first command) nil buffer nil (cdr command))))
             (data (buffer-substring-no-properties (point-min) (point-max)))
             (response (claude-shell--extract-claude-response data)))
        (shell-maker--write-output-to-log-buffer (format "// Data (status: %d)\n\n" status) config)
        (shell-maker--write-output-to-log-buffer data config)
        (shell-maker--write-output-to-log-buffer "\n\n" config)
        (shell-maker--write-output-to-log-buffer "// Response\n\n" config)
        (shell-maker--write-output-to-log-buffer response config)
        (shell-maker--write-output-to-log-buffer "\n\n" config)
        response))))

(defun claude-shell-describe-image ()
  "Request Anthropic to describe image.

When visiting a buffer with an image, send that.

If in a `dired' buffer, use selection (single image only for now)."
  (interactive)
  (let* ((file (claude-shell--current-file))
         (extension (downcase (file-name-extension file))))
    (unless (seq-contains-p '("jpg" "jpeg" "png" "webp" "gif") extension)
      (user-error "Must be user either .jpg, .jpeg, .png, .webp or .gif file"))
    (claude-shell-vision-make-request
     (read-string "Send vision prompt (default \"What’s in this image?\"): " nil nil "What’s in this image?")
     file)))

(defun claude-shell--current-file ()
  "Return buffer file (if available) or Dired selected file."
  (when (use-region-p)
    (user-error "No region selection supported"))
  (if (buffer-file-name)
      (buffer-file-name)
    (let* ((dired-files (dired-get-marked-files))
           (file (seq-first dired-files)))
      (unless dired-files
        (user-error "No file selected"))
      (when (> (length dired-files) 1)
        (user-error "Only one file selection supported"))
      file)))

(cl-defun claude-shell-vision-make-request (prompt url-path &key on-success on-failure)
  "Make a vision request using PROMPT and URL-PATH.

PROMPT can be somethign like: \"Describe the image in detail\".
URL-PATH can be either a local file path or an http:// URL.

Optionally pass ON-SUCCESS and ON-FAILURE, like:

\(lambda (response)
  (message response))

\(lambda (error)
  (message error))"
  (let* ((url (if (string-prefix-p "http" url-path)
                  url-path
                (unless (file-exists-p url-path)
                  (error "File not found"))
                (concat "data:image/jpeg;base64,"
                        (with-temp-buffer
                          (insert-file-contents-literally url-path)
                          (base64-encode-region (point-min) (point-max) t)
                          (buffer-string)))))
         (messages
          (vconcat ;; Convert to vector for json
           (append
            `(((role . "user")
               (content . ,(vconcat
                            `(((type . "text")
                               (text . ,prompt))
                              ((type . "image_url")
                               (image_url . ,url)))))))))))
    (message "Requesting...")
    (claude-shell-post-messages
     messages
     #'claude-shell--extract-claude-response
     "gpt-4-vision-preview"
     (if on-success
         (lambda (response _partial)
           (funcall on-success response))
       (lambda (response _partial)
         (message response)))
     (or on-failure (lambda (error)
                      (message error)))
     nil '(max_tokens . 300))))

(defun claude-shell-post-prompt (prompt &optional response-extractor version callback error-callback temperature other-params)
  "Make a single Claude request with PROMPT.
Optionally pass model RESPONSE-EXTRACTOR, VERSION, CALLBACK,
ERROR-CALLBACK, TEMPERATURE, and OTHER-PARAMS.

`claude-shell--extract-claude-response' typically used as extractor.

If CALLBACK or ERROR-CALLBACK are missing, execute synchronously.

OTHER-PARAMS are appended to the json object at the top level.

For example:

\(claude-shell-post-prompt
 \"hello\"
 nil
 \"gpt-3.5-turbo\"
 (lambda (response more-pending)
   (message \"%s\" response))
 (lambda (error)
   (message \"%s\" error)))."
  (claude-shell-post-messages `(((role . "user")
                                  (content . ,prompt)))
                               (or response-extractor #'claude-shell--extract-claude-response)
                               version
                               callback
                               error-callback
                               temperature
                               other-params))

(defun claude-shell-anthropic-key ()
  "Get the Claude key."
  (cond ((stringp claude-shell-anthropic-key)
         claude-shell-anthropic-key)
        ((functionp claude-shell-anthropic-key)
         (condition-case _err
             (funcall claude-shell-anthropic-key)
           (error
            "KEY-NOT-FOUND")))
        (t
         nil)))

(defun claude-shell--api-url ()
  "The complete URL to Anthropic's API.

`claude-shell--api-url' =
   `claude-shell--api-url-base' + `claude-shell--api-url-path'"
  (concat claude-shell-api-url-base claude-shell-api-url-path))

(defun claude-shell--json-request-file ()
  "JSON request written to this file prior to sending."
  (concat
   (file-name-as-directory
    (shell-maker-files-path shell-maker--config))
   "request.json"))

(defun claude-shell--make-curl-request-command-list (request-data)
  "Build Claude curl command list using REQUEST-DATA."
  (let ((json-path (claude-shell--json-request-file)))
    (with-temp-file json-path
      (when (eq system-type 'windows-nt)
        (setq-local buffer-file-coding-system 'utf-8))
      (insert (shell-maker--json-encode request-data)))
    (append (list "curl" (claude-shell--api-url))
            claude-shell-additional-curl-options
            (list "--fail-with-body"
                  "--no-progress-meter"
                  "-m" (number-to-string claude-shell-request-timeout)
                  "-H" "Content-Type: application/json; charset=utf-8"
                  "--http1.1"
                  "-H" (funcall claude-shell-auth-header)
                  "-d" (format "@%s" json-path)))))

(defun claude-shell--make-payload (history)
  "Create the request payload from HISTORY."
  (let* ((history-vector
          (vconcat
           (claude-shell--user-assistant-messages
            (last history (claude-shell--unpaired-length
                           (if (functionp claude-shell-transmitted-context-length)
                               (funcall claude-shell-transmitted-context-length (claude-shell-model-version) history)
                             claude-shell-transmitted-context-length))))))
         (request-data
          `((model . ,(claude-shell-model-version))
            (messages . ,history-vector)
            (max_tokens . 4096))))  ; Added max_tokens field
    
    ;; Add system message as a top-level field if present
    (when (claude-shell-system-prompt)
      (push `(system . ,(claude-shell-system-prompt)) request-data))
    
    ;; Add temperature if set
    (when claude-shell-model-temperature
      (push `(temperature . ,claude-shell-model-temperature) request-data))
    
    ;; Add streaming option if set
    (when claude-shell-streaming
      (push `(stream . t) request-data))
    
    request-data))

(defun claude-shell--approximate-context-length (model messages)
  "Approximate the context length using MODEL and MESSAGES."
  (let* ((tokens-per-message)
         (max-tokens)
         (original-length (floor (/ (length messages) 2)))
         (context-length original-length))
    ;; Remove "ft:" from fine-tuned models and recognize as usual
    (setq model (string-remove-prefix "ft:" model))
    ;; TODO: Find best values for each model.
    ;; https://docs.anthropic.com/en/docs/about-claude/models
    (setq tokens-per-message 4 max-tokens 4096)
    
    (while (> (claude-shell--num-tokens-from-messages
               tokens-per-message messages)
              max-tokens)
      (setq messages (cdr messages)))
    (setq context-length (floor (/ (length messages) 2)))
    (unless (eq original-length context-length)
      (message "Warning: claude-shell context clipped"))
    context-length))

;; Very rough token approximation loosely based on num_tokens_from_messages from:
;; https://github.com/openai/openai-cookbook/blob/main/examples/How_to_count_tokens_with_tiktoken.ipynb
(defun claude-shell--num-tokens-from-messages (tokens-per-message messages)
  "Approximate number of tokens in MESSAGES using TOKENS-PER-MESSAGE."
  (let ((num-tokens 0))
    (dolist (message messages)
      (setq num-tokens (+ num-tokens tokens-per-message))
      (setq num-tokens (+ num-tokens (/ (length (cdr message)) tokens-per-message))))
    ;; Every reply is primed with <|start|>assistant<|message|>
    (setq num-tokens (+ num-tokens 3))
    num-tokens))

(defun claude-shell--extract-claude-response (json)
  "Extract Claude response from JSON, handling both streaming and non-streaming formats."
  (if (eq (type-of json) 'cons)
      (let-alist json ;; already parsed
        (cond
         ;; Streaming response - content block delta
         ((string= .type "content_block_delta")
          (let-alist .delta
            (cond
             ((string= .type "text_delta") .text)
             ((string= .type "input_json_delta") .partial_json)
             (t ""))))
         ;; Streaming response - message start
         ((string= .type "message_start")
          "")  ; Return empty string, actual content will come in deltas
         ;; Streaming response - message delta (e.g., stop reason)
         ((string= .type "message_delta")
          "")  ; Typically doesn't contain content to display
         ;; Non-streaming response
         (.content
          (let-alist (seq-first .content)
            (or .text "")))
         ;; Error message
         (.error
          (or .error.message "An error occurred"))
         ;; Default case
         (t "")))
    ;; JSON is a string, need to parse
    (if-let (parsed (shell-maker--json-parse-string json))
        (claude-shell--extract-claude-response parsed)  ; Recurse with parsed JSON
      ;; Parsing failed, try to extract error message
      (if-let (parsed-error (shell-maker--json-parse-string-filtering
                             json "^curl:.*\n?"))
          (let-alist parsed-error
            (or .error.message "An error occurred"))
        ;; If all else fails, return empty string
        ""))))

;; FIXME: Make shell agnostic or move to claude-shell.
(defun claude-shell-restore-session-from-transcript ()
  "Restore session from transcript.

Very much EXPERIMENTAL."
  (interactive)
  (unless (eq major-mode 'claude-shell-mode)
    (user-error "Not in a shell"))
  (let* ((dir (when shell-maker-transcript-default-path
                (file-name-as-directory shell-maker-transcript-default-path)))
         (path (read-file-name "Restore from: " dir nil t))
         (prompt-regexp (shell-maker-prompt-regexp shell-maker--config))
         (history (with-temp-buffer
                    (insert-file-contents path)
                    (claude-shell--extract-history
                     (buffer-substring-no-properties
                      (point-min) (point-max))
                     prompt-regexp)))
         (execute-command (shell-maker-config-execute-command
                           shell-maker--config))
         (validate-command (shell-maker-config-validate-command
                            shell-maker--config))
         (command)
         (response)
         (failed))
    ;; Momentarily overrides request handling to replay all commands
    ;; read from file so comint treats all commands/outputs like
    ;; any other command.
    (unwind-protect
        (progn
          (setf (shell-maker-config-validate-command shell-maker--config) nil)
          (setf (shell-maker-config-execute-command shell-maker--config)
                (lambda (_command _history callback _error-callback)
                  (setq response (car history))
                  (setq history (cdr history))
                  (when response
                    (unless (string-equal (map-elt response 'role)
                                          "assistant")
                      (setq failed t)
                      (user-error "Invalid transcript"))
                    (funcall callback (map-elt response 'content) nil)
                    (setq command (car history))
                    (setq history (cdr history))
                    (when command
                      (goto-char (point-max))
                      (insert (map-elt command 'content))
                      (shell-maker--send-input)))))
          (goto-char (point-max))
          (comint-clear-buffer)
          (setq command (car history))
          (setq history (cdr history))
          (when command
            (unless (string-equal (map-elt command 'role)
                                  "user")
              (setq failed t)
              (user-error "Invalid transcript"))
            (goto-char (point-max))
            (insert (map-elt command 'content))
            (shell-maker--send-input)))
      (if failed
          (setq shell-maker--file nil)
        (setq shell-maker--file path))
      (setq shell-maker--busy nil)
      (setf (shell-maker-config-validate-command shell-maker--config)
            validate-command)
      (setf (shell-maker-config-execute-command shell-maker--config)
            execute-command)))
  (goto-char (point-max)))

;; TODO: Move to shell-maker.
(defun claude-shell--fontify-source-block (quotes1-start quotes1-end lang
lang-start lang-end body-start body-end quotes2-start quotes2-end)
  "Fontify a source block.
Use QUOTES1-START QUOTES1-END LANG LANG-START LANG-END BODY-START
 BODY-END QUOTES2-START and QUOTES2-END."
  ;; Overlay beginning "```" with a copy block button.
  (overlay-put (make-overlay quotes1-start
                             quotes1-end)
               'display
               (propertize "📋 "
                           'pointer 'hand
                           'keymap (shell-maker--make-ret-binding-map
                                    (lambda ()
                                      (interactive)
                                      (kill-ring-save body-start body-end)
                                      (message "Copied")))))
  ;; Hide end "```" altogether.
  (overlay-put (make-overlay quotes2-start
                             quotes2-end) 'invisible 'claude-shell)
  (unless (eq lang-start lang-end)
    (overlay-put (make-overlay lang-start
                               lang-end) 'face '(:box t))
    (overlay-put (make-overlay lang-end
                               (1+ lang-end)) 'display "\n\n"))
  (let ((lang-mode (intern (concat (or
                                    (claude-shell--resolve-internal-language lang)
                                    (downcase (string-trim lang)))
                                   "-mode")))
        (string (buffer-substring-no-properties body-start body-end))
        (buf (if (and (boundp 'shell-maker--config)
                      shell-maker--config)
                 (shell-maker-buffer shell-maker--config)
               (current-buffer)))
        (pos 0)
        (props)
        (overlay)
        (propertized-text))
    (if (fboundp lang-mode)
        (progn
          (setq propertized-text
                (with-current-buffer
                    (get-buffer-create
                     (format " *claude-shell-fontification:%s*" lang-mode))
                  (let ((inhibit-modification-hooks nil)
                        (inhibit-message t))
                    (erase-buffer)
                    ;; Additional space ensures property change.
                    (insert string " ")
                    (funcall lang-mode)
                    (font-lock-ensure))
                  (buffer-string)))
          (while (< pos (length propertized-text))
            (setq props (text-properties-at pos propertized-text))
            (setq overlay (make-overlay (+ body-start pos)
                                        (+ body-start (1+ pos))
                                        buf))
            (overlay-put overlay 'face (plist-get props 'face))
            (setq pos (1+ pos))))
      (overlay-put (make-overlay body-start body-end buf)
                   'face 'font-lock-doc-markup-face))))

(defun claude-shell--fontify-divider (start end)
  "Display text between START and END as a divider."
  (overlay-put (make-overlay start end
                             (if (and (boundp 'shell-maker--config)
                                      shell-maker--config)
                                 (shell-maker-buffer shell-maker--config)
                               (current-buffer)))
               'display
               (concat (propertize (concat (make-string (window-body-width) ? ) "")
                                   'face '(:underline t)) "\n")))

;; TODO: Move to shell-maker.
(defun claude-shell--fontify-link (start end title-start title-end url-start url-end)
  "Fontify a markdown link.
Use START END TITLE-START TITLE-END URL-START URL-END."
  ;; Hide markup before
  (overlay-put (make-overlay start title-start) 'invisible 'claude-shell)
  ;; Show title as link
  (overlay-put (make-overlay title-start title-end) 'face 'link)
  ;; Make RET open the URL
  (define-key (let ((map (make-sparse-keymap)))
                (define-key map [mouse-1]
                  (lambda () (interactive)
                    (browse-url (buffer-substring-no-properties url-start url-end))))
                (define-key map (kbd "RET")
                  (lambda () (interactive)
                    (browse-url (buffer-substring-no-properties url-start url-end))))
                (overlay-put (make-overlay title-start title-end) 'keymap map)
                map)
    [remap self-insert-command] 'ignore)
  ;; Hide markup after
  (overlay-put (make-overlay title-end end) 'invisible 'claude-shell))

;; TODO: Move to shell-maker.
(defun claude-shell--fontify-bold (start end text-start text-end)
  "Fontify a markdown bold.
Use START END TEXT-START TEXT-END."
  ;; Hide markup before
  (overlay-put (make-overlay start text-start) 'invisible 'claude-shell)
  ;; Show title as bold
  (overlay-put (make-overlay text-start text-end) 'face 'bold)
  ;; Hide markup after
  (overlay-put (make-overlay text-end end) 'invisible 'claude-shell))

;; TODO: Move to shell-maker.
(defun claude-shell--fontify-header (start _end level-start level-end title-start title-end)
  "Fontify a markdown header.
Use START END LEVEL-START LEVEL-END TITLE-START TITLE-END."
  ;; Hide markup before
  (overlay-put (make-overlay start title-start) 'invisible 'claude-shell)
  ;; Show title as header
  (overlay-put (make-overlay title-start title-end) 'face
               (cond ((eq (- level-end level-start) 1)
                      'org-level-1)
                     ((eq (- level-end level-start) 2)
                      'org-level-2)
                     ((eq (- level-end level-start) 3)
                      'org-level-3)
                     ((eq (- level-end level-start) 4)
                      'org-level-4)
                     ((eq (- level-end level-start) 5)
                      'org-level-5)
                     ((eq (- level-end level-start) 6)
                      'org-level-6)
                     ((eq (- level-end level-start) 7)
                      'org-level-7)
                     ((eq (- level-end level-start) 8)
                      'org-level-8)
                     (t
                      'org-level-1))))

;; TODO: Move to shell-maker.
(defun claude-shell--fontify-italic (start end text-start text-end)
  "Fontify a markdown italic.
Use START END TEXT-START TEXT-END."
  ;; Hide markup before
  (overlay-put (make-overlay start text-start) 'invisible 'claude-shell)
  ;; Show title as italic
  (overlay-put (make-overlay text-start text-end) 'face 'italic)
  ;; Hide markup after
  (overlay-put (make-overlay text-end end) 'invisible 'claude-shell))

;; TODO: Move to shell-maker.
(defun claude-shell--fontify-strikethrough (start end text-start text-end)
  "Fontify a markdown strikethrough.
Use START END TEXT-START TEXT-END."
  ;; Hide markup before
  (overlay-put (make-overlay start text-start) 'invisible 'claude-shell)
  ;; Show title as strikethrough
  (overlay-put (make-overlay text-start text-end) 'face '(:strike-through t))
  ;; Hide markup after
  (overlay-put (make-overlay text-end end) 'invisible 'claude-shell))

;; TODO: Move to shell-maker.
(defun claude-shell--fontify-inline-code (body-start body-end)
  "Fontify a source block.
Use QUOTES1-START QUOTES1-END LANG LANG-START LANG-END BODY-START
 BODY-END QUOTES2-START and QUOTES2-END."
  ;; Hide ```
  (overlay-put (make-overlay (1- body-start)
                             body-start) 'invisible 'claude-shell)
  (overlay-put (make-overlay body-end
                             (1+ body-end)) 'invisible 'claude-shell)
  (overlay-put (make-overlay body-start body-end
                             (if (and (boundp 'shell-maker--config)
                                      shell-maker--config)
                                 (shell-maker-buffer shell-maker--config)
                               (current-buffer)))
               'face 'font-lock-doc-markup-face))

(defun claude-shell-rename-block-at-point ()
  "Rename block at point (perhaps a different language)."
  (interactive)
  (save-excursion
    (if-let ((block (claude-shell-markdown-block-at-point)))
        (if (map-elt block 'language)
            (perform-replace (map-elt block 'language)
                             (read-string "Name: " nil nil "") nil nil nil nil nil
                             (map-elt block 'language-start) (map-elt block 'language-end))
          (let ((new-name (read-string "Name: " nil nil "")))
            (goto-char (map-elt block 'language-start))
            (insert new-name)
            (claude-shell--put-source-block-overlays)))
      (user-error "No block at point"))))

(defun claude-shell-remove-block-overlays ()
  "Remove block overlays.  Handy for renaming blocks."
  (interactive)
  (dolist (overlay (overlays-in (point-min) (point-max)))
    (delete-overlay overlay)))

(defun claude-shell-refresh-rendering ()
  "Refresh markdown rendering by re-applying to entire buffer."
  (interactive)
  (claude-shell--put-source-block-overlays))

;; TODO: Move to shell-maker.
(defun claude-shell--put-source-block-overlays ()
  "Put overlays for all source blocks."
  (when claude-shell-highlight-blocks
    (let* ((source-blocks (claude-shell--source-blocks))
           (avoid-ranges (seq-map (lambda (block)
                                    (map-elt block 'body))
                                  source-blocks)))
      (dolist (overlay (overlays-in (point-min) (point-max)))
        (delete-overlay overlay))
      (dolist (block source-blocks)
        (claude-shell--fontify-source-block
         (car (map-elt block 'start))
         (cdr (map-elt block 'start))
         (buffer-substring-no-properties (car (map-elt block 'language))
                                         (cdr (map-elt block 'language)))
         (car (map-elt block 'language))
         (cdr (map-elt block 'language))
         (car (map-elt block 'body))
         (cdr (map-elt block 'body))
         (car (map-elt block 'end))
         (cdr (map-elt block 'end))))
      (when claude-shell-insert-dividers
        (dolist (divider (shell-maker--prompt-end-markers))
          (claude-shell--fontify-divider (car divider) (cdr divider))))
      (dolist (link (claude-shell--markdown-links avoid-ranges))
        (claude-shell--fontify-link
         (map-elt link 'start)
         (map-elt link 'end)
         (car (map-elt link 'title))
         (cdr (map-elt link 'title))
         (car (map-elt link 'url))
         (cdr (map-elt link 'url))))
      (dolist (header (claude-shell--markdown-headers avoid-ranges))
        (claude-shell--fontify-header
         (map-elt header 'start)
         (map-elt header 'end)
         (car (map-elt header 'level))
         (cdr (map-elt header 'level))
         (car (map-elt header 'title))
         (cdr (map-elt header 'title))))
      (dolist (bold (claude-shell--markdown-bolds avoid-ranges))
        (claude-shell--fontify-bold
         (map-elt bold 'start)
         (map-elt bold 'end)
         (car (map-elt bold 'text))
         (cdr (map-elt bold 'text))))
      (dolist (italic (claude-shell--markdown-italics avoid-ranges))
        (claude-shell--fontify-italic
         (map-elt italic 'start)
         (map-elt italic 'end)
         (car (map-elt italic 'text))
         (cdr (map-elt italic 'text))))
      (dolist (strikethrough (claude-shell--markdown-strikethroughs avoid-ranges))
        (claude-shell--fontify-strikethrough
         (map-elt strikethrough 'start)
         (map-elt strikethrough 'end)
         (car (map-elt strikethrough 'text))
         (cdr (map-elt strikethrough 'text))))
      (dolist (inline-code (claude-shell--markdown-inline-codes avoid-ranges))
        (claude-shell--fontify-inline-code
         (car (map-elt inline-code 'body))
         (cdr (map-elt inline-code 'body)))))))

;; TODO: Move to shell-maker.
(defun claude-shell--unpaired-length (length)
  "Expand LENGTH to include paired responses.

Each request has a response, so double LENGTH if set.

Add one for current request (without response).

If no LENGTH set, use 2048."
  (if length
      (1+ (* 2 length))
    2048))

(defun claude-shell-view-at-point ()
  "View prompt and output at point in a separate buffer."
  (interactive)
  (unless (eq major-mode 'claude-shell-mode)
    (user-error "Not in a shell"))
  (let ((prompt-pos (save-excursion
                      (goto-char (process-mark
                                  (get-buffer-process (current-buffer))))
                      (point)))
        (buf))
    (save-excursion
      (when (>= (point) prompt-pos)
        (goto-char prompt-pos)
        (forward-line -1)
        (end-of-line))
      (let* ((items (claude-shell--user-assistant-messages
                     (shell-maker--command-and-response-at-point)))
             (command (string-trim (or (map-elt (seq-first items) 'content) "")))
             (response (string-trim (or (map-elt (car (last items)) 'content) ""))))
        (setq buf (generate-new-buffer (if command
                                           (concat
                                            (buffer-name (current-buffer)) "> "
                                            ;; Only the first line of prompt.
                                            (seq-first (split-string command "\n")))
                                         (concat (buffer-name (current-buffer)) "> "
                                                 "(no prompt)"))))
        (when (seq-empty-p items)
          (user-error "Nothing to view"))
        (with-current-buffer buf
          (save-excursion
            (insert (propertize (or command "") 'face font-lock-doc-face))
            (when (and command response)
              (insert "\n\n"))
            (insert (or response "")))
          (claude-shell--put-source-block-overlays)
          (view-mode +1)
          (setq view-exit-action 'kill-buffer))))
    (switch-to-buffer buf)
    buf))

(defun claude-shell--extract-history (text prompt-regexp)
  "Extract all command and responses in TEXT with PROMPT-REGEXP."
  (claude-shell--user-assistant-messages
   (shell-maker--extract-history text prompt-regexp)))

(defun claude-shell--user-assistant-messages (history)
  "Convert HISTORY to Claude format.

Sequence must be a vector for json serialization.

For example:

 [
   ((role . \"user\") (content . \"hello\"))
   ((role . \"assistant\") (content . \"world\"))
 ]"
  (let ((result))
    (mapc
     (lambda (item)
       (when (car item)
         (push (list (cons 'role "user")
                     (cons 'content (car item))) result))
       (when (cdr item)
         (push (list (cons 'role "assistant")
                     (cons 'content (cdr item))) result)))
     history)
    (nreverse result)))

(defun claude-shell-run-command (command callback)
  "Run COMMAND list asynchronously and call CALLBACK function.

CALLBACK can be like:

\(lambda (success output)
  (message \"%s\" output))"
  (let* ((buffer (generate-new-buffer "*run command*"))
         (proc (apply #'start-process
                      (append `("exec" ,buffer) command))))
    (set-process-sentinel
     proc
     (lambda (proc _)
       (with-current-buffer buffer
         (funcall callback
                  (equal (process-exit-status proc) 0)
                  (buffer-string))
         (kill-buffer buffer))))))

;; TODO: Move to shell-maker.
(defun claude-shell--resolve-internal-language (language)
  "Resolve external LANGUAGE to internal.

For example \"elisp\" -> \"emacs-lisp\"."
  (when language
    (or (map-elt claude-shell-language-mapping
                 (downcase (string-trim language)))
        (when (intern (concat (downcase (string-trim language))
                              "-mode"))
          (downcase (string-trim language))))))

(defun claude-shell-block-action-at-point ()
  "Return t if block at point has an action.  nil otherwise."
  (let* ((source-block (claude-shell-markdown-block-at-point))
         (language (claude-shell--resolve-internal-language
                    (map-elt source-block 'language)))
         (actions (claude-shell--get-block-actions language)))
    actions
    (if actions
        actions
      (claude-shell--org-babel-command language))))

(defun claude-shell--get-block-actions (language)
  "Get block actions for LANGUAGE."
  (map-elt claude-shell-source-block-actions
           (claude-shell--resolve-internal-language
            language)))

(defun claude-shell--org-babel-command (language)
  "Resolve LANGUAGE to org babel command."
  (require 'ob)
  (when language
    (ignore-errors
      (or (require (intern (concat "ob-" (capitalize language))) nil t)
          (require (intern (concat "ob-" (downcase language))) nil t)))
    (let ((f (intern (concat "org-babel-execute:" language)))
          (f-cap (intern (concat "org-babel-execute:" (capitalize language)))))
      (if (fboundp f)
          f
        (if (fboundp f-cap)
            f-cap)))))

(defun claude-shell-execute-block-action-at-point ()
  "Execute block at point."
  (interactive)
  (if-let ((block (claude-shell-markdown-block-at-point)))
      (if-let ((actions (claude-shell--get-block-actions (map-elt block 'language)))
               (action (map-elt actions 'primary-action))
               (confirmation (map-elt actions 'primary-action-confirmation))
               (default-directory "/tmp"))
          (when (y-or-n-p confirmation)
            (funcall action (buffer-substring-no-properties
                             (map-elt block 'start)
                             (map-elt block 'end))))
        (if (and (map-elt block 'language)
                 (claude-shell--org-babel-command
                  (claude-shell--resolve-internal-language
                   (map-elt block 'language))))
            (claude-shell-execute-babel-block-action-at-point)
          (user-error "No primary action for %s blocks" (map-elt block 'language))))
    (user-error "No block at point")))

(defun claude-shell--override-language-params (language params)
  "Override PARAMS for LANGUAGE if found in `claude-shell-babel-headers'."
  (if-let* ((overrides (map-elt claude-shell-babel-headers
                                language))
            (temp-dir (file-name-as-directory
                       (make-temp-file "claude-shell-" t)))
            (temp-file (concat temp-dir "source-block-" language)))
      (if (cdr (assq :file overrides))
          (append (list
                   (cons :file
                         (replace-regexp-in-string (regexp-quote "<temp-file>")
                                                   temp-file
                                                   (cdr (assq :file overrides)))))
                  (assq-delete-all :file overrides)
                  params)
        (append
         overrides
         params))
    params))

(defun claude-shell-execute-babel-block-action-at-point ()
  "Execute block as org babel."
  (interactive)
  (require 'ob)
  (if-let ((block (claude-shell-markdown-block-at-point)))
      (if-let* ((language (claude-shell--resolve-internal-language
                           (map-elt block 'language)))
                (babel-command (claude-shell--org-babel-command language))
                (lang-headers (intern
                               (concat "org-babel-default-header-args:" language)))
                (bound (fboundp babel-command))
                (default-directory "/tmp"))
          (when (y-or-n-p (format "Execute %s ob block?" (capitalize language)))
            (message "Executing %s block..." (capitalize language))
            (let* ((params (org-babel-process-params
                            (claude-shell--override-language-params
                             language
                             (org-babel-merge-params
                              org-babel-default-header-args
                              (and (boundp
                                    (intern
                                     (concat "org-babel-default-header-args:" language)))
                                   (eval (intern
                                          (concat "org-babel-default-header-args:" language)) t))))))
                   (output (progn
                             (when (get-buffer org-babel-error-buffer-name)
                               (kill-buffer (get-buffer org-babel-error-buffer-name)))
                             (funcall babel-command
                                      (buffer-substring-no-properties
                                       (map-elt block 'start)
                                       (map-elt block 'end)) params)))
                   (buffer))
              (if (and output (not (stringp output)))
                  (setq output (format "%s" output))
                (when (and (cdr (assq :file params))
                           (file-exists-p (cdr (assq :file params))))
                  (setq output (cdr (assq :file params)))))
              (if (and output (not (string-empty-p output)))
                  (progn
                    (setq buffer (get-buffer-create (format "*%s block output*" (capitalize language))))
                    (with-current-buffer buffer
                      (save-excursion
                        (let ((inhibit-read-only t))
                          (erase-buffer)
                          (setq output (when output (string-trim output)))
                          (if (file-exists-p output) ;; Output was a file.
                              ;; Image? insert image.
                              (if (member (downcase (file-name-extension output))
                                          '("jpg" "jpeg" "png" "gif" "bmp" "webp"))
                                  (progn
                                    (insert "\n")
                                    (insert-image (create-image output)))
                                ;; Insert content of all other file types.
                                (insert-file-contents output))
                            ;; Just text output, insert that.
                            (insert output))))
                      (view-mode +1)
                      (setq view-exit-action 'kill-buffer))
                    (message "")
                    (select-window (display-buffer buffer)))
                (if (get-buffer org-babel-error-buffer-name)
                    (select-window (display-buffer org-babel-error-buffer-name))
                  (setq buffer (get-buffer-create (format "*%s block output*" (capitalize language))))
                  (message "No output. Check %s blocks work in your .org files." language)))))
        (user-error "No primary action for %s blocks" (map-elt block 'language)))
    (user-error "No block at point")))

(defun claude-shell-eval-elisp-block-in-ielm (text)
  "Run elisp source in TEXT."
  (claude-shell-send-to-ielm-buffer text t))

(defun claude-shell-compile-swift-block (text)
  "Compile Swift source in TEXT."
  (when-let* ((source-file (claude-shell-write-temp-file text ".swift"))
              (default-directory (file-name-directory source-file)))
    (claude-shell-run-command
     `("swiftc" ,(file-name-nondirectory source-file))
     (lambda (success output)
       (if success
           (message
            (concat (propertize "Compiles cleanly" 'face '(:foreground "green"))
                    " :)"))
         (let ((buffer (generate-new-buffer "*block error*")))
           (with-current-buffer buffer
             (save-excursion
               (insert
                (claude-shell--remove-compiled-file-names
                 (file-name-nondirectory source-file)
                 (ansi-color-apply output))))
             (compilation-mode)
             (view-mode +1)
             (setq view-exit-action 'kill-buffer))
           (select-window (display-buffer buffer)))
         (message
          (concat (propertize "Compilation failed" 'face '(:foreground "orange"))
                  " :(")))))))

(defun claude-shell-write-temp-file (content extension)
  "Create a temporary file with EXTENSION and write CONTENT to it.

Return the file path."
  (let* ((temp-dir (file-name-as-directory
                    (make-temp-file "claude-shell-" t)))
         (temp-file (concat temp-dir "source-block" extension)))
    (with-temp-file temp-file
      (insert content)
      (let ((inhibit-message t))
        (write-file temp-file)))
    temp-file))

(defun claude-shell--remove-compiled-file-names (filename text)
  "Remove lines starting with FILENAME in TEXT.

Useful to remove temp file names from compilation output when
compiling source blocks."
  (replace-regexp-in-string
   (rx-to-string `(: bol ,filename (one-or-more (not (any " "))) " ") " ")
   "" text))

;;; TODO: Move to claude-shell-prompt-compose.el, but first update
;;; the MELPA recipe, so it can load additional files other than claude-shell.el.
;;; https://github.com/melpa/melpa/blob/master/recipes/claude-shell

(defvar-local claude-shell-prompt-compose--exit-on-submit nil
  "Whether or not compose buffer should close after submission.

This is typically used to craft prompts and immediately jump over to
the shell to follow the response.")

(defvar-local claude-shell-prompt-compose--transient-frame-p nil
  "Identifies whether or not buffer is running on a dedicated frame.

t if invoked from a transient frame (quitting closes the frame).")

(defvar claude-shell-prompt-compose-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'claude-shell-prompt-compose-send-buffer)
    (define-key map (kbd "C-c C-k") #'claude-shell-prompt-compose-cancel)
    (define-key map (kbd "C-c C-s") #'claude-shell-prompt-compose-swap-system-prompt)
    (define-key map (kbd "C-c C-v") #'claude-shell-prompt-compose-swap-model-version)
    (define-key map (kbd "C-c C-o") #'claude-shell-prompt-compose-other-buffer)
    (define-key map (kbd "M-r") #'claude-shell-prompt-compose-search-history)
    (define-key map (kbd "M-p") #'claude-shell-prompt-compose-previous-history)
    (define-key map (kbd "M-n") #'claude-shell-prompt-compose-next-history)
    map))

(define-derived-mode claude-shell-prompt-compose-mode fundamental-mode "Claude Compose"
  "Major mode for composing Claude prompts from a dedicated buffer."
  :keymap claude-shell-prompt-compose-mode-map)

(defvar claude-shell-prompt-compose-view-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "g") #'claude-shell-prompt-compose-retry)
    (define-key map (kbd "C-M-h") #'claude-shell-mark-block)
    (define-key map (kbd "n") #'claude-shell-prompt-compose-next-block)
    (define-key map (kbd "p") #'claude-shell-prompt-compose-previous-block)
    (define-key map (kbd "r") #'claude-shell-prompt-compose-reply)
    (define-key map (kbd "q") #'claude-shell-prompt-compose-quit-and-close-frame)
    (define-key map (kbd "e") #'claude-shell-prompt-compose-request-entire-snippet)
    (define-key map (kbd "o") #'claude-shell-prompt-compose-other-buffer)
    (set-keymap-parent map view-mode-map)
    map)
  "Keymap for `claude-shell-prompt-compose-view-mode'.")

(define-minor-mode claude-shell-prompt-compose-view-mode
  "Like `view-mode`, but extended for Claude Compose."
  :lighter "Claude view"
  :keymap claude-shell-prompt-compose-view-mode-map)

(define-minor-mode claude-shell-prompt-compose-view-mode
  "Like `view-mode`, but extended for Claude Compose."
  :lighter "Claude view"
  :keymap claude-shell-prompt-compose-view-mode-map
  (setq buffer-read-only claude-shell-prompt-compose-view-mode))

(defun claude-shell-prompt-compose (prefix)
  "Compose and send prompt from a dedicated buffer.

With PREFIX, clear existing history (wipe asociated shell history).

Whenever `claude-shell-prompt-compose' is invoked, appends any active
region (or flymake issue at point) to compose buffer.

Additionally, if point is at an error/warning raised by flymake,
automatically add context (error/warning + code) to expedite Claude
for help to fix the issue.

The compose buffer always shows the latest interaction, but it's
backed by the shell history.  You can always switch to the shell buffer
to view the history.

Editing: While compose buffer is in in edit mode, it offers a couple
of magit-like commit buffer bindings.

 `\\[claude-shell-prompt-compose-send-buffer]` to send the buffer query.
 `\\[claude-shell-prompt-compose-cancel]` to cancel compose buffer.
 `\\[claude-shell-prompt-compose-search-history]` search through history.
 `\\[claude-shell-prompt-compose-previous-history]` cycle through previous
item in history.
 `\\[claude-shell-prompt-compose-next-history]` cycle through next item in
history.

Read-only: After sending a query, the buffer becomes read-only and
enables additional key bindings.

 `\\[claude-shell-prompt-compose-send-buffer]` After sending offers to abort
query in-progress.
 `\\[View-quit]` Exits the read-only buffer.
 `\\[claude-shell-prompt-compose-retry]` Refresh (re-send the query).  Useful
to retry on disconnects.
 `\\[claude-shell-prompt-compose-next-block]` Jump to next source block.
 `\\[claude-shell-prompt-compose-previous-block]` Jump to next previous block.
 `\\[claude-shell-prompt-compose-reply]` Reply to follow-up with additional questions.
 `\\[claude-shell-prompt-compose-request-entire-snippet]` Send \"Show entire snippet\" query (useful to request alternative
 `\\[claude-shell-prompt-compose-other-buffer]` Jump to other buffer (ie. the shell itself).
 `\\[claude-shell-mark-block]` Mark block at point."
  (interactive "P")
  (claude-shell-prompt-compose-show-buffer nil prefix))

(defun claude-shell-prompt-compose-show-buffer (&optional content clear-history transient-frame-p)
  "Show a prompt compose buffer.

Prepopulate buffer with optional CONTENT.

Set CLEAR-HISTORY to wipe any existing shell history.

Set TRANSIENT-FRAME-P to also close frame on exit."
  (let* ((exit-on-submit (eq major-mode 'claude-shell-mode))
         (region (or content
                     (when-let ((region-active (region-active-p))
                                (region (buffer-substring (region-beginning)
                                                          (region-end))))
                       (deactivate-mark)
                       region)
                     (when-let* ((diagnostic (flymake-diagnostics (point)))
                                 (line-start (line-beginning-position))
                                 (line-end (line-end-position))
                                 (top-context-start (max (line-beginning-position 1) (point-min)))
                                 (top-context-end (max (line-beginning-position -5) (point-min)))
                                 (bottom-context-start (min (line-beginning-position 2) (point-max)))
                                 (bottom-context-end (min (line-beginning-position 7) (point-max)))
                                 (current-line (buffer-substring line-start line-end)))
                       (concat
                        "Fix this code and only show me a diff without explanation\n\n"
                        (mapconcat #'flymake-diagnostic-text diagnostic "\n")
                        "\n\n"
                        (buffer-substring top-context-start top-context-end)
                        (buffer-substring line-start line-end)
                        " <--- issue is here\n"
                        (buffer-substring bottom-context-start bottom-context-end)))))
         (instructions (concat "Type "
                               (propertize "C-c C-c" 'face 'help-key-binding)
                               " to send prompt. "
                               (propertize "C-c C-k" 'face 'help-key-binding)
                               " to cancel and exit. "))
         (erase-buffer (or clear-history
                           (not region)
                           ;; view-mode = old query, erase for new one.
                           (with-current-buffer (claude-shell-prompt-compose-buffer)
                             claude-shell-prompt-compose-view-mode)))
         (prompt))
    (with-current-buffer (claude-shell-prompt-compose-buffer)
      (claude-shell-prompt-compose-mode)
      (setq-local claude-shell-prompt-compose--exit-on-submit exit-on-submit)
      (setq-local claude-shell-prompt-compose--transient-frame-p transient-frame-p)
      (visual-line-mode +1)
      (when erase-buffer
        (claude-shell-prompt-compose-view-mode -1)
        (erase-buffer))
      (when region
        (save-excursion
          (goto-char (point-min))
          (let ((insert-trailing-newlines (not (looking-at-p "\n\n"))))
            (insert "\n\n")
            (insert region)
            (when insert-trailing-newlines
              (insert "\n\n")))))
      (when clear-history
        (let ((claude-shell-prompt-query-response-style 'inline))
          (claude-shell-send-to-buffer "clear")))
      ;; TODO: Find a better alternative to prevent clash.
      ;; Disable "n"/"p" for region-bindings-mode-map, so it doesn't
      ;; clash with "n"/"p" selection binding.
      (when (boundp 'region-bindings-mode-disable-predicates)
        (add-to-list 'region-bindings-mode-disable-predicates
                     (lambda () buffer-read-only)))
      (defvar-local claude-shell--ring-index nil)
      (setq claude-shell--ring-index nil)
      (message instructions))
    (unless transient-frame-p
      (select-window (display-buffer (claude-shell-prompt-compose-buffer))))
    (claude-shell-prompt-compose-buffer)))

(defun claude-shell-prompt-compose-search-history ()
  "Search prompt history, select, and insert to current compose buffer."
  (interactive)
  (unless (eq major-mode 'claude-shell-prompt-compose-mode)
    (user-error "Not in a shell compose buffer"))
  (let ((candidate (with-current-buffer (claude-shell--primary-buffer)
                     (completing-read
                      "History: "
                      (delete-dups
                       (seq-filter
                        (lambda (item)
                          (not (string-empty-p item)))
                        (ring-elements comint-input-ring))) nil t))))
    (insert candidate)))

(defun claude-shell-prompt-compose-quit-and-close-frame ()
  "Quit compose and close frame if it's the last window."
  (interactive)
  (unless (eq major-mode 'claude-shell-prompt-compose-mode)
    (user-error "Not in a shell compose buffer"))
  (let ((transient-frame-p claude-shell-prompt-compose--transient-frame-p))
    (quit-restore-window (get-buffer-window (current-buffer)) 'kill)
    (when (and transient-frame-p
               (< (claude-shell-prompt-compose-frame-window-count) 2))
      (delete-frame))))

(defun claude-shell-prompt-compose-frame-window-count ()
  "Get the number of windows per current frame."
  (if-let ((window (get-buffer-window (current-buffer)))
           (frame (window-frame window)))
      (length (window-list frame))
    0))

(defun claude-shell-prompt-compose-previous-history ()
  "Insert previous prompt from history into compose buffer."
  (interactive)
  (unless claude-shell-prompt-compose-view-mode
    (let* ((ring (with-current-buffer (claude-shell--primary-buffer)
                   (seq-filter
                    (lambda (item)
                      (not (string-empty-p item)))
                    (ring-elements comint-input-ring))))
           (next-index (unless (seq-empty-p ring)
                         (if claude-shell--ring-index
                             (1+ claude-shell--ring-index)
                           0))))
      (let ((prompt (buffer-string)))
        (with-current-buffer (claude-shell--primary-buffer)
          (unless (ring-member comint-input-ring prompt)
            (ring-insert comint-input-ring prompt))))
      (if next-index
          (if (>= next-index (seq-length ring))
              (setq claude-shell--ring-index (1- (seq-length ring)))
            (setq claude-shell--ring-index next-index))
        (setq claude-shell--ring-index nil))
      (when claude-shell--ring-index
        (erase-buffer)
        (insert (seq-elt ring claude-shell--ring-index))))))

(defun claude-shell-prompt-compose-next-history ()
  "Insert next prompt from history into compose buffer."
  (interactive)
  (unless claude-shell-prompt-compose-view-mode
    (let* ((ring (with-current-buffer (claude-shell--primary-buffer)
                   (seq-filter
                    (lambda (item)
                      (not (string-empty-p item)))
                    (ring-elements comint-input-ring))))
           (next-index (unless (seq-empty-p ring)
                         (if claude-shell--ring-index
                             (1- claude-shell--ring-index)
                           0))))
      (if next-index
          (if (< next-index 0)
              (setq claude-shell--ring-index nil)
            (setq claude-shell--ring-index next-index))
        (setq claude-shell--ring-index nil))
      (when claude-shell--ring-index
        (erase-buffer)
        (insert (seq-elt ring claude-shell--ring-index))))))

(defun claude-shell-mark-block ()
  "Mark current block in compose buffer."
  (interactive)
  (when-let ((block (claude-shell-markdown-block-at-point)))
    (set-mark (map-elt block 'end))
    (goto-char (map-elt block 'start))))

(defun claude-shell-prompt-compose-send-buffer ()
  "Send compose buffer content to shell for processing."
  (interactive)
  (unless (eq major-mode 'claude-shell-prompt-compose-mode)
    (user-error "Not in a shell compose buffer"))
  (with-current-buffer (claude-shell--primary-buffer)
    (when shell-maker--busy
      (unless (y-or-n-p "Abort?")
        (cl-return))
      (shell-maker-interrupt t)
      (with-current-buffer (claude-shell-prompt-compose-buffer)
        (progn
          (claude-shell-prompt-compose-view-mode -1)
          (erase-buffer)))
      (user-error "Aborted")))
  (when (claude-shell-block-action-at-point)
    (claude-shell-execute-block-action-at-point)
    (cl-return))
  (when (string-empty-p
         (string-trim
          (buffer-substring-no-properties
           (point-min) (point-max))))
    (erase-buffer)
    (user-error "Nothing to send"))
  (if claude-shell-prompt-compose-view-mode
      (progn
        (claude-shell-prompt-compose-view-mode -1)
        (erase-buffer)
        (message instructions))
    (setq prompt
          (string-trim
           (buffer-substring-no-properties
            (point-min) (point-max))))
    (erase-buffer)
    (insert (propertize (concat prompt "\n\n") 'face font-lock-doc-face))
    (claude-shell-prompt-compose-view-mode +1)
    (setq view-exit-action 'kill-buffer)
    (when (string-equal prompt "clear")
      (view-mode -1)
      (erase-buffer))
    (if claude-shell-prompt-compose--exit-on-submit
        (let ((view-exit-action nil)
              (claude-shell-prompt-query-response-style 'shell))
          (quit-window t (get-buffer-window (claude-shell-prompt-compose-buffer)))
          (claude-shell-send-to-buffer prompt))
      (let ((claude-shell-prompt-query-response-style 'inline))
        (claude-shell-send-to-buffer prompt nil nil
                                      (lambda ()
                                        (with-current-buffer (claude-shell-prompt-compose-buffer)
                                          (claude-shell--put-source-block-overlays))))))))

;; TODO: Delete and use claude-shell-prompt-compose-quit-and-close-frame instead.
(defun claude-shell-prompt-compose-cancel ()
  "Cancel and close compose buffer."
  (interactive)
  (unless (eq major-mode 'claude-shell-prompt-compose-mode)
    (user-error "Not in a shell compose buffer"))
  (claude-shell-prompt-compose-quit-and-close-frame))

(defun claude-shell-prompt-compose-buffer-name ()
  "Generate compose buffer name."
  (concat (claude-shell--minibuffer-prompt) "compose"))

(defun claude-shell-prompt-compose-swap-system-prompt ()
  "Swap the compose buffer's system prompt."
  (interactive)
  (unless (eq major-mode 'claude-shell-prompt-compose-mode)
    (user-error "Not in a shell compose buffer"))
  (with-current-buffer (claude-shell--primary-buffer)
    (claude-shell-swap-system-prompt))
  (rename-buffer (claude-shell-prompt-compose-buffer-name)))

(defun claude-shell-prompt-compose-swap-model-version ()
  "Swap the compose buffer's model version."
  (interactive)
  (unless (eq major-mode 'claude-shell-prompt-compose-mode)
    (user-error "Not in a shell compose buffer"))
  (with-current-buffer (claude-shell--primary-buffer)
    (claude-shell-swap-model-version))
  (rename-buffer (claude-shell-prompt-compose-buffer-name)))

(defun claude-shell-prompt-compose-buffer ()
  "Get the available shell compose buffer."
  (unless (claude-shell--primary-buffer)
    (error "No shell to compose to"))
  (let* ((buffer (get-buffer-create (claude-shell-prompt-compose-buffer-name))))
    (unless buffer
      (error "No compose buffer available"))
    buffer))

(defun claude-shell-prompt-compose-retry ()
  "Retry sending request to shell.

Useful if sending a request failed, perhaps from failed connectivity."
  (interactive)
  (unless (eq major-mode 'claude-shell-prompt-compose-mode)
    (user-error "Not in a shell compose buffer"))
  (when-let ((prompt (with-current-buffer (claude-shell--primary-buffer)
                       (seq-first (delete-dups
                                   (seq-filter
                                    (lambda (item)
                                      (not (string-empty-p item)))
                                    (ring-elements comint-input-ring))))))
             (inhibit-read-only t)
             (claude-shell-prompt-query-response-style 'inline))
    (erase-buffer)
    (insert (propertize (concat prompt "\n\n") 'face font-lock-doc-face))
    (claude-shell-send-to-buffer prompt nil nil
                                  (lambda ()
                                    (with-current-buffer (claude-shell-prompt-compose-buffer)
                                      (claude-shell--put-source-block-overlays))))))

(defun claude-shell-prompt-compose-next-block ()
  "Jump to and select next code block."
  (interactive)
  (unless (eq major-mode 'claude-shell-prompt-compose-mode)
    (user-error "Not in a shell compose buffer"))
  (call-interactively #'claude-shell-next-source-block)
  (when-let ((block (claude-shell-markdown-block-at-point)))
    (set-mark (map-elt block 'end))
    (goto-char (map-elt block 'start))))

(defun claude-shell-prompt-compose-previous-block ()
  "Jump to and select previous code block."
  (interactive)
  (unless (eq major-mode 'claude-shell-prompt-compose-mode)
    (user-error "Not in a shell compose buffer"))
  (call-interactively #'claude-shell-previous-source-block)
  (when-let ((block (claude-shell-markdown-block-at-point)))
    (set-mark (map-elt block 'end))
    (goto-char (map-elt block 'start))))

(defun claude-shell-prompt-compose-reply ()
  "Reply as a follow-up and compose another query."
  (interactive)
  (unless (eq major-mode 'claude-shell-prompt-compose-mode)
    (user-error "Not in a shell compose buffer"))
  (with-current-buffer (claude-shell--primary-buffer)
    (when shell-maker--busy
      (user-error "Busy, please wait")))
  (claude-shell-prompt-compose-view-mode -1)
  (erase-buffer))

(defun claude-shell-prompt-compose-request-entire-snippet ()
  "If the response code is incomplete, request the entire snippet."
  (interactive)
  (unless (eq major-mode 'claude-shell-prompt-compose-mode)
    (user-error "Not in a shell compose buffer"))
  (with-current-buffer (claude-shell--primary-buffer)
    (when shell-maker--busy
      (user-error "Busy, please wait")))
  (let ((prompt "show entire snippet")
        (inhibit-read-only t)
        (claude-shell-prompt-query-response-style 'inline))
    (erase-buffer)
    (insert (propertize (concat prompt "\n\n") 'face font-lock-doc-face))
    (claude-shell-send-to-buffer prompt)))

(defun claude-shell-prompt-compose-other-buffer ()
  "Jump to the shell buffer (compose's other buffer)."
  (interactive)
  (unless (eq major-mode 'claude-shell-prompt-compose-mode)
    (user-error "Not in a shell compose buffer"))
  (switch-to-buffer (claude-shell--primary-buffer)))

(provide 'claude-shell)

;;; claude-shell.el ends here
