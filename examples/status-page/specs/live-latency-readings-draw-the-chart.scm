(test "Status page — Live latency readings draw the chart"
  (steps
    ; The page subscribes to the latency feed at mount. The spec stands in
    ; for the feed's JavaScript: each `emit-port` is one message, and each
    ; message is one turn of the app.
    (expect-port-subscriptions "roc-signals.example/status-page/latency" 1)
    (expect-text (test-id "live-status") "Connecting to the latency feed")
    (expect-text (test-id "live-received") "0")
    (expect-text (test-id "live-api-p95") "no reading yet")

    ; A message writes only the feed's own state: the checks, the cards and
    ; the uptime history do no work for it, and no rows are made.
    (mark-metrics)
    (emit-port "roc-signals.example/status-page/latency" "{\"Event\":{\"seq\":1,\"at_ms\":\"1762852800250\",\"p95_ms\":{\"api\":140,\"web\":150,\"database\":115,\"notifications\":190},\"dropped\":0}}")
    (expect-metric-delta rows_created 0)
    (expect-metric-delta scopes_created 0)
    (expect-text (test-id "live-status") "Live: a reading of every service's p95 every 250 ms")
    (expect-text (test-id "live-received") "1")
    (expect-text (test-id "live-api-p95") "140 ms")

    ; The next reading joins the line. Reading 3 never came, so reading 4
    ; starts a new segment (a null y in the figure). The API's p95 in
    ; readings 4 and 5 is over its 300 ms objective: a shaded band marks the
    ; stretch, from the first reading over to the first back under.
    (emit-port "roc-signals.example/status-page/latency" "{\"Event\":{\"seq\":2,\"at_ms\":\"1762852800500\",\"p95_ms\":{\"api\":150,\"web\":152,\"database\":116,\"notifications\":188},\"dropped\":0}}")
    (emit-port "roc-signals.example/status-page/latency" "{\"Event\":{\"seq\":4,\"at_ms\":\"1762852801000\",\"p95_ms\":{\"api\":620,\"web\":149,\"database\":190,\"notifications\":191},\"dropped\":0}}")
    (emit-port "roc-signals.example/status-page/latency" "{\"Event\":{\"seq\":5,\"at_ms\":\"1762852801250\",\"p95_ms\":{\"api\":780,\"web\":151,\"database\":205,\"notifications\":187},\"dropped\":0}}")
    (emit-port "roc-signals.example/status-page/latency" "{\"Event\":{\"seq\":6,\"at_ms\":\"1762852801500\",\"p95_ms\":{\"api\":180,\"web\":150,\"database\":120,\"notifications\":189},\"dropped\":0}}")
    (expect-text (test-id "live-received") "5")
    (expect-text (test-id "live-api-p95") "180 ms")

    ; The chart is redrawn from the readings on the page's redraw tick, not
    ; once per reading: a backlog drains as back-to-back turns with no paint
    ; between them. Until the tick it still draws no reading.
    (expect-attr (test-id "latency-chart") data-figure "{\"data\":[{\"type\":\"scatter\",\"x\":[],\"y\":[],\"marker\":{\"color\":[],\"size\":[],\"symbol\":[]},\"name\":\"API\",\"line\":{\"width\":2.5,\"color\":\"rgb(37, 99, 235)\",\"dash\":\"solid\"},\"mode\":\"lines\"},{\"type\":\"scatter\",\"x\":[],\"y\":[],\"marker\":{\"color\":[],\"size\":[],\"symbol\":[]},\"name\":\"Web app\",\"line\":{\"width\":1.5,\"color\":\"rgb(124, 58, 237)\",\"dash\":\"solid\"},\"mode\":\"lines\"},{\"type\":\"scatter\",\"x\":[],\"y\":[],\"marker\":{\"color\":[],\"size\":[],\"symbol\":[]},\"name\":\"Database\",\"line\":{\"width\":1.5,\"color\":\"rgb(13, 148, 136)\",\"dash\":\"solid\"},\"mode\":\"lines\"},{\"type\":\"scatter\",\"x\":[],\"y\":[],\"marker\":{\"color\":[],\"size\":[],\"symbol\":[]},\"name\":\"Notifications\",\"line\":{\"width\":1.5,\"color\":\"rgb(219, 39, 119)\",\"dash\":\"solid\"},\"mode\":\"lines\"}],\"layout\":{\"font\":{},\"title\":{},\"xaxis\":{\"autorange\":true,\"type\":\"date\",\"title\":{\"text\":\"Time (UTC)\",\"font\":{}},\"color\":\"rgb(68, 68, 68)\",\"tickformat\":\"%H:%M:%S\"},\"yaxis\":{\"autorange\":true,\"rangemode\":\"tozero\",\"title\":{\"text\":\"p95 latency\",\"font\":{}},\"color\":\"rgb(68, 68, 68)\",\"ticksuffix\":\" ms\"},\"showlegend\":true,\"legend\":{\"orientation\":\"h\",\"x\":0,\"xanchor\":\"left\",\"y\":1.02,\"yanchor\":\"bottom\"},\"height\":320,\"margin\":{\"l\":64,\"r\":16,\"t\":48,\"b\":48},\"hovermode\":\"x unified\",\"uirevision\":\"live-latency\",\"shapes\":[{\"type\":\"line\",\"xref\":\"paper\",\"yref\":\"y\",\"x0\":0,\"x1\":1,\"y0\":300,\"y1\":300,\"layer\":\"above\",\"line\":{\"width\":1,\"color\":\"rgb(113, 113, 122)\",\"dash\":\"dash\"},\"label\":{\"text\":\"API objective 300 ms\",\"textposition\":\"end\"}}]}}")
    (tick-interval 250)
    (expect-attr (test-id "latency-chart") data-figure "{\"data\":[{\"type\":\"scatter\",\"x\":[\"2025-11-11 09:20:00.250\",\"2025-11-11 09:20:00.500\",\"2025-11-11 09:20:01\",\"2025-11-11 09:20:01\",\"2025-11-11 09:20:01.250\",\"2025-11-11 09:20:01.500\"],\"y\":[140,150,null,620,780,180],\"marker\":{\"color\":\"rgb(31, 119, 180)\",\"size\":6,\"symbol\":\"circle\"},\"name\":\"API\",\"line\":{\"width\":2.5,\"color\":\"rgb(37, 99, 235)\",\"dash\":\"solid\"},\"mode\":\"lines\"},{\"type\":\"scatter\",\"x\":[\"2025-11-11 09:20:00.250\",\"2025-11-11 09:20:00.500\",\"2025-11-11 09:20:01\",\"2025-11-11 09:20:01\",\"2025-11-11 09:20:01.250\",\"2025-11-11 09:20:01.500\"],\"y\":[150,152,null,149,151,150],\"marker\":{\"color\":\"rgb(31, 119, 180)\",\"size\":6,\"symbol\":\"circle\"},\"name\":\"Web app\",\"line\":{\"width\":1.5,\"color\":\"rgb(124, 58, 237)\",\"dash\":\"solid\"},\"mode\":\"lines\"},{\"type\":\"scatter\",\"x\":[\"2025-11-11 09:20:00.250\",\"2025-11-11 09:20:00.500\",\"2025-11-11 09:20:01\",\"2025-11-11 09:20:01\",\"2025-11-11 09:20:01.250\",\"2025-11-11 09:20:01.500\"],\"y\":[115,116,null,190,205,120],\"marker\":{\"color\":\"rgb(31, 119, 180)\",\"size\":6,\"symbol\":\"circle\"},\"name\":\"Database\",\"line\":{\"width\":1.5,\"color\":\"rgb(13, 148, 136)\",\"dash\":\"solid\"},\"mode\":\"lines\"},{\"type\":\"scatter\",\"x\":[\"2025-11-11 09:20:00.250\",\"2025-11-11 09:20:00.500\",\"2025-11-11 09:20:01\",\"2025-11-11 09:20:01\",\"2025-11-11 09:20:01.250\",\"2025-11-11 09:20:01.500\"],\"y\":[190,188,null,191,187,189],\"marker\":{\"color\":\"rgb(31, 119, 180)\",\"size\":6,\"symbol\":\"circle\"},\"name\":\"Notifications\",\"line\":{\"width\":1.5,\"color\":\"rgb(219, 39, 119)\",\"dash\":\"solid\"},\"mode\":\"lines\"}],\"layout\":{\"font\":{},\"title\":{},\"xaxis\":{\"autorange\":true,\"type\":\"date\",\"title\":{\"text\":\"Time (UTC)\",\"font\":{}},\"color\":\"rgb(68, 68, 68)\",\"tickformat\":\"%H:%M:%S\"},\"yaxis\":{\"autorange\":true,\"rangemode\":\"tozero\",\"title\":{\"text\":\"p95 latency\",\"font\":{}},\"color\":\"rgb(68, 68, 68)\",\"ticksuffix\":\" ms\"},\"showlegend\":true,\"legend\":{\"orientation\":\"h\",\"x\":0,\"xanchor\":\"left\",\"y\":1.02,\"yanchor\":\"bottom\"},\"height\":320,\"margin\":{\"l\":64,\"r\":16,\"t\":48,\"b\":48},\"hovermode\":\"x unified\",\"uirevision\":\"live-latency\",\"shapes\":[{\"type\":\"line\",\"xref\":\"paper\",\"yref\":\"y\",\"x0\":0,\"x1\":1,\"y0\":300,\"y1\":300,\"layer\":\"above\",\"line\":{\"width\":1,\"color\":\"rgb(113, 113, 122)\",\"dash\":\"dash\"},\"label\":{\"text\":\"API objective 300 ms\",\"textposition\":\"end\"}},{\"type\":\"rect\",\"xref\":\"x\",\"yref\":\"paper\",\"x0\":\"2025-11-11 09:20:01\",\"x1\":\"2025-11-11 09:20:01.500\",\"y0\":0,\"y1\":1,\"layer\":\"below\",\"line\":{\"width\":0},\"fillcolor\":\"rgba(220, 38, 38, 0.149019607843137254)\",\"label\":{\"text\":\"API over objective\",\"textposition\":\"top left\"}}]}}")

    ; The feed says it dropped readings its buffer could not hold, and the
    ; page shows the count.
    (emit-port "roc-signals.example/status-page/latency" "{\"Event\":{\"seq\":30,\"at_ms\":\"1762852807500\",\"p95_ms\":{\"api\":170,\"web\":150,\"database\":120,\"notifications\":189},\"dropped\":16}}")
    (expect-text (test-id "live-dropped") "16")
  )
)
