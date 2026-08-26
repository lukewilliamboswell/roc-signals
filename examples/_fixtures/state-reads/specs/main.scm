(test "State reads"
  (steps
    ; An event reducer can atomically read one state while writing another.

    (expect-visible (role heading :name "State reads"))
    (expect-text (test-id "result") "waiting")
    (click (role button :name "Copy source"))
    (expect-text (test-id "result") "alpha")
    (fill (label "Source") "beta")
    (click (role button :name "Copy source"))
    (expect-text (test-id "result") "beta")
  )
)
