(test "Status page — The uptime chart follows the checks"
  (steps
    ; The chart is a `plume-chart` element whose `data-figure` attribute is
    ; the Plotly figure Plume built. Before any check reports, every bar is
    ; empty and grey.
    (expect-visible (role img :name "Uptime by service"))
    (expect-attr (test-id "uptime-chart") data-figure "{\"data\":[{\"type\":\"bar\",\"x\":[\"API\",\"Web app\",\"Database\",\"Notifications\"],\"y\":[0,0,0,0],\"marker\":{\"color\":[\"rgb(161, 161, 170)\",\"rgb(161, 161, 170)\",\"rgb(161, 161, 170)\",\"rgb(161, 161, 170)\"]},\"orientation\":\"v\",\"name\":\"Uptime\",\"width\":0.75}],\"layout\":{\"font\":{},\"title\":{},\"xaxis\":{},\"yaxis\":{\"range\":[0,100],\"type\":\"linear\",\"title\":{\"text\":\"Uptime (%)\",\"font\":{}},\"color\":\"rgb(68, 68, 68)\"},\"showlegend\":false}}")

    ; The API check arrives: its bar rises to its uptime, in the
    ; operational tone. The others still wait.
    (stub-http "api" :url "/api/status/api" :status 200 :body "operational|99.98")
    (run-effect 1)
    (expect-attr (test-id "uptime-chart") data-figure "{\"data\":[{\"type\":\"bar\",\"x\":[\"API\",\"Web app\",\"Database\",\"Notifications\"],\"y\":[99.98,0,0,0],\"marker\":{\"color\":[\"rgb(5, 150, 105)\",\"rgb(161, 161, 170)\",\"rgb(161, 161, 170)\",\"rgb(161, 161, 170)\"]},\"orientation\":\"v\",\"name\":\"Uptime\",\"width\":0.75}],\"layout\":{\"font\":{},\"title\":{},\"xaxis\":{},\"yaxis\":{\"range\":[0,100],\"type\":\"linear\",\"title\":{\"text\":\"Uptime (%)\",\"font\":{}},\"color\":\"rgb(68, 68, 68)\"},\"showlegend\":false}}")

    ; The database degrades and the notifications check fails: one bar
    ; turns amber at its lower uptime, the failed one stays empty.
    (stub-http "web" :url "/api/status/web" :status 200 :body "operational|99.99")
    (run-effect 2)
    (stub-http "database" :url "/api/status/database" :status 200 :body "degraded|97.40")
    (run-effect 3)
    (stub-http "notifications" :url "/api/status/notifications" :status 503 :body "unavailable")
    (run-effect 4)
    (expect-attr (test-id "uptime-chart") data-figure "{\"data\":[{\"type\":\"bar\",\"x\":[\"API\",\"Web app\",\"Database\",\"Notifications\"],\"y\":[99.98,99.99,97.4,0],\"marker\":{\"color\":[\"rgb(5, 150, 105)\",\"rgb(5, 150, 105)\",\"rgb(217, 119, 6)\",\"rgb(217, 119, 6)\"]},\"orientation\":\"v\",\"name\":\"Uptime\",\"width\":0.75}],\"layout\":{\"font\":{},\"title\":{},\"xaxis\":{},\"yaxis\":{\"range\":[0,100],\"type\":\"linear\",\"title\":{\"text\":\"Uptime (%)\",\"font\":{}},\"color\":\"rgb(68, 68, 68)\"},\"showlegend\":false}}")
  )
)
