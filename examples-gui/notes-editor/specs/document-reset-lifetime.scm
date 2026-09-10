(test "New and Revert replace the document, and cancelling them does not"
  (steps
    ; Keeping the draft closes the confirmation only: one scope, no new editor.
    (fill (label "Note text") "Draft one")
    (click (role button :name "Revert changes"))
    (mark-metrics)
    (click (role button :name "Keep editing"))
    (expect-value (label "Note text") "Draft one")
    (expect-metric-delta scopes_created 1)
    (expect-metric-delta scopes_disposed 1)

    ; Discarding restores the accepted baseline, which is a replacement
    ; document even though its text was on screen a moment ago: one scope for
    ; the confirmation and one more for the replacement editor.
    (click (role button :name "Revert changes"))
    (mark-metrics)
    (click (role button :name "Discard changes"))
    (expect-value (label "Note text") "")
    (expect-text (test-id "note-status") "No changes")
    (expect-metric-delta scopes_created 2)
    (expect-metric-delta scopes_disposed 2)

    ; New replaces a clean, empty, untitled document with another one. Equal
    ; text again does not entitle the old editor to survive.
    (mark-metrics)
    (shortcut (test-id "notes-editor") "n" 1)
    (expect-value (label "Note text") "")
    (expect-text (test-id "document-name") "Untitled note")
    (expect-metric-delta scopes_created 1)
    (expect-metric-delta scopes_disposed 1)

    ; Repeating it keeps allocating distinct lifetimes.
    (mark-metrics)
    (shortcut (test-id "notes-editor") "n" 1)
    (expect-value (label "Note text") "")
    (expect-metric-delta scopes_created 1)
    (expect-metric-delta scopes_disposed 1)

    ; Revert is unavailable on a clean document, so it cannot replace one.
    (expect-disabled (role button :name "Revert changes") true)))
