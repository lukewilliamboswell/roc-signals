(scenario "counting-window"
  :window "1200x820"
  ; Initial and populated state for the smallest example: the count a person can
  ; read must follow the actions they took, not only the engine's own signal.
  (steps
    (expect-visible (text "0"))
    (expect-visible (text "Counter"))
    (click (role button :name "Increment"))
    (wait 150)
    (click (role button :name "Increment"))
    (wait 150)
    (expect-visible (text "2"))
    (snapshot "incremented")
    (click (role button :name "Decrement"))
    (wait 150)
    (expect-visible (text "1"))
    (click (role button :name "Reset"))
    (wait 150)
    (expect-visible (text "0"))
    (expect-onscreen (test-id "count"))))
