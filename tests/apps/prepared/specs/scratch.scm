(test "Prepared — a builder kept in a prepared state is a contract error in a later job, a finished file kept there is not"
  (setup
    (file "doc.txt" "text/plain" "alpha beta\n"))
  (steps
    (choose-files (label "Document") "doc.txt")
    (run-effect 1)
    (expect-text (test-id "stats") "1 lines, 2 words, 2 distinct")
    ; The task appends to the builder the preparation opened and kept: the
    ; builder outlived the call that opened it, so nothing is written and
    ; the job is lost to a contract error.
    (click (role button :name "Write scratch"))
    (expect-pending-work "test.roc-signals/prepared/scratch/write" 1)
    (run-effect 2)
    (expect-text (test-id "write") "lost Contract")
    ; The copy the preparation finished is an ordinary file: a task answers
    ; with it, and the page holds it.
    (click (role button :name "Keep copy"))
    (run-effect 3)
    (expect-text (test-id "copy") "kept copy.txt:11")
    (expect-files 2)
  )
)
