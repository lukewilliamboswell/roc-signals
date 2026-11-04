(test "Package explorer — H. unknown address"
  (setup (manual-effects))
  (steps
    ; Retain search results while navigation changes the visible page.
    (stub-http "initial search" :url "/api/packages/search?q=" :status 200 :body "roc-json|JSON codec for Roc;roc-http|HTTP client for Roc;roc-parser|Parser combinators for Roc")
    (run-effect 1)

    ; H. unknown address

    (navigate "/not/a/package")
    (expect-current-location "/")
    (expect-document-title "Package Explorer")
    (expect-visible (role region :name "Package search"))
    (expect-absent (role region :name "Package detail"))
    (expect-text (test-id "context") "Context: search results (3 matches)")
  )
)
