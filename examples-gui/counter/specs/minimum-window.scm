(scenario "minimum-window"
  :window "360x240"
  ; The smallest window the host allows. The reading a person came for and the
  ; actions they take must both still work there. The companion layout scenario
  ; also checks that every control fits without scrolling.
  (steps
    (expect-visible (text "Counter"))
    (click (role button :name "Increment"))
    (wait 150)
    (expect-visible (text "1"))
    (click (role button :name "Reset"))
    (wait 150)
    (expect-visible (text "0"))))
