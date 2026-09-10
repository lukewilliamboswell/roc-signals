(test "A Windows file path supplies only its final segment as the title"
  (steps
    (click (role button :name "Open…"))
    (resolve-task "notes-open" "6:files16:chosen22:C:\\Users\\Lee\\Ideas.txt")
    (resolve-task "notes-read" "6:files122:C:\\Users\\Lee\\Ideas.txt5:Hello")
    (expect-text (test-id "document-name") "Ideas.txt")))
