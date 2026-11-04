(test "Support inbox — pausing and resuming polling"
  (setup (manual-effects))
  (steps
    ; Load a settled inbox and open c1 before the scenario begins.
    (stub-http "initial inbox" :url "/api/inbox" :status 200 :body "c1|Card declined|Ada Lovelace|me;c2|Cannot log in|Grace Hopper|sam;c3|Refund status|Alan Turing|me#m1|c1|customer|My card was declined|read|-;m2|c1|agent|Looking into it now|read|-;m3|c2|customer|Login loop on mobile|read|-;m9|c1|agent|Refund issued|read|p1")
    (run-effect 1)
    (click (test-id "open-c1"))
    (stub-http "read c1" :url "/api/inbox" :status 200 :body "c1|Card declined|Ada Lovelace|me;c2|Cannot log in|Grace Hopper|sam;c3|Refund status|Alan Turing|me#m1|c1|customer|My card was declined|read|-;m2|c1|agent|Looking into it now|read|-;m3|c2|customer|Login loop on mobile|read|-;m9|c1|agent|Refund issued|read|p1")
    (run-effect 2)

    ; pausing and resuming polling

    (uncheck (label "Poll for updates"))
    (expect-checked (label "Poll for updates") false)
    (expect-text (test-id "poll-state") "Paused")
    (expect-text (test-id "poll-paused") "Polling is paused.")
    (expect-absent (role region :name "Poll loop"))
    (expect-interval 4000 0)
    (expect-cleanup "inbox polling cleanup" 1)
    (tick-interval-if-active 4000)
    (expect-pending-effects 0)
    (check (label "Poll for updates"))
    (expect-checked (label "Poll for updates") true)
    (expect-visible (role region :name "Poll loop"))
    (expect-text (test-id "poll-count") "Polls issued: 0")
    (expect-text (test-id "poll-state") "Polling every 4s")
    (expect-interval 4000 1)
    (expect-absent (test-id "poll-paused"))
  )
)
