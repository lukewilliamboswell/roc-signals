(test "Support inbox — unread clears when the thread is read"
  (setup (manual-effects))
  (steps
    ; Given the state established by earlier scenarios
    (stub-http "inbox snapshot" :url "/api/inbox" :status 200 :body "c1|Card declined|Ada Lovelace|me;c2|Cannot log in|Grace Hopper|sam;c3|Refund status|Alan Turing|me#m1|c1|customer|My card was declined|read|-;m2|c1|agent|Looking into it now|read|-;m3|c2|customer|Login loop on mobile|new|-")
    (run-effect 1)
    ; unread clears when the thread is read

    (click (test-id "open-c2"))
    (expect-pending-effects 1)
    (expect-text (test-id "thread-title") "Cannot log in")
    (expect-text (test-id "body-m3") "Login loop on mobile")
    (expect-text (test-id "mstate-m3") "unread")
    (stub-http "inbox snapshot" :url "/api/inbox" :status 200 :body "c1|Card declined|Ada Lovelace|me;c2|Cannot log in|Grace Hopper|sam;c3|Refund status|Alan Turing|me#m1|c1|customer|My card was declined|read|-;m2|c1|agent|Looking into it now|read|-;m3|c2|customer|Login loop on mobile|read|-")
    (run-effect 2)
    (expect-text (test-id "unread-c2") "No unread")
    (expect-text (test-id "mstate-m3") "delivered")
    (expect-text (test-id "summary-conversations") "3")
    (expect-text (test-id "summary-unread") "0")
    (expect-text (test-id "summary-sending") "0")
  )
)
