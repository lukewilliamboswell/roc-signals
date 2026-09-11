(test "Mount effects decode the stubbed handshake in queue order"
  (setup
    (stub-file-read "first" :path "/tmp/roc-signals-overlap-fixture.txt" :text "ready-0")
    (stub-file-read "second" :path "/tmp/roc-signals-overlap-fixture.txt" :text "waiting-0"))
  (steps
    (expect-text (text "Both effects overlapped") "Both effects overlapped")))
