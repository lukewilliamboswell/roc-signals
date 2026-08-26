(test "Checkbox real click"
  (steps
    ; Checkbox real-click default-action scenario

    (expect-visible (role heading :name "Checkbox Real Click"))
    (expect-attr (role region :name "Checkbox Real Click") data-fixture "checkbox-real-click")
    (expect-checked (label "Accept terms") false)
    (expect-text (text "Accepted: false") "Accepted: false")
    (expect-text (text "Changes: 0") "Changes: 0")
    (real-click (label "Accept terms"))
    (expect-checked (label "Accept terms") true)
    (expect-text (text "Accepted: true") "Accepted: true")
    (expect-text (text "Changes: 1") "Changes: 1")
    (real-click (label "Accept terms"))
    (expect-checked (label "Accept terms") false)
    (expect-text (text "Accepted: false") "Accepted: false")
    (expect-text (text "Changes: 2") "Changes: 2")
  )
)
