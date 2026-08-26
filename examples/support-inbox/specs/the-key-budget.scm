(test "Support inbox — the key budget"
  (steps
    ; Given the state established by earlier scenarios
    (resolve-task "inbox" "c1|Card declined|Ada Lovelace|me;c2|Cannot log in|Grace Hopper|sam;c3|Refund status|Alan Turing|me#m1|c1|customer|My card was declined|read|-;m2|c1|agent|Looking into it now|read|-;m3|c2|customer|Login loop on mobile|new|-")
    (click (test-id "open-c1"))
    (mark-metrics)
    (click (test-id "open-c3"))
    (resolve-stale-task "inbox" "c9|Stale conversation|Nobody|me#")
    (click (test-id "open-c2"))
    (resolve-task "inbox" "c1|Card declined|Ada Lovelace|me;c2|Cannot log in|Grace Hopper|sam;c3|Refund status|Alan Turing|me#m1|c1|customer|My card was declined|read|-;m2|c1|agent|Looking into it now|read|-;m3|c2|customer|Login loop on mobile|read|-")
    (change (label "Assigned to me") "mine")
    (change (label "Unread") "unread")
    (change (label "All") "all")
    (click (test-id "open-c1"))
    (resolve-task "inbox" "c1|Card declined|Ada Lovelace|me;c2|Cannot log in|Grace Hopper|sam;c3|Refund status|Alan Turing|me#m1|c1|customer|My card was declined|read|-;m2|c1|agent|Looking into it now|read|-;m3|c2|customer|Login loop on mobile|read|-")
    (fill (label "Message") "Refund issued")
    (mark-metrics)
    (click (role button :name "Send message"))
    (tick-interval 4000)
    (mark-metrics)
    (resolve-task "inbox" "c1|Card declined|Ada Lovelace|me;c2|Cannot log in|Grace Hopper|sam;c3|Refund status|Alan Turing|me#m1|c1|customer|My card was declined|read|-;m2|c1|agent|Looking into it now|read|-;m3|c2|customer|Login loop on mobile|read|-")
    (resolve-task "send" "p1")
    (click (test-id "open-c3"))
    (resolve-task "inbox" "c1|Card declined|Ada Lovelace|me;c2|Cannot log in|Grace Hopper|sam;c3|Refund status|Alan Turing|me#m1|c1|customer|My card was declined|read|-;m2|c1|agent|Looking into it now|read|-;m3|c2|customer|Login loop on mobile|read|-;m9|c1|agent|Refund issued|read|p1")
    (click (test-id "open-c1"))
    (resolve-task "inbox" "c1|Card declined|Ada Lovelace|me;c2|Cannot log in|Grace Hopper|sam;c3|Refund status|Alan Turing|me#m1|c1|customer|My card was declined|read|-;m2|c1|agent|Looking into it now|read|-;m3|c2|customer|Login loop on mobile|read|-;m9|c1|agent|Refund issued|read|p1")
    (fill (label "Message") "Second reply")
    (mark-metrics)
    (click (role button :name "Send message"))
    (mark-metrics)
    (reject-task "send" "p2")
    (click (role button :name "Discard failed message"))

    ; the key budget
    ;
    ; A poll adds a message to c2, which is NOT the open conversation. Its unread
    ; count must rise while the open thread is left completely alone: no thread row
    ; is created, removed, or even re-rendered.

    (expect-text (test-id "state-c1") "Open")
    (expect-text (test-id "unread-c2") "No unread")
    (mark-metrics)
    (tick-interval 4000)
    (resolve-task "inbox" "c1|Card declined|Ada Lovelace|me;c2|Cannot log in|Grace Hopper|sam;c3|Refund status|Alan Turing|me#m1|c1|customer|My card was declined|read|-;m2|c1|agent|Looking into it now|read|-;m3|c2|customer|Login loop on mobile|read|-;m9|c1|agent|Refund issued|read|p1;m10|c2|customer|Still broken|new|-")
    (expect-text (test-id "unread-c2") "1 unread")
    (expect-text (test-id "inbox-summary") "Conversations3Unread1Sending0")
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta rows_reused 3)
    (expect-metric-delta scopes_created 0)
    (expect-metric-delta scopes_disposed 0)
    (expect-metric-delta-at-most patches_emitted 6)
    (expect-metric-delta-at-most dirty_source_roots 4)
    (expect-text (test-id "body-m1") "My card was declined")
    (expect-text (test-id "body-p1") "Refund issued")
    (expect-absent (role region :name "Message m10"))
    ; Sibling isolation, measured: the open thread's first message and the two
    ; untouched conversation rows have each had their text written exactly once
    ; since they were mounted; only c2's unread counter was written a second time.
    (expect-updates (test-id "body-m1") 1)
    (expect-updates (test-id "unread-c1") 1)
    (expect-updates (test-id "unread-c3") 1)
    (expect-updates (test-id "unread-c2") 2)
  )
)
