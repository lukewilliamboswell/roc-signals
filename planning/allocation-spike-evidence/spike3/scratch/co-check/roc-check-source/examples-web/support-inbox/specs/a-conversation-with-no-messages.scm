(test "Support inbox — a conversation with no messages"
  (setup (manual-effects))
  (steps
    ; A settled snapshot provides the conversations this scenario needs.
    (stub-http "initial inbox" :url "/api/inbox" :status 200 :body "c1|Card declined|Ada Lovelace|me;c2|Cannot log in|Grace Hopper|sam;c3|Refund status|Alan Turing|me#m1|c1|customer|My card was declined|read|-;m2|c1|agent|Looking into it now|read|-;m3|c2|customer|Login loop on mobile|read|-;m9|c1|agent|Refund issued|read|p1")
    (run-effect 1)

    ; a conversation with no messages

    (click (test-id "open-c3"))
    (expect-pending-effects 1)
    (stub-http "read empty conversation" :url "/api/inbox" :status 200 :body "c1|Card declined|Ada Lovelace|me;c2|Cannot log in|Grace Hopper|sam;c3|Refund status|Alan Turing|me#m1|c1|customer|My card was declined|read|-;m2|c1|agent|Looking into it now|read|-;m3|c2|customer|Login loop on mobile|read|-;m9|c1|agent|Refund issued|read|p1")
    (run-effect 2)
    (expect-text (test-id "thread-title") "Refund status")
    (expect-text (test-id "thread-empty") "No messages yet.")
    (expect-text (test-id "thread-count") "0 messages")
    (expect-absent (role region :name "Message p1"))
    (expect-absent (role region :name "Message m1"))
    (expect-disabled (role button :name "Send message") true)
  )
)
