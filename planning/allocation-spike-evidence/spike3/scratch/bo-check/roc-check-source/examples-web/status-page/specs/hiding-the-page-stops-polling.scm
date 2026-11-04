(test "Status page — Hiding the page stops polling"
  (setup (manual-effects))
  (steps
    ; Establish a healthy board; mount effects 1–5 each answer once.
    (stub-http "api" :url "/api/status/api" :status 200 :body "operational|99.98")
    (run-effect 1)
    (stub-http "web" :url "/api/status/web" :status 200 :body "operational|99.99")
    (run-effect 2)
    (stub-http "database" :url "/api/status/database" :status 200 :body "operational|99.90")
    (run-effect 3)
    (stub-http "notifications" :url "/api/status/notifications" :status 200 :body "operational|99.95")
    (run-effect 4)
    (stub-http "incidents" :url "/api/status/incidents" :status 200 :body "")
    (run-effect 5)

    ; Hiding the page stops polling

    (tick-interval 5000)
    (expect-pending-effects 5)
    ; Hiding stops future ticks; already admitted effects remain queued.
    (set-visibility hidden)
    (expect-text (test-id "refresh-mode") "Auto refresh paused while the page is hidden")
    (expect-interval 5000 0)
    (expect-pending-effects 5)
    (tick-interval-if-active 5000)
    (expect-pending-effects 5)
    (expect-text (test-id "overall-rollup") "All systems operational")
    ; Manual refresh still works while hidden; it is not gated on visibility.
    (click (role button :name "Refresh now"))
    (expect-text (test-id "refresh-count") "Refreshes requested: 1")
    (expect-pending-effects 10)
    ; Manual refresh effects 11–15 answer while the timer remains stopped.
    (stub-http "api" :url "/api/status/api" :status 200 :body "degraded|97.40")
    (run-effect 11)
    (stub-http "web" :url "/api/status/web" :status 200 :body "operational|99.99")
    (run-effect 12)
    (stub-http "database" :url "/api/status/database" :status 200 :body "operational|99.90")
    (run-effect 13)
    (stub-http "notifications" :url "/api/status/notifications" :status 200 :body "operational|99.95")
    (run-effect 14)
    (stub-http "incidents" :url "/api/status/incidents" :status 200 :body "")
    (run-effect 15)
    (expect-text (test-id "overall-rollup") "Degraded performance")
    (expect-interval 5000 0)
  )
)
