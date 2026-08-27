(test "Pomodoro tracker — logging the block writes the ledger and rewinds the clock"
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
    (click (role button :name "Start timer"))
    (tick-interval 1000)
    (tick-interval 1000)
    (tick-interval 1000)
    (tick-interval 1000)
    (tick-interval 1000)
    (tick-interval 1000)
    (tick-interval 1000)
    (tick-interval 1000)

    ; logging the block writes the ledger and rewinds the clock
    (mark-metrics)
    (click (role button :name "Log block to Docs pass"))
    (expect-text (test-id "row-total-docs") "15 min today")
    (expect-text (test-id "blocks-logged") "4")
    (expect-text (test-id "focus-minutes") "20")
    (expect-text (test-id "clock-face") "Focus 0/5 min")
    (expect-local-storage "pomodoro:ledger" "api=0;docs=3;triage=1")
    ; Writing the ledger changes the seed row key, so the ledger scope is re-mounted
    ; from the freshly saved text: the seed row plus the three project rows.
    (expect-metric-delta rows_created 4)
    (expect-metric-delta rows_removed 1)
    (expect-text (test-id "row-total-api") "0 min today")
    (expect-text (test-id "row-total-triage") "5 min today")
  )
)
