(test "retiring the selected row leaves its duplicate membership selected"
  (steps
    (click (role button :name "Create 1,000 rows"))
    (click (role button :name "Select row 2"))
    (expect-attr (test-id "row-2") class "danger")
    (expect-attr (test-id "pinned-2") class "danger")
    (mark-metrics)
    (click (role button :name "Remove row 2"))
    (expect-absent (test-id "row-2"))
    ; The selected row's memberships leave; the pinned duplicate of the same
    ; exact key stays selected and no member is dirtied by the removal.
    (expect-metric-delta selector_registry_visits 2)
    (expect-metric-delta selector_memberships_released 2)
    (expect-metric-delta selector_registrations 0)
    (expect-metric-delta selector_members_dirtied 0)
    (expect-attr (test-id "pinned-2") class "danger")
    ; Moving the selection off the retired key dirties the surviving old
    ; member and both new members, and nothing else.
    (mark-metrics)
    (click (role button :name "Select row 3"))
    (expect-attr (test-id "pinned-2") class "")
    (expect-attr (test-id "row-3") class "danger")
    (expect-attr (test-id "pinned-3") class "danger")
    (expect-metric-delta selector_members_dirtied 3)
    (expect-metric-delta-at-most derived_calls_into_roc 5)
    (expect-metric-delta selector_registry_visits 0)))
