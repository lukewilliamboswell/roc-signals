(test "Services — url initial preprocessing"
  (setup (initial-location "/url-probe/ca\tfé\n?word=ça\r va'\"#tag=é ` \r "))
  (steps
    (expect-current-location "/url-probe/caf%C3%A9?word=%C3%A7a%20va%27%22#tag=%C3%A9%20%60")
    (expect-text (test-id "received-location") "/url-probe/caf%C3%A9?word=%C3%A7a%20va%27%22#tag=%C3%A9%20%60")
  ))
