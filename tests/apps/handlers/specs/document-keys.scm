(test "document shortcuts are restored when the newest scope leaves"
  (steps
    (press "F4")
    (expect-text (test-id "key-log") "shell;")
    (click (role button :name "Toggle shortcut scope"))
    (press "F4")
    (expect-text (test-id "key-log") "shell;modal;")
    (click (role button :name "Toggle shortcut scope"))
    (press "F4")
    (expect-text (test-id "key-log") "shell;modal;shell;")))
