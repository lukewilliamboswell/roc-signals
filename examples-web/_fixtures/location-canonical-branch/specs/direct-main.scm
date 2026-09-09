(test "Location canonical branch"
  (setup
    (initial-location "/services/workers")
  )
  (steps
    (expect-visible (text "Detail branch"))
    (navigate "/")
    (expect-current-location "/")
    (expect-visible (text "Path: /"))
    (expect-visible (text "Overview branch"))
    (expect-absent (text "Detail branch"))
  )
)
