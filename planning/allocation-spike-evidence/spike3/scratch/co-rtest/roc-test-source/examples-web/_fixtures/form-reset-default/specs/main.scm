(test "Form reset default"
  (steps
    ; Form reset default-action scenario

    (expect-visible (role heading :name "Form Reset Default"))
    (expect-attr (role region :name "Form Reset Default") data-fixture "form-reset-default")
    (expect-attr (role form :name "Reset default form") id "reset-default-form")
    (expect-attr (role button :name "Reset form") type "reset")
    (expect-value (label "Name") "")
    (expect-checked (label "Accept reset terms") false)
    (expect-text (text "Reset clicks: 0") "Reset clicks: 0")
    (expect-text (text "Resets: 0") "Resets: 0")
    (fill (label "Name") "Ada")
    (check (label "Accept reset terms"))
    (expect-value (label "Name") "Ada")
    (expect-checked (label "Accept reset terms") true)
    (real-click (role button :name "Reset form"))
    (expect-value (label "Name") "")
    (expect-checked (label "Accept reset terms") false)
    (expect-text (text "Reset clicks: 1") "Reset clicks: 1")
    (expect-text (text "Resets: 1") "Resets: 1")
  )
)
