(test "Query builder — initial state"
  (steps
    ; initial state
    (expect-visible (role heading :name "Query Builder"))
    (expect-visible (role region :name "Dataset"))
    (expect-visible (role region :name "Generated query"))
    (expect-visible (role region :name "Matches"))
    (expect-visible (role region :name "Filter tree"))
    (expect-visible (role region :name "Group n1"))
    (expect-visible (role region :name "Condition n2"))
    (expect-checked (label "Include archived rows") false)
    ; The header numbers moved from sentences into stat tiles, so these
    ; assertions read the tile value rather than "Dataset rows: 5" prose. The
    ; single "Conditions N / Groups N / Depth N" line became three tiles;
    ; "shape-stats" stays on the conditions tile and the other two are new ids.
    (expect-text (test-id "dataset-summary") "5")
    (expect-text (test-id "query-text") "(dept = 'Platform')")
    (expect-text (test-id "shape-stats") "1")
    (expect-text (test-id "group-count") "1")
    (expect-text (test-id "tree-depth") "1")
    (expect-text (test-id "match-summary") "2 of 5")
    (expect-text (test-id "summary-n1") "(dept = 'Platform')")
    (expect-text (test-id "summary-n2") "dept = 'Platform'")
    ; The group operator is a segmented AND/OR control now, not a select.
    (expect-attr (role button :name "Set AND for n1") aria-pressed "true")
    (expect-attr (role button :name "Set OR for n1") aria-pressed "false")
    (expect-checked (label "Negate n1") false)
    (expect-value (label "Field n2") "dept")
    (expect-value (label "Operator n2") "eq")
    (expect-value (label "Value n2") "Platform")
    (expect-visible (test-id "match-Ada"))
    (expect-visible (test-id "match-Bo"))
    (expect-absent (test-id "match-Cy"))
    (expect-absent (test-id "match-Dee"))
    (expect-absent (test-id "match-Eli"))
    ; The root group is not deletable.
    (expect-absent (role button :name "Delete n1"))
    (expect-visible (text "Root group"))
  )
)
