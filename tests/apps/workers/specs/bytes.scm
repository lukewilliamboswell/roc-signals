(test "Workers — a program maps input bytes to output bytes, a slice of its input included"
  (steps
    (fill (label "Rounds") "25")
    (expect-pending-effects 0)
    (click (role button :name "Spin"))
    (click (role button :name "Tail"))
    (click (role button :name "Tail"))
    (expect-pending-effects 3)
    (run-effect 2)
    (run-effect 3)
    (run-effect 1)
    (expect-text (test-id "log") "tail:tail 1|tail:tail 2|spin:spun 25 841")
  )
)
