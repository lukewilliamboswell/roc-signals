(test "Documents — closing the panel stops its job, but not the kept export it started"
  (steps
    (run-effect 1)
    (run-effect 2)
    (click (role button :name "Statistics"))
    (expect-text (test-id "totals") "Counting…")
    (expect-pending-effects 1)
    ; Closing the panel disposes its site, and that stops its job.
    (click (role button :name "Statistics"))
    (expect-absent (test-id "totals"))
    (expect-pending-effects 0)
    (click (role button :name "Statistics"))
    (run-effect 4)
    (expect-text (test-id "totals") "8 words in 2 documents")
    (click (role button :name "Export"))
    (expect-text (test-id "report") "Exporting…")
    (expect-pending-work "example.org/documents/report" 1)
    ; The export site is inside the panel, but its task says on_dispose: Keep,
    ; so its job survives the panel and its answer still reaches the page.
    (click (role button :name "Statistics"))
    (expect-pending-work "example.org/documents/report" 1)
    (run-effect 5)
    (expect-text (test-id "report") "doc-1: 3 words; doc-2: 5 words")
    ; Opening the panel again asks for nothing new.
    (click (role button :name "Statistics"))
    (expect-pending-work "example.org/documents/report" 0)
  )
)
