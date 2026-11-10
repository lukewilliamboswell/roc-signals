(test "Words — a count starts from a button, can be cancelled, and its answer lands in state"
  (steps
    (run-effect 1)
    (run-effect 2)
    (expect-text (test-id "counted") "")
    (click (role button :name "Count words"))
    (expect-text (test-id "counted") "Counting…")
    (expect-pending-effects 1)
    ; Cancelling stops the job: nothing is left waiting.
    (click (role button :name "Cancel"))
    (expect-pending-effects 0)
    (expect-text (test-id "counted") "Cancelled")
    (click (role button :name "Count words"))
    (run-effect 4)
    (expect-text (test-id "counted") "the 2, cat 1, saw 1")
    ; Editing the text summarises it again, but starts no count.
    (fill (label "Text") "b a b")
    (expect-pending-effects 1)
    (run-effect 5)
    (expect-text (test-id "counted") "the 2, cat 1, saw 1")
    ; Pressing again counts the new text; pressing during a count starts over.
    (click (role button :name "Count words"))
    (click (role button :name "Count words"))
    (expect-pending-effects 1)
    (run-effect 7)
    (expect-text (test-id "counted") "b 2, a 1")
  )
)
