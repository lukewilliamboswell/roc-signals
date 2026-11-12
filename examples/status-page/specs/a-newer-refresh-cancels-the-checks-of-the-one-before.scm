(test "Status page — A newer refresh cancels the checks of the one before"
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

    ; The first timed refresh issues effects 6–10. Before any answers, the
    ; next tick starts another: each check is a `latest` site, so the five
    ; still in flight are cancelled (their fetches aborted) and only the
    ; newest refresh's five wait. No answer to the superseded refresh can
    ; arrive, so nothing in the state has to remember which refresh is
    ; current.
    (tick-interval 5000)
    (expect-pending-effects 5)
    (mark-metrics)
    (tick-interval 5000)
    (expect-metric-delta effects_cancelled 5)
    (expect-pending-effects 5)
    (expect-text (test-id "service-api-status") "Operational")
    (expect-text (test-id "overall-rollup") "All systems operational")

    ; The current refresh's answers (effects 11–15) apply.
    (stub-http "api" :url "/api/status/api" :status 200 :body "outage|10.00")
    (run-effect 11)
    (stub-http "web" :url "/api/status/web" :status 200 :body "operational|99.99")
    (run-effect 12)
    (stub-http "database" :url "/api/status/database" :status 200 :body "operational|99.90")
    (run-effect 13)
    (stub-http "notifications" :url "/api/status/notifications" :status 200 :body "operational|99.95")
    (run-effect 14)
    (stub-http "incidents" :url "/api/status/incidents" :status 200 :body "")
    (run-effect 15)
    (expect-pending-effects 0)
    (expect-text (test-id "service-api-status") "Outage")
    (expect-text (test-id "overall-rollup") "Major outage")
  )
)
