; A round trip back to the board it started from: the soak (`--soak`)
; repeats the steps after `mark-metrics` and requires them to leave
; nothing allocated.
(test "Kanban board — round trip: a card added and deleted leaves the board as it was"
  (steps
    (mark-metrics)
    (fill (label "New card title") "Soak card")
    (click (role button :name "Add card"))
    (expect-visible (role button :name "Delete: Soak card"))
    (click (role button :name "Delete: Soak card"))
    (expect-absent (role button :name "Delete: Soak card"))
  )
)
