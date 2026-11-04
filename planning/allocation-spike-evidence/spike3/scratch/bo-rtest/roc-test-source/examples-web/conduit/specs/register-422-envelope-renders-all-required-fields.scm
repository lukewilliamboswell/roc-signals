(test "Conduit — Register: 422 envelope renders all required fields"
  (setup
    (manual-effects)
    (initial-location "/roc-signals/examples-web/conduit/#/register")
  )
  (steps
    ; Register: 422 envelope renders all required fields
    (navigate "/roc-signals/examples-web/conduit/#/register")
    (expect-document-title "Sign up - Conduit")
    (expect-visible (role heading :name "Sign up"))
    (click (role button :name "Sign up"))
    (expect-pending-effects 1)
    (stub-http "register response" :url "/api/users" :status 422 :body "{\"errors\":{\"username\":[\"can't be blank\"],\"email\":[\"can't be blank\"],\"password\":[\"can't be blank\"]}}")
    (run-effect 1)
    (expect-visible (text "username can't be blank"))
    (expect-visible (text "email can't be blank"))
    (expect-visible (text "password can't be blank"))
  )
)
