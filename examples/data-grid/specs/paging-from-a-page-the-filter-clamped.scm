(test "Data grid — paging steps from the page shown when a filter leaves fewer pages"
  (steps
    (click (role button :name "Next page"))
    (click (role button :name "Next page"))
    (click (role button :name "Next page"))
    (expect-text (test-id "page-label") "Page 4 of 120")
    ; Twelve rows match, on two pages: the grid shows the last of them, not
    ; the fourth page the reader asked for.
    (fill (label "Filter") "119")
    (expect-text (test-id "page-label") "Page 2 of 2")
    (expect-text (test-id "rows-showing") "Showing 2 of 12 rows")
    (expect-disabled (role button :name "Next page") true)
    (expect-disabled (role button :name "Previous page") false)
    ; "Previous page" steps back from the page shown.
    (click (role button :name "Previous page"))
    (expect-text (test-id "page-label") "Page 1 of 2")
    (expect-text (test-id "rows-showing") "Showing 10 of 12 rows")
    (expect-text (test-id "row-name-119") "Node-0119")
    (expect-disabled (role button :name "Previous page") true)
    (click (role button :name "Next page"))
    (expect-text (test-id "page-label") "Page 2 of 2")
    (expect-disabled (role button :name "Next page") true)
    ; The page turned to is the reader's place: widening the filter shows it.
    (fill (label "Filter") "")
    (expect-text (test-id "page-label") "Page 2 of 120")
    (expect-text (test-id "row-name-10") "Node-0010")
  )
)
