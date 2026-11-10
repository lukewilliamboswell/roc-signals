; A round trip back to the shape it started from: the soak (`--soak`)
; repeats the steps after `mark-metrics` and requires them to leave
; nothing allocated. The late branch issues a timer each time it opens;
; closing it cancels the timer, so the cycle needs no answers.
(test "Supersede — round trip: the late branch opened, its nested states written, and closed"
  (steps
    (mark-metrics)
    (click (role button :name "Toggle late"))
    (click (role button :name "Inc derived"))
    (click (role button :name "Toggle inner"))
    (click (role button :name "Inc inner"))
    (click (role button :name "Toggle inner"))
    (click (role button :name "Toggle late"))
    (expect-absent (role button :name "Inc derived"))
  )
)
