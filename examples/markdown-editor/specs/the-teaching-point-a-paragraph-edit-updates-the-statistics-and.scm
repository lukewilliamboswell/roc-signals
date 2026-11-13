(test "Markdown editor — The teaching point: a paragraph edit updates the statistics and the"
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
    ; The heading spine recomputes to an equal value, so the equality cutoff stops
    ; propagation before Outline.rows: no outline row is created, removed, or even
    ; relabelled.
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 0)
    ; Six patches: the textarea, word count, character count, summary, edited
    ; paragraph and first unsaved-status change. The outline emits nothing,
    ; and the reading estimate stays 1 min. Guard and draft commands are not DOM patches.
    (expect-metric-delta patches_emitted 6)
    (expect-visible (test-id "toc:roc-signals-field-guide"))
    (expect-visible (test-id "toc:performance"))
    (expect-attr (test-id "toc:performance") data-level "2")
  )
)
