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

    ; A save, including the interval where the editor is temporarily
    ; unavailable, changes only the accepted baseline. The two scopes here
    ; belong to the conditional Cancel-operation row, not to the editor.
    (mark-metrics)
    (shortcut (test-id "notes-editor") "s" 1)
    (expect-disabled (label "Note text") true)
    (resolve-file-choice "notes-save-path" (chosen "/tmp/Ideas.txt"))
    (expect-disabled (label "Note text") false)
    (resolve-file-write "notes-write" :path "/tmp/Ideas.txt" :bytes 18)
    (expect-text (test-id "note-status") "No changes")
    (expect-value (label "Note text") "Same body and more")
    (expect-metric-delta scopes_created 2)
    (expect-metric-delta scopes_disposed 2)

    ; The remaining windows are identical open cycles from a clean document, so
    ; their conditional rows cost the same two scopes every time. A cycle that
    ; accepts a document costs exactly one more: its replacement editor.

    ; A failed read installs no document, so it replaces neither the editor nor
    ; the draft the reader still owns.
    (mark-metrics)
    (shortcut (test-id "notes-editor") "o" 1)
    (resolve-file-choice "notes-open" (chosen "/tmp/Broken.txt"))
    (reject-file "notes-read" :kind invalid-utf8 :detail "document bytes")
    (expect-text (test-id "note-problem") "Not valid UTF-8: document bytes")
    (expect-value (label "Note text") "Same body and more")
    (expect-text (test-id "document-name") "Ideas.txt")
    (expect-metric-delta scopes_created 2)
    (expect-metric-delta scopes_disposed 2)

    ; A successful read accepts a new document, so it gets a new editor.
    (mark-metrics)
    (shortcut (test-id "notes-editor") "o" 1)
    (resolve-file-choice "notes-open" (chosen "/tmp/First.txt"))
    (resolve-file-read "notes-read" :path "/tmp/First.txt" :text "Same body")
    (expect-value (label "Note text") "Same body")
    (expect-text (test-id "document-name") "First.txt")
    (expect-text (test-id "note-status") "No changes")
    (expect-metric-delta scopes_created 3)
    (expect-metric-delta scopes_disposed 3)

    ; The decisive case: a different document whose text equals the text already
    ; on screen. Equal text must not let the previous document's editor, and its
    ; native selection and undo history, survive into the new document.
    (mark-metrics)
    (shortcut (test-id "notes-editor") "o" 1)
    (resolve-file-choice "notes-open" (chosen "/tmp/Second.txt"))
    (resolve-file-read "notes-read" :path "/tmp/Second.txt" :text "Same body")
    (expect-value (label "Note text") "Same body")
    (expect-text (test-id "document-name") "Second.txt")
    (expect-metric-delta scopes_created 3)
    (expect-metric-delta scopes_disposed 3)

    ; Reopening the same path with the same text is still a new document.
    (mark-metrics)
    (shortcut (test-id "notes-editor") "o" 1)
    (resolve-file-choice "notes-open" (chosen "/tmp/Second.txt"))
    (resolve-file-read "notes-read" :path "/tmp/Second.txt" :text "Same body")
    (expect-value (label "Note text") "Same body")
    (expect-metric-delta scopes_created 3)
    (expect-metric-delta scopes_disposed 3)))
