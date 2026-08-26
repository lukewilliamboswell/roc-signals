(test "On change initial"
  (steps
    ; on_change_initial lifecycle scenario

    (expect-visible (role heading :name "On Change Initial"))
    (expect-visible (text "Initial value: mounted"))
    (expect-visible (text "Regular value: mounted"))
    (expect-visible (text "First hook: mounted"))
    (expect-visible (text "Second hook: mounted"))
    (expect-document-title "initial:mounted")
    (click (role button :name "Change regular"))
    (expect-visible (text "Regular value: updated"))
    (expect-document-title "regular:updated")
    (click (role button :name "Change initial"))
    (expect-visible (text "Initial value: updated"))
    (expect-document-title "initial:updated")
  )
)
