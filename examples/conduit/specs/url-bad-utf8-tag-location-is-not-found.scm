(test "Conduit URL — bad utf8 tag location is not found"
  (setup (initial-location "/roc-signals/examples/conduit/#/?tag=%FF"))
  (steps
    (expect-document-title "Page not found - Conduit")
    (expect-visible (text "This address does not match any conduit page."))
    (expect-pending-effects 0)
  )
)
