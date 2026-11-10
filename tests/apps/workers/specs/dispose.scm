(test "Workers — disposing the issuing site cancels its job and no result arrives"
  (steps
    (click (role button :name "Panel"))
    (expect-visible (text "panel open"))
    (expect-pending-effects 1)
    (click (role button :name "Panel"))
    (expect-absent (text "panel open"))
    ; Work is scoped like a timer: disposal emits CANCEL and forgets it.
    (expect-pending-effects 0)
    (click (role button :name "Upper"))
    (expect-pending-effects 1)
    (run-effect 2)
    (expect-text (test-id "log") "upper:JOB 1")
  )
)
