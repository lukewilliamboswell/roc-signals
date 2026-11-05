(test "A value the app rewrites waits for blur while its control has focus"
  (steps
    (fill (label "Trimmed") "  hi  ")
    ; The app trimmed it; the control keeps what was typed while focused.
    (expect-text (test-id "trimmed") "hi")
    (expect-value (label "Trimmed") "  hi  ")
    ; Typing what the app would show leaves nothing held.
    (fill (label "Trimmed") "hi")
    (expect-value (label "Trimmed") "hi")
    (fill (label "Trimmed") " yo ")
    (expect-value (label "Trimmed") " yo ")
    (blur (label "Trimmed"))
    (expect-value (label "Trimmed") "yo")
    (expect-text (test-id "trimmed") "yo")))
