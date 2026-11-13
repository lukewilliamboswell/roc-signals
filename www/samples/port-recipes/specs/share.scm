(test "A dismissed share sheet is a cancellation, not a shared answer"
  (steps
    (click (role button :name "Share"))
    (expect-port-call 1 "example.org/recipes/share" "{\"text\":\"A pure engine and a browser host.\",\"title\":\"Roc Signals\",\"url\":\"https://lukewilliamboswell.github.io/roc-signals/\"}")
    (answer-port 1 reply "\"Cancelled\"")
    (expect-text (test-id "share-result") "Cancelled")
    (click (role button :name "Share"))
    (answer-port 2 reply "\"Shared\"")
    (expect-text (test-id "share-result") "Shared")))
