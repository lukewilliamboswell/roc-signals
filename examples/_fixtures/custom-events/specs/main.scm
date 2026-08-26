(test "Custom events"
  (steps
    ; Custom DOM event coverage. Preserved from the retired service-ops-center
    ; example, which was the only place Html.on_custom and State.on_detail were
    ; exercised.

    (expect-visible (role region :name "Custom Events"))
    (expect-text (test-id "hover") "Hover: none")
    (expect-text (test-id "selected") "Selected: none")
    (custom-event (test-id "chart") "chart-hover" "-2m | 1,490 rpm")
    (expect-text (test-id "hover") "Hover: -2m | 1,490 rpm")
    (expect-text (test-id "selected") "Selected: none")
    (custom-event (test-id "chart") "chart-select" "now | 1,558 rpm")
    (expect-text (test-id "selected") "Selected: now | 1,558 rpm")
    (expect-text (test-id "hover") "Hover: -2m | 1,490 rpm")
    ; An empty detail clears the value rather than being ignored.
    (custom-event (test-id "chart") "chart-hover" "")
    (expect-text (test-id "hover") "Hover: none")
    (expect-text (test-id "selected") "Selected: now | 1,558 rpm")
  )
)
