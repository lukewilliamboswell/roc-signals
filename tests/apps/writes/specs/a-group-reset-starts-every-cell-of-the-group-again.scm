(test "Writes — a group's generated reset starts every cell of the group again and wakes their readers, no one else's"
  (steps
    (fill (label "Draft") "hello")
    (click (role button :name "Send"))
    (expect-text (test-id "draft") "draft=hello")
    (expect-text (test-id "sent") "sent=1")
    (expect-text (test-id "log") "log=hello")
    ; The draft's reader and its input's value, and the count's reader.
    (mark-metrics)
    (click (role button :name "Start again"))
    (expect-metric-delta derived_calls_into_roc 3)
    (expect-text (test-id "draft") "draft=")
    (expect-value (label "Draft") "")
    (expect-text (test-id "sent") "sent=0")
    (expect-text (test-id "log") "log=hello")
  ))
