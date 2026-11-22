import pf.Core

## The rules the structure target checks on the engine's probe
## (`Core.probe_tree`, `Core.probe_take`): on what each site holds after a
## step, and on what each turn of the step did. Each answers `Err` with the
## rule it found broken. They read facts only, never the engine, and they
## hold for any program; the count model (`Counts`) adds what a valued
## program's turn must do.
ProbeRules := [].{

	## The rules on the site tree as it is stored after a step:
	## - no site waits for a pass, and the root holds no write set;
	## - the reads a block tests a pass against, for each child (and the
	##   marks a drawn row may take, and the reads its nested sites are
	##   tested against), cover every mask held below it except the layer
	##   of the child's own site: the hypothesis under which a pass that
	##   skips a child skips no reader;
	## - the node ids the sites hold are exactly the live ones (allocated
	##   and not freed), and no id is held twice.
	tree : List(Core.Fact) -> Try({}, Str)
	tree = |facts| {
		var $stack = [{ need: 0, own_layer: 0, row_layer: 0, reads: all_reads, what: "the root" }]
		var $held = Dict.empty()
		var $allocated = { next: 1.U32, free: [] }
		var $sites = 0.U64
		for fact in facts {
			top : Frame
			top = $stack.last() ?? crash "structure: the probe closed more than it opened"
			rest = $stack.drop_last(1)
			match fact {
				Ids(ids) => {
					$allocated = ids
				}
				AtSite({ kind, depth, waiting, own, cap: _ }) => {
					$sites = $sites + 1
					if waiting {
						return Err("the probe found ${Str.inspect(kind)} site ${$sites.to_str()} (in document order, layer ${depth.to_str()}) still waiting after the step")
					}
					own_layer = match kind {
						State | Derive | Resource => layer_bit(depth)
						_ => 0
					}
					row_layer = match kind {
						Each | View => layer_bit(depth)
						_ => 0
					}
					$stack = rest.append({ ..top, need: top.need.bitwise_or(own), own_layer, row_layer, what: "${top.what}, ${Str.inspect(kind)} site ${$sites.to_str()}" })
				}
				HoleHeld({ mask, .. }) => {
					$stack = rest.append({ ..top, need: top.need.bitwise_or(mask) })
				}
				NodesHeld(ids) => {
					for id in ids {
						if $held.contains(id) {
							return Err("the probe found node ${id.to_str()} held twice (${top.what})")
						}
						$held = $held.insert(id, {})
					}
				}
				ChildAt({ index, reads }) => {
					$stack = $stack.append({ need: 0, own_layer: 0, row_layer: 0, reads, what: "${top.what}, child ${index.to_str()}" })
				}
				RowAt({ slot, key, reads, .. }) => {
					$stack = $stack.append({ need: 0, own_layer: top.row_layer, row_layer: 0, reads, what: "${top.what}, row ${slot.to_str()} (${key})" })
				}
				Close => {
					above = top.need.bitwise_and(top.own_layer.bitwise_not())
					if above.bitwise_and(top.reads) != above {
						return Err("the probe found ${top.what} tested against reads ${top.reads.to_str()} while something below it reads ${above.to_str()}")
					}
					parent : Frame
					parent = rest.last() ?? crash "structure: the probe closed the root"
					$stack = rest.drop_last(1).append({ ..parent, need: parent.need.bitwise_or(above) })
				}
				_ => {}
			}
		}
		if $stack.len() != 1 {
			return Err("the probe left ${($stack.len() - 1).to_str()} children open")
		}
		var $live = 0.U64
		var $freed = Dict.empty()
		for id in $allocated.free {
			if $freed.contains(id) {
				return Err("node id ${id.to_str()} is free twice")
			}
			$freed = $freed.insert(id, {})
		}
		var $id = 1.U32
		while $id < $allocated.next {
			if !$freed.contains($id) {
				$live = $live + 1
				if !$held.contains($id) {
					return Err("node id ${$id.to_str()} is allocated and not freed, but no site holds it")
				}
			} else if $held.contains($id) {
				return Err("node id ${$id.to_str()} is free, but a site holds it")
			}
			$id = $id + 1
		}
		if $live != $held.len() {
			return Err("the sites hold ${$held.len().to_str()} node ids, ${$live.to_str()} are live")
		}
		Ok({})
	}

	## The rules on what the turns of a step did:
	## - within one turn no hole and no row hole is evaluated twice, and no
	##   `derive`'s input and no `when`, `switch` or `remount_on` is read
	##   twice at one place;
	## - a `derive` is read before anything below it is evaluated in the
	##   same turn;
	## - a turn runs at most one pass (one root pass for cells, or one pass
	##   from the site of its outermost written layer), and refreshes each
	##   written layer once, below where its pass started;
	## - a site mounted in a turn reads, as mounted, nothing that neither its
	##   static reads nor the cap it was mounted under name.
	turns : List(Core.Fact) -> Try({}, Str)
	turns = |facts| {
		var $turn = 0.U64
		var $seen = Dict.empty()
		var $path = []
		var $evaluated = []
		var $decided = []
		var $passes = []
		var $layers = []
		for fact in facts {
			match fact {
				TurnBegan => {
					if !$path.is_empty() {
						return Err("turn ${$turn.to_str()} of the step ended inside a site")
					}
					$turn = $turn + 1
					$seen = Dict.empty()
					$evaluated = []
					$decided = []
					$passes = []
					$layers = []
				}
				Entered(index) => {
					$path = $path.append(index * 2)
				}
				EnteredRow(slot) => {
					$path = $path.append(slot.to_u64() * 2 + 1)
				}
				Left => {
					$path = $path.drop_last(1)
				}
				Evaluated({ node, hole, .. }) => {
					at = node.to_u64().shl_wrap(32).bitwise_or(hole)
					if $seen.contains(at) {
						return Err("the probe found hole ${hole.to_str()} of node ${node.to_str()} evaluated twice in turn ${$turn.to_str()} of the step")
					}
					$seen = $seen.insert(at, {})
					$evaluated = $evaluated.append($path)
				}
				Derived({ depth, .. }) => {
					if $evaluated.any(|below| below.starts_with($path)) {
						return Err("the probe found the derive at layer ${depth.to_str()} read after a reader below it was evaluated, in turn ${$turn.to_str()} of the step")
					}
					if $decided.contains($path) {
						return Err("the probe found the derive at layer ${depth.to_str()} read twice in turn ${$turn.to_str()} of the step")
					}
					$decided = $decided.append($path)
				}
				Chose(_) => {
					if $decided.contains($path) {
						return Err("the probe found the branch site at ${path_text($path)} deciding twice in turn ${$turn.to_str()} of the step")
					}
					$decided = $decided.append($path)
				}
				RootPass(_) => {
					$passes = $passes.append(0)
				}
				PassFrom(depth) => {
					if $layers.contains(depth) {
						return Err("the probe found layer ${depth.to_str()} refreshed twice in turn ${$turn.to_str()} of the step")
					}
					$passes = $passes.append(depth)
					$layers = $layers.append(depth)
				}
				Joined(depth) | Walked(depth) => {
					if $layers.contains(depth) {
						return Err("the probe found layer ${depth.to_str()} refreshed twice in turn ${$turn.to_str()} of the step")
					}
					match $passes.first() {
						Ok(start) if start < depth => {}
						_ => return Err("the probe found layer ${depth.to_str()} refreshed in turn ${$turn.to_str()} of the step with no pass started above it")
					}
					$layers = $layers.append(depth)
				}
				Mounted({ kind, depth, reads, static, cap }) => {
					if reads.bitwise_and(static.bitwise_or(cap)) != reads {
						return Err("the probe found a ${Str.inspect(kind)} site at layer ${depth.to_str()} mounted reading ${reads.to_str()}, beyond its static reads ${static.to_str()} and its cap ${cap.to_str()}")
					}
				}
				_ => {}
			}
			if $passes.len() > 1 {
				return Err("the probe found turn ${$turn.to_str()} of the step settled by ${$passes.len().to_str()} passes")
			}
		}
		Ok({})
	}

	## The written layers each turn of a step refreshed, in the order it
	## refreshed them: where its pass started, then each layer that joined
	## it or that the walk after it reached.
	layers : List(Core.Fact) -> List(List(U64))
	layers = |facts| facts.fold(
		[],
		|acc, fact| match fact {
			TurnBegan => acc.append([])
			PassFrom(depth) | Joined(depth) | Walked(depth) => {
				last = acc.last() ?? []
				acc.drop_last(1).append(last.append(depth))
			}
			_ => acc
		},
	)
}

## One open child while the tree's facts are read: what is read below it so
## far, the layer bit its own site adds (never needed above it), the row bit
## of a site that draws rows, the reads its parent tests it against, and
## where it is, for a diagnostic.
Frame : { need : U128, own_layer : U128, row_layer : U128, reads : U128, what : Str }

## A place as `turns` keeps it (child `j` as `2j`, drawn row `slot` as
## `2 slot + 1`), as a diagnostic names it.
path_text : List(U64) -> Str
path_text = |path| Str.join_with(path.map(|at| if (at % 2 == 0) "/${(at // 2).to_str()}" else "/row ${(at // 2).to_str()}"), "")

all_reads : U128
all_reads = 0xFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF

## The signature bit of layer index `depth` (`Sig.bit`): bit `depth % 64`.
layer_bit : U64 -> U128
layer_bit = |depth| (1.U128).shl_wrap((depth % 64).to_u8_wrap())

## A child whose reads leave out a bit read below it breaks the rule; its
## own layer's bit is not needed above it.
expect {
	ok = [Ids({ next: 1, free: [] }), AtSite({ kind: Root, depth: 0, waiting: False, own: 0, cap: 0 }), ChildAt({ index: 0, reads: 2 }), AtSite({ kind: State, depth: 2, waiting: False, own: 0, cap: 0 }), HoleHeld({ node: 0, mask: 6, dirty: False, last: "" }), Close]
	lost = [Ids({ next: 1, free: [] }), AtSite({ kind: Root, depth: 0, waiting: False, own: 0, cap: 0 }), ChildAt({ index: 0, reads: 4 }), AtSite({ kind: State, depth: 2, waiting: False, own: 0, cap: 0 }), HoleHeld({ node: 0, mask: 6, dirty: False, last: "" }), Close]
	(ProbeRules.tree(ok), ProbeRules.tree(lost).is_err()) == (Ok({}), Bool.True)
}

## Two passes in one turn, a hole read twice and a derive read after its
## reader each break a rule of `turns`.
expect {
	two = [TurnBegan, PassFrom(1), PassFrom(2)]
	twice = [TurnBegan, Evaluated({ node: 3, hole: 0, carried: 2, kept: True }), Evaluated({ node: 3, hole: 0, carried: 2, kept: True })]
	late = [TurnBegan, Entered(0), Entered(1), Evaluated({ node: 3, hole: 0, carried: 2, kept: True }), Left, Derived({ depth: 2, kept: False }), Left]
	once = [TurnBegan, PassFrom(1), Joined(2), Evaluated({ node: 3, hole: 0, carried: 6, kept: False }), TurnBegan, Evaluated({ node: 3, hole: 0, carried: 2, kept: True })]
	{ two: ProbeRules.turns(two).is_err(), twice: ProbeRules.turns(twice).is_err(), late: ProbeRules.turns(late).is_err(), once: ProbeRules.turns(once) } == { two: Bool.True, twice: Bool.True, late: Bool.True, once: Ok({}) }
}
