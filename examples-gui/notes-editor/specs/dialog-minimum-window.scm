(scenario "dialog-minimum-window"
  :window "360x600"
  ; The discard dialog is admitted at the narrowest window the host permits, and
  ; Escape dismisses it. Whether it is laid out inside the window is left to the
  ; capture: a dialog is lifted into its own render layer and the bounds probe
  ; records nothing for it, which is a gap in this harness rather than a property
  ; of the dialog.
  (steps
    (type (label "Note text") "hi")
    (wait 400)
    (click (role button :name "New"))
    (wait 400)
    (expect-visible (text "Discard your changes?"))
    (key "escape")
    (wait 400)
    (expect-absent (text "Discard your changes?"))))
