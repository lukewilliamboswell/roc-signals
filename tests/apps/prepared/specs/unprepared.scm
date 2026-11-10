(test "Prepared — a preparation that fails answers its tasks with its error, which the app matches"
  (setup
    (file "empty.txt" "text/plain" "")
    (file "doc.txt" "text/plain" "alpha beta\n"))
  (steps
    ; An empty file cannot be indexed: prepare! answers Err(Empty), and the
    ; task's job is answered Failed(Empty), not lost.
    (choose-files (label "Document") "empty.txt")
    (run-effect 1)
    (expect-text (test-id "stats") "failed Empty")
    ; Every task over the same input fails the same way.
    (click (role button :name "Top"))
    (run-effect 2)
    (expect-text (test-id "top") "failed Empty")
    ; A document that can be indexed answers as usual.
    (choose-files (label "Document") "doc.txt")
    (run-effect 3)
    (expect-text (test-id "top") "alpha:1 beta:1")
  )
)
