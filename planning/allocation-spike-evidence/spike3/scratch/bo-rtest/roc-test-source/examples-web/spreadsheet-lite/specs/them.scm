(test "Spreadsheet lite — them"
  (steps
    ; Given the state established by earlier scenarios
    (focus (label "D2"))
    (fill (label "Formula") "=B2+C2+100")
    (fill (label "Formula") "=B2+C2")
    (blur (label "D2"))
    (focus (label "D5"))
    (blur (label "D5"))
    (focus (label "F5"))
    (blur (label "F5"))

    ; them

    (focus (label "B2"))
    (mark-metrics)
    (fill (label "B2") "1500")
  )
)
