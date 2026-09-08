(test "Kanban board — cross column move"
  (steps
    ; cross column move
    (mark-metrics)
    (click (role button :name "Move right: Draft onboarding copy"))
    ; Only the moved card is recreated. The sibling left behind in Backlog and the
    ; sibling already in In Progress are both reused.
    (expect-metric-delta rows_created 1)
    (expect-metric-delta rows_removed 1)
    (expect-metric-delta rows_reused 2)
    (expect-text (test-id "count-backlog") "1 card")
    (expect-text (test-id "count-progress") "2 cards")
    (expect-text (test-id "card-position-Design login screen") "1 of 1 in Backlog")
    (expect-text (test-id "card-position-Ship search filters") "1 of 2 in In Progress")
    (expect-text (test-id "card-position-Draft onboarding copy") "2 of 2 in In Progress")
    (expect-text (test-id "wip-backlog") "WIP 1/1")
    (expect-text (test-id "wip-progress") "Over 2/1")
    (expect-attr (role region :name "Backlog") data-wip "ok")
    (expect-attr (role region :name "In Progress") data-wip "over")
    (expect-text (test-id "board-over") "1")
    (expect-text (test-id "board-total") "5")
    (expect-disabled (role button :name "Move left: Draft onboarding copy") false)
    (expect-disabled (role button :name "Move up: Draft onboarding copy") false)
    (expect-disabled (role button :name "Move down: Draft onboarding copy") true)
    (expect-disabled (role button :name "Move up: Design login screen") true)
    (expect-disabled (role button :name "Move down: Design login screen") true)
  )
)
