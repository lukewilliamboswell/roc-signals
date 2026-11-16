(test "A guarded navigate must name leave-page"
  (setup (initial-location "/#persistence"))
  (steps
    (click (role "button" :name "Guard on"))
    (navigate "/after-leaving")))
