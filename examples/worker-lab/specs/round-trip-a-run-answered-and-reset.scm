; A round trip back to the lab it started from: the soak (`--soak`)
; repeats the steps after `mark-metrics`, answering each job as this run
; answered it, and requires them to leave nothing allocated. The drawing
; makes, shows, composes, digests and saves files; resetting lets every one
; of them go, the saved picture's included.
(test "Worker Lab — round trip: a run of the initial parameters and a drawing, each answered, then reset"
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
    (select-option (label "Workload") "draw")
    (fill (label "Jobs") "2")
    (fill (label "Weight") "1")
    (click (role button :name "Start"))
    (run-effect 9)
    (run-effect 10)
    (run-effect 11)
    (run-effect 12)
    (run-effect 13)
    (run-effect 14)
    (run-effect 15)
    (expect-visible (test-id "picture-image"))
    (click (role button :name "Save picture"))
    (expect-saves 1)
    (click (role button :name "Reset"))
    ; No `expect-files 0` here: a soak records the answers that carried
    ; files with their handles, so it holds them while it runs. The spec
    ; that draws a picture checks that Reset lets every file go.
    (select-option (label "Workload") "primes")
    (fill (label "Jobs") "8")
    (fill (label "Weight") "4")
    (expect-text (test-id "checksum") "no run")
    (expect-pending-effects 0)
  )
)
