(test "GUI row drafts survive moves and reset on disposal"
  (steps
    (fill (label "Draft Alpha") "kept draft")
    (expect-value (label "Draft Alpha") "kept draft")
    (click (role button :name "Move first to end"))
    (expect-value (label "Draft Alpha") "kept draft")
    (click (role button :name "Hide / show rows"))
    (expect-visible (text "Rows disposed"))
    (click (role button :name "Hide / show rows"))
    (expect-value (label "Draft Alpha") "")))
