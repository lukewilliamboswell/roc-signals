(test "Writes — a cell and a local state written by one event are observed together below a derive of the local state"
  (steps
    (expect-text (test-id "rewarded") "rewarded=0/0")
    ; One click writes the local count and the bonus cell. One pass
    ; settles both, from the root: the cell's reader, then the local
    ; count, which joins the pass at its own site, the derive of it, and
    ; below that the text and the effect site, each evaluated once with
    ; the derived value and the cell both new (4 evaluations). Two texts
    ; (the bonus and the pair), one title and one timer, for the pair that
    ; holds: a text of 0/1, the new cell beside the old derived value, or
    ; a request for it, would be a pair that never held.
    (mark-metrics)
    (click (role button :name "Tap and reward"))
    (expect-metric-delta set_text 2)
    (expect-metric-delta set_metadata 1)
    (expect-metric-delta effects_issued 1)
    (expect-metric-delta derived_calls_into_roc 4)
    (expect-metric-delta dirty_source_roots 2)
    (expect-updates (test-id "rewarded") 2)
    (expect-text (test-id "bonus") "bonus=1")
    (expect-text (test-id "rewarded") "rewarded=2/1")
    (expect-document-title "rewarded 2/1")
    (expect-pending-effects 1)
    (mark-metrics)
    (click (role button :name "Tap and reward"))
    (expect-metric-delta set_text 2)
    (expect-metric-delta set_metadata 1)
    (expect-metric-delta effects_issued 1)
    (expect-metric-delta derived_calls_into_roc 4)
    (expect-updates (test-id "rewarded") 3)
    (expect-text (test-id "rewarded") "rewarded=4/2")
    (expect-document-title "rewarded 4/2")
  ))
