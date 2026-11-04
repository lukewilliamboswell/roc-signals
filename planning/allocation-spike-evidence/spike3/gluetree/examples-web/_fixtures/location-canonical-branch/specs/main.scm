(test "Location canonical branch"
  (setup
    (initial-location "/services/workers")
  )
  (steps
    (expect-current-location "/services/workers")
    (expect-visible (text "Detail branch"))
    (navigate "/services/missing")
    (expect-current-location "/")
    (expect-visible (text "Path: /"))
    (expect-visible (text "Overview branch"))
    (expect-absent (text "Detail branch"))
  )
)
