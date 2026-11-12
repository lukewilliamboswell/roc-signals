(test "a point writes one row, and the row moves when its place changes"
  (steps
    (expect-text (test-id "podium") "Ada Ben Cy ")
    (expect-visible (text "Cy 20"))
    (expect-absent (text "Di 15"))
    ; One point to Cy leaves it third: its text changes and nothing else does.
    (mark-metrics)
    (click (role button :name "Point to Cy"))
    (expect-visible (text "Cy 21"))
    (expect-metric-delta set_text 1)
    (expect-metric-delta rows_moved 0)
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 0)
    (click (role button :name "Point to Cy"))
    (click (role button :name "Point to Cy"))
    (click (role button :name "Point to Cy"))
    (click (role button :name "Point to Cy"))
    (expect-text (test-id "podium") "Ada Ben Cy ")
    ; The sixth takes Cy past Ben. Each view moves the row it already drew:
    ; no row is created or removed in either.
    (mark-metrics)
    (click (role button :name "Point to Cy"))
    (expect-visible (text "Cy 26"))
    (expect-text (test-id "podium") "Ada Cy Ben ")
    (expect-metric-delta rows_moved 2)
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 0)))
