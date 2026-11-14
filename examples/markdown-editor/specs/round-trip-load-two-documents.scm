; A round trip across two documents, including the draft, save and copy
; channels. The source, saved revision, clipboard status and posted payloads
; return to the same shape; only their small occurrence counts advance.
(test "Markdown editor — round trip: edit, save and copy both documents"
  (steps
    (click (role button :name "Load document without headings"))
    (click (role button :name "Save"))
    (click (role button :name "Copy as markdown"))
    (mark-metrics)
    (click (role button :name "Load heading drill"))
    (click (role button :name "Save"))
    (click (role button :name "Copy as HTML"))
    (click (role button :name "Load document without headings"))
    (click (role button :name "Save"))
    (click (role button :name "Copy as markdown"))
    (expect-text (test-id "document-status") "Saved")
    (expect-text (test-id "copy-status") "Copied")
  )
)
