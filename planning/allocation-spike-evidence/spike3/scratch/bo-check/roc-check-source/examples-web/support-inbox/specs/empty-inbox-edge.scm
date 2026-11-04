(test "Support inbox — empty inbox edge"
  (setup (manual-effects))
  (steps
    ; Load a settled inbox and open c1 before the scenario begins.
    (stub-http "initial inbox" :url "/api/inbox" :status 200 :body "c1|Card declined|Ada Lovelace|me;c2|Cannot log in|Grace Hopper|sam;c3|Refund status|Alan Turing|me#m1|c1|customer|My card was declined|read|-;m2|c1|agent|Looking into it now|read|-;m3|c2|customer|Login loop on mobile|read|-;m9|c1|agent|Refund issued|read|p1")
    (run-effect 1)
    (click (test-id "open-c1"))
    (stub-http "read c1" :url "/api/inbox" :status 200 :body "c1|Card declined|Ada Lovelace|me;c2|Cannot log in|Grace Hopper|sam;c3|Refund status|Alan Turing|me#m1|c1|customer|My card was declined|read|-;m2|c1|agent|Looking into it now|read|-;m3|c2|customer|Login loop on mobile|read|-;m9|c1|agent|Refund issued|read|p1")
    (run-effect 2)

    ; empty inbox edge

    (tick-interval 4000)
    (expect-pending-effects 1)
    (stub-http "next poll" :url "/api/inbox" :status 200 :body "#")
    (run-effect 3)
    (expect-text (test-id "summary-conversations") "0")
    (expect-text (test-id "summary-unread") "0")
    (expect-text (test-id "summary-sending") "0")
    (expect-text (test-id "conv-empty") "No conversations to show.")
    (expect-absent (role region :name "Conversation c1"))
    (expect-text (test-id "thread-title") "c1 is no longer in the inbox")
    (expect-text (test-id "thread-empty") "No messages yet.")
    (expect-text (test-id "thread-count") "0 messages")
    (expect-text (test-id "filter-notice") "The open conversation is hidden by the current filter.")
  )
)
