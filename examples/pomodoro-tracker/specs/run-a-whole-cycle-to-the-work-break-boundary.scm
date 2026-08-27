(test "Pomodoro tracker — run a whole cycle to the work/break boundary"
  (setup
    ; Pomodoro Tracker - restore, run, log, and rewind the clock.

    ; The saved ledger and the saved attachment are read before the first render.
    ; Deliberately messy saved text: "api" is absent, "bogus" has no value, and
    ; "gone" is not a known project. The decoder falls back to zero and ignores the
    ; rest, so "API rewrite" mounts as a project with no logged time.
    (local-storage "pomodoro:ledger" "docs=2;bogus;gone=9;triage=1")
    (local-storage "pomodoro:project" "docs")
  )
  (steps
    ; Given the state established by earlier scenarios
    (click (role button :name "Start timer"))
    (tick-interval 1000)
    (mark-metrics)
    (tick-interval 1000)
    (mark-metrics)
    (click (role button :name "Attach Bug triage"))
    (click (role button :name "Attach Docs pass"))
    (click (role button :name "Pause timer"))
    (tick-interval-if-active 1000)
    (click (role button :name "Resume timer"))
    (tick-interval 1000)
    (click (role button :name "Reset timer"))

    ; run a whole cycle to the work/break boundary
    (click (role button :name "Start timer"))
    (tick-interval 1000)
    (tick-interval 1000)
    (tick-interval 1000)
    (tick-interval 1000)
    (expect-text (test-id "clock-face") "Focus 4/5 min")
    (expect-text (test-id "row-total-docs") "14 min today")
    (expect-disabled (role button :name "Log block to Docs pass") true)
    (tick-interval 1000)
    (expect-text (test-id "clock-face") "Break 0/2 min")
    (expect-text (test-id "row-total-docs") "15 min today")
    (expect-disabled (role button :name "Log block to Docs pass") false)
    (expect-disabled (role button :name "Log block to API rewrite") true)
    (tick-interval 1000)
    (expect-text (test-id "clock-face") "Break 1/2 min")
    (expect-text (test-id "row-total-docs") "15 min today")
    (tick-interval 1000)
    (tick-interval 1000)
    (expect-text (test-id "clock-face") "Cycle complete")
  )
)
