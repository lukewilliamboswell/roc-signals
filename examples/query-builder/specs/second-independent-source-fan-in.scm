(test "Query builder — second independent source fan in"
  (steps
    ; Given the state established by earlier scenarios
    (fill (label "Value n2") "")
    (fill (label "Value n2") "Platform")
    (select-option (label "Operator n2") "ne")
    (select-option (label "Operator n2") "contains")
    (fill (label "Value n2") "esi")
    (select-option (label "Field n2") "name")
    (select-option (label "Operator n2") "gt")
    (fill (label "Value n2") "3")
    (select-option (label "Field n2") "level")
    (select-option (label "Operator n2") "lt")
    (fill (label "Value n2") "three")
    (select-option (label "Field n2") "dept")
    (select-option (label "Operator n2") "eq")
    (fill (label "Value n2") "Platform")

    ; second independent source fan in
    (mark-metrics)
    (check (label "Include archived rows"))
    (expect-text (test-id "dataset-summary") "6")
    (expect-text (test-id "match-summary") "3 of 6")
    (expect-visible (test-id "match-Fay"))
    ; Only the matched-row list grows; the tree editor is untouched.
    (expect-metric-delta rows_created 1)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta rows_reused 2)
    (uncheck (label "Include archived rows"))
    (expect-text (test-id "dataset-summary") "5")
    (expect-text (test-id "match-summary") "2 of 5")
    (expect-absent (test-id "match-Fay"))
  )
)
