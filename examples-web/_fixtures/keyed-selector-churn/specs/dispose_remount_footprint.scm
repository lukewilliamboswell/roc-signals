(test "repeated dispose and remount of selected rows returns to the same footprint"
  (steps
    (click (role button :name "Create 1,000 rows"))
    (click (role button :name "Select row 2"))
    (expect-attr (test-id "row-2") class "danger")
    (click (role button :name "Toggle table"))
    (click (role button :name "Toggle table"))
    (click (role button :name "Toggle table"))
    (click (role button :name "Toggle table"))
    (expect-attr (test-id "row-2") class "danger")
    ; Once capacities are warm, a complete dispose/remount cycle of 1,000
    ; selected rows leaves no retained Roc or host allocation behind: every
    ; membership released on disposal is matched by the one registered on
    ; remount, and the index reuses its own reserved capacity.
    (mark-metrics)
    (click (role button :name "Toggle table"))
    (click (role button :name "Toggle table"))
    (expect-attr (test-id "row-2") class "danger")
    (expect-attr (test-id "pinned-2") class "danger")
    (expect-metric-delta selector_memberships_released 2000)
    (expect-metric-delta selector_registrations 2000)
    (expect-metric-delta retained_alloc_delta 0)
    (expect-metric-delta host_retained_alloc_delta 0)
    (expect-metric-delta host_retained_bytes_delta 0)))
