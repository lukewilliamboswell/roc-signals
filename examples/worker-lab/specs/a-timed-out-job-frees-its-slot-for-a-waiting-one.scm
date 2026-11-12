(test "Worker Lab — A job that times out at the bound frees its slot for the first waiting job"
  (steps
    (fill (label "Jobs") "20")
    (fill (label "Weight") "1")
    (fill (label "Timeout (ms)") "50")
    (click (role button :name "Start"))
    (expect-pending-work "roc-signals.example/worker-lab/primes" 15)
    (expect-text (test-id "job-16") "waiting")
    ; A waiting job's timeout has not started: the page has not asked for
    ; it yet. Expiring the timeout of a job in flight answers it Timeout,
    ; and the slot it held goes to the lowest waiting job.
    (mark-metrics)
    (time-out-work 3)
    (expect-metric-delta effects_delivered 1)
    (expect-metric-delta effects_cancelled 0)
    (expect-text (test-id "job-3") "timed out")
    (expect-text (test-id "job-16") "running")
    (expect-text (test-id "job-17") "waiting")
    (expect-pending-work "roc-signals.example/worker-lab/primes" 15)
    ; The job admitted in its place carries the same timeout, which can
    ; expire in turn (occurrence 16 is job 16).
    (time-out-work 16)
    (expect-text (test-id "job-16") "timed out")
    (expect-text (test-id "job-17") "running")
    (run-effect 1)
    (expect-text (test-id "job-1") "done: 152 primes")
    (expect-text (test-id "job-18") "running")
    (expect-text (test-id "stopped") "2")
    (expect-text (test-id "refused") "Refused at the in-flight bound and retried: 0")
  )
)
