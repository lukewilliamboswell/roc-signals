(test "Form builder — an option typed twice is offered once"
  (steps
    (click (role button :name "Add select field"))
    (click (role button :name "Settings f3"))
    ; The preview's select keys its options by their text: an option typed
    ; twice is one choice, offered once, and the field stays answerable.
    (fill (label "Options f3") "Small, Large, Small")
    (expect-text (test-id "preview-f3-verdict") "Valid")
    (click (role button :name "Done f3"))
    (expect-text (label "Answer f3") "Choose...SmallLarge")
    (select-option (label "Answer f3") "Small")
    (expect-value (label "Answer f3") "Small")
    (expect-text (test-id "preview-f3-verdict") "Valid")
  )
)
