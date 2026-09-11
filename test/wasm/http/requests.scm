(test "web hosted HTTP returns typed results through action effects"
  (steps
    (stub-http "fetch" :url "https://example.test/value" :status 200 :body "hello λ")
    (click (text "Fetch"))
    (expect-visible (text "hello λ"))
    (stub-http "fetch" :url "https://example.test/value" :status 404 :body "missing")
    (click (text "Fetch"))
    (expect-visible (text "HTTP 404"))
    (stub-http-reject "fetch" :kind timeout :detail "")
    (click (text "Fetch"))
    (expect-visible (text "Timeout"))))
