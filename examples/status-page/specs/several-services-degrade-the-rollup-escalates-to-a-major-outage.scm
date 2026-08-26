(test "Status page — Several services degrade: the rollup escalates to a major outage"
  (steps
    ; Given the state established by earlier scenarios
    (resolve-task "check:api" "operational|99.98")
    (resolve-task "check:web" "operational|99.99")
    (resolve-task "check:database" "operational|99.90")
    (resolve-task "check:notifications" "operational|99.95")
    (resolve-task "incidents" "")
    (tick-interval 5000)
    (resolve-task "check:api" "degraded|97.40")
    (resolve-task "check:web" "operational|99.99")
    (resolve-task "check:database" "operational|99.90")
    (resolve-task "check:notifications" "operational|99.95")
    (resolve-task "incidents" "inc-42~major~Elevated API error rate~10:02@Investigating elevated 5xx responses^10:20@Identified a bad deploy^10:45@Monitoring after rollback")

    ; Several services degrade: the rollup escalates to a major outage

    (tick-interval 5000)
    (resolve-task "check:api" "degraded|97.40")
    (resolve-task "check:web" "degraded|98.10")
    (expect-text (test-id "overall-rollup") "Degraded performance")
    (resolve-task "check:database" "degraded|96.00")
    (expect-text (test-id "overall-rollup") "Major outage")
    (expect-text (test-id "count-operational") "1")
    (expect-text (test-id "count-degraded") "3")
    (expect-text (test-id "count-outage") "0")
    (expect-text (test-id "count-awaiting") "0")
    (resolve-task "check:notifications" "operational|99.95")
    (expect-text (test-id "overall-rollup") "Major outage")
    (expect-text (test-id "overall-uptime") "97.86%")
    ; Adding a second incident creates its incident row plus its single update row.
    ; The untouched incident is reused and its three update rows are never revisited.
    (mark-metrics)
    (resolve-task "incidents" "inc-42~major~Elevated API error rate~10:02@Investigating elevated 5xx responses^10:20@Identified a bad deploy^10:45@Monitoring after rollback#inc-51~minor~Delayed notification delivery~11:10@Investigating a backlog")
    (expect-metric-delta rows_created 2)
    (expect-metric-delta rows_reused 1)
    (expect-metric-delta rows_removed 0)
    (expect-text (test-id "open-incident-count") "2")
    (expect-visible (role region :name "Incident inc-51"))
    (expect-text (test-id "incident-inc-51-severity") "Minor")
    (expect-text (test-id "incident-inc-51-latest") "11:10 - Investigating a backlog")
  )
)
