(test "Pomodoro tracker — start: the running branch mounts the interval"
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
    ; start: the running branch mounts the interval
    (click (role button :name "Start timer"))
    (expect-text (test-id "timer-state") "Timer: running")
    (expect-text (test-id "clock-face") "Focus 0/5 min")
    (expect-disabled (role button :name "Reset timer") false)
    (expect-interval 1000 1)
    (tick-interval 1000)
    (expect-text (test-id "clock-face") "Focus 1/5 min")
    (expect-text (test-id "row-total-docs") "11 min today")
    (expect-text (test-id "focus-minutes") "16")
    (expect-text (test-id "blocks-logged") "3")
    ; One tick touches the attached row only. Three sinks change - the clock face,
    ; the attached row's total, and the daily rollup - and no row is recreated.
    (mark-metrics)
    (tick-interval 1000)
    (expect-text (test-id "clock-face") "Focus 2/5 min")
    (expect-text (test-id "row-total-docs") "12 min today")
    (expect-text (test-id "row-total-api") "0 min today")
    (expect-text (test-id "row-total-triage") "5 min today")
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta scopes_created 0)
    (expect-metric-delta-at-most patches_emitted 3)
    (expect-metric-delta dirty_source_roots 1)
  )
)
