(test "Support inbox — unread clears when the thread is read"
  (steps
    ; Given the state established by earlier scenarios
    (resolve-task "inbox" "c1|Card declined|Ada Lovelace|me;c2|Cannot log in|Grace Hopper|sam;c3|Refund status|Alan Turing|me#m1|c1|customer|My card was declined|read|-;m2|c1|agent|Looking into it now|read|-;m3|c2|customer|Login loop on mobile|new|-")
    (click (test-id "open-c1"))
    (mark-metrics)
    (click (test-id "open-c3"))
    (resolve-stale-task "inbox" "c9|Stale conversation|Nobody|me#")

    ; unread clears when the thread is read

    (click (test-id "open-c2"))
    (expect-pending-task "inbox" 1)
    (expect-text (test-id "thread-title") "Thread: Cannot log in")
    (expect-text (test-id "body-m3") "customer: Login loop on mobile")
    (expect-text (test-id "mstate-m3") "unread")
    (resolve-task "inbox" "c1|Card declined|Ada Lovelace|me;c2|Cannot log in|Grace Hopper|sam;c3|Refund status|Alan Turing|me#m1|c1|customer|My card was declined|read|-;m2|c1|agent|Looking into it now|read|-;m3|c2|customer|Login loop on mobile|read|-")
    (expect-text (test-id "unread-c2") "no unread")
    (expect-text (test-id "mstate-m3") "delivered")
    (expect-text (test-id "inbox-summary") "3 conversations, 0 unread, 0 sending")
  )
)
