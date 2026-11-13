(test "A disposed guard leaves without a question"
  (setup (initial-location "/#persistence"))
  (steps
    (click (role "button" :name "Guard on"))
    (click (role "button" :name "Dispose guard"))
    (leave-page "/after-leaving" unasked)
    (expect-current-location "/after-leaving")))
