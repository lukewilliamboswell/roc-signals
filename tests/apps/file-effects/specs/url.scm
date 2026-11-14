(test "File effects — a URL shows the file the app holds, and goes when the app gives it up"
  (setup
    (file "a.txt" "text/plain" "abc"))
  (steps
    (choose-files (label "Upload") "a.txt")
    (click (role button :name "Show"))
    (expect-text (test-id "shown") "waiting")
    (expect-pending-effects 1)
    (run-effect 1)
    (expect-text (test-id "shown") "shown")
    (expect-has-attr (test-id "preview") "title")
    (expect-has-attr (test-id "preview") "href")
    (click (role button :name "Hide"))
    (expect-text (test-id "shown") "idle")
    (expect-no-attr (test-id "preview") "href")
    (click (role button :name "Clear"))
    (expect-files 0)
  )
)
