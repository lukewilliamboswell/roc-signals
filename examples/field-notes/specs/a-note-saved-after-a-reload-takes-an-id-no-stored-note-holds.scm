(test "Field notes — a note saved after a reload takes an id no stored note holds"
  (setup
    ; The storage an earlier session left: a restored note and a note that
    ; session captured, which keeps its session id ("s1"). Session ids are
    ; numbered from one in every session, so this one must pass over "s1".

    (initial-online offline)
    (local-storage "field-notes:notes" "n0|0|1|r7|Generator hours;s1|1|0|r0|Pump pressure log")
  )
  (steps
    (expect-visible (role region :name "Note s1"))
    (expect-value (label "Body s1") "Pump pressure log")

    ; The first note saved is "s2": two rows keyed "s1" would be a
    ; duplicate key, which is a contract error.
    (fill (label "Note body") "Tank level 42")
    (click (role button :name "Save note"))
    (expect-visible (role region :name "Note s2"))
    (expect-value (label "Body s1") "Pump pressure log")
    (expect-value (label "Body s2") "Tank level 42")
    (expect-text (test-id "status-s2") "Draft")

    ; The next follows it.
    (fill (label "Note body") "Radio check")
    (click (role button :name "Save note"))
    (expect-visible (role region :name "Note s3"))
    (expect-text (test-id "capacity") "Full")
    (expect-local-storage "field-notes:notes" "n0|0|1|r7|Generator hours;s1|1|0|r0|Pump pressure log;s2|2|0|r0|Tank level 42;s3|3|0|r0|Radio check")
  )
)
