(test "Typed workers — a lambda calling a pure function and a named effectful function both run as tasks, and a task's own error is an answer"
  (steps
    (run-effect 1)
    ; "Shout" asks both tasks about the empty text: one cannot fail, the
    ; other refuses it with its own error, which arrives as Failed.
    (click (role button :name "Shout"))
    (expect-pending-work "test.roc-signals/typed/loud" 1)
    (expect-pending-work "test.roc-signals/typed/checked" 1)
    (run-effect 2)
    (run-effect 3)
    (expect-text (test-id "loud") "!")
    (expect-text (test-id "checked") "empty")
    (fill (label "Text") "roc")
    (run-effect 4)
    (click (role button :name "Shout"))
    (run-effect 6)
    (run-effect 5)
    (expect-text (test-id "loud") "roc!")
    (expect-text (test-id "checked") "roc!")
    (expect-pending-effects 0)
  )
)
