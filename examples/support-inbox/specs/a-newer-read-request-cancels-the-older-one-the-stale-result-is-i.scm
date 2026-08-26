(test "Support inbox — a newer read request cancels the older one; the stale result is ignored"
  (steps
    ; Given the state established by earlier scenarios
    (resolve-task "inbox" "c1|Card declined|Ada Lovelace|me;c2|Cannot log in|Grace Hopper|sam;c3|Refund status|Alan Turing|me#m1|c1|customer|My card was declined|read|-;m2|c1|agent|Looking into it now|read|-;m3|c2|customer|Login loop on mobile|new|-")
    (click (test-id "open-c1"))

    ; a newer read request cancels the older one; the stale result is ignored

    (mark-metrics)
    (click (test-id "open-c3"))
    (expect-canceled-task "inbox" 1)
    (expect-pending-task "inbox" 1)
    (expect-text (test-id "thread-title") "Refund status")
    (expect-text (test-id "thread-empty") "No messages yet.")
    (expect-absent (test-id "msg-m1"))
    (resolve-stale-task "inbox" "c9|Stale conversation|Nobody|me#")
    (expect-metric-delta stale_task_results_ignored 1)
    (expect-text (test-id "inbox-summary") "Conversations3Unread1Sending0")
    (expect-visible (role region :name "Conversation c1"))
    (expect-absent (role region :name "Conversation c9"))
  )
)
