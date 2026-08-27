(test "Support inbox — selecting a conversation"
  (steps
    ; Given the state established by earlier scenarios
    (resolve-task "inbox" "c1|Card declined|Ada Lovelace|me;c2|Cannot log in|Grace Hopper|sam;c3|Refund status|Alan Turing|me#m1|c1|customer|My card was declined|read|-;m2|c1|agent|Looking into it now|read|-;m3|c2|customer|Login loop on mobile|new|-")

    ; selecting a conversation

    (click (test-id "open-c1"))
    (expect-text (test-id "state-c1") "Open")
    (expect-text (test-id "state-c2") "Closed")
    (expect-text (test-id "thread-title") "Card declined")
    (expect-absent (test-id "thread-empty"))
    (expect-visible (role region :name "Message m1"))
    (expect-visible (role region :name "Message m2"))
    (expect-text (test-id "body-m1") "My card was declined")
    (expect-text (test-id "body-m2") "Looking into it now")
    (expect-text (test-id "mstate-m1") "delivered")
    (expect-pending-task "inbox" 1)
  )
)
