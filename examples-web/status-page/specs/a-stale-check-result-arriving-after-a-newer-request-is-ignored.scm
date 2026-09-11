(test "Status page — A stale check result arriving after a newer request is ignored"
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

    ; A stale check result arriving after a newer request is ignored

    (tick-interval 5000)
    (expect-pending-effects 5)
    (tick-interval 5000)
    (expect-pending-effects 10)
    (mark-metrics)
    (stub-http "api" :url "/api/status/api" :status 200 :body "outage|10.00")
    ; First timed API refresh: its generation has already been superseded.
    (run-effect 6)
    (expect-metric-delta patches_emitted 0)
    (expect-pending-effects 9)
    (expect-text (test-id "service-api-status") "Operational")
    (expect-text (test-id "service-api-uptime") "99.98%")
    (expect-text (test-id "overall-rollup") "All systems operational")
    (stub-http "api" :url "/api/status/api" :status 200 :body "operational|99.98")
    ; Second timed API refresh: this is the current generation.
    (run-effect 11)
    (stub-http "web" :url "/api/status/web" :status 200 :body "operational|99.99")
    (run-effect 12)
    (stub-http "database" :url "/api/status/database" :status 200 :body "operational|99.90")
    (run-effect 13)
    (stub-http "notifications" :url "/api/status/notifications" :status 200 :body "operational|99.95")
    (run-effect 14)
    (stub-http "incidents" :url "/api/status/incidents" :status 200 :body "")
    (run-effect 15)
    (expect-text (test-id "overall-rollup") "All systems operational")
  )
)
