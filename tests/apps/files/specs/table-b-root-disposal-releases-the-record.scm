(test "The instance ends with a File held only by its table record"
  (setup (file "retained.txt" "text/plain" "retained"))
  (steps
    (expect-files 0)
    (drop-files (label "Table files") "retained.txt")
    (click (role button :name "Remove table files"))
    (expect-text (test-id "table-rows") "table rows 0")
    (expect-files 1)
    ; End with the retained handle. The following spec checks the same
    ; native host after this root is dropped; Chrome teardown is also
    ; checked against these exports by the focused browser contract.
  ))
