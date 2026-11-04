(test "Support inbox — the server reorders rows"
  (setup (manual-effects))
  (steps
    ; Load a settled inbox and open c1 before the scenario begins.
    (stub-http "initial inbox" :url "/api/inbox" :status 200 :body "c1|Card declined|Ada Lovelace|me;c2|Cannot log in|Grace Hopper|sam;c3|Refund status|Alan Turing|me#m1|c1|customer|My card was declined|read|-;m2|c1|agent|Looking into it now|read|-;m3|c2|customer|Login loop on mobile|read|-;m9|c1|agent|Refund issued|read|p1;m10|c2|customer|Still broken|new|-")
    (run-effect 1)
    (click (test-id "open-c1"))
    (stub-http "read c1" :url "/api/inbox" :status 200 :body "c1|Card declined|Ada Lovelace|me;c2|Cannot log in|Grace Hopper|sam;c3|Refund status|Alan Turing|me#m1|c1|customer|My card was declined|read|-;m2|c1|agent|Looking into it now|read|-;m3|c2|customer|Login loop on mobile|read|-;m9|c1|agent|Refund issued|read|p1;m10|c2|customer|Still broken|new|-")
    (run-effect 2)

    ; the server reorders rows
    ;
    ; A poll returns the same three conversations in a different order. Keyed rows
    ; move; none is created or destroyed, and each keeps its own data.

    (tick-interval 4000)
    (mark-metrics)
    (stub-http "next poll" :url "/api/inbox" :status 200 :body "c2|Cannot log in|Grace Hopper|sam;c3|Refund status|Alan Turing|me;c1|Card declined|Ada Lovelace|me#m1|c1|customer|My card was declined|read|-;m2|c1|agent|Looking into it now|read|-;m3|c2|customer|Login loop on mobile|read|-;m9|c1|agent|Refund issued|read|p1;m10|c2|customer|Still broken|new|-")
    (run-effect 3)
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta rows_reused 3)
    (expect-text (test-id "meta-c1") "Ada Lovelace · assigned to me")
    (expect-text (test-id "meta-c2") "Grace Hopper · assigned to sam")
    (expect-text (test-id "meta-c3") "Alan Turing · assigned to me")
    (expect-text (test-id "unread-c2") "1 unread")
    (expect-text (test-id "unread-c1") "No unread")
    (expect-text (test-id "state-c1") "Open")
    (expect-text (test-id "thread-count") "3 messages")
  )
)
