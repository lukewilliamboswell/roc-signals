(test "Services — setting an unchanged browser fact delivers no turn"
  (steps
    (mark-metrics)
    (set-online online)
    (set-visibility visible)
    (expect-metric-delta effects_delivered 0)
    (expect-metric-delta dirty_source_roots 0)
    (set-online offline)
    (set-visibility hidden)
    (mark-metrics)
    (set-online offline)
    (set-visibility hidden)
    (expect-metric-delta effects_delivered 0)
    (expect-metric-delta dirty_source_roots 0)))
