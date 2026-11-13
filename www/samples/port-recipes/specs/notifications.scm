(test "Permission is a call; showing a notification is a command"
  (steps
    (click (role button :name "Allow notifications"))
    (expect-port-call 1 "example.org/recipes/notification-permission" "{}")
    (answer-port 1 reply "\"Denied\"")
    (expect-text (test-id "notification-result") "Denied")
    (click (role button :name "Allow notifications"))
    (answer-port 2 reply "\"Granted\"")
    (expect-text (test-id "notification-result") "Granted")
    (click (role button :name "Show notification"))
    (expect-port-sent "example.org/recipes/notification-show" 1 "{\"body\":\"The page asked for this notification.\",\"title\":\"Roc Signals\"}")))
