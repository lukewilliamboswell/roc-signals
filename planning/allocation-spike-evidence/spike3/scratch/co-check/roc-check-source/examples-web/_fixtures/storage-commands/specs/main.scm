(test "Storage commands"
  (setup
    (local-storage "checkout:draft" "seeded local")
    (session-storage "checkout:flash" "seeded flash")
  )
  (steps
    (expect-visible (text "Storage Commands"))
    (expect-visible (text "Local draft: mount saved"))
    (expect-visible (text "Session flash: missing"))
    (expect-visible (text "Missing draft: missing"))
    (expect-local-storage "checkout:draft" "mount saved")
    (expect-no-session-storage "checkout:flash")
    (expect-local-storage "checkout:coalesced" "new")
  )
)
