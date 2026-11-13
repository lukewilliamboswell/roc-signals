(test "Files — files chosen in a file input arrive as handles with their name, size and type"
  (setup
    (file "notes.txt" "text/plain" "hello world")
    (file "data.csv" "text/csv" "ab" 1000))
  (steps
    (expect-files 0)
    (choose-files (label "Upload") "notes.txt" "data.csv")
    (expect-text (test-id "files") "notes.txt:11:text/plain|data.csv:2000:text/csv")
    (expect-files 2)
    ; Choosing again gives a new handle, even for the same file.
    (choose-files (label "Upload") "notes.txt")
    (expect-text (test-id "files") "notes.txt:11:text/plain|data.csv:2000:text/csv|notes.txt:11:text/plain")
    (expect-files 3)
  )
)
