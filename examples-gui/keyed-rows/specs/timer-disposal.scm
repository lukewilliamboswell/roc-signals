(test "The scope clock stops when its branch is disposed and restarts fresh"
  (steps
    (expect-interval 1000 1)
    (tick-interval 1000)
    (expect-visible (text "Scope clock: 1"))
    ; Disposing the branch that owns the interval must cancel it, not leave a
    ; timer running against a scope that no longer has anywhere to render.
    (click (role button :name "Hide / show rows"))
    (expect-interval 1000 0)
    (tick-interval-if-active 1000)
    (expect-visible (text "Rows disposed"))
    ; The recreated branch owns a new interval, counting from zero rather than
    ; resuming the disposed one.
    (click (role button :name "Hide / show rows"))
    (expect-interval 1000 1)
    (expect-visible (text "Scope clock: 0"))
    (tick-interval 1000)
    (expect-visible (text "Scope clock: 1"))))
