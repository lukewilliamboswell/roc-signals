(test "Documents — each row has its own job, and removing a row stops it"
  (steps
    ; One job per row at mount.
    (expect-pending-effects 2)
    (expect-text (test-id "words-doc-1") "Counting…")
    ; Jobs answer in the order they finish, not the order they were asked for.
    (run-effect 2)
    (expect-text (test-id "words-doc-2") "5 words")
    (expect-text (test-id "words-doc-1") "Counting…")
    (click (role button :name "Remove doc-1"))
    (expect-absent (test-id "words-doc-1"))
    (expect-pending-effects 0)
    (click (role button :name "Add document"))
    (expect-pending-effects 1)
    (run-effect 3)
    (expect-text (test-id "words-doc-3") "4 words")
    (expect-text (test-id "words-doc-2") "5 words")
  )
)
