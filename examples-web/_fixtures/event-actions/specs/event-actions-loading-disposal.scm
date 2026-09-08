(test "Loading disposes its own action scope and cancels the accepted request"
  (steps
    (expect-text (test-id "dispose-status") "idle")
    (expect-absent (role button :name "Dispose on loading"))
    (click (role button :name "Prime disposal"))
    (expect-pending-task "action-dispose" 1)
    (resolve-task "action-dispose" "ready")
    (expect-text (test-id "dispose-status") "ready")
    (click (role button :name "Dispose on loading"))
    (expect-text (test-id "dispose-status") "idle")
    (expect-absent (role button :name "Dispose on loading"))
    (expect-pending-task "action-dispose" 0)
    (expect-canceled-task "action-dispose" 1)

    ; A new occurrence outside the disposed scope remains usable. It is not
    ; suppressed by equal inputs or confused with the retired request.
    (click (role button :name "Prime disposal"))
    (expect-pending-task "action-dispose" 1)
    (resolve-task "action-dispose" "ready")
    (click (role button :name "Dispose on loading"))
    (expect-text (test-id "dispose-status") "idle")
    (expect-pending-task "action-dispose" 0)
    (expect-canceled-task "action-dispose" 2)
  )
)
