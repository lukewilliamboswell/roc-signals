(test "Package explorer — B. navigating away cancels the in flight panel requests"
  (setup
    ; A. deep link

    (initial-location "/packages/roc-json")
  )
  (steps
    ; B. navigating away cancels the in flight panel requests

    (click (role link :name "Back to search"))
    (expect-current-location "/")
    (expect-document-title "Package Explorer")
    (expect-absent (role region :name "Package detail"))
    (expect-absent (role region :name "Overview"))
    (expect-pending-task "detail" 0)
    (expect-pending-task "versions" 0)
    (expect-pending-task "deps" 0)
    (expect-canceled-task "detail" 1)
    (expect-canceled-task "versions" 1)
    (expect-canceled-task "deps" 1)
    (expect-cleanup "package detail panels" 1)
  )
)
