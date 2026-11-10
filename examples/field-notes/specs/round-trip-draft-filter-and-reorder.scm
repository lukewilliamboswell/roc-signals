; A round trip back to the notes it started from: the soak (`--soak`)
; repeats the steps after `mark-metrics` and requires them to leave
; nothing allocated.
(test "Field notes — round trip: a draft typed and cleared, the synced filter on and off, and two notes promoted"
  (setup
    (local-storage "field-notes:notes" "n0|0|1|r7|Generator hours;n1|1|0|r7|Fence line check")
  )
  (steps
    (stub-http "completed sync n0#r7" :url "/api/notes/sync" :status 200 :body "n0#r7")
    (run-effect 1)
    (expect-text (test-id "synced-count") "1")
    (mark-metrics)
    (fill (label "Note body") "Soak note")
    (fill (label "Note body") "")
    (check (label "Hide synced notes"))
    (uncheck (label "Hide synced notes"))
    (click (role button :name "Promote note n1"))
    (click (role button :name "Promote note n0"))
    (expect-pending-effects 0)
  )
)
