(test "Data grid — paging"
  (steps
    ; Given the state established by earlier scenarios
    (mark-metrics)
    (click (role button :name "Sort by score"))
    (mark-metrics)
    (click (role button :name "Sort by score"))
    (click (role button :name "Sort by name"))
    (click (role button :name "Sort by name"))
    (click (role button :name "Sort by team"))
    (click (role button :name "Sort by id"))

    ; 3. paging
    (mark-metrics)
    (click (role button :name "Next page"))
    (expect-text (test-id "page-label") "Page 2 of 120")
    (expect-text (test-id "row-name-10") "Node-0010")
    (expect-text (test-id "row-score-19") "761")
    (expect-absent (test-id "row-name-9"))
    (expect-text (test-id "rows-showing") "Showing 10 of 1200 rows")
    (expect-disabled (role button :name "Previous page") false)
    (expect-metric-delta rows_created 10)
    (expect-metric-delta rows_reused 0)
    (expect-metric-delta rows_removed 10)
    (expect-metric-delta set_value 10)
    ; The polished grid renders each row as cells on a shared column
    ; template rather than one text line, so a re-render touches a few more
    ; nodes per row. Still O(visible rows), which is what this bounds.
    (expect-metric-delta-at-most patches_emitted 346)
    (expect-metric-delta each_key_hashes 10)
    (expect-metric-delta-at-most each_key_compares 10)
    (click (role button :name "Previous page"))
    (expect-text (test-id "page-label") "Page 1 of 120")
    (expect-text (test-id "row-name-0") "Node-0000")
    (expect-disabled (role button :name "Previous page") true)
    (click (role button :name "First page"))
    (expect-text (test-id "page-label") "Page 1 of 120")
  )
)
