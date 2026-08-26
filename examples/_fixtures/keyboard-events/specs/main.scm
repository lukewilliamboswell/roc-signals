(test "Keyboard events"
  (steps
    ; Keyboard event coverage. Preserved from the retired command-palette example,
    ; which was the only place Html.on_key_down and Ui.KeyPayload were exercised.

    (expect-visible (role region :name "Keyboard"))
    (expect-text (test-id "last-key") "No key yet")
    (expect-text (test-id "key-count") "Keys seen: 0")
    (key-down (label "Key capture") "K" true)
    (expect-text (test-id "last-key") "Key: K with Shift")
    (expect-text (test-id "key-count") "Keys seen: 1")
    (key-down (label "Key capture") "Enter" false)
    (expect-text (test-id "last-key") "Key: Enter")
    (expect-text (test-id "key-count") "Keys seen: 2")
    (key-down (label "Key capture") "Escape" false)
    (expect-text (test-id "last-key") "Key: Escape")
    (expect-text (test-id "key-count") "Keys seen: 3")
  )
)
