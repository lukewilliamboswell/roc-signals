(test "a reply's draft starts again when another message is opened"
  (steps
    (expect-text (test-id "to") "Reply to Welcome")
    (fill (label "Reply") "Thanks!")
    (expect-text (test-id "length") "7 bytes")
    ; Opening the same message again changes nothing: the key is equal.
    (click (role button :name "Welcome"))
    (expect-value (label "Reply") "Thanks!")
    ; Another message: the reply is built again, with a draft of its own.
    (mark-metrics)
    (click (role button :name "Invoice"))
    (expect-metric-delta scopes_disposed 1)
    (expect-metric-delta scopes_created 1)
    (expect-text (test-id "to") "Reply to Invoice")
    (expect-value (label "Reply") "")
    (expect-text (test-id "length") "0 bytes")
    ; Going back does not bring the first draft back: it went with its reply.
    (click (role button :name "Welcome"))
    (expect-value (label "Reply") "")))
