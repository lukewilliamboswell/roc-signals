(test "Support inbox — first snapshot arrives"
  (steps
    ; first snapshot arrives

    (resolve-task "inbox" "c1|Card declined|Ada Lovelace|me;c2|Cannot log in|Grace Hopper|sam;c3|Refund status|Alan Turing|me#m1|c1|customer|My card was declined|read|-;m2|c1|agent|Looking into it now|read|-;m3|c2|customer|Login loop on mobile|new|-")
    (expect-pending-task "inbox" 0)
    (expect-text (test-id "sync-status") "Sync: up to date")
    (expect-text (test-id "inbox-summary") "3 conversations, 1 unread, 0 sending")
    (expect-absent (test-id "conv-empty"))
    (expect-visible (role region :name "Conversation c1"))
    (expect-visible (role region :name "Conversation c2"))
    (expect-visible (role region :name "Conversation c3"))
    (expect-text (test-id "meta-c1") "Ada Lovelace / me")
    (expect-text (test-id "meta-c2") "Grace Hopper / sam")
    (expect-text (test-id "unread-c1") "no unread")
    (expect-text (test-id "unread-c2") "1 unread")
    (expect-text (test-id "unread-c3") "no unread")
    (expect-text (test-id "state-c1") "closed")
    (expect-text (test-id "state-c2") "closed")
    (expect-text (test-id "state-c3") "closed")
    (expect-text (test-id "thread-title") "Thread: no conversation selected")
    (expect-text (test-id "thread-empty") "No messages yet.")
  )
)
