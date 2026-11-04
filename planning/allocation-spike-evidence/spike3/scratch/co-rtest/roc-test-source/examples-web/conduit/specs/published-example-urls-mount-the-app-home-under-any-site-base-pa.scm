(test "Conduit — Published example URLs mount the app home under any site base path"
  (setup
    (manual-effects)
    (initial-location "/roc-signals/examples-web/conduit/#/login")
  )
  (steps
    ; Published example URLs mount the app home under any site base path
    (navigate "/roc-signals/examples-web/conduit/")
    (expect-current-location "/roc-signals/examples-web/conduit/")
    (expect-document-title "Conduit")
    (expect-visible (text "A place to share your knowledge."))
  )
)
