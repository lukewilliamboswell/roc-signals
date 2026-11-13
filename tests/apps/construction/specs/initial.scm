(test "The default construction frame is legal"
  (steps
    (expect-text (role button :name "Trigger construction") "Trigger construction")
    (expect-text (text "Choose a construction contract") "Choose a construction contract")))
