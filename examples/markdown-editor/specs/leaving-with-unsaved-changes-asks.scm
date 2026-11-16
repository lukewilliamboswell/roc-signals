(test "Markdown editor — leaving with unsaved changes asks"
  (steps
    (fill (label "Markdown source") "# Stay here")
    (leave-page "/away" stay)
    (expect-current-location "/")
    (expect-value (label "Markdown source") "# Stay here")
    (leave-page "/away" leave)
    (expect-current-location "/away")
    (expect-value (label "Markdown source") "# Stay here"))
)
