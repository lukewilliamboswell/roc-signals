(test "Onboarding wizard — submitting: pending, supersede, stale, success, failure"
  (setup
    ; Onboarding Wizard
    ;
    ; The app mounts with a part-finished draft in local storage, so the "initial
    ; state" this spec asserts first is the *restored* one: step 4 (Review), with
    ; the organisation step still missing a data region. The empty/initial state is
    ; asserted at the end, after "Start over" clears every handle and removes the
    ; saved draft.

    (local-storage "onboarding:draft" "ana@example.com|Ana Diaz|Northwind|growth|||member|review")
  )
  (steps
    ; Given the state established by earlier scenarios
    (click (role button :name "Go to Organisation"))
    (click (role button :name "Next step"))
    (mark-metrics)
    (fill (label "Organisation name") "Northwind Labs")
    (real-click (label "European Union"))
    (click (role button :name "Next step"))
    (real-click (label "Admin"))
    (fill (label "Invite emails") "bo@example.com, not-an-email")
    (click (role button :name "Next step"))
    (fill (label "Invite emails") "bo@example.com, cy@example.com")
    (click (role button :name "Go to Organisation"))
    (select-option (label "Plan") "starter")
    (click (role button :name "Next step"))
    (click (role button :name "Next step"))

    ; 10. submitting: pending, supersede, stale, success, failure

    (click (role button :name "Create workspace"))
    (expect-pending-task "onboarding-submit" 1)
    (expect-text (test-id "submit-status") "Creating workspace…")
    ; Submitting again supersedes the in-flight request.
    (click (role button :name "Create workspace"))
    (expect-pending-task "onboarding-submit" 1)
    (expect-canceled-task "onboarding-submit" 1)
    (resolve-stale-task "onboarding-submit" "stale-workspace")
    (expect-text (test-id "submit-status") "Creating workspace…")
    (resolve-task "onboarding-submit" "acme-42")
    (expect-text (test-id "submit-status") "Workspace ready: acme-42")
    (click (role button :name "Create workspace"))
    (expect-text (test-id "submit-status") "Creating workspace…")
    (reject-task "onboarding-submit" "region unavailable")
    (expect-text (test-id "submit-status") "Submit failed: region unavailable")
  )
)
