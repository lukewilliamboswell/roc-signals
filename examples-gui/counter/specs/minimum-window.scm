(scenario "minimum-window"
  :window "360x240"
  ; The smallest window the host allows. The reading a person came for and the
  ; actions they take must both still work there; only the *layout* at that size
  ; is a separate, currently-failing diagnostic.
  (steps
    (expect-visible (text "Counter"))
    (click (role button :name "Increment"))
    (wait 150)
    (expect-visible (text "1"))
    (click (role button :name "Reset"))
    (wait 150)
    (expect-visible (text "0"))))
