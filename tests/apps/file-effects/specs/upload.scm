(test "File effects — an upload sends the file, or a range of it, as an HTTP request's body"
  (setup
    (file "a.txt" "text/plain" "abcdef"))
  (steps
    (choose-files (label "Upload") "a.txt")
    (click (role button :name "Send"))
    (expect-text (test-id "sent") "waiting")
    (expect-pending-effects 1)
    (expect-upload 1 "a.txt" 0 6)
    (stub-http "stored" :url "/upload" :status 201 :body "stored")
    (run-effect 1)
    (expect-text (test-id "sent") "sent stored")
    (click (role button :name "Send tail"))
    (expect-upload 2 "a.txt" 3 3)
    (stub-http-reject "down" :kind network :detail "offline")
    (run-effect 2)
    (expect-text (test-id "sent") "send failed Network(\"offline\")")
  )
)
