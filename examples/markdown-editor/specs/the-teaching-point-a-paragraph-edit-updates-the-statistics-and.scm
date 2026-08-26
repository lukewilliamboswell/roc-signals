(test "Markdown editor — The teaching point: a paragraph edit updates the statistics and the"
  (steps
    ; Given the state established by earlier scenarios
    (mark-metrics)
    (uncheck (label "Number the outline"))
    (check (label "Number the outline"))
    (mark-metrics)
    (select-option (label "Reading speed") "100")
    (select-option (label "Reading speed") "300")
    (select-option (label "Reading speed") "200")

    ; 4. The teaching point: a paragraph edit updates the statistics and the
    ; preview, and leaves the table of contents entirely alone.
    ; ---------------------------------------------------------------------------

    (mark-metrics)
    (click (role button :name "Append a word"))
    (expect-text (test-id "stat-words") "Words: 148")
    (expect-text (test-id "stat-characters") "Characters: 827")
    (expect-text (test-id "stat-headings") "Headings: 5")
    (expect-visible (text "Use "))
    ; The heading spine recomputes to an equal value, so the equality cutoff stops
    ; propagation before Outline.rows: no outline row is created, removed, or even
    ; relabelled.
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 0)
    ; Exactly five patches: the textarea value, the word count, the character
    ; count, the summary line, and the edited paragraph's text. The outline emits
    ; nothing at all, and the reading estimate is still 1 min so it stays quiet.
    (expect-metric-delta-at-most patches_emitted 5)
    (expect-visible (test-id "toc:roc-signals-field-guide"))
    (expect-visible (test-id "toc:performance"))
    (expect-attr (test-id "toc:performance") data-level "2")
  )
)
