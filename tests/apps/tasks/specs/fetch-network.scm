(test "Tasks — a download that cannot reach the server fails as a request does"
  (steps
    (click (role button :name "Fetch"))
    (stub-http-reject "offline" :kind network :detail "TypeError: Failed to fetch")
    (run-effect 1)
    (expect-text (test-id "outcome") "fetch failed Network(\"TypeError: Failed to fetch\")")
    (expect-files 0)
  )
)
