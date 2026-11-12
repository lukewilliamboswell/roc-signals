(test "Deep — an answer layer past index 64 settles at its own site"
  (steps
    (expect-text (test-id "answers") "answers=0")
    ; The answer layer (index 65) shares its bit with the derive at the
    ; top (index 1), which strips that bit from the reads it reports. An
    ; answer settles at its own site and refreshes its one reader: it needs
    ; no pass from the root, which could not find its way back past that
    ; derive.
    (mark-metrics)
    (run-effect 1)
    (expect-metric-delta derived_calls_into_roc 1)
    (expect-metric-delta set_text 1)
    (expect-text (test-id "answers") "answers=1")
  )
)
