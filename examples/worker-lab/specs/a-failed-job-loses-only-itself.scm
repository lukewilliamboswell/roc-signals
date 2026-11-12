(test "Worker Lab — A crashed, lost or timed-out job stops only itself"
  (steps
    (select-option (label "Workload") "faulty")
    (fill (label "Jobs") "4")
    (fill (label "Weight") "1")
    (click (role button :name "Start"))
    ; Every fourth job goes to the task that always crashes.
    (expect-pending-work "roc-signals.example/worker-lab/primes" 3)
    (expect-pending-work "roc-signals.example/worker-lab/crash" 1)
    (expect-visible (text "primes in [1006000, 1008000), crashing task"))
    ; It really runs and crashes, in an instance of its own; the others
    ; still answer.
    (run-effect 4)
    (expect-text (test-id "job-4") "lost: app crash")
    (run-effect 1)
    (run-effect 2)
    (run-effect 3)
    (expect-text (test-id "job-3") "done: 136 primes")
    (expect-text (test-id "stopped") "1")
    (expect-text (test-id "checksum") "incomplete")
    ; A deadline expires only when the spec says so, and a job can be lost
    ; for any fault class; each shows as its own row's outcome.
    (select-option (label "Workload") "primes")
    (fill (label "Deadline (ms)") "50")
    (click (role button :name "Start"))
    (expect-pending-work "roc-signals.example/worker-lab/primes" 4)
    (time-out-work 6)
    (lose-work 7 out_of_memory)
    (run-effect 5)
    (run-effect 8)
    (expect-pending-effects 0)
    (expect-text (test-id "job-1") "done: 152 primes")
    (expect-text (test-id "job-2") "timed out")
    (expect-text (test-id "job-3") "lost: out of memory")
    (expect-text (test-id "job-4") "done: 158 primes")
    (expect-text (test-id "stopped") "2")
  )
)
