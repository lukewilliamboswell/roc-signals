(test "A Windows document is named by its final path component through Save As"
  (steps
    (stub-file-choice "notes-open" (chosen "C:\\Users\\Lee\\Ideas.txt"))
    (stub-file-read "notes-read" :path "C:\\Users\\Lee\\Ideas.txt" :text "Hello")
    (click (role button :name "Open…"))
    (expect-text (test-id "document-name") "Ideas.txt")
    (expect-text (test-id "note-status") "No changes")
    (stub-file-choice "notes-save-path" (chosen "C:\\Users\\Lee\\Notes\\Ideas.txt"))
    (click (role button :name "Save As…"))
    (expect-text (test-id "document-name") "Ideas.txt")
    (expect-text (test-id "note-status") "No changes")
  ))
