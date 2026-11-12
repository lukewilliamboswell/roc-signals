(test "Status page — The uptime history follows the checks"
  (steps
    ; The history is a `plume-chart` element whose `data-figure` attribute
    ; is the Plotly figure Plume built: one line per service, the newest
    ; check at 0 and older ones to its left, over a fixed axis of the 60
    ; checks the page keeps. Before any check answers, every line is empty.
    (expect-visible (role img :name "Uptime history by service"))
    (expect-attr (test-id "uptime-chart") data-figure "{\"data\":[{\"type\":\"scatter\",\"x\":[],\"y\":[],\"marker\":{\"color\":[],\"size\":[],\"symbol\":[]},\"name\":\"API\",\"line\":{\"width\":2,\"color\":\"rgb(37, 99, 235)\",\"dash\":\"solid\"},\"mode\":\"lines+markers\"},{\"type\":\"scatter\",\"x\":[],\"y\":[],\"marker\":{\"color\":[],\"size\":[],\"symbol\":[]},\"name\":\"Web app\",\"line\":{\"width\":2,\"color\":\"rgb(124, 58, 237)\",\"dash\":\"solid\"},\"mode\":\"lines+markers\"},{\"type\":\"scatter\",\"x\":[],\"y\":[],\"marker\":{\"color\":[],\"size\":[],\"symbol\":[]},\"name\":\"Database\",\"line\":{\"width\":2,\"color\":\"rgb(13, 148, 136)\",\"dash\":\"solid\"},\"mode\":\"lines+markers\"},{\"type\":\"scatter\",\"x\":[],\"y\":[],\"marker\":{\"color\":[],\"size\":[],\"symbol\":[]},\"name\":\"Notifications\",\"line\":{\"width\":2,\"color\":\"rgb(219, 39, 119)\",\"dash\":\"solid\"},\"mode\":\"lines+markers\"}],\"layout\":{\"font\":{},\"title\":{},\"xaxis\":{\"range\":[-59,0],\"type\":\"linear\",\"title\":{\"text\":\"Checks before the latest\",\"font\":{}},\"color\":\"rgb(68, 68, 68)\"},\"yaxis\":{\"autorange\":true,\"type\":\"linear\",\"title\":{\"text\":\"Uptime\",\"font\":{}},\"color\":\"rgb(68, 68, 68)\",\"ticksuffix\":\"%\"},\"showlegend\":true,\"legend\":{\"orientation\":\"h\",\"x\":0,\"xanchor\":\"left\",\"y\":1.02,\"yanchor\":\"bottom\"},\"height\":280,\"margin\":{\"l\":56,\"r\":16,\"t\":48,\"b\":48},\"hovermode\":\"x unified\",\"uirevision\":\"uptime-history\"}}")

    ; The mount's refresh answers: each service that reported an uptime
    ; has a point at 0. The notifications check failed, so it has none.
    (stub-http "api" :url "/api/status/api" :status 200 :body "operational|99.98")
    (run-effect 1)
    (stub-http "web" :url "/api/status/web" :status 200 :body "operational|99.99")
    (run-effect 2)
    (stub-http "database" :url "/api/status/database" :status 200 :body "degraded|97.40")
    (run-effect 3)
    (stub-http "notifications" :url "/api/status/notifications" :status 503 :body "unavailable")
    (run-effect 4)
    (expect-attr (test-id "uptime-chart") data-figure "{\"data\":[{\"type\":\"scatter\",\"x\":[0],\"y\":[99.98],\"marker\":{\"color\":\"rgb(37, 99, 235)\",\"size\":6,\"symbol\":\"circle\"},\"name\":\"API\",\"line\":{\"width\":2,\"color\":\"rgb(37, 99, 235)\",\"dash\":\"solid\"},\"mode\":\"lines+markers\"},{\"type\":\"scatter\",\"x\":[0],\"y\":[99.99],\"marker\":{\"color\":\"rgb(124, 58, 237)\",\"size\":6,\"symbol\":\"circle\"},\"name\":\"Web app\",\"line\":{\"width\":2,\"color\":\"rgb(124, 58, 237)\",\"dash\":\"solid\"},\"mode\":\"lines+markers\"},{\"type\":\"scatter\",\"x\":[0],\"y\":[97.4],\"marker\":{\"color\":\"rgb(13, 148, 136)\",\"size\":6,\"symbol\":\"circle\"},\"name\":\"Database\",\"line\":{\"width\":2,\"color\":\"rgb(13, 148, 136)\",\"dash\":\"solid\"},\"mode\":\"lines+markers\"},{\"type\":\"scatter\",\"x\":[],\"y\":[],\"marker\":{\"color\":[],\"size\":[],\"symbol\":[]},\"name\":\"Notifications\",\"line\":{\"width\":2,\"color\":\"rgb(219, 39, 119)\",\"dash\":\"solid\"},\"mode\":\"lines+markers\"}],\"layout\":{\"font\":{},\"title\":{},\"xaxis\":{\"range\":[-59,0],\"type\":\"linear\",\"title\":{\"text\":\"Checks before the latest\",\"font\":{}},\"color\":\"rgb(68, 68, 68)\"},\"yaxis\":{\"autorange\":true,\"type\":\"linear\",\"title\":{\"text\":\"Uptime\",\"font\":{}},\"color\":\"rgb(68, 68, 68)\",\"ticksuffix\":\"%\"},\"showlegend\":true,\"legend\":{\"orientation\":\"h\",\"x\":0,\"xanchor\":\"left\",\"y\":1.02,\"yanchor\":\"bottom\"},\"height\":280,\"margin\":{\"l\":56,\"r\":16,\"t\":48,\"b\":48},\"hovermode\":\"x unified\",\"uirevision\":\"uptime-history\"}}")

    ; Two more refreshes. In the first the API check fails; in the second
    ; it recovers. Every earlier point moves one check to the left each
    ; time, and the API line breaks where its check failed instead of
    ; joining across it. The incident feed is not part of the history.
    (click (role button :name "Refresh now"))
    (stub-http "api" :url "/api/status/api" :status 503 :body "unavailable")
    (run-effect 6)
    (stub-http "web" :url "/api/status/web" :status 200 :body "operational|99.99")
    (run-effect 7)
    (stub-http "database" :url "/api/status/database" :status 200 :body "operational|99.90")
    (run-effect 8)
    (stub-http "notifications" :url "/api/status/notifications" :status 200 :body "operational|99.95")
    (run-effect 9)
    (click (role button :name "Refresh now"))
    (stub-http "api" :url "/api/status/api" :status 200 :body "operational|99.98")
    (run-effect 11)
    (stub-http "web" :url "/api/status/web" :status 200 :body "operational|99.99")
    (run-effect 12)
    (stub-http "database" :url "/api/status/database" :status 200 :body "operational|99.90")
    (run-effect 13)
    (stub-http "notifications" :url "/api/status/notifications" :status 200 :body "operational|99.95")
    (run-effect 14)
    (expect-attr (test-id "uptime-chart") data-figure "{\"data\":[{\"type\":\"scatter\",\"x\":[-2,0,0],\"y\":[99.98,null,99.98],\"marker\":{\"color\":\"rgb(37, 99, 235)\",\"size\":6,\"symbol\":\"circle\"},\"name\":\"API\",\"line\":{\"width\":2,\"color\":\"rgb(37, 99, 235)\",\"dash\":\"solid\"},\"mode\":\"lines+markers\"},{\"type\":\"scatter\",\"x\":[-2,-1,0],\"y\":[99.99,99.99,99.99],\"marker\":{\"color\":\"rgb(124, 58, 237)\",\"size\":6,\"symbol\":\"circle\"},\"name\":\"Web app\",\"line\":{\"width\":2,\"color\":\"rgb(124, 58, 237)\",\"dash\":\"solid\"},\"mode\":\"lines+markers\"},{\"type\":\"scatter\",\"x\":[-2,-1,0],\"y\":[97.4,99.9,99.9],\"marker\":{\"color\":\"rgb(13, 148, 136)\",\"size\":6,\"symbol\":\"circle\"},\"name\":\"Database\",\"line\":{\"width\":2,\"color\":\"rgb(13, 148, 136)\",\"dash\":\"solid\"},\"mode\":\"lines+markers\"},{\"type\":\"scatter\",\"x\":[-1,0],\"y\":[99.95,99.95],\"marker\":{\"color\":\"rgb(219, 39, 119)\",\"size\":6,\"symbol\":\"circle\"},\"name\":\"Notifications\",\"line\":{\"width\":2,\"color\":\"rgb(219, 39, 119)\",\"dash\":\"solid\"},\"mode\":\"lines+markers\"}],\"layout\":{\"font\":{},\"title\":{},\"xaxis\":{\"range\":[-59,0],\"type\":\"linear\",\"title\":{\"text\":\"Checks before the latest\",\"font\":{}},\"color\":\"rgb(68, 68, 68)\"},\"yaxis\":{\"autorange\":true,\"type\":\"linear\",\"title\":{\"text\":\"Uptime\",\"font\":{}},\"color\":\"rgb(68, 68, 68)\",\"ticksuffix\":\"%\"},\"showlegend\":true,\"legend\":{\"orientation\":\"h\",\"x\":0,\"xanchor\":\"left\",\"y\":1.02,\"yanchor\":\"bottom\"},\"height\":280,\"margin\":{\"l\":56,\"r\":16,\"t\":48,\"b\":48},\"hovermode\":\"x unified\",\"uirevision\":\"uptime-history\"}}")
  )
)
