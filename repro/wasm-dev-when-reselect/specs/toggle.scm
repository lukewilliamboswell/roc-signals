(test "Wasm dev when reselect — toggling back remounts the first branch"
  (steps
    (expect-text (test-id "s") "on")
    (click (role button :name "T"))
    (expect-text (test-id "s") "off")
    (click (role button :name "T"))
    (expect-text (test-id "s") "on")
  )
)
