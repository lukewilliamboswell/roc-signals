(test "Deep payload — a prepared task's answer past the bound is TooDeep, and the next job over the same preparation answers"
  (steps
    ; The preparation's state is 100; the task answers a chain of 100 plus
    ; the levels typed.
    (fill (label "Levels") "29")
    (click (role button :name "Grow"))
    (expect-pending-work "test.roc-signals/deep-payload/grow" 1)
    (run-effect 1)
    (expect-text (test-id "grown") "too deep")
    (fill (label "Levels") "28")
    (click (role button :name "Grow"))
    (expect-pending-work "test.roc-signals/deep-payload/grow" 1)
    (run-effect 2)
    (expect-text (test-id "grown") "128 levels")
    (expect-pending-effects 0)
  )
)
