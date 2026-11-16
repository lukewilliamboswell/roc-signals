(test "A guarded link must name leave-page"
  (setup (initial-location "/#persistence"))
  (steps
    (click (role "button" :name "Guard on"))
    (click (role "link" :name "Leave link"))))
