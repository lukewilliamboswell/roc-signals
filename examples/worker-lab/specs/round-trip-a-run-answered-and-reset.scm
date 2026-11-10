; A round trip back to the lab it started from: the soak (`--soak`)
; repeats the steps after `mark-metrics`, answering each job as this run
; answered it, and requires them to leave nothing allocated.
(test "Worker Lab — round trip: a run of the initial parameters answered, then reset"
  (steps
    (mark-metrics)
    (click (role button :name "Start"))
    (expect-pending-effects 8)
    (run-effect 1)
    (run-effect 2)
    (run-effect 3)
    (run-effect 4)
    (run-effect 5)
    (run-effect 6)
    (run-effect 7)
    (run-effect 8)
    (expect-text (test-id "progress") "8 of 8 done")
    (click (role button :name "Reset"))
    (expect-text (test-id "checksum") "no run")
    (expect-pending-effects 0)
  )
)
