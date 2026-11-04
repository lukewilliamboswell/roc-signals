(test "Support inbox — filter meets selection"
  (setup (manual-effects))
  (steps
    ; A settled snapshot provides the conversations this scenario needs.
    (stub-http "initial inbox" :url "/api/inbox" :status 200 :body "c1|Card declined|Ada Lovelace|me;c2|Cannot log in|Grace Hopper|sam;c3|Refund status|Alan Turing|me#m1|c1|customer|My card was declined|read|-;m2|c1|agent|Looking into it now|read|-;m3|c2|customer|Login loop on mobile|read|-;m9|c1|agent|Refund issued|read|p1")
    (run-effect 1)
    (click (test-id "open-c2"))
    (stub-http "read c2" :url "/api/inbox" :status 200 :body "c1|Card declined|Ada Lovelace|me;c2|Cannot log in|Grace Hopper|sam;c3|Refund status|Alan Turing|me#m1|c1|customer|My card was declined|read|-;m2|c1|agent|Looking into it now|read|-;m3|c2|customer|Login loop on mobile|read|-;m9|c1|agent|Refund issued|read|p1")
    (run-effect 2)

    ; filter meets selection
    ;
    ; Decision: filtering never closes the open thread. The row can leave the list,
    ; the thread pane stays put, and a notice explains the mismatch.

    (change (label "Assigned to me") "mine")
    (expect-text (test-id "filter-state") "Assigned to me")
    (expect-checked (label "Assigned to me") true)
    (expect-visible (role region :name "Conversation c1"))
    (expect-absent (role region :name "Conversation c2"))
    (expect-visible (role region :name "Conversation c3"))
    (expect-text (test-id "filter-notice") "The open conversation is hidden by the current filter.")
    (expect-text (test-id "thread-title") "Cannot log in")
    (expect-text (test-id "body-m3") "Login loop on mobile")
    (change (label "Unread") "unread")
    (expect-text (test-id "filter-state") "Unread")
    (expect-text (test-id "conv-empty") "No conversations to show.")
    (expect-absent (role region :name "Conversation c1"))
    (expect-text (test-id "filter-notice") "The open conversation is hidden by the current filter.")
    (expect-text (test-id "thread-title") "Cannot log in")
    (change (label "All") "all")
    (expect-text (test-id "filter-state") "All")
    (expect-absent (test-id "conv-empty"))
    (expect-text (test-id "filter-notice") "All open conversations are listed.")
    (expect-text (test-id "state-c2") "Open")
  )
)
