(test "document shortcuts are restored when the newest scope leaves"
  (steps
    (press "F4")
    (expect-text (test-id "key-log") "shell;")
    (click (role button :name "Toggle shortcut scope"))
    (press "F4")
    (expect-text (test-id "key-log") "shell;modal;")
    (mark-metrics)
    (click (role button :name "Toggle shortcut scope"))
    (expect-metric-delta registrations_released 1)
    (press "F4")
    (expect-text (test-id "key-log") "shell;modal;shell;")))
