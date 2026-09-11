(scenario "editing-and-discard"
  :window "1200x820"
  ; Initial, populated, focused, disabled and modal states for the editor.
  ; The discard dialog is the one modal the review pass captured, and the
  ; enable/disable rules on Save and Revert are what tell a person whether their
  ; work is safe; neither is observable from a screenshot of the first frame.
  (steps
    (expect-visible (text "Notes"))
    (expect-visible (text "No changes"))
    (expect-disabled (role button :name "Save") true)
    (expect-disabled (role button :name "Revert changes") true)
    (expect-history (label "Note text") 0)
    (snapshot "initial")
    (type (label "Note text") "hello")
    (wait 400)
    (expect-focused (text "Note text"))
    (expect-value (label "Note text") "hello")
    (expect-disabled (role button :name "Save") false)
    (expect-disabled (role button :name "Revert changes") false)
    (snapshot "edited")
    (click (role button :name "New"))
    (wait 400)
    (snapshot "discard-dialog")))
