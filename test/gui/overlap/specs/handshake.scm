(test "Mount effects decode the stubbed handshake in queue order"
  (setup
    (stub-file-write "first" :path "/tmp/roc-signals-overlap-fixture.txt" :bytes 9)
    (stub-file-read "first" :path "/tmp/roc-signals-overlap-fixture.txt" :text "ready-0")
    (stub-file-read "second" :path "/tmp/roc-signals-overlap-fixture.txt" :text "waiting-0")
    (stub-file-write "second" :path "/tmp/roc-signals-overlap-fixture.txt" :bytes 7))
  (steps
    (expect-text (text "Both effects overlapped") "Both effects overlapped")))
