; A round trip back to the grid it started from: the soak (`--soak`)
; repeats the steps after `mark-metrics` and requires them to leave
; nothing allocated.
(test "Data grid — round trip: a filter typed and cleared, and a page forward and back"
  (steps
    (mark-metrics)
    (fill (label "Filter") "Node-0007")
    (fill (label "Filter") "")
    (click (role button :name "Next page"))
    (click (role button :name "Previous page"))
  )
)
