(test "Status page — One service degrades; the rollup follows"
  (steps
    ; Given the state established by earlier scenarios
    (resolve-task "check:api" "operational|99.98")
    (resolve-task "check:web" "operational|99.99")
    (resolve-task "check:database" "operational|99.90")
    (resolve-task "check:notifications" "operational|99.95")
    (resolve-task "incidents" "")

    ; One service degrades; the rollup follows

    (tick-interval 5000)
    (expect-pending-task "check:api" 1)
    (expect-pending-task "check:web" 1)
    (expect-pending-task "incidents" 1)
    (resolve-task "check:api" "degraded|97.40")
    (expect-text (test-id "service-api-status") "Degraded")
    (expect-text (test-id "service-api-uptime") "97.40%")
    (expect-text (test-id "overall-rollup") "Degraded performance")
    (expect-text (test-id "count-operational") "3")
    (expect-text (test-id "count-degraded") "1")
    (expect-text (test-id "count-outage") "0")
    (expect-text (test-id "count-awaiting") "0")
    (expect-text (test-id "service-web-status") "Operational")
    (resolve-task "check:web" "operational|99.99")
    (resolve-task "check:database" "operational|99.90")
    (resolve-task "check:notifications" "operational|99.95")
    (expect-text (test-id "overall-rollup") "Degraded performance")
    (expect-text (test-id "overall-uptime") "99.31%")
  )
)
