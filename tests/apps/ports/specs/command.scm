(test "Ports — a command carries its value as JSON and is counted as a port command"
  (steps
    (expect-port-sends "test.roc-signals/log" 0)
    (mark-metrics)
    (click (role button :name "Send"))
    (click (role button :name "Send"))
    (expect-port-sends "test.roc-signals/log" 2)
    (expect-port-sent "test.roc-signals/log" 1 "{\"text\":\"hello 1\"}")
    (expect-port-sent "test.roc-signals/log" 2 "{\"text\":\"hello 2\"}")
    ; A command is not an awaited request: nothing is pending or issued.
    (expect-pending-effects 0)
    (expect-metric-delta effects_issued 0)
  )
)
