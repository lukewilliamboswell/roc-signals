(test "probe" (steps
 (click (role button :name "Update middle row"))
 (mark-metrics)
 (click (role button :name "Update middle row"))
 (mark-metrics)
 (click (role button :name "Update middle row"))
 (mark-metrics)))
