import pf.Engine exposing [Elem, Signal, State]
import pf.Html
import pf.Table

## A league table: players held by key in a table, drawn as a sorted,
## filtered window of it.
Scores := [League].{

	# region table
	Player : { name : Str, team : [Red, Blue], points : I64 }

	## The players a league starts with, each under its key.
	roster : List({ key : U64, row : Player })
	roster = [
		{ key: 1, row: { name: "Ada", team: Red, points: 30 } },
		{ key: 2, row: { name: "Ben", team: Blue, points: 25 } },
		{ key: 3, row: { name: "Cy", team: Red, points: 20 } },
		{ key: 4, row: { name: "Di", team: Blue, points: 15 } },
		{ key: 5, row: { name: "Eve", team: Red, points: 10 } },
		{ key: 6, row: { name: "Flo", team: Blue, points: 5 } },
	]

	## What the board shows: which players, in which order. Plain data,
	## which a view compares to know when to build itself again.
	Listing : { show : [Everyone, Team([Red, Blue])], order : [Highest, Lowest] }

	## The store. `players` is a table. It and the key the next player
	## takes are one group, so one generated write starts both again.
	store = Engine.store(
		Scores.League,
		{
			league: {
				players: Engine.table(Scores.roster),
				next: Engine.cell(7.U64),
			}.Engine.Cells.with_reset(|described, reset| { players: described.players, next: described.next, reset }),
			listing: Engine.cell({ show: Everyone, order: Highest }),
			window: Engine.cell({ start: 0.U64, count: 3.U64 }),
			scroll_window: Engine.cell({ start: 0.U64, count: 3.U64 }),
			scrolled: Engine.cell(False),
		}.Engine.Cells,
	)

	## The store's cells.
	cells = Scores.store.cells()
	# endregion table

	program : Engine.Program
	program = Engine.program_store({ storage_keys: [], max_inflight: 32 }, |_boot| Scores.store, |_boot| Scores.view({}))

	# region plan
	## Where a player stands in a listing's order: the number the order goes
	## by, then the key, so that no two players tie.
	Place : { rank : I64, key : U64 }

	## How a listing selects and orders players.
	plan : Listing -> Engine.QueryPlan(U64, Player, Place)
	plan = |{ show, order }| {
		keep: |_, player| match show {
			Everyone => True
			Team(team) => player.team == team
		},
		sort: |key, player| match order {
			Highest => { rank: 0 - player.points, key }
			Lowest => { rank: player.points, key }
		},
		compare: before,
	}
	# endregion plan

	# region board
	## The board: three rows of the listing's order, from where the window
	## starts.
	board : {} -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	board = |{}|
		Html.ul(
			[],
			[
				Engine.table_view(
					Scores.cells.league.players,
					{ query: Scores.cells.listing.signal(), plan: Scores.plan, window: Scores.cells.window.signal() },
					|key, player| Scores.row(key, player),
				),
			],
		)
	# endregion board

	# region scroll
	## This second board follows its scrollbar. The spacer uses the table's
	## whole row count, so changing the drawn window never moves the scrollbar.
	scroll_board : {} -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	scroll_board = |_args| Engine.element(
		"div",
		[
			Html.aria_label("Scrolled scores"),
			Engine.attr("style", "height:84px;overflow:auto;overflow-anchor:none;position:relative"),
			Html.on_scroll(Engine.handle(|position| [Scores.cells.scroll_window.set({ start: position.top.to_u64() // 28, count: 3 })])),
		],
		[
			Engine.element(
				"div",
				[Engine.attr_s("style", Scores.cells.league.players.signal().map(|table| "height:${(table.len() * 28).to_str()}px;position:relative"))],
				[
					Engine.element(
						"div",
						[Engine.attr_s("style", Scores.cells.scroll_window.signal().map(|window| "position:absolute;top:${(window.start * 28).to_str()}px;width:100%"))],
						[
							Engine.table_view(
								Scores.cells.league.players,
								{ query: Engine.const({ show: Everyone, order: Highest }), plan: Scores.plan, window: Scores.cells.scroll_window.signal() },
								|_key, player| Html.p_s(player.signal().map(|held| "Scrolled ${held.name} ${held.points.to_str()}"), [Engine.attr("style", "height:28px;line-height:28px;margin:0")]),
							),
						],
					),
				],
			),
		],
	)
	# endregion scroll

	# region row
	## One row of the board. `player` is a `State` of this row: reading it
	## reads the row at this key, and writing it writes that row and no
	## other. Removing the row is a write of the table, so it is a decision
	## over the table's cell.
	row : Signal(r, U64), State(r, Player) -> Elem(r)
		where [r.store : () -> Engine.Reach(r, _)]
	row = |key, player| {
		name = player.signal().map(|held| held.name)
		# region cheers
		# How often this row was cheered: state of the row on the page, which
		# the table knows nothing of.
		cheer = Engine.state(
			0.U64,
			|cheers| Html.button_s(
				cheers.signal().map2(name.lift(), |count, who| "Cheer ${who} (${count.to_str()})"),
				[],
				cheers.update(|count| count + 1),
			),
		)
		# endregion cheers
		Html.li(
			[],
			[
				Html.span_s(player.signal().map(|held| "${held.name} ${held.points.to_str()}"), []),
				Html.button_s(name.map(|who| "Point to ${who}"), [], player.update(|held| { ..held, points: held.points + 1 })),
				Html.button_s(name.map(|who| "Remove ${who}"), [], Engine.handle_by(key, |id, _| [Scores.cells.league.players.update(|table| table.remove(id))])),
				cheer,
			],
		)
	}
	# endregion row

	# region writes
	## What "Add player" writes, given the key the next player takes: the
	## new row, and the key after it.
	joined : U64 -> List(Engine.Write(_))
	joined = |key| [
		Scores.cells.league.players.update(|table| table.insert(key, { name: "Player ${key.to_str()}", team: Red, points: 0 })),
		Scores.cells.league.next.set(key + 1),
	]

	## A point to each of `keys`, as that many keyed writes in one event. A
	## fold over the keys rather than a `while` loop over a `var` holding
	## the table, which copies the table on every iteration in optimised
	## builds (roc-lang/roc#12971).
	awarded : Table(U64, Player), List(U64) -> Table(U64, Player)
	awarded = |table, keys| keys.fold(table, |held, key| held.update(key, |player| { ..player, points: player.points + 1 }))

	## What choosing who is shown writes: the listing, and the window back at
	## the top of the new order.
	shown : [Everyone, Team([Red, Blue])] -> List(Engine.Write(_))
	shown = |show| [
		Scores.cells.listing.update(|listing| { ..listing, show }),
		Scores.cells.window.update(|window| { ..window, start: 0 }),
	]
	# endregion writes

	# region toolbar
	## The buttons. Each one's handler is a decision over the store's cells:
	## the listing, the window, or the table itself. A transition that needs
	## nothing from the event is a list of writes (`Engine.does`).
	toolbar : {} -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	toolbar = |{}| {
		players = Scores.cells.league.players
		window = Scores.cells.window
		Html.div(
			"toolbar",
			[
				Html.button("Everyone", [], Engine.does(Scores.shown(Everyone))),
				Html.button("Red team", [], Engine.does(Scores.shown(Team(Red)))),
				Html.button("Lowest first", [], Engine.does([Scores.cells.listing.update(|listing| { ..listing, order: Lowest })])),
				Html.button("Next three", [], Engine.does([window.update(|at| { ..at, start: at.start + 3 })])),
				Html.button("First three", [], Engine.does([window.update(|at| { ..at, start: 0 })])),
				Html.button("Add player", [], Engine.handle_by(Scores.cells.league.next.signal(), |key, _| Scores.joined(key))),
				Html.button("Point to the first three", [], Engine.does([players.update(|table| Scores.awarded(table, [1, 2, 3]))])),
				Html.button("Clear the points", [], Engine.does([players.update(|table| table.update_all(|_, player| { ..player, points: 0 }))])),
				Html.button("New season", [], Engine.does([Scores.cells.league.reset])),
				Html.button("Show scrolled scores", [], Engine.does([Scores.cells.scrolled.set(True)])),
			],
		)
	}
	# endregion toolbar

	# region podium
	## The three players with the most points, whatever the board shows: a
	## second view of the same table, with a query and a window that never
	## change.
	podium : {} -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	podium = |{}|
		Engine.element(
			"p",
			[Engine.test_id("podium")],
			[
				Engine.table_view(
					Scores.cells.league.players,
					{ query: Engine.const({ show: Everyone, order: Highest }), plan: Scores.plan, window: Engine.const({ start: 0, count: 3 }) },
					|_key, player| Html.span_s(player.signal().map(|held| "${held.name} "), []),
				),
			],
		)
	# endregion podium

	# region reader
	## How many players the league has: a plain reader of the table's cell,
	## evaluated on every write of the table.
	size : {} -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	size = |{}| Html.p_s(Scores.cells.league.players.signal().map(|table| "${table.len().to_str()} players"), [Engine.test_id("size")])
	# endregion reader

	## The page: the buttons, the count, the podium and the board.
	view : {} -> Elem(Engine.StoreRoot(_))
	view = |{}| Html.div("scores", [Scores.toolbar({}), Scores.size({}), Scores.podium({}), Scores.board({}), Engine.when(Scores.cells.scrolled.signal(), || Scores.scroll_board({}), || Engine.text(""))])
}

## The order of two places: by rank, then by key. `Same` only for a row's
## own place.
before : Scores.Place, Scores.Place -> [Before, Same, After]
before = |a, b|
	if a.rank < b.rank {
		Before
	} else if a.rank > b.rank {
		After
	} else if a.key < b.key {
		Before
	} else if a.key > b.key {
		After
	} else {
		Same
	}

# region expects
## A new player takes the next key, and the key after it becomes the next.
expect {
	after = Scores.store.after(Scores.joined(7))
	league = Scores.cells.league

	actual =
		\\players: ${after.read(league.players).len().to_str()}
		\\new: ${Str.inspect(after.read(league.players).get(7).map_ok(|player| player.name))}
		\\next: ${after.read(league.next).to_str()}
	expected =
		\\players: 7
		\\new: Ok("Player 7")
		\\next: 8
	actual == expected
}

## A new season starts the league again at the roster it was described
## with, whatever was added or scored.
expect {
	league = Scores.cells.league
	played = Scores.store.after(Scores.joined(7)).after([league.players.update(|table| Scores.awarded(table, [1, 7]))])
	again = played.after([league.reset])

	actual =
		\\played: ${played.read(league.players).len().to_str()} players, Ada on ${Str.inspect(played.read(league.players).get(1).map_ok(|player| player.points))}
		\\again: ${again.read(league.players).len().to_str()} players, Ada on ${Str.inspect(again.read(league.players).get(1).map_ok(|player| player.points))}, next ${again.read(league.next).to_str()}
	expected =
		\\played: 7 players, Ada on Ok(31)
		\\again: 6 players, Ada on Ok(30), next 7
	actual == expected
}
# endregion expects
