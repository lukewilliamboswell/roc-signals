(test "Remount — the pane's private state starts again when the open message changes, and only then"
  (steps
    (fill (label "Reply") "Thanks, A")
    ; An equal key: the pane stays, draft and all.
    (mark-metrics)
    (click (role button :name "Open a"))
    (expect-metric-delta scopes_disposed 0)
    (expect-metric-delta scopes_created 0)
    (expect-value (label "Reply") "Thanks, A")
    ; A new key: the pane is disposed and mounted again.
    (mark-metrics)
    (click (role button :name "Open b"))
    (expect-metric-delta scopes_disposed 1)
    (expect-metric-delta scopes_created 1)
    (expect-text (test-id "message") "Message b")
    (expect-value (label "Reply") "")
    (fill (label "Reply") "Thanks, B")
    (click (role button :name "Open a"))
    (expect-value (label "Reply") "")
  ))
