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
    (pointer-down (test-id "grip-Draft onboarding copy"))
    (pointer-move (test-id "lane-end-progress"))
    (pointer-up (test-id "lane-end-progress"))
    (pointer-down (test-id "grip-Draft onboarding copy"))
    (pointer-move (role region :name "Design login screen") :at 50 25)
    (pointer-up (role region :name "Design login screen") :at 50 25)
    (expect-text (test-id "card-position-Draft onboarding copy") "1 of 2 in Backlog")
    (expect-text (test-id "drag-status") "Ready to move cards")
  )
)
