(test "Files — a chosen file has exactly the declared name, type and contents, whatever its name suggests"
  (setup
    ; The names do not decide the types: systems map `.log` differently,
    ; `README` to none and `.txt` to `text/plain`, and the app is given
    ; the declared type in both runners and on every system.
    (file "app.log" "text/x-log" "a line\n")
    (file "README" "text/markdown" "# notes\n")
    (file "photo.txt" "image/png" "not text"))
  (steps
    (choose-files (label "Upload") "app.log" "README" "photo.txt")
    (expect-text (test-id "files") "app.log:7:text/x-log|README:8:text/markdown|photo.txt:8:image/png")
    (expect-files 3)
  )
)
