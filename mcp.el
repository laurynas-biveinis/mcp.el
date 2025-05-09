;;; mcp.el --- Model Context Protocol implementation -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Laurynas Biveinis

;; Author: Laurynas Biveinis <laurynas.biveinis@gmail.com>
;; Keywords: comm, tools
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))
;; URL: https://github.com/laurynas-biveinis/mcp.el

;; This file is NOT part of GNU Emacs.

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

;; An Emacs Lisp implementation of the Model Context Protocol (MCP),
;; an open standard for communication between AI applications and
;; language models.
;; See https://modelcontextprotocol.io/ for the protocol specification.

;;; Code:

(require 'json)

;;; Customization variables

(defgroup mcp nil
  "Model Context Protocol for Emacs."
  :group 'comm
  :prefix "mcp-")

(defcustom mcp-log-io nil
  "If non-nil, log all JSON-RPC messages to the *mcp-log* buffer."
  :group 'mcp
  :type 'boolean)

;;; Constants

(defconst mcp--error-parse -32700
  "Error code for Parse Error.")

(defconst mcp--error-invalid-request -32600
  "Error code for Invalid Request.")

(defconst mcp--error-method-not-found -32601
  "Error code for Method Not Found.")

(defconst mcp--error-internal -32603
  "Error code for Internal Error.")

(defconst mcp--name "emacs-mcp"
  "Name of the MCP server.")

(defconst mcp--protocol-version "2025-03-26"
  "Current MCP protocol version supported by this server.")

;;; Internal global state variables

(defvar mcp--running nil
  "Whether the MCP server is currently running.")

(defvar mcp--tools (make-hash-table :test 'equal)
  "Hash table of registered MCP tools.")

;;; Core helpers

(defun mcp--jsonrpc-response (id result)
  "Create a JSON-RPC response with ID and RESULT."
  (json-encode `((jsonrpc . "2.0") (id . ,id) (result . ,result))))

(defun mcp--jsonrpc-error (id code message)
  "Create a JSON-RPC error response with ID, error CODE and MESSAGE."
  (json-encode
   `((jsonrpc . "2.0")
     (id . ,id)
     (error . ((code . ,code) (message . ,message))))))

(defun mcp--respond-with-result (request-context result-data)
  "Send RESULT-DATA as response to the client through REQUEST-CONTEXT.

Arguments:
  REQUEST-CONTEXT  The MCP request context from the handler
  RESULT-DATA      The data to return to the client (any Elisp value)

The RESULT-DATA will be automatically converted to JSON-compatible format:
  - Strings, numbers, booleans are sent as-is
  - Symbols are converted to strings
  - Lists are converted to JSON arrays
  - Alists with string keys are converted to JSON objects
  - Other Elisp types are stringified appropriately"
  (let ((id (plist-get request-context :id)))
    (mcp--jsonrpc-response id result-data)))

(defun mcp--log-json-rpc (direction json-message)
  "Log JSON-RPC message in DIRECTION with JSON-MESSAGE.
DIRECTION should be \"in\" for incoming, \"out\" for outgoing."
  (when mcp-log-io
    (let ((buffer (get-buffer-create "*mcp-log*"))
          (direction-prefix
           (if (string= direction "in")
               "->"
             "<-"))
          (direction-name
           (if (string= direction "in")
               "(request)"
             "(response)")))
      (with-current-buffer buffer
        (goto-char (point-max))
        (let ((inhibit-read-only t))
          (view-mode 1)
          (insert
           (format "%s %s [%s]\n"
                   direction-prefix
                   direction-name
                   json-message)))))))

(defun mcp--handle-error (err)
  "Handle error ERR in MCP process by logging and creating an error response.
Returns a JSON-RPC error response string for internal errors."
  (mcp--jsonrpc-error
   nil
   mcp--error-internal
   (format "Internal error: %s" (error-message-string err))))

(defun mcp--validate-and-dispatch-request (request)
  "Process a JSON-RPC REQUEST object and validate JSON-RPC 2.0 compliance.

REQUEST is a parsed JSON object (alist) containing the JSON-RPC request fields.

The function performs JSON-RPC 2.0 validation, checking:
- Protocol version (must be \"2.0\")
- ID field presence (required for regular requests, forbidden for notifications)
- Method field presence (always required)

If validation succeeds, dispatches the request to the appropriate handler.
Returns a JSON-RPC formatted response string, or nil for notifications."
  (let* ((jsonrpc (alist-get 'jsonrpc request))
         (id (alist-get 'id request))
         (method (alist-get 'method request))
         (params (alist-get 'params request))
         (is-notification
          (and method (string-prefix-p "notifications/" method))))
    ;; Check for JSON-RPC 2.0 compliance first
    (cond
     ;; Return error for non-2.0 requests
     ((not (equal jsonrpc "2.0"))
      (mcp--jsonrpc-error
       id
       mcp--error-invalid-request
       "Invalid Request: Not JSON-RPC 2.0"))

     ;; Check if id is present for notifications/* methods
     ((and id is-notification)
      (mcp--jsonrpc-error
       nil
       mcp--error-invalid-request
       "Invalid Request: Notifications must not include 'id' field"))
     ;; Check if id is missing
     ((and (not id) (not is-notification))
      (mcp--jsonrpc-error
       nil
       mcp--error-invalid-request
       "Invalid Request: Missing required 'id' field"))
     ;; Check if method is missing
     ((not method)
      (mcp--jsonrpc-error
       id
       mcp--error-invalid-request
       "Invalid Request: Missing required 'method' field"))

     ;; Process valid request
     (t
      (mcp--dispatch-jsonrpc-method id method params)))))

(defun mcp--dispatch-jsonrpc-method (id method params)
  "Dispatch a JSON-RPC request to the appropriate handler.
ID is the JSON-RPC request ID to use in response.
METHOD is the JSON-RPC method name to dispatch.
PARAMS is the JSON-RPC params object from the request.
Returns a JSON-RPC response string for the request."
  (cond
   ;; Initialize handshake
   ((equal method "initialize")
    (mcp--handle-initialize id))
   ;; Notifications/initialized format
   ((equal method "notifications/initialized")
    (mcp--handle-initialized)
    nil)
   ;; Notifications/cancelled format
   ((equal method "notifications/cancelled")
    nil)
   ;; List available tools
   ((equal method "tools/list")
    (let ((tool-list (vector)))
      (maphash
       (lambda (id tool)
         (let* ((tool-description (plist-get tool :description))
                (tool-title (plist-get tool :title))
                (tool-read-only (plist-get tool :read-only))
                (tool-schema
                 (or (plist-get tool :schema) '((type . "object"))))
                (tool-entry
                 `((name . ,id)
                   (description . ,tool-description)
                   (inputSchema . ,tool-schema)))
                (annotations nil))
           ;; Collect annotations if present
           (when tool-title
             (push (cons 'title tool-title) annotations))
           ;; Add readOnlyHint when :read-only is explicitly provided (both t
           ;; and nil)
           (when (plist-member tool :read-only)
             (let ((annot-value
                    (if tool-read-only
                        t
                      :json-false)))
               (push (cons 'readOnlyHint annot-value) annotations)))
           ;; Add annotations to tool entry if any exist
           (when annotations
             (setq tool-entry
                   (append
                    tool-entry `((annotations . ,annotations)))))
           (setq tool-list (vconcat tool-list (vector tool-entry)))))
       mcp--tools)
      (mcp--jsonrpc-response id `((tools . ,tool-list)))))
   ;; List available prompts
   ((equal method "prompts/list")
    (mcp--jsonrpc-response id `((prompts . ,(vector)))))
   ;; Tool invocation
   ((equal method "tools/call")
    (let* ((tool-name (alist-get 'name params))
           (tool (gethash tool-name mcp--tools))
           (tool-args (alist-get 'arguments params)))
      (if tool
          (let ((handler (plist-get tool :handler))
                (context (list :id id)))
            (condition-case err
                (let*
                    ((result
                      ;; Pass first arg value for single-string-arg tools
                      ;; when arguments are present
                      (if (and tool-args (not (equal tool-args '())))
                          (let ((first-arg-value
                                 (cdr (car tool-args))))
                            (funcall handler first-arg-value))
                        (funcall handler)))
                     ;; Wrap the handler result in the MCP format
                     (formatted-result
                      `((content
                         .
                         ,(vector
                           `((type . "text") (text . ,result))))
                        (isError . :json-false))))
                  (mcp--respond-with-result context formatted-result))
              ;; Handle tool-specific errors thrown with mcp-tool-throw
              (mcp-tool-error
               (let ((formatted-error
                      `((content
                         .
                         ,(vector
                           `((type . "text") (text . ,(cadr err)))))
                        (isError . t))))
                 (mcp--respond-with-result context formatted-error)))
              ;; Keep existing handling for all other errors
              (error
               (mcp--jsonrpc-error
                id mcp--error-internal
                (format "Internal error executing tool: %s"
                        (error-message-string err))))))
        (mcp--jsonrpc-error
         id
         mcp--error-invalid-request
         (format "Tool not found: %s" tool-name)))))
   ;; Method not found
   (t
    (mcp--jsonrpc-error
     id
     mcp--error-method-not-found
     (format "Method not found: %s" method)))))

;;; Notification handlers

(defun mcp--handle-initialize (id)
  "Handle initialize request with ID.

This implements the MCP initialize handshake, which negotiates protocol
version and capabilities between the client and server."
  ;; TODO: Add proper protocol version compatibility check
  ;; For now, accept any protocol version for compatibility

  ;; Determine if we need to include tools capabilities
  ;; Include listChanged:true when tools are registered
  (let ((tools-capability
         (if (> (hash-table-count mcp--tools) 0)
             '((listChanged . t))
           (make-hash-table))))
    ;; Respond with server capabilities
    (mcp--jsonrpc-response
     id
     `((protocolVersion . ,mcp--protocol-version)
       (serverInfo
        . ((name . ,mcp--name) (version . ,mcp--protocol-version)))
       ;; Format server capabilities according to MCP spec
       (capabilities
        .
        ((tools . ,tools-capability)
         (resources . ,(make-hash-table))
         (prompts . ,(make-hash-table))))))))

(defun mcp--handle-initialized ()
  "Handle initialized notification from client.

This is called after successful initialization to complete the handshake.
The client sends this notification to acknowledge the server's response
to the initialize request.")

;;; Tool helpers

(defun mcp--extract-param-descriptions (docstring arglist)
  "Extract parameter descriptions from DOCSTRING based on ARGLIST.
The docstring should contain an \"MCP Parameters:\" section at the end,
with each parameter described as \"parameter-name - description\".
ARGLIST should be the function's argument list.
Returns an alist mapping parameter names to their descriptions.
Signals an error if a parameter is described multiple times,
doesn't match function arguments, or if any parameter is not documented."
  (let ((descriptions nil))
    (when docstring
      (when
          (string-match
           "MCP Parameters:[\n\r]+\\(\\(?:[ \t]+[^ \t\n\r].*[\n\r]*\\)*\\)"
           docstring)
        (let ((params-text (match-string 1 docstring))
              (param-regex
               "[ \t]+\\([^ \t\n\r]+\\)[ \t]*-[ \t]*\\(.*\\)[\n\r]*"))
          (with-temp-buffer
            (insert params-text)
            (goto-char (point-min))
            (while (re-search-forward param-regex nil t)
              (let ((param-name (match-string 1))
                    (param-desc (match-string 2)))
                ;; Check for duplicate parameter names
                (when (assoc param-name descriptions)
                  (error
                   "Duplicate parameter '%s' in MCP Parameters"
                   param-name))
                ;; Check parameter name matches function arguments
                (unless (and (= 1 (length arglist))
                             (symbolp (car arglist))
                             (string=
                              param-name (symbol-name (car arglist))))
                  (error
                   "Parameter '%s' in MCP Parameters not in function args %S"
                   param-name
                   arglist))
                ;; Add to descriptions
                (push (cons param-name (string-trim param-desc))
                      descriptions))))))
      ;; Check that all function parameters have descriptions
      (when (and (= 1 (length arglist))
                 (symbolp (car arglist))
                 (not (memq (car arglist) '(&optional &rest))))
        (let ((arg-name (symbol-name (car arglist))))
          (unless (assoc arg-name descriptions)
            (error
             "Function parameter '%s' missing from MCP Parameters section"
             arg-name)))))
    descriptions))

(defun mcp--generate-schema-from-function (func)
  "Generate JSON schema by analyzing FUNC's signature.
Returns a schema object suitable for tool registration.
Supports functions with zero or one argument only.
Extracts parameter descriptions from the docstring if available."
  (let* ((arglist (help-function-arglist func t))
         (docstring (documentation func))
         (param-descriptions
          (mcp--extract-param-descriptions docstring arglist)))
    (cond
     ;; No arguments case
     ((null arglist)
      '((type . "object")))

     ;; One argument case
     ((and (= 1 (length arglist))
           (symbolp (car arglist))
           (not (memq (car arglist) '(&optional &rest))))
      (let* ((arg-name (symbol-name (car arglist)))
             (description (cdr (assoc arg-name param-descriptions)))
             ;; Build property schema with type
             (property-schema `((type . "string")))
             ;; Add description if provided
             (property-schema
              (if description
                  (cons `(description . ,description) property-schema)
                property-schema)))
        `((type . "object")
          (properties . ((,arg-name . ,property-schema)))
          (required . [,arg-name]))))

     ;; Everything else is unsupported
     (t
      (error
       "Only functions with zero or one argument are supported")))))

;;; API - Server

(defun mcp-start ()
  "Start the MCP server and begin handling client requests.

This function starts the MCP server that can process JSON-RPC
requests via `mcp-process-jsonrpc'.  Once started, the server
will dispatch incoming requests to the appropriate tool
handlers that have been registered with `mcp-register-tool'."
  (interactive)
  (when mcp--running
    (error "MCP server is already running"))

  (setq mcp--running t))

(defun mcp-stop ()
  "Stop the MCP server from processing client requests.

Sets the server state to stopped, which prevents further processing of
client requests.  Note that this does not release any resources or unregister
tools, it simply prevents `mcp-process-jsonrpc' from accepting new requests."
  (interactive)
  (unless mcp--running
    (error "MCP server is not running"))

  ;; Mark server as not running
  (setq mcp--running nil)
  t)

;;; API - Transport

(defun mcp-process-jsonrpc (json-string)
  "Process a JSON-RPC message JSON-STRING and return the response.
This is the main entry point for stdio transport in MCP.

The function accepts a JSON-RPC 2.0 message string and returns
a JSON-RPC response string suitable for returning to clients via stdout.

When using the MCP server with emacsclient, invoke this function like:
emacsclient -e \\='(mcp-process-jsonrpc \"[JSON-RPC message]\")\\='

Example:
  (mcp-process-jsonrpc
   \"{\\\"jsonrpc\\\":\\\"2.0\\\",
     \\\"method\\\":\\\"mcp.server.describe\\\",\\\"id\\\":1}\")"
  (unless mcp--running
    (error
     "No active MCP server, start server with `mcp-start' first"))

  (mcp--log-json-rpc "in" json-string)

  ;; Step 1: Try to parse the JSON, handle parsing errors
  (let ((json-object nil)
        (response nil))
    ;; Attempt to parse the JSON
    (condition-case json-err
        (setq json-object (json-read-from-string json-string))
      (json-error
       ;; If JSON parsing fails, create a parse error response
       (setq response
             (mcp--jsonrpc-error
              nil mcp--error-parse
              (format "Parse error: %s"
                      (error-message-string json-err))))))
    ;; Step 2: Process the request if JSON parsing succeeded
    (unless response
      (condition-case err
          (setq response
                (mcp--validate-and-dispatch-request json-object))
        (error (setq response (mcp--handle-error err)))))

    ;; Only log and return responses when they exist (not for notifications)
    (when response
      (mcp--log-json-rpc "out" response))
    response))

;;; API - Utilities

(defun mcp-create-tools-list-request (&optional id)
  "Create a tools/list JSON-RPC request with optional ID.
If ID is not provided, it defaults to 1."
  (json-encode
   `(("jsonrpc" . "2.0")
     ("method" . "tools/list")
     ("id" . ,(or id 1)))))

(defun mcp-create-tools-call-request (tool-name &optional id args)
  "Create a tools/call JSON-RPC request for TOOL-NAME with optional ID and ARGS.
TOOL-NAME is the registered identifier of the tool to call.
ID is the JSON-RPC request ID, defaults to 1 if not provided.
ARGS is an association list of arguments to pass to the tool.

Example:
  (mcp-create-tools-call-request \"list-files\" 42 \\='((\"path\" . \"/tmp\")))"
  (json-encode
   `(("jsonrpc" . "2.0")
     ("method" . "tools/call") ("id" . ,(or id 1))
     ("params" .
      (("name" . ,tool-name) ("arguments" . ,(or args '())))))))

;;; API - Tools

(defun mcp-register-tool (handler &rest properties)
  "Register a tool with the MCP server.

Arguments:
  HANDLER          Function to handle tool invocations
  PROPERTIES       Property list with tool attributes

Required properties:
  :id              String identifier for the tool (e.g., \"list-files\")
  :description     String describing what the tool does

Optional properties:
  :title           User-friendly display name for the tool
  :read-only       If true, indicates tool doesn't modify its environment

The HANDLER function's signature determines its input schema.
Currently only no-argument and single-argument handlers are supported.

Example:
  (mcp-register-tool #\\='my-org-files-handler
    :id \"org-list-files\"
    :description \"Lists all available Org mode files for task management\")

With optional properties:
  (mcp-register-tool #\\='my-org-files-handler
    :id \"org-list-files\"
    :description \"Lists all available Org mode files for task management\"
    :title \"List Org Files\"
    :read-only t)"
  (let* ((id (plist-get properties :id))
         (description (plist-get properties :description))
         (title (plist-get properties :title))
         (read-only (plist-get properties :read-only)))
    ;; Error checking for required properties
    (unless (functionp handler)
      (error "Tool registration requires handler function"))
    (unless id
      (error "Tool registration requires :id property"))
    (unless description
      (error "Tool registration requires :description property"))
    ;; Generate schema from handler function
    (let* ((schema (mcp--generate-schema-from-function handler))
           (tool
            (list
             :id id
             :description description
             :handler handler
             :schema schema)))
      ;; Add optional properties if provided
      (when title
        (setq tool (plist-put tool :title title)))
      ;; Always include :read-only if it was specified, even if nil
      (when (plist-member properties :read-only)
        (setq tool (plist-put tool :read-only read-only)))
      ;; Register the tool
      (puthash id tool mcp--tools)
      tool)))

(defun mcp-unregister-tool (tool-id)
  "Unregister a tool with ID TOOL-ID from the MCP server.

Arguments:
  TOOL-ID  String identifier for the tool to unregister

Returns t if the tool was found and removed, nil otherwise.

Example:
  (mcp-unregister-tool \"org-list-files\")"
  (when (gethash tool-id mcp--tools)
    (remhash tool-id mcp--tools)
    t))

;; Custom error type for tool errors
(define-error 'mcp-tool-error "MCP tool error" 'user-error)

(defun mcp-tool-throw (error-message)
  "Signal a tool error with ERROR-MESSAGE.
The error will be properly formatted and sent to the client.

Arguments:
  ERROR-MESSAGE  String describing the error"
  (signal 'mcp-tool-error (list error-message)))

(provide 'mcp)
;;; mcp.el ends here
