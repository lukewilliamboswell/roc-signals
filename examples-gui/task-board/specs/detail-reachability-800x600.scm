(scenario "detail-reachability-800x600"
  :window "800x600"
  ; The columns region yields its width to the fixed detail panel rather than
  ; taking its intrinsic width, so the panel stays on screen at the smaller
  ; supported size and the columns scroll horizontally instead.
  (steps
    (expect-onscreen (test-id "task-detail"))))
