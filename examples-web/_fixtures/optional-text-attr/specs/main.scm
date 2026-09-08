(test "Optional text attr"
  (steps
    ; Optional text attr absence scenario

    (expect-visible (role heading :name "Optional Text Attr"))
    (expect-attr (role region :name "Optional Text Attr") data-fixture "optional-text-attr")
    (expect-value (label "Assignee") "")
    (expect-attr (label "Assignee") id "assignee-input")
    (expect-no-attr (label "Assignee") aria-activedescendant)
    (click (role button :name "Open options"))
    (expect-attr (label "Assignee") aria-activedescendant "option-alpha")
    (click (role button :name "Close options"))
    (expect-no-attr (label "Assignee") aria-activedescendant)
  )
)
