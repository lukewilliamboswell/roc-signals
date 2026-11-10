(test "Tasks — closing a panel stops its job, unless the task keeps it, whose answer reaches the page"
  (setup
    (file "notes.txt" "text/plain" "abcdef"))
  (steps
    (choose-files (label "Upload") "notes.txt")
    (click (role button :name "Panel"))
    (expect-pending-work "test.roc-signals/tasks/stopped" 1)
    (expect-pending-work "test.roc-signals/tasks/kept" 1)
    (click (role button :name "Panel"))
    (expect-absent (label "panel"))
    (expect-pending-work "test.roc-signals/tasks/stopped" 0)
    (expect-pending-work "test.roc-signals/tasks/kept" 1)
    (run-effect 2)
    (expect-text (test-id "kept") "kept 6")
  )
)
