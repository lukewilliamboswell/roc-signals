(test "Files — retired handles are admitted again without a count observation"
  (setup (file "f.txt" "text/plain" "f"))
  (steps
    (drop-files (label "Drop") "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt")
    (expect-text (test-id "refused") "refused 6")
    (click (role button :name "Clear"))
    (expect-text (test-id "files") "none")
    ; No expect-files drains retirement before the next input.
    (drop-files (label "Drop") "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt" "f.txt")
    (expect-text (test-id "refused") "refused 12")
    (expect-files 64)
    (click (role button :name "Clear"))
    (choose-files (label "Upload") "f.txt")
    (expect-text (test-id "files") "f.txt:1:text/plain")
    (expect-files 1)))
