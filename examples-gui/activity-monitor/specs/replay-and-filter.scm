(scenario "replay-and-filter"
  :window "1200x820"
  ; Initial, loading, populated, selected and filtered states for the streaming
  ; example. Replay is the deterministic source, so the event count after a fixed
  ; number of steps is a fact the harness can assert rather than a screenshot.
  (steps
    (expect-visible (text "Activity Monitor"))
    ; Retry and Cancel are phase-gated: they are not offered at all unless the
    ; phase they belong to is live, so their absence here is the assertion.
    (expect-absent (text "\"Retry read\""))
    (expect-absent (text "\"Cancel operation\""))
    (expect-count "event-" 0)
    (snapshot "initial")
    (click (role button :name "Step replay"))
    (wait 400)
    (click (role button :name "Step replay"))
    (wait 400)
    (click (role button :name "Step replay"))
    (wait 400)
    (expect-count "event-" 3)
    (snapshot "replayed")
    (click (role button :name "Clear history"))
    (wait 500)
    (expect-count "event-" 0)
    (click (role button :name "Step replay"))
    (wait 400)
    (click (role button :name "Step replay"))
    (wait 400)
    (expect-count "event-" 2)
    (type (label "Filter activity") "zzz")
    (wait 700)
    (expect-count "event-" 0)
    (snapshot "filtered-empty")
    (key "ctrl-a")
    (key "backspace")
    (wait 700)
    (expect-count "event-" 2)))
