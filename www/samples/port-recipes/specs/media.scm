(test "A camera scope follows device state and disposes its subscription"
  (steps
    (click (role button :name "Toggle camera"))
    (expect-port-subscriptions "example.org/recipes/camera" 1)
    (emit-port "example.org/recipes/camera" "\"Starting\"")
    (expect-text (test-id "camera-result") "Starting")
    (emit-port "example.org/recipes/camera" "\"Active\"")
    (expect-text (test-id "camera-result") "Active")
    (click (role button :name "Toggle camera"))
    (expect-port-subscriptions "example.org/recipes/camera" 0)))
