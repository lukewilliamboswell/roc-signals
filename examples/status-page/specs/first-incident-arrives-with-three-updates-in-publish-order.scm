(test "Status page — First incident arrives, with three updates in publish order"
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

    ; First incident arrives, with three updates in publish order

    (resolve-task "incidents" "inc-42~major~Elevated API error rate~10:02@Investigating elevated 5xx responses^10:20@Identified a bad deploy^10:45@Monitoring after rollback")
    (expect-text (test-id "open-incident-count") "Open incidents: 1")
    (expect-absent (text "No incidents reported"))
    (expect-visible (role region :name "Incident inc-42"))
    (expect-text (test-id "incident-inc-42-severity") "inc-42 severity: Major")
    (expect-text (test-id "incident-inc-42-title") "inc-42 title: Elevated API error rate")
    (expect-text (test-id "incident-inc-42-latest") "inc-42 latest: 10:45 - Monitoring after rollback")
    (expect-visible (role region :name "inc-42#1"))
    (expect-visible (role region :name "inc-42#2"))
    (expect-visible (role region :name "inc-42#3"))
    (expect-text (test-id "update-inc-42#1") "inc-42 update 1 - 10:02 - Investigating elevated 5xx responses")
    (expect-text (test-id "update-inc-42#2") "inc-42 update 2 - 10:20 - Identified a bad deploy")
    (expect-text (test-id "update-inc-42#3") "inc-42 update 3 - 10:45 - Monitoring after rollback")
  )
)
