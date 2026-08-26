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
    (expect-text (test-id "open-incident-count") "1")
    (expect-absent (text "No incidents reported in the last 90 days."))
    (expect-visible (role region :name "Incident inc-42"))
    (expect-text (test-id "incident-inc-42-severity") "Major")
    (expect-text (test-id "incident-inc-42-title") "Elevated API error rate")
    (expect-text (test-id "incident-inc-42-latest") "10:45 - Monitoring after rollback")
    (expect-visible (role region :name "inc-42#1"))
    (expect-visible (role region :name "inc-42#2"))
    (expect-visible (role region :name "inc-42#3"))
    ; The update row shows the timestamp in its own column beside the body.
    (expect-visible (text "10:02"))
    (expect-text (test-id "update-inc-42#1") "Investigating elevated 5xx responses")
    (expect-text (test-id "update-inc-42#2") "Identified a bad deploy")
    (expect-text (test-id "update-inc-42#3") "Monitoring after rollback")
  )
)
