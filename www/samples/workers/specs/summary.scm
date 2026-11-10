(test "Words — the summary follows the text, keeping the last answer while the next one is computed"
  (steps
    ; Mounting asks for the summary of the first text, and the total of no
    ; numbers: two jobs.
    (expect-pending-effects 2)
    (expect-text (test-id "summary") "Analysing…")
    ; The word count is a derive on the page: it has its answer at once.
    (expect-text (test-id "length") "5 words")
    (run-effect 1)
    (expect-text (test-id "summary") "4 different words; most used: the")
    (fill (label "Text") "a rose is a rose")
    (expect-text (test-id "length") "5 words")
    (expect-text (test-id "summary") "4 different words; most used: the (analysing…)")
    (expect-pending-effects 2)
    ; A newer text stops the job for the older one before its own starts, so
    ; there is still one summary job waiting, besides the total.
    (fill (label "Text") "a rose is a rose is a rose")
    (expect-text (test-id "length") "8 words")
    (expect-pending-effects 2)
    (run-effect 4)
    (expect-text (test-id "summary") "3 different words; most used: a")
    (expect-pending-effects 1)
    ; An equal text asks nothing.
    (fill (label "Text") "a rose is a rose is a rose")
    (expect-pending-effects 1)
    (expect-text (test-id "summary") "3 different words; most used: a")
  )
)
