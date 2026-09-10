(test "Opening equal text must start a fresh editor lifetime"
  (steps
    (fill (label "Note text") "Same body")
    (shortcut (test-id "notes-editor") "o" 1)
    (click (role button :name "Discard changes"))
    (resolve-file-choice "notes-open" (chosen "/tmp/Another.txt"))
    (mark-metrics)
    (resolve-file-read "notes-read" :path "/tmp/Another.txt" :text "Same body")
    (expect-metric-delta bind_event 1)))
