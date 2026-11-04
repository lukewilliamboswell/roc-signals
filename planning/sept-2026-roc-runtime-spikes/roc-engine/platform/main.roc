platform ""
    requires {} { main : () -> U64 }
    exposes []
    packages { roc: "nightly-2026-09-12-220fd47" }
    provides { "engine_create": create, "engine_event": event, "engine_check": check, "engine_drop": drop }
    targets: {
        inputs_dir: "targets/",
        wasm32: { inputs: ["host.wasm", app], exports: ["start", "event", "check", "drop_state", "reset_metrics", "metric"] },
    }

# A closed numeric graph representation. Topological node IDs define scheduler
# order; arbitrary user closures and arbitrary value types are not yet modeled.
Kind : [Source, Half, Third, Sum]
Node : { kind : Kind, value : U64, a : U64, b : U64, edge_at : U64, edge_count : U64, alive : Bool }
Command : [Set(U64, U64), Remove(U64)]
State : { nodes : List(Node), edges : List(U64), queue : List(U64), commands : List(Command), live : U64, calls : U64, prunes : U64, visits : U64 }

create : U64 -> Box(State)
create = |rows| {
    var $nodes = List.with_capacity(rows * 4)
    var $edges = List.with_capacity(rows * 4)
    var $row = 0.U64
    while $row < rows {
        n = $row * 4
        e = $edges.len()
        $nodes = $nodes.append({ kind: Source, value: main(), a: 0, b: 0, edge_at: e, edge_count: 2, alive: True })
        $nodes = $nodes.append({ kind: Half, value: 0, a: n, b: 0, edge_at: e + 2, edge_count: 1, alive: True })
        $nodes = $nodes.append({ kind: Third, value: 0, a: n, b: 0, edge_at: e + 3, edge_count: 1, alive: True })
        $nodes = $nodes.append({ kind: Sum, value: 0, a: n + 1, b: n + 2, edge_at: 0, edge_count: 0, alive: True })
        $edges = $edges.append(n + 1).append(n + 2).append(n + 3).append(n + 3)
        $row = $row + 1
    }
    Box.box({ nodes: $nodes, edges: $edges, queue: [], commands: [], live: rows, calls: 0, prunes: 0, visits: 0 })
}

node_at : State, U64 -> Node
node_at = |state, id| state.nodes.get(id) ?? crash "unknown node"

set_node : State, U64, Node -> State
set_node = |{ nodes, edges, queue, commands, live, calls, prunes, visits }, id, node| {
    { nodes: nodes.set(id, node) ?? crash "missing slot", edges, queue, commands, live, calls, prunes, visits }
}

# Ordered, deduplicating queue. Deliberately simple: O(queue length) insertion.
# Independent row turns have at most two pending nodes. This is not a general
# large-frontier scheduler complexity claim.
enqueue : List(U64), U64 -> List(U64)
enqueue = |queue, id| {
    if queue.contains(id) { queue } else { queue.append(id).sort_with(|a, b| if a < b { Before } else if a > b { After } else { Same }) }
}

notify : State, Node -> State
notify = |state, node| {
    var $queue = state.queue
    var $i = 0.U64
    while $i < node.edge_count {
        id = state.edges.get(node.edge_at + $i) ?? crash "missing dependency edge"
        $queue = enqueue($queue, id)
        $i = $i + 1
    }
    { ..state, queue: $queue }
}

settle : State -> State
settle = |state| {
    var $state = state
    while !$state.queue.is_empty() {
        id = $state.queue.get(0) ?? crash "empty scheduler"
        node = node_at($state, id)
        $state = { ..$state, queue: $state.queue.drop_first(1), visits: $state.visits + 1 }
        if !node.alive { crash "retired node scheduled" }
        value = match node.kind {
            Source => crash "source in derived queue"
            Half => node_at($state, node.a).value.div_trunc_by(2)
            Third => node_at($state, node.a).value.div_trunc_by(3)
            Sum => node_at($state, node.a).value + node_at($state, node.b).value
        }
        $state = { ..$state, calls: $state.calls + 1 }
        if value == node.value {
            $state = { ..$state, prunes: $state.prunes + 1 }
        } else {
            $state = set_node($state, id, { ..node, value })
            if node.kind == Sum {
                $state = { ..$state, commands: $state.commands.append(Set(id.div_trunc_by(4), value)) }
            }
            $state = notify($state, node)
        }
    }
    $state
}

remove : State, U64 -> State
remove = |{ nodes, edges, queue, commands, live, calls, prunes, visits }, row| {
    first = row * 4
    first_node = nodes.get(first) ?? crash "missing row node"
    if !first_node.alive { crash "row already retired" }
    var $nodes = nodes
    var $i = 0.U64
    while $i < 4 {
        old = $nodes.get(first + $i) ?? crash "missing row node"
        $nodes = $nodes.set(first + $i, { ..old, alive: False }) ?? crash "missing row node"
        $i = $i + 1
    }
    { nodes: $nodes, edges, queue, live: live - 1, calls, prunes, visits: visits + 4, commands: commands.append(Remove(row)) }
}

# op 0 sets one source, op 1 retires one row, op 2 clears all live rows.
# Commands are owned output data retained until the next host call; no effects
# occur during evaluation. The prototype asserts the command stream in check.
event : Box(State), U64, U64, U64 -> Box(State)
event = |boxed, op, row, value| {
    before = Box.unbox(boxed)
    state = { ..before, commands: [], calls: 0, prunes: 0, visits: 0 }
    next = if op == 0 {
        id = row * 4
        source = node_at(state, id)
        if !source.alive { crash "write to disposed row" }
        if source.value == value {
            { ..state, prunes: 1 }
        } else {
            settle(notify(set_node(state, id, { ..source, value }), source))
        }
    } else if op == 1 {
        remove(state, row)
    } else if op == 2 {
        var $state = state
        var $row = 0.U64
        while $row < $state.nodes.len().div_trunc_by(4) {
            if node_at($state, $row * 4).alive { $state = remove($state, $row) }
            $row = $row + 1
        }
        # Clear ends storage ownership. Individual remove leaves reusable-sized
        # holes, but insertion and slot-generation reuse are outside this spike.
        { ..$state, nodes: [], edges: [] }
    } else { crash "unknown operation" }
    Box.box(next)
}

# Consuming validation returns the owner to Zig. Inspect a row and all commands,
# and require exactly the expected work. Validation is outside measurement.
check : Box(State), U64, U64, U64, U64, U64, U64 -> Box(State)
check = |boxed, row, value, live, calls, prunes, commands| {
    state = Box.unbox(boxed)
    if state.live != live { crash "live count mismatch" }
    if state.calls != calls { crash "derived call count mismatch" }
    if state.prunes != prunes { crash "prune count mismatch" }
    if state.commands.len() != commands { crash "command count mismatch" }
    if !state.queue.is_empty() { crash "unsettled queue" }
    if live > 0 {
        source = node_at(state, row * 4)
        if !source.alive or source.value != value { crash "source mismatch" }
        if node_at(state, row * 4 + 1).value != value.div_trunc_by(2) { crash "half mismatch" }
        if node_at(state, row * 4 + 2).value != value.div_trunc_by(3) { crash "third mismatch" }
        if node_at(state, row * 4 + 3).value != value.div_trunc_by(2) + value.div_trunc_by(3) { crash "diamond glitch" }
    }
    for command in state.commands {
        match command {
            Set(key, output) => {
                expected = node_at(state, key * 4).value
                if output != expected.div_trunc_by(2) + expected.div_trunc_by(3) { crash "unsettled render output" }
            }
            Remove(key) => {
                if !state.nodes.is_empty() and node_at(state, key * 4).alive { crash "removed live row" }
            }
        }
    }
    Box.box(state)
}

drop : Box(State) -> {}
drop = |_| {}
