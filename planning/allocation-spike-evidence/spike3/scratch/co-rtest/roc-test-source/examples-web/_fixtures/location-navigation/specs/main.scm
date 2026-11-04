(test "Location navigation"
  (setup
    (initial-location "/")
  )
  (steps
    (expect-visible (text "Location Navigation"))
    (expect-visible (text "Path: /services/web"))
    (expect-visible (text "Query: tab=deploys"))
    (expect-visible (text "Hash: events"))
    (expect-current-location "/services/web?tab=deploys#events")
  )
)
