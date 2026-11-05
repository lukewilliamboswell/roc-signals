(test "Services — a changed text box hears change when it loses focus"
  (steps
    (fill (label "Commit") "draft")
    (expect-text (test-id "committed") "")
    (blur (label "Commit"))
    (expect-text (test-id "committed") "draft")
    ; Focus and leave again without editing: no change.
    (focus (label "Commit"))
    (click (role button :name "Press"))
    (expect-text (test-id "committed") "draft")
    ; An edit commits when another control takes focus.
    (fill (label "Commit") "final")
    (fill (label "Note") "x")
    (expect-text (test-id "committed") "final")
  )
)
