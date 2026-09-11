(test "Conduit — an older login success cannot replace a newer rejection"
  (setup
    (manual-effects)
    (initial-location "/roc-signals/examples-web/conduit/#/login")
  )
  (steps
    (fill (label "Email") "kim@conduit.test")
    (fill (label "Password") "secret-kim")
    (click (role button :name "Sign in"))
    (fill (label "Password") "wrong")
    (click (role button :name "Sign in"))
    (expect-pending-effects 2)

    ; The second submission finishes first and owns the displayed result.
    (stub-http "newer rejection" :url "/api/users/login" :status 422 :body "{\"errors\":{\"email or password\":[\"is invalid\"]}}")
    (run-effect 2)
    (expect-visible (text "email or password is invalid"))

    ; The first request still runs, but its success must not log the user in.
    (stub-http "older success" :url "/api/users/login" :status 200 :body "{\"user\":{\"email\":\"kim@conduit.test\",\"token\":\"jwt.conduit.kim\",\"username\":\"kim\",\"bio\":\"\",\"image\":\"\"}}")
    (run-effect 1)
    (expect-pending-effects 0)
    (expect-visible (text "email or password is invalid"))
    (expect-current-location "/roc-signals/examples-web/conduit/#/login")
    (expect-no-local-storage "conduit.jwt")
    (expect-no-local-storage "conduit.username")
  )
)
