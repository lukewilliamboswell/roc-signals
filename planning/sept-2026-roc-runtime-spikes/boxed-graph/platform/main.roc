platform ""
    requires {} { main : () -> U64 }
    exposes []
    packages { roc: "nightly-2026-09-12-220fd47" }
    provides { "graph_create": create, "graph_step": step, "graph_finish": finish, "graph_drop": drop, "graph_handoff": handoff }
    targets: {
        inputs_dir: "targets/",
        wasm32: { inputs: ["host.wasm", app], exports: ["start", "update", "finish", "drop_state", "handoff", "reset_metrics", "metric"] },
    }

Key : { owner : U64, ordinal : U64 }
Payload : { numbers : List(U64), labels : List(Str), index : Dict(Key, U64), source : U64, left : U64, right : U64, sum : U64 }
Graph : { current : Box(Payload), saved : List(Box(Payload)) }

create : U64, U64 -> Box(Graph)
create = |count, retain| {
    var $numbers = List.with_capacity(count)
    var $labels = List.with_capacity(count)
    var $index = 0.U64
    var $lookup = Dict.with_capacity(count)
    while $index < count {
        $numbers = $numbers.append(0)
        $labels = $labels.append(if retain >= 2 { "label" } else { "a deliberately heap-backed string for ownership verification" })
        $lookup = Dict.insert($lookup, { owner: 42, ordinal: $index }, $index)
        $index = $index + 1
    }
    payload = Box.box({ numbers: $numbers, labels: $labels, index: $lookup, source: main(), left: 0, right: 0, sum: 0 })
    Box.box({ current: payload, saved: if retain.rem_by(2) == 1 { [payload] } else { [] } })
}

step : Box(Graph), U64, U64 -> Box(Graph)
step = |boxed, index, iterations| {
    graph = Box.unbox(boxed)
    var $payload = Box.unbox(graph.current)
    var $iteration = 0.U64
    while $iteration < iterations {
        $payload = update_payload($payload, index)
        $iteration = $iteration + 1
    }
    Box.box({ ..graph, current: Box.box($payload) })
}

update_payload : Payload, U64 -> Payload
update_payload = |payload, index| {
    source = payload.source + 1
    left = source * 2
    right = source + 3
    slot = payload.index.get({ owner: 42, ordinal: index }) ?? crash "typed key missing"
    numbers = payload.numbers.set(slot, source) ?? crash "update index out of bounds"
    { ..payload, numbers, source, left, right, sum: left + right }
}

drop : Box(Graph) -> {}
drop = |_| {}

handoff : Box(Graph) -> Box(Graph)
handoff = |state| state

finish : Box(Graph), U64 -> U64
finish = |boxed, expected| {
    graph = Box.unbox(boxed)
    payload = Box.unbox(graph.current)
    if payload.source != expected { crash "source mismatch" }
    if expected > 0 and payload.sum != expected * 3 + 3 { crash "diamond mismatch" }
    if expected > 0 and (payload.numbers.get(0) ?? crash "missing number") != expected { crash "row mismatch" }
    var $index = 0.U64
    for value in payload.numbers {
        if (payload.index.get({ owner: 42, ordinal: $index }) ?? crash "missing key") != $index { crash "typed index mismatch" }
        if value != (if $index == 0 { expected } else { 0 }) { crash "unrelated row mutated" }
        $index = $index + 1
    }
    for label in payload.labels {
        if label != "label" and label != "a deliberately heap-backed string for ownership verification" { crash "string ownership mismatch" }
    }
    for saved in graph.saved {
        old = Box.unbox(saved)
        if old.source != 0 { crash "snapshot source mutated" }
        for value in old.numbers { if value != 0 { crash "snapshot row mutated" } }
    }
    payload.source
}
