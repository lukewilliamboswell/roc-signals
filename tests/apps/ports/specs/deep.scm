(test "Ports — a value nested 512 deep is sent, and one 513 deep is not: a call answers TooDeep and a command is not sent"
  (steps
    (fill (label "Depth") "512")
    (click (role button :name "Nest"))
    (expect-pending-effects 1)
    (answer-port 1 reply "\"512\"")
    (expect-text (test-id "log") "nest:512")
    (click (role button :name "Log nest"))
    (expect-port-sends "test.roc-signals/nest-log" 1)
    (fill (label "Depth") "513")
    (mark-metrics)
    (click (role button :name "Nest"))
    ; Nothing was sent or admitted: the refusal answers at once.
    (expect-pending-effects 0)
    (expect-metric-delta effects_issued 0)
    (expect-metric-delta effects_refused 1)
    (expect-text (test-id "log") "nest:512|nest:too deep")
    (click (role button :name "Log nest"))
    ; The command is not sent; the page reports it instead.
    (expect-port-sends "test.roc-signals/nest-log" 1)
    (expect-pending-effects 0)
    ; The next value within the bound is sent as before.
    (fill (label "Depth") "3")
    (click (role button :name "Nest"))
    (answer-port 2 reply "\"3\"")
    (expect-text (test-id "log") "nest:512|nest:too deep|nest:3")
  )
)
