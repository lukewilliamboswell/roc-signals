(test "Documents — closing the panel stops its run, but not the export it started"
  (steps
    (run-effect 1)
    (run-effect 2)
    (click (role button :name "Statistics"))
    (expect-text (test-id "totals") "Counting…")
    (expect-pending-effects 1)
    ; Closing the panel disposes its site, and that stops its run.
    (click (role button :name "Statistics"))
    (expect-absent (test-id "totals"))
    (expect-pending-effects 0)
    (click (role button :name "Statistics"))
    (run-effect 4)
    (expect-text (test-id "totals") "8 words in 2 documents")
    (click (role button :name "Export"))
    (expect-text (test-id "report") "Exporting…")
    (expect-pending-effects 1)
    ; The export site is outside the panel, so its run survives the panel.
    (click (role button :name "Statistics"))
    (expect-pending-effects 1)
    (run-effect 5)
    (expect-text (test-id "report") "doc-1: 3 words; doc-2: 5 words")
  )
)
