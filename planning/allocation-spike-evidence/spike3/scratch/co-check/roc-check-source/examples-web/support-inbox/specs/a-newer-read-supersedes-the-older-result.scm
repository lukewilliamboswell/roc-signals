(test "Support inbox — a newer read request supersedes the older result"
  (setup (manual-effects))
  (steps
    ; Given the state established by earlier scenarios
    (stub-http "inbox snapshot" :url "/api/inbox" :status 200 :body "c1|Card declined|Ada Lovelace|me;c2|Cannot log in|Grace Hopper|sam;c3|Refund status|Alan Turing|me#m1|c1|customer|My card was declined|read|-;m2|c1|agent|Looking into it now|read|-;m3|c2|customer|Login loop on mobile|new|-")
    (run-effect 1)
    (click (test-id "open-c1"))

    ; a newer read request supersedes the older result

    (mark-metrics)
    (click (test-id "open-c3"))
    (expect-pending-effects 2)
    (expect-text (test-id "thread-title") "Refund status")
    (expect-text (test-id "thread-empty") "No messages yet.")
    (expect-absent (test-id "msg-m1"))
    (stub-http "older read response" :url "/api/inbox" :status 200 :body "c9|Stale conversation|Nobody|me#")
    (mark-metrics)
    (run-effect 2)
    (expect-pending-effects 1)
    (expect-metric-delta patches_emitted 0)
    (expect-text (test-id "summary-conversations") "3")
    (expect-text (test-id "summary-unread") "1")
    (expect-text (test-id "summary-sending") "0")
    (expect-visible (role region :name "Conversation c1"))
    (expect-absent (role region :name "Conversation c9"))
  )
)
