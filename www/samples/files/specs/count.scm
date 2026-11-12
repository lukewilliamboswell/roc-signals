(test "Upload — a chosen or dropped file is counted in a worker, and released when forgotten"
  (setup
    (file "notes.txt" "text/plain" "one two\nthree\n")
    (file "more.txt" "text/plain" "a b c"))
  (steps
    (expect-text (test-id "counts") "Choose a file.")
    (choose-files (label "Text file") "notes.txt")
    (expect-text (test-id "counts") "Counting…")
    (run-effect 1)
    (expect-text (test-id "counts") "notes.txt: 3 lines, 3 words")
    (drop-files (label "Drop a file") "more.txt")
    (run-effect 2)
    (expect-text (test-id "counts") "more.txt: 1 lines, 3 words")
    (expect-files 2)
    (click (role button :name "Forget files"))
    (expect-files 0)
  )
)
