(test "Deep payload — an input at the bound is sent, and one level past it is refused as TooDeep with nothing sent"
  (steps
    (fill (label "Levels") "128")
    (click (role button :name "Send"))
    (expect-pending-work "test.roc-signals/deep-payload/take" 1)
    (run-effect 1)
    (expect-text (test-id "sent") "128 levels")
    (fill (label "Levels") "129")
    (click (role button :name "Send"))
    ; Nothing was sent: no job waits and no effect is pending, and the
    ; refusal has already answered.
    (expect-pending-work "test.roc-signals/deep-payload/take" 0)
    (expect-pending-effects 0)
    (expect-text (test-id "sent") "too deep")
    ; The refusal issued no effect, so the next input sent is the second.
    (fill (label "Levels") "128")
    (click (role button :name "Send"))
    (expect-pending-work "test.roc-signals/deep-payload/take" 1)
    (run-effect 2)
    (expect-text (test-id "sent") "128 levels")
    (expect-pending-effects 0)
  )
)
