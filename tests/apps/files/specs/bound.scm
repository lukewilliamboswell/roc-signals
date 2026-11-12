(test "Files — files beyond the 64 handles an instance holds are refused, and counted"
  (setup
    (file "f.txt" "text/plain" "f"))
  (steps
    (drop-files (label "Drop") "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt")
    (expect-text (test-id "refused") "refused 6")
    (expect-files 64)
    (click (role button :name "Keep first"))
    (expect-files 1)
    (drop-files (label "Drop") "f.txt")
    (expect-text (test-id "files") "f.txt:1:text/plain|f.txt:1:text/plain")
    (expect-files 2)
  )
)
