(test "update every 10th row in 10,000 rows"
  (steps
    (click (role button :name "Create 10,000 rows"))
    (mark-metrics)
    (click (role button :name "Update every 10th row"))
    (expect-text (text "pretty red table 1 !!!") "pretty red table 1 !!!")
    (expect-text (text "pretty red table 11 !!!") "pretty red table 11 !!!")))
