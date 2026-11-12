(test "Writes — a local state and a cell written by one event are observed together below a derive of the cell"
  (steps
    (expect-text (test-id "paired") "paired=0/0")
    ; One click writes the local count and the score cell. One pass
    ; settles both, from the root: the cell's reader, the derive of the
    ; cell, the local count, which joins the pass at its own site, and
    ; below it the text and the effect site, each evaluated once with
    ; both new values (4 evaluations). Two texts (the score and the pair),
    ; one title and one timer: a text of 1/0 or a request for it would be
    ; a pair that never held. The local count is the second layer on its
    ; path, as the count beside the "Deep" buttons is on its own: that
    ; count's reader, a sibling at the same depth, is not evaluated.
    (mark-metrics)
    (click (role button :name "Tap and score"))
    (expect-metric-delta set_text 2)
    (expect-metric-delta set_metadata 1)
    (expect-metric-delta effects_issued 1)
    (expect-metric-delta derived_calls_into_roc 4)
    (expect-metric-delta dirty_source_roots 2)
    (expect-text (test-id "score") "score=1")
    (expect-text (test-id "paired") "paired=1/2")
    (expect-document-title "paired 1/2")
    (expect-pending-effects 1)
  ))
