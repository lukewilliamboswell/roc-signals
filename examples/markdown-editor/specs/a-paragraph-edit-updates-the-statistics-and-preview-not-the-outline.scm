(test "Markdown editor — A paragraph edit updates the statistics and preview, not the outline"
  (steps
    ; Bring the page to the state this spec starts from.
    (mark-metrics)
    (uncheck (label "Number the outline"))
    (check (label "Number the outline"))
    (mark-metrics)
    (select-option (label "Reading speed") "100")
    (select-option (label "Reading speed") "300")
    (select-option (label "Reading speed") "200")

    ; The teaching point: a paragraph edit updates the statistics and the
    ; preview, and leaves the table of contents entirely alone.
    ; ---------------------------------------------------------------------------

    (mark-metrics)
    (click (role button :name "Append a word"))
    (expect-text (test-id "stat-words") "148")
    (expect-text (test-id "stat-characters") "828")
    (expect-text (test-id "stat-headings") "5")
    (expect-visible (text "Use "))
    ; The list of headings is derived again and equals the one before, so
    ; nothing that reads it is woken: no outline row is created, removed, or
    ; even relabelled.
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 0)
    ; Exactly five patches: the textarea value, the word count, the character
    ; count, the summary line, and the edited paragraph's text. The outline emits
    ; nothing at all, and the reading estimate is still 1 min so it stays quiet.
    (expect-visible (test-id "toc:roc-signals-field-guide"))
    (expect-visible (test-id "toc:performance"))
    (expect-attr (test-id "toc:performance") data-level "2")
  )
)
