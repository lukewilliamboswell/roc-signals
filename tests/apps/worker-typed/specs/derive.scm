(test "Typed workers — resource runs for the first value and follows later ones"
  (steps
    ; The run for the initial text starts at mount.
    (expect-pending-effects 1)
    (expect-text (test-id "measure") "measuring; nothing yet")
    (run-effect 1)
    (expect-text (test-id "measure") "measured; 0 bytes, Empty")
    (fill (label "Text") "roc")
    ; The previous answer stays shown while the next run is wanted.
    (expect-text (test-id "measure") "measuring; 0 bytes, Empty")
    (run-effect 2)
    (expect-text (test-id "measure") "measured; 3 bytes, Short")
    (fill (label "Text") "roc-signals")
    (run-effect 3)
    (expect-text (test-id "measure") "measured; 11 bytes, Long")
    (expect-pending-effects 0)
  )
)
