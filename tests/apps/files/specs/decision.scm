(test "Files — a file event is a decision: one drop writes several cells, with a reading, and local state with them"
  (setup
    (file "a.txt" "text/plain" "a")
    (file "b.txt" "text/plain" "bb"))
  (steps
    (expect-text (test-id "inbox") "none")
    (expect-text (test-id "note") "nothing arrived")
    ; One drop, one decision: the inbox and the note are two cells written
    ; as one event, and each has one reader.
    (mark-metrics)
    (drop-files (label "Inbox") "a.txt" "b.txt")
    (expect-text (test-id "inbox") "a.txt:1:text/plain|b.txt:2:text/plain")
    (expect-text (test-id "note") "2 arrived, 0 refused")
    (expect-metric-delta dirty_source_roots 2)
    (expect-metric-delta derived_calls_into_roc 2)
    (expect-metric-delta set_text 2)
    (expect-files 2)
    ; A decision with a reading: how many files the inbox held when the
    ; drop arrived, read before the decision's own writes.
    (drop-files (label "Inbox with a reading") "a.txt")
    (expect-text (test-id "inbox") "a.txt:1:text/plain|b.txt:2:text/plain|a.txt:1:text/plain")
    (expect-text (test-id "note") "1 arrived after 2")
    (expect-files 3)
    ; A local reducer and a decision as one event: the list, a local
    ; state, and the two cells. The inbox's earlier files are replaced and
    ; released; the dropped file is held twice and is one handle.
    (mark-metrics)
    (drop-files (label "Inbox and list") "b.txt")
    (expect-text (test-id "files") "b.txt:2:text/plain")
    (expect-text (test-id "inbox") "b.txt:2:text/plain")
    (expect-text (test-id "note") "1 arrived, 0 refused")
    (expect-metric-delta dirty_source_roots 3)
    (expect-files 1)
    ; A handler that is a list of writes lets the inbox's files go; the
    ; list still holds its own.
    (click (role button :name "Empty inbox"))
    (expect-text (test-id "inbox") "none")
    (expect-text (test-id "note") "emptied")
    (expect-files 1)
    (click (role button :name "Clear"))
    (expect-files 0)
  )
)
