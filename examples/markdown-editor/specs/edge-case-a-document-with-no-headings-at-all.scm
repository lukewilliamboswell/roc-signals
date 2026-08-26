(test "Markdown editor — Edge case: a document with no headings at all."
  (steps
    ; Given the state established by earlier scenarios
    (mark-metrics)
    (uncheck (label "Number the outline"))
    (check (label "Number the outline"))
    (mark-metrics)
    (select-option (label "Reading speed") "100")
    (select-option (label "Reading speed") "300")
    (select-option (label "Reading speed") "200")
    (mark-metrics)
    (click (role button :name "Append a word"))
    (mark-metrics)
    (click (role button :name "Append a section"))
    (click (role button :name "Append a section"))
    (click (role button :name "Load heading drill"))
    (mark-metrics)
    (click (role button :name "Move the last section up"))
    (mark-metrics)
    (click (role button :name "Remove the last section"))
    (mark-metrics)
    (click (role button :name "Append a section"))
    (mark-metrics)
    (click (role button :name "Demote the last heading"))

    ; 7. Edge case: a document with no headings at all.
    ; ---------------------------------------------------------------------------

    (click (role button :name "Load document without headings"))
    (expect-text (test-id "stat-headings") "Headings: 0")
    (expect-visible (text "No headings yet: add a line that starts with a hash."))
    (expect-absent (test-id "toc:alpha"))
    (expect-visible (text "Just a paragraph with no headings at all."))
    (expect-visible (text "And a second paragraph so the preview has something to show."))
    (expect-text (test-id "stat-words") "Words: 19")
  )
)
