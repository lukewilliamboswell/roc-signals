import pf.Engine exposing [Elem, State, Val]
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
			}.Engine.Cells.with_reset(|handles, reset| { players: handles.players, next: handles.next, reset }),
			listing: Engine.cell({ show: Everyone, order: Highest }),
			window: Engine.cell({ start: 0.U64, count: 3.U64 }),
		}.Engine.Cells,
	)

	## The handles on the store's cells.
	h = Scores.store.handles()
	# endregion table

	program : Engine.Program
	program = Engine.program_store({ storage_keys: [], max_inflight: 32 }, |_boot| Scores.store, |_boot| Scores.view({}))

	# region plan
	## Where a player stands in a listing's order: the number the order goes
	## by, then the key, so that no two players tie.
	Place : { rank : I64, key : U64 }

	## How a listing selects and orders players.
	plan : Listing -> Engine.Query(U64, Player, Place)
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
				Engine.each_view(
					Scores.h.league.players,
					{ query: Scores.h.listing.val(), plan: Scores.plan, window: Scores.h.window.val() },
					|key, player| Scores.row(key, player),
				),
			],
		)
	# endregion board

	# region row
	## One row of the board. `player` is a `State` of this row: reading it
	## reads the row at this key, and writing it writes that row and no
	## other. Removing the row is a write of the table, so it is a decision
	## over the table's cell.
	row : Val(r, U64), State(r, Player) -> Elem(r)
		where [r.store : () -> Engine.Reach(r, _)]
	row = |key, player| {
		name = player.val().map(|held| held.name)
		# region cheers
		# How often this row was cheered: state of the row on the page, which
		# the table knows nothing of.
		cheer = Engine.state(
			0.U64,
			|cheers| Html.button_v(
				cheers.val().map2(name.lift(), |count, who| "Cheer ${who} (${count.to_str()})"),
				[],
				cheers.update(|count| count + 1),
			),
		)
		# endregion cheers
		Html.li(
			[],
			[
				Html.span_v(player.val().map(|held| "${held.name} ${held.points.to_str()}"), []),
				Html.button_v(name.map(|who| "Point to ${who}"), [], player.update(|held| { ..held, points: held.points + 1 })),
				Html.button_v(name.map(|who| "Remove ${who}"), [], Engine.handle_by(key, |id, _| [Scores.h.league.players.change(|table| table.remove(id))])),
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
		Scores.h.league.players.change(|table| table.insert(key, { name: "Player ${key.to_str()}", team: Red, points: 0 })),
		Scores.h.league.next.put(key + 1),
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
		Scores.h.listing.change(|listing| { ..listing, show }),
		Scores.h.window.change(|window| { ..window, start: 0 }),
	]
	# endregion writes

	# region toolbar
	## The buttons. Each one's handler is a decision over the store's cells:
	## the listing, the window, or the table itself. A transition that needs
	## nothing from the event is a list of writes (`Engine.does`).
	toolbar : {} -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	toolbar = |{}| {
		players = Scores.h.league.players
		window = Scores.h.window
		Html.div(
			"toolbar",
			[
				Html.button("Everyone", [], Engine.does(Scores.shown(Everyone))),
				Html.button("Red team", [], Engine.does(Scores.shown(Team(Red)))),
				Html.button("Lowest first", [], Engine.does([Scores.h.listing.change(|listing| { ..listing, order: Lowest })])),
				Html.button("Next three", [], Engine.does([window.change(|at| { ..at, start: at.start + 3 })])),
				Html.button("First three", [], Engine.does([window.change(|at| { ..at, start: 0 })])),
				Html.button("Add player", [], Engine.handle_by(Scores.h.league.next.val(), |key, _| Scores.joined(key))),
				Html.button("Point to the first three", [], Engine.does([players.change(|table| Scores.awarded(table, [1, 2, 3]))])),
				Html.button("Clear the points", [], Engine.does([players.change(|table| table.update_all(|_, player| { ..player, points: 0 }))])),
				Html.button("New season", [], Engine.does([Scores.h.league.reset])),
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
				Engine.each_view(
					Scores.h.league.players,
					{ query: Engine.const({ show: Everyone, order: Highest }), plan: Scores.plan, window: Engine.const({ start: 0, count: 3 }) },
					|_key, player| Html.span_v(player.val().map(|held| "${held.name} "), []),
				),
			],
		)
	# endregion podium

	# region reader
	## How many players the league has: a plain reader of the table's cell,
	## evaluated on every write of the table.
	size : {} -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	size = |{}| Html.p_v(Scores.h.league.players.val().map(|table| "${table.len().to_str()} players"), [Engine.test_id("size")])
	# endregion reader

	## The page: the buttons, the count, the podium and the board.
	view : {} -> Elem(Engine.StoreRoot(_))
	view = |{}| Html.div("scores", [Scores.toolbar({}), Scores.size({}), Scores.podium({}), Scores.board({})])
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
	league = Scores.h.league

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
	league = Scores.h.league
	played = Scores.store.after(Scores.joined(7)).after([league.players.change(|table| Scores.awarded(table, [1, 7]))])
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
