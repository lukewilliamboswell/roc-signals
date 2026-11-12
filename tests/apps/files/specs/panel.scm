(test "Files — the files a state holds go with it when its scope is disposed"
  (setup
    (file "a.txt" "text/plain" "a")
    (file "b.txt" "text/plain" "bb"))
  (steps
    (choose-files (label "Upload") "a.txt")
    (click (role button :name "Panel"))
    (choose-files (label "Panel upload") "b.txt")
    (expect-text (test-id "panel-files") "b.txt:2:text/plain")
    (expect-files 2)
    (click (role button :name "Panel"))
    (expect-absent (test-id "panel-files"))
    (expect-files 1)
    (expect-text (test-id "files") "a.txt:1:text/plain")
  )
)
