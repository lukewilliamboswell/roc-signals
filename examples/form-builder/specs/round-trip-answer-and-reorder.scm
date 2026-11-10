; A round trip back to the form it started from: the soak (`--soak`)
; repeats the steps after `mark-metrics` and requires them to leave
; nothing allocated.
(test "Form Builder — round trip: an answer typed and cleared, and two fields swapped and swapped back"
  (steps
    (mark-metrics)
    (fill (label "Answer f1") "Ada")
    (fill (label "Answer f1") "")
    (click (role button :name "Move up f2"))
    (click (role button :name "Move up f1"))
  )
)
