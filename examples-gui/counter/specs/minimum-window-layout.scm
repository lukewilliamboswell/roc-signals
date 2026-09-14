(scenario "minimum-window-layout"
  :window "360x240"
  ; The value and all controls fit inside the smallest supported window,
  ; including when the host's title bar and insets reserve 48 vertical pixels.
  ; No window-scroll fallback should be needed to reveal a control.
  (steps
    (expect-onscreen (test-id "count"))
    (expect-onscreen (test-id "Increment"))
    (expect-onscreen (test-id "Decrement"))
    (expect-onscreen (test-id "Reset"))))
