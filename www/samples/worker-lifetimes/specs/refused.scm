(test "Documents — a run beyond the in-flight bound is refused, and the others go on"
  (steps
    (expect-pending-effects 2)
    (click (role button :name "Add document"))
    (expect-pending-effects 3)
    ; The bound is three: the fourth run is not started, and its row is told.
    (click (role button :name "Add document"))
    (expect-pending-effects 3)
    (expect-text (test-id "words-doc-4") "Too much is running.")
    (run-effect 1)
    (run-effect 2)
    (run-effect 3)
    (expect-text (test-id "words-doc-1") "3 words")
    (expect-text (test-id "words-doc-3") "4 words")
    ; A refused run is not retried on its own.
    (expect-pending-effects 0)
    (expect-text (test-id "words-doc-4") "Too much is running.")
  )
)
