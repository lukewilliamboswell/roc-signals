(scenario "dialog-smallest-window"
  :window "360x240"
  ; The host permits a 360x240 window, so a dialog has to work there too — this is
  ; the size at which an unbounded dialog is worst. The scenario deliberately ends
  ; with the dialog open so the captured frame is evidence of where it was laid
  ; out; Escape is covered at 360x600.
  (steps
    (type (label "Note text") "hi")
    (wait 400)
    (click (role button :name "New"))
    (wait 400)
    (expect-visible (text "Discard your changes?"))))
