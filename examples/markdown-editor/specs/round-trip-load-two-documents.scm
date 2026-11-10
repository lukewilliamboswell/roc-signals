; A round trip back to the document it started from: the soak (`--soak`)
; repeats the steps after `mark-metrics` and requires them to leave
; nothing allocated. (Appending a section and removing it is not an
; exact inverse in this app: each time leaves one more trailing newline.)
(test "Markdown editor — round trip: the heading drill loaded, then the document without headings"
  (steps
    (click (role button :name "Load document without headings"))
    (mark-metrics)
    (click (role button :name "Load heading drill"))
    (click (role button :name "Load document without headings"))
  )
)
