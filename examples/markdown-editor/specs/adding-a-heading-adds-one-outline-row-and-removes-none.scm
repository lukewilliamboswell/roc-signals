(test "Markdown editor — Adding a heading adds one outline row and removes none"
  (steps
    ; Bring the page to the state this spec starts from.
    (mark-metrics)
    (uncheck (label "Number the outline"))
    (check (label "Number the outline"))
    (mark-metrics)
    (select-option (label "Reading speed") "100")
    (select-option (label "Reading speed") "300")
    (select-option (label "Reading speed") "200")
    (mark-metrics)
    (click (role button :name "Append a word"))

    ; Adding a heading does rebuild the outline, by exactly one row, where a
    ; paragraph edit leaves it alone.
    ; ---------------------------------------------------------------------------

    (mark-metrics)
    (click (role button :name "Append a section"))
    (expect-text (test-id "stat-headings") "6")
    (expect-visible (test-id "toc:new-section"))
    (expect-attr (test-id "toc:new-section") data-level "2")
    ; Three new rows and no removals: one preview block, its inline segment, and one outline entry.
    (expect-metric-delta rows_created 3)
    (expect-metric-delta rows_removed 0)
    ; Duplicate heading titles still get unique, stable row identities.
    (click (role button :name "Append a section"))
    (expect-text (test-id "stat-headings") "7")
    (expect-visible (test-id "toc:new-section"))
    (expect-visible (test-id "toc:new-section-2"))
  )
)
