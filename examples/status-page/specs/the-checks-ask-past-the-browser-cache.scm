(test "Status page — The checks ask past the browser cache"
  (setup (seed 7))
  (steps
    (expect-request 1 :method "GET" :url "/api/status/api" :cache no-store :credentials same-origin)
    (expect-request 5 :url "/api/status/incidents" :cache no-store)
    (click (role button :name "Refresh now"))
    (expect-request 1 :url "/api/status/api" :cache no-store)
  )
)
