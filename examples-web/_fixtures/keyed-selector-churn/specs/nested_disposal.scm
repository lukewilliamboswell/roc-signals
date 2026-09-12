(test "disposing the table retires every nested membership and remounting restores them"
  (steps
    (click (role button :name "Create 1,000 rows"))
    (click (role button :name "Select row 2"))
    (expect-attr (test-id "row-2") class "danger")
    (mark-metrics)
    (click (role button :name "Toggle table"))
    (expect-visible (test-id "table-hidden"))
    (expect-absent (test-id "row-2"))
    ; Every row scope is disposed through the when branch: 2,000 memberships
    ; leave, none are registered, and the pinned duplicate keeps the selection.
    (expect-metric-delta scopes_disposed 1001)
    (expect-metric-delta selector_memberships_released 2000)
    (expect-metric-delta selector_registrations 0)
    (expect-metric-delta-at-most selector_registry_visits 2008)
    (expect-attr (test-id "pinned-2") class "danger")
    ; With the table gone only the pinned members remain for these keys.
    (mark-metrics)
    (click (role button :name "Choose key 3"))
    (expect-attr (test-id "pinned-2") class "")
    (expect-attr (test-id "pinned-3") class "danger")
    (expect-metric-delta selector_members_dirtied 2)
    (expect-metric-delta selector_registry_visits 0)
    ; Remounting registers exactly the new rows' memberships and copies exactly
    ; their key bytes: sum(len(str(i)) for i in 1..1000) twice.
    (mark-metrics)
    (click (role button :name "Toggle table"))
    (expect-visible (test-id "row-1000"))
    (expect-attr (test-id "row-3") class "danger")
    (expect-attr (test-id "row-2") class "")
    (expect-metric-delta scopes_created 1001)
    (expect-metric-delta selector_registrations 2000)
    (expect-metric-delta selector_key_bytes_copied 5786)
    (expect-metric-delta selector_memberships_released 0)
    ; Selecting after the remount reaches the re-registered members: the old
    ; key's two members and the new key's two members, nothing else.
    (mark-metrics)
    (click (role button :name "Select row 2"))
    (expect-attr (test-id "row-2") class "danger")
    (expect-attr (test-id "pinned-2") class "danger")
    (expect-attr (test-id "row-3") class "")
    (expect-attr (test-id "pinned-3") class "")
    (expect-metric-delta selector_members_dirtied 4)
    (expect-metric-delta selector_registry_visits 0)))
