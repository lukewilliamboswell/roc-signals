(test "Declining a guarded leave keeps the document"
  (setup (initial-location "/#persistence"))
  (steps
    (click (role "button" :name "Guard on"))
    (leave-page "/after-leaving" stay)
    (expect-current-location "/#persistence")
    (expect-visible (role "button" :name "Guard off"))))
