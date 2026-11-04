(test "small keyed selector churn survives every recoverable allocation failure"
  (steps
    ; A small copy of the structural cases, sized so the host allocation fault
    ; campaign can replay every coordinate: the selector index must refuse and
    ; retry a failed preparation without partial publication.
    (click (role button :name "Create 8 rows"))
    (click (role button :name "Select row 2"))
    (expect-attr (test-id "row-2") class "danger")
    (mark-metrics)
    (click (role button :name "Remove row 2"))
    (expect-absent (test-id "row-2"))
    (expect-metric-delta selector_memberships_released 2)
    (expect-metric-delta selector_registrations 0)
    (expect-attr (test-id "pinned-2") class "danger")
    (mark-metrics)
    (click (role button :name "Append one row"))
    (expect-visible (test-id "row-9"))
    (expect-metric-delta selector_registrations 2)
    (expect-metric-delta selector_key_bytes_copied 2)
    (click (role button :name "Select row 9"))
    (expect-attr (test-id "row-9") class "danger")
    (expect-attr (test-id "pinned-2") class "")
    (click (role button :name "Hover row 5"))
    (expect-attr (test-id "row-5") data-hover "hover")
    (click (role button :name "Toggle table"))
    (expect-visible (test-id "table-hidden"))
    (click (role button :name "Toggle table"))
    (expect-attr (test-id "row-9") class "danger")
    (expect-attr (test-id "row-5") data-hover "hover")))
