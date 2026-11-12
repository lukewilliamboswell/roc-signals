(test "Worker Lab — A drawing keeps the bound: the page's clock takes a slot, and a drawn strip holds its own until its URL comes back"
  (steps
    (select-option (label "Workload") "draw")
    ; The parameters a picture accepts.
    (fill (label "Jobs") "61")
    (expect-text (test-id "problem") "A picture has from 1 to 60 strips: the page holds every strip, and the picture, as a file.")
    (fill (label "Jobs") "20")
    (fill (label "Weight") "17")
    (expect-text (test-id "problem") "A picture's weight is from 1 to 16, 128 pixels of width each.")
    (fill (label "Weight") "1")
    (click (role button :name "Start"))
    ; 16 requests in flight at most: the heartbeat, the page's clock and
    ; 14 strips.
    (expect-pending-work "roc-signals.example/worker-lab/strip" 14)
    (expect-interval 100 1)
    (expect-text (test-id "waiting") "6")
    ; A drawn strip asks for its URL and keeps its slot: no strip is
    ; admitted until the URL comes back.
    (run-effect 1)
    (expect-pending-work "roc-signals.example/worker-lab/strip" 13)
    (expect-pending-effects 14)
    (expect-text (test-id "waiting") "6")
    (run-effect 15)
    (expect-pending-work "roc-signals.example/worker-lab/strip" 14)
    (expect-text (test-id "waiting") "5")
    (expect-text (test-id "strip-15") "drawing")
    (expect-text (test-id "strip-16") "waiting")
    (expect-text (test-id "refused") "Refused at the in-flight bound and retried: 0")
  )
)
