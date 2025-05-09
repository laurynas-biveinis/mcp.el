;;; mcp-test-bytecode-handler.el --- Bytecode handler test -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Laurynas Biveinis
;; Author: Laurynas Biveinis
;; Version: 0.1.0
;; Package-Requires: ((emacs "24.1"))
;; URL: https://github.com/laurynas-biveinis/mcp.el

;;; Commentary:

;; This file contains a handler function that will be byte-compiled and used
;; in tests.

;;; Code:

(require 'mcp)

(defun mcp-test-bytecode-handler--handler (input-string)
  "Test handler function that will be loaded as bytecode.
INPUT-STRING is the string argument passed to the tool.

MCP Parameters:
  input-string - Input string parameter for bytecode testing"
  (format "Bytecode handler result: %s" input-string))

(provide 'mcp-test-bytecode-handler)
;;; mcp-test-bytecode-handler.el ends here
