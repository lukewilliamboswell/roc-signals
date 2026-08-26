(test "Log viewer — Level filter removes only its own rows."
  (steps
    ; Given the state established by earlier scenarios
    (tick-interval 1000)
    (tick-interval 1000)
    (tick-interval 1000)
    (tick-interval 1000)

    ; Level filter removes only its own rows.
    (uncheck (label "Show debug"))
    (expect-checked (label "Show debug") false)
    (expect-absent (role region :name "Log line-4"))
    (expect-visible (role region :name "Log line-1"))
    (expect-text (test-id "line-count") "Showing 3 of 4 lines")
    (expect-text (test-id "tail-line") "Tail: [3] error upstream timeout")
  )
)
