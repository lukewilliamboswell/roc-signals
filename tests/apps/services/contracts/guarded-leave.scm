(test "Accepting a guarded leave mounts a fresh document"
  (setup (initial-location "/#persistence"))
  (steps
    (click (role "button" :name "Guard on"))
    (leave-page "/after-leaving" leave)
    (expect-current-location "/after-leaving")
    (expect-visible (role "button" :name "Start"))))
