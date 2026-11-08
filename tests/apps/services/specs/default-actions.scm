(test "Services — clicks take the browser's default actions unless prevented"
  (steps
    ; A link with no handler navigates within the document.
    (click (role link :name "Jump"))
    (expect-current-location "/#jump")
    ; A link whose handler prevents the default stays put.
    (click (role link :name "Stay"))
    (expect-text (test-id "prevented") "1")
    (expect-current-location "/#jump")
    (history-back)
    (expect-current-location "/")
    ; An invalid email blocks the form's submission by its button.
    (fill (label "Email") "not-an-address")
    (real-click (role button :name "Place order"))
    (expect-text (test-id "submitted") "0")
    (submit (role form :name "Order"))
    (expect-text (test-id "submitted") "0")
    (fill (label "Email") "ada@example.test")
    (real-click (role button :name "Place order"))
    (expect-text (test-id "submitted") "1")
  )
)
