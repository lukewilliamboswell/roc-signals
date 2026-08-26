(test "Metric semantics"
  (steps
    ; Documents what dirty_source_roots actually counts.
    ;
    ; One click dirties one source root and evaluates six derived transforms
    ; (four chain steps, the display map, and the always-equal constant).
    ; dirty_source_roots reports roots; derived_calls_into_roc reports derived
    ; evaluations; propagation_prunes reports the equality cutoff that fired.

    (expect-text (test-id "chain") "Chain: 4")
    (expect-text (test-id "constant") "Constant: unchanged")
    (mark-metrics)
    (click (role button :name "Bump"))
    (expect-text (test-id "chain") "Chain: 5")
    (expect-metric-delta dirty_source_roots 1)
    (expect-metric-delta derived_calls_into_roc 6)
    (expect-metric-delta propagation_prunes 1)
    (expect-metric-delta patches_emitted 1)
  )
)
