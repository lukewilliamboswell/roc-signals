(test "HTTP effect to utf8 lifetime"
  (setup (manual-effects))
  (steps
    ; HTTP text effects own decoded UTF-8 beyond the response lifetime.

    (expect-visible (role heading :name "Effect UTF-8 lifetime"))
    (expect-visible (text "loading"))
    (expect-pending-effects 1)
    (stub-http "UTF-8 body" :url "/api/ops/dashboard" :status 200 :body "Roc task body with UTF-8 payload: café 🚀 stays owned")
    (run-effect 1)
    (expect-pending-effects 0)
    (expect-visible (text "ready bytes 56"))
    ; A later input reads the retained string after the HTTP effect has returned.
    (click (role button :name "Measure retained body"))
    (expect-visible (text "retained bytes 56"))
  )
)
