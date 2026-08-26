(test "Availability picker — the headline: one timezone change reprojects every rendered slot"
  (steps
    ; Given the state established by earlier scenarios
    (mark-metrics)
    (click (role button :name "Mark review available"))
    (click (role button :name "Mark review busy"))

    ; the headline: one timezone change reprojects every rendered slot
    ; Auckland is +13:00, so "Late shift" crosses forward over local midnight
    ; (Mon 23:30 UTC becomes Tue 12:30) and "Wednesday focus" lands on Thursday.
    ; No row is created, removed or re-scoped; only text sinks are patched.
    (mark-metrics)
    (select-option (label "Timezone") "auckland")
    (expect-text (test-id "zone-label") "Auckland UTC+13:00")
    (expect-text (test-id "when-sunrise") "Mon 13:00-14:00")
    (expect-text (test-id "when-standup") "Mon 22:00-22:30")
    (expect-text (test-id "when-review") "Mon 22:15-23:15")
    (expect-text (test-id "when-midnight") "Tue 12:30-13:00")
    (expect-text (test-id "when-focus") "Thu 01:00-03:00")
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta rows_reused 5)
    (expect-metric-delta scopes_created 0)
    (expect-metric-delta scopes_disposed 0)
    ; Still exactly seven DOM text writes: the five slot times, the free-day list
    ; and the zone label. The day columns and the per-day "no availability"
    ; markers move by class alone, so re-laying out the whole week costs no extra
    ; text write.
    (expect-metric-delta-at-most set_text 7)
    (expect-metric-delta-at-most patches_emitted 32)
    ; derived work is proportional to the rows on screen (5 rows x 7 sinks: title,
    ; time, status text, status badge class, conflict text, conflict class and the
    ; block's day-column/tint class) plus the zone, row-view, free-day-name and
    ; free-day-text nodes and the seven day-header markers. Still proportional to
    ; what is on screen, not to the size of the graph: the conflict/summary chain
    ; is untouched.
    (expect-metric-delta-at-most derived_calls_into_roc 49)
    ; conflicts and totals compare instants, so the timezone did not touch them
    (expect-text (test-id "conflict-standup") "Clashes with Design review")
    (expect-text (test-id "conflict-review") "Clashes with Standup")
    (expect-text (test-id "summary") "3h 0m")
    (expect-text (test-id "stat-slots") "5")
    (expect-text (test-id "stat-conflicts") "2")
    ; ... but which local day is free does move with the zone
    (expect-text (test-id "free-days") "Tue, Wed, Fri, Sat, Sun")
  )
)
