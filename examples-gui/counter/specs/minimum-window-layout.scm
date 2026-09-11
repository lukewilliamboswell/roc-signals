(scenario "minimum-window-layout"
  :window "360x240"
  :diagnostic "GUI-35. Where the compositor delegates decorations to the host, the host's own title bar and insets take 48 of the window's 240 pixels, and the button row is laid out below the window."
  :on (client-frame)
  ; The counter's own headline value fits inside the smallest window the host
  ; permits, without relying on the window-scroll fallback to reveal it. This
  ; guards the fix for the fixed 380-pixel panel and the oversized paddings that
  ; put the reading past the bottom and right edges.
  (steps
    (expect-onscreen (test-id "count"))
    (expect-onscreen (test-id "Increment"))
    (expect-onscreen (test-id "Decrement"))
    (expect-onscreen (test-id "Reset"))))
