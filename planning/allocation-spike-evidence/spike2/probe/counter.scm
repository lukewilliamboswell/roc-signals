(test "probe" (steps
 (click (role button :name "Increment"))
 (mark-metrics)
 (click (role button :name "Increment"))
 (mark-metrics)
 (click (role button :name "Increment"))
 (mark-metrics)))
