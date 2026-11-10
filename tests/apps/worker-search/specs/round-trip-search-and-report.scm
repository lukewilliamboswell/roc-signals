; A round trip back to the page it started from: the soak (`--soak`)
; repeats the steps after `mark-metrics`, answering each job as this run
; answered it, and requires them to leave nothing allocated.
(test "Worker search — round trip: a search answered and cleared, and the report answered and closed"
  (steps
    (mark-metrics)
    (fill (label "Search") "roc")
    (run-effect 1)
    (expect-text (test-id "status") "Found")
    (fill (label "Search") "")
    (expect-text (test-id "status") "")
    (click (role button :name "Report"))
    (run-effect 2)
    (expect-text (test-id "summary") "8 entries, longest basic-webserver")
    (click (role button :name "Report"))
    (expect-absent (test-id "summary"))
    (expect-pending-effects 0)
  )
)
