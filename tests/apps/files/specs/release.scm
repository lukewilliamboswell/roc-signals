(test "Files — a file is released when no value holds its handle any more"
  (setup
    (file "a.txt" "text/plain" "a")
    (file "b.txt" "text/plain" "bb")
    (file "c.txt" "text/plain" "ccc"))
  (steps
    (choose-files (label "Upload") "a.txt" "b.txt" "c.txt")
    (expect-files 3)
    (click (role button :name "Keep first"))
    (expect-text (test-id "files") "a.txt:1:text/plain")
    (expect-files 1)
    (click (role button :name "Clear"))
    (expect-text (test-id "files") "none")
    (expect-files 0)
  )
)
