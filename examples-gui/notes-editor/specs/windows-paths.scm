(test "A Windows document is named by its final path component through Save As"
  (steps
    (click (role button :name "Open…"))
    (resolve-file-choice "notes-open" (chosen "C:\\Users\\Lee\\Ideas.txt"))
    (resolve-file-read "notes-read" :path "C:\\Users\\Lee\\Ideas.txt" :text "Hello")
    (expect-text (test-id "document-name") "Ideas.txt")
    (expect-text (test-id "note-status") "No changes")
    (click (role button :name "Save As…"))
    (expect-pending-task "notes-save-path" 1)
    (resolve-file-choice "notes-save-path" (chosen "C:\\Users\\Lee\\Notes\\Ideas.txt"))
    (resolve-file-write "notes-write" :path "C:\\Users\\Lee\\Notes\\Ideas.txt" :bytes 5)
    (expect-text (test-id "document-name") "Ideas.txt")
    (expect-text (test-id "note-status") "No changes")
  ))
