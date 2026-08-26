(test "Support inbox — filter meets selection"
  (steps
    ; Given the state established by earlier scenarios
    (resolve-task "inbox" "c1|Card declined|Ada Lovelace|me;c2|Cannot log in|Grace Hopper|sam;c3|Refund status|Alan Turing|me#m1|c1|customer|My card was declined|read|-;m2|c1|agent|Looking into it now|read|-;m3|c2|customer|Login loop on mobile|new|-")
    (click (test-id "open-c1"))
    (mark-metrics)
    (click (test-id "open-c3"))
    (resolve-stale-task "inbox" "c9|Stale conversation|Nobody|me#")
    (click (test-id "open-c2"))
    (resolve-task "inbox" "c1|Card declined|Ada Lovelace|me;c2|Cannot log in|Grace Hopper|sam;c3|Refund status|Alan Turing|me#m1|c1|customer|My card was declined|read|-;m2|c1|agent|Looking into it now|read|-;m3|c2|customer|Login loop on mobile|read|-")

    ; filter meets selection
    ;
    ; Decision: filtering never closes the open thread. The row can leave the list,
    ; the thread pane stays put, and a notice explains the mismatch.

    (change (label "Assigned to me") "mine")
    (expect-text (test-id "filter-state") "Filter: mine")
    (expect-checked (label "Assigned to me") true)
    (expect-visible (role region :name "Conversation c1"))
    (expect-absent (role region :name "Conversation c2"))
    (expect-visible (role region :name "Conversation c3"))
    (expect-text (test-id "filter-notice") "The open conversation is hidden by the current filter.")
    (expect-text (test-id "thread-title") "Thread: Cannot log in")
    (expect-text (test-id "body-m3") "customer: Login loop on mobile")
    (change (label "Unread") "unread")
    (expect-text (test-id "filter-state") "Filter: unread")
    (expect-text (test-id "conv-empty") "No conversations to show.")
    (expect-absent (role region :name "Conversation c1"))
    (expect-text (test-id "filter-notice") "The open conversation is hidden by the current filter.")
    (expect-text (test-id "thread-title") "Thread: Cannot log in")
    (change (label "All") "all")
    (expect-text (test-id "filter-state") "Filter: all")
    (expect-absent (test-id "conv-empty"))
    (expect-text (test-id "filter-notice") "All open conversations are listed.")
    (expect-text (test-id "state-c2") "open")
  )
)
