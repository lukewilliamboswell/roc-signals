(test "Onboarding wizard — submitting: pending, supersede, stale, success, failure"
  (setup
    (manual-effects)
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
    (expect-pending-effects 1)
    (expect-text (test-id "submit-status") "Creating workspace…")
    ; Both effects remain pending; the newer generation owns the displayed result.
    (click (role button :name "Create workspace"))
    (expect-pending-effects 2)
    (stub-http "submission" :url "/api/onboarding/submit-1" :status 200 :body "stale-workspace")
    (run-effect 1)
    (expect-text (test-id "submit-status") "Creating workspace…")
    (stub-http "submission" :url "/api/onboarding/submit-2" :status 200 :body "acme-42")
    (run-effect 2)
    (expect-text (test-id "submit-status") "Workspace ready: acme-42")
    (click (role button :name "Create workspace"))
    (expect-text (test-id "submit-status") "Creating workspace…")
    (stub-http-reject "submission failure" :kind timeout :detail "")
    (run-effect 3)
    (expect-text (test-id "submit-status") "Submit failed: Timeout")
    ; Reset invalidates the displayed submission without cancelling its effect.
    (click (role button :name "Create workspace"))
    (expect-pending-effects 1)
    (click (role button :name "Start over"))
    (expect-pending-effects 1)
    (expect-text (test-id "progress-label") "Step 1 of 4 — Account")
    (mark-metrics)
    (stub-http "late submission" :url "/api/onboarding/submit-4" :status 200 :body "too-late")
    (run-effect 4)
    (expect-pending-effects 0)
    (expect-metric-delta patches_emitted 0)
    (expect-no-local-storage "onboarding:draft")
    (expect-text (test-id "progress-label") "Step 1 of 4 — Account")
  )
)
