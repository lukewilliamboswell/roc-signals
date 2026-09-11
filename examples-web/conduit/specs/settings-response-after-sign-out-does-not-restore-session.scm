(test "Conduit — a settings response after sign-out cannot restore the session"
  (setup
    (manual-effects)
    (local-storage "conduit.jwt" "jwt.conduit.kim")
    (local-storage "conduit.username" "kim")
    (initial-location "/roc-signals/examples-web/conduit/#/settings")
  )
  (steps
    (fill (label "Email") "kim@new.test")
    (click (role button :name "Update Settings"))
    (expect-pending-effects 1)
    (click (role button :name "Sign out"))
    (expect-current-location "/roc-signals/examples-web/conduit/#/login")
    (expect-no-local-storage "conduit.jwt")
    (expect-no-local-storage "conduit.username")

    ; Disposal does not cancel the admitted request; its local result is retired.
    (expect-pending-effects 1)
    (stub-http "saved after sign-out" :url "/api/user" :status 200 :body "{\"user\":{\"email\":\"kim@new.test\",\"token\":\"jwt.conduit.kim\",\"username\":\"kim\",\"bio\":\"\",\"image\":\"\"}}")
    (run-effect 1)
    (expect-pending-effects 0)
    (expect-current-location "/roc-signals/examples-web/conduit/#/login")
    (expect-no-local-storage "conduit.jwt")
    (expect-no-local-storage "conduit.username")
    (expect-absent (text "Settings saved."))
    (expect-visible (role heading :name "Sign in"))
  )
)
