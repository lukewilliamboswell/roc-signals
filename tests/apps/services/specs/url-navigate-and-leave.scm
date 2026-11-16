(test "Services — url navigate and leave"
  (setup (initial-location "/url-probe/history?before=%26#start"))
  (steps
    (navigate "/url-probe/navigate ca\tfé?word=ça\r va'\n\"#tag=é ` \r ")
    (expect-current-location "/url-probe/navigate%20caf%C3%A9?word=%C3%A7a%20va%27%22#tag=%C3%A9%20%60")
    (expect-text (test-id "received-location") "/url-probe/navigate%20caf%C3%A9?word=%C3%A7a%20va%27%22#tag=%C3%A9%20%60")
    (leave-page "/url-probe/leave café?word=ça va'\"#tag=é `" unasked)
    (expect-current-location "/url-probe/leave%20caf%C3%A9?word=%C3%A7a%20va%27%22#tag=%C3%A9%20%60")
    (expect-text (test-id "received-location") "/url-probe/leave%20caf%C3%A9?word=%C3%A7a%20va%27%22#tag=%C3%A9%20%60")
  ))
