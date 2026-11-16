(test "Services — url initial"
  (setup (initial-location "/url-probe/café au lait/\"<>`{}?q=\"<>'`{}#f=\"<>`{}' ?#"))
  (steps
    (expect-current-location "/url-probe/caf%C3%A9%20au%20lait/%22%3C%3E%60%7B%7D?q=%22%3C%3E%27`{}#f=%22%3C%3E%60{}'%20?#")
    (expect-text (test-id "received-location") "/url-probe/caf%C3%A9%20au%20lait/%22%3C%3E%60%7B%7D?q=%22%3C%3E%27`{}#f=%22%3C%3E%60{}'%20?#")
  ))
