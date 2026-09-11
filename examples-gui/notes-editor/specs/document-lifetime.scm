(test "Every accepted document gets its own editor, and editing keeps it"
  (steps
    ; Typing is not a document replacement. The editor must survive it so the
    ; native control keeps the selection and undo history for this document.
    (fill (label "Note text") "Same body")
    (mark-metrics)
    (fill (label "Note text") "Same body")
    (fill (label "Note text") "Same body and more")
    (expect-value (label "Note text") "Same body and more")
    (expect-metric-delta scopes_created 0)
    (expect-metric-delta scopes_disposed 0)

    ; A save changes only the accepted baseline; the editor survives it.
    (mark-metrics)
    (stub-file-choice "notes-save-path" (chosen "/tmp/Ideas.txt"))
    (shortcut (test-id "notes-editor") "s" 1)
    (expect-disabled (label "Note text") false)
    (expect-text (test-id "note-status") "No changes")
    (expect-value (label "Note text") "Same body and more")
    (expect-metric-delta scopes_created 0)
    (expect-metric-delta scopes_disposed 0)

    ; A failed read installs no document, so it replaces neither the editor nor
    ; the draft the reader still owns.
    (mark-metrics)
    (stub-file-choice "notes-open" (chosen "/tmp/Broken.txt"))
    (stub-file-reject "notes-read" :kind invalid-utf8 :detail "document bytes")
    (shortcut (test-id "notes-editor") "o" 1)
    (expect-text (test-id "note-problem") "Not valid UTF-8: document bytes")
    (expect-value (label "Note text") "Same body and more")
    (expect-text (test-id "document-name") "Ideas.txt")
    (expect-metric-delta scopes_created 0)
    (expect-metric-delta scopes_disposed 0)

    ; A successful read accepts a new document, so it gets a new editor: one
    ; scope created for the replacement, one disposed for the old.
    (mark-metrics)
    (stub-file-choice "notes-open" (chosen "/tmp/First.txt"))
    (stub-file-read "notes-read" :path "/tmp/First.txt" :text "Same body")
    (shortcut (test-id "notes-editor") "o" 1)
    (expect-value (label "Note text") "Same body")
    (expect-text (test-id "document-name") "First.txt")
    (expect-text (test-id "note-status") "No changes")
    (expect-metric-delta scopes_created 1)
    (expect-metric-delta scopes_disposed 1)

    ; The decisive case: a different document whose text equals the text already
    ; on screen. Equal text must not let the previous document's editor, and its
    ; native selection and undo history, survive into the new document.
    (mark-metrics)
    (stub-file-choice "notes-open" (chosen "/tmp/Second.txt"))
    (stub-file-read "notes-read" :path "/tmp/Second.txt" :text "Same body")
    (shortcut (test-id "notes-editor") "o" 1)
    (expect-value (label "Note text") "Same body")
    (expect-text (test-id "document-name") "Second.txt")
    (expect-metric-delta scopes_created 1)
    (expect-metric-delta scopes_disposed 1)

    ; Reopening the same path with the same text is still a new document.
    (mark-metrics)
    (stub-file-choice "notes-open" (chosen "/tmp/Second.txt"))
    (stub-file-read "notes-read" :path "/tmp/Second.txt" :text "Same body")
    (shortcut (test-id "notes-editor") "o" 1)
    (expect-value (label "Note text") "Same body")
    (expect-metric-delta scopes_created 1)
    (expect-metric-delta scopes_disposed 1)))
