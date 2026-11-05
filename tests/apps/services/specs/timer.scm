(test "Services — run-effect fires a pending timer without a staged answer"
  (steps
    (click (role button :name "Delay"))
    (expect-pending-effects 1)
    (run-effect 1)
    (expect-pending-effects 0)
    (expect-text (test-id "delayed") "Fired")
  )
)
