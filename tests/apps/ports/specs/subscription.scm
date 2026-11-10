(test "Ports — a subscription delivers each message as a turn until its site is disposed"
  (steps
    (click (role button :name "Panel"))
    (expect-visible (text "panel open"))
    (expect-port-subscriptions "test.roc-signals/ticks" 1)
    (emit-port "test.roc-signals/ticks" "\"7\"")
    (emit-port "test.roc-signals/ticks" "18446744073709551615")
    (emit-port "test.roc-signals/ticks" "\"seven\"")
    (expect-text (test-id "log") "tick:7|tick:undecodable port \"test.roc-signals/ticks\": number out of range for its type at byte 0|tick:undecodable port \"test.roc-signals/ticks\": expected an integer at byte 0")
    (mark-metrics)
    ; Closing the panel cancels the subscription and keeps the call, which
    ; is still answered.
    (click (role button :name "Panel"))
    (expect-port-subscriptions "test.roc-signals/ticks" 0)
    (expect-metric-delta effects_cancelled 1)
    (expect-metric-delta effects_reparented 1)
    (expect-pending-effects 1)
    (answer-port 1 reply "{\"value\":\"late\"}")
    (expect-text (test-id "log") "tick:7|tick:undecodable port \"test.roc-signals/ticks\": number out of range for its type at byte 0|tick:undecodable port \"test.roc-signals/ticks\": expected an integer at byte 0|panel get:late")
  )
)
