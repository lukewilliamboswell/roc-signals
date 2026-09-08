(test "Timer self-disposal and restart retain only the current scope"
  (steps
    (expect-visible (text "Ticks: 0"))
    (tick-interval 100)
    (expect-visible (text "Ticks: 1"))
    (tick-interval 100)
    (expect-visible (text "Paused after 2 ticks"))
    (click (role button :name "Restart"))
    (expect-visible (text "Ticks: 0"))
    (expect-absent (text "Paused after 2 ticks"))
    (tick-interval 100)
    (tick-interval 100)
    (expect-visible (text "Paused after 2 ticks"))))
