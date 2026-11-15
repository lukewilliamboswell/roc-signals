(test "Markdown editor — a heading whose slug another heading took gets the next free one"
  (steps
    ; The outline draws its rows keyed by slug. "A 2" slugs to a-2, which the
    ; second "A" already took, so it takes a-2-2 and every row keeps a key.
    (fill (label "Markdown source") "# A\n\n# A\n\n# A 2")
    (expect-text (test-id "stat-headings") "3")
    (expect-attr (test-id "toc:a") href "#a")
    (expect-attr (test-id "toc:a-2") href "#a-2")
    (expect-attr (test-id "toc:a-2-2") href "#a-2-2")
  )
)
