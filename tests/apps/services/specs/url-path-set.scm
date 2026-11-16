(test "Services — a pushed path percent-encodes | and ^ as Chrome does"
  (setup (initial-location "/url-probe/pipe"))
  (steps
    (click (role button :name "Push pipe path"))
    (expect-current-location "/url-probe/a%7Cb%5Ec?q=|^#|^")
    (history-back)
    (expect-current-location "/url-probe/pipe")
    (expect-text (test-id "received-location") "/url-probe/pipe")
    (history-forward)
    (expect-text (test-id "received-location") "/url-probe/a%7Cb%5Ec?q=|^#|^")))
