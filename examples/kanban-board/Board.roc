import pf.Engine exposing [Cell, Elem, Handler, Row, Signal, State]
import pf.Html
import pf.Table
import Kanban

## The board as a store holds it and a page draws it: the cards as a table
## by title, the transitions that write them, and the column that draws a
## view of them.
##
## A board is drawn over cells of whichever store holds them (`Props`), so
## this module never imports the app's store. The rules themselves (where
## a moved card lands, which cards close the gap it leaves) are `Kanban`'s:
## a completed drag applies the edits `Kanban` decides and clears its
## gesture together in one turn.
Board := [].{

	## The cards, by title. A card's place in its column is a field of its
	## row (`Kanban.Card`), which each column's view sorts by.
	Cards : Table(Str, Kanban.Card)

	## One gesture owns the drag until it releases or cancels. Remembering its
	## pointer prevents a second finger from moving or ending the first drag.
	Drag := [Idle, Dragging({ title : Str, pointer : U32, over : Kanban.Spot })].{
		is_eq : _
	}

	## The board starts with no gesture in progress.
	idle_drag : Drag
	idle_drag = Idle

	## What a board is drawn over, in a store whose type is `st`: the
	## cards, the filter and WIP limit text, and the active drag.
	Props(st) : { cards : Cell(st, Cards), filter : Cell(st, Str), limit : Cell(st, Str), drag : Cell(st, Drag) }

	## A main-button press starts one drag. Another press while it is active
	## writes nothing, even when it comes from another device or finger.
	started_drag : Cell(st, Drag), { before : Drag, title : Str, pointer : Engine.Pointer } -> List(Engine.Write(st))
	started_drag = |drag, { before, title, pointer }| match (before, pointer.button) {
		(Idle, Main) => [drag.set(Dragging({ title, pointer: pointer.id, over: pointer_spot(pointer) }))]
		_ => []
	}

	## A move writes only when the owning pointer enters another gap. Several
	## points inside the same half of one card therefore perform no engine work.
	moved_drag : Cell(st, Drag), { before : Drag, pointer : Engine.Pointer } -> List(Engine.Write(st))
	moved_drag = |drag, { before, pointer }| match before {
		Dragging(held) if held.pointer == pointer.id => {
			over = pointer_spot(pointer)
			if (over == held.over) [] else [drag.set(Dragging({ ..held, over }))]
		}
		_ => []
	}

	## A release decides the card edits and clears the drag together. The
	## reading holds a listing, never the table itself, so its write keeps the
	## table uniquely owned. A drop on the existing gap writes no card.
	finished_drag : { cards : Cell(st, Cards), drag : Cell(st, Drag) }, { before : Drag, listing : Kanban.Listing, pointer : Engine.Pointer } -> List(Engine.Write(st))
	finished_drag = |cells, { before, listing, pointer }| match before {
		Dragging(held) if held.pointer == pointer.id => {
			edits = Kanban.move_to(listing, { title: held.title, over: pointer_spot(pointer) })
			cleared = cells.drag.set(Idle)
			if (edits.is_empty()) [cleared] else [cells.cards.update(|table| table.apply(edits)), cleared]
		}
		_ => []
	}

	## Cancellation abandons only the active pointer's drag and edits no card.
	cancelled_drag : Cell(st, Drag), { before : Drag, pointer : Engine.Pointer } -> List(Engine.Write(st))
	cancelled_drag = |drag, { before, pointer }| match before {
		Dragging(held) if held.pointer == pointer.id => [drag.set(Idle)]
		_ => []
	}

	## The live announcement names the target lane and place. Lookup is by
	## the table's keys, and lane counts come from the page's existing tally.
	drag_status : Props(st), Signal(ctx, Kanban.Tally) -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, st)]
	drag_status = |props, sizes| Html.p_s(
		{ drag: props.drag.signal(), cards: props.cards.signal(), sizes: sizes }.Engine.Signal.map(|reading| drag_caption(reading.drag, { cards: reading.cards, sizes: reading.sizes })),
		[Engine.attr("aria-live", "polite"), Engine.test_id("drag-status"), Engine.class("hint")],
	)

	## What "Add card" writes for the text of the add form: the card it
	## titles at the end of Backlog, or no card for a draft the form does
	## not accept.
	added : Cell(st, Cards), Str -> List(Engine.Write(st))
	added = |cards, draft| edit(cards, |held| Kanban.add_card(held, draft))

	## What a card's "Move left" and "Move right" write: the card at the
	## end of the neighbouring column, and the cards that were below it one
	## place up.
	moved_across : Cell(st, Cards), { title : Str, toward : [Leftward, Rightward] } -> List(Engine.Write(st))
	moved_across = |cards, move| edit(cards, |held| Kanban.move_across(held, move))

	## What a card's "Move up" and "Move down" write: the card and its
	## neighbour in the column, with their places exchanged.
	moved_within : Cell(st, Cards), { title : Str, toward : [Upward, Downward] } -> List(Engine.Write(st))
	moved_within = |cards, move| edit(cards, |held| Kanban.move_within(held, move))

	## What a card's "Delete" writes: the card gone, and the cards that
	## were below it one place up.
	deleted : Cell(st, Cards), Str -> List(Engine.Write(st))
	deleted = |cards, title| edit(cards, |held| Kanban.delete_card(held, title))

	## The size of each column under the filter as it stands. It reads
	## every card, so mount it once in an `Engine.derive` and read that
	## layer: the count is then taken once for each write of the cards or
	## the filter, and a write that changes no size (a flag, a move inside
	## a column) wakes none of its readers.
	tally : Props(st) -> Signal(ctx, Kanban.Tally)
		where [ctx.store : () -> Engine.Reach(ctx, st)]
	tally = |props| props.cards.signal().map2(
		props.filter.signal(),
		|table, text| {
			filter = text.trim()
			table.fold(Kanban.empty_tally, |counts, title, card| Kanban.counted(counts, { title, card, filter }))
		},
	)

	## One column of the board: its heading, its size against the WIP
	## limit, and a view of the cards' table showing the column's cards
	## that pass the filter, in the order of their places. `sizes` is the
	## board's tally. A column is short, so its view draws every card it
	## keeps.
	lane : Props(st), Kanban.Column, Signal(ctx, Kanban.Tally) -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, st)]
	lane = |props, column, sizes| Engine.derive(
		lane_marker(props, column),
		|marker| {
			size = sizes.lift().map(|counts| Kanban.size_in(counts, column))
			wip = size.map2(props.limit.signal(), |held, text| Kanban.WipState.of(held.cards, Kanban.Limit.from_str(text)))
			heading = Kanban.Column.to_str(column)
			slug = Kanban.Column.slug(column)
			Engine.element(
				"section",
				[Html.aria_label(heading), Engine.class_s(marker.map(|now| if (now.over == Nowhere) "panel min-w-0" else "panel min-w-0 ring-2 ring-blue-500")), Engine.attr_s("data-wip", wip.map(Kanban.WipState.attr))],
				[
					Html.div(
						"panel-head",
						[
							Html.div(
								"flex min-w-0 items-baseline gap-2",
								[
									Html.h2(heading, "card-title"),
									Html.p_s(size.map(|held| if (held.cards == 1) "1 card" else "${held.cards.to_str()} cards"), [Engine.class("hint numeric"), Engine.test_id("count-${slug}")]),
								],
							),
							Html.p_s(wip.map(Kanban.WipState.to_str), [Engine.class_s(wip.map(Kanban.WipState.class)), Engine.test_id("wip-${slug}")]),
						],
					),
					Html.div_attrs(
						[Engine.class("panel-body"), Html.zone("lane:${slug}"), Engine.test_id("lane-${slug}")],
						[
							Html.p_s(size.map(|held| "${held.shown.to_str()} shown"), [Engine.class("hint numeric"), Engine.test_id("matching-${slug}")]),
							Engine.table_view(
								props.cards,
								{
									query: props.filter.signal().map(|text| { column, filter: text.trim() }),
									plan: Kanban.plan,
									window: Engine.const(Engine.every_row),
								},
								# The template is a lambda here, not the result of a
								# helper that returns one (roc-lang/roc#12970).
								|title, card| card_row({ cards: props.cards, drag: props.drag, column, size: size.lift_row(), marker: marker.lift_row() }, title, card),
							),
							Engine.when(
								size.map(|held| held.shown == 0),
								|| Engine.element("p", [Engine.class("empty-state"), Engine.test_id("empty-${slug}")], [Engine.text("No cards")]),
								|| Engine.text(""),
							),
							Engine.element(
								"div",
								[Html.zone("lane:${slug}"), Engine.test_id("lane-end-${slug}"), Engine.class_s(marker.map(|now| if (now.over == EndOf(column)) "hint border-t-2 border-blue-500 py-2" else "hint py-2")), Engine.attr("style", "min-height:32px")],
								[Engine.text("Drop at end")],
							),
						],
					),
				],
			)
		},
	)
}

## The marker carried into one lane. Equality at its derive keeps a drag
## over another lane from waking this lane's rows.
Marker : { source : Str, over : Kanban.Spot }

lane_marker : Board.Props(st), Kanban.Column -> Signal(ctx, Marker)
	where [ctx.store : () -> Engine.Reach(ctx, st)]
lane_marker = |props, column| props.drag.signal().map2(
	props.cards.signal(),
	|drag, cards| match drag {
		Idle => { source: "", over: Nowhere }
		Dragging(held) => {
			source = match cards.get(held.title) {
				Ok(card) if card.column == column => held.title
				_ => ""
			}
			target = match held.over {
				Before(title) | After(title) => cards.get(title).map_ok(|card| card.column)
				EndOf(lane) => Ok(lane)
				Nowhere => Err(Missing)
			}
			{ source, over: if (target == Ok(column)) held.over else Nowhere }
		}
	},
)

pointer_spot : Engine.Pointer -> Kanban.Spot
pointer_spot = |pointer| match pointer.at {
	Outside => Nowhere
	In({ zone, y, .. }) => Kanban.Spot.from_zone(zone, y)
}

drag_caption : Board.Drag, { cards : Board.Cards, sizes : Kanban.Tally } -> Str
drag_caption = |drag, { cards, sizes }| match drag {
	Idle => "Ready to move cards"
	Dragging(held) => {
		card = cards.get(held.title) ?? return "Moving ${held.title} outside the board"
		target = match held.over {
			Before(title) => cards.get(title).map_ok(|row| { column: row.column, place: row.place })
			After(title) => cards.get(title).map_ok(|row| { column: row.column, place: row.place + 1 })
			EndOf(column) => Ok({ column, place: Kanban.size_in(sizes, column).cards })
			Nowhere => Err(Missing)
		}
		match target {
			Ok(gap) => {
				at = Kanban.landing(card, gap)
				"Moving ${held.title} to ${Kanban.Column.to_str(at.column)}, place ${(at.place + 1).to_str()}"
			}
			Err(_) => "Moving ${held.title} outside the board"
		}
	}
}

## One write of the cards: the edits `decide` gives for a listing of them,
## applied to the table as keyed writes, so that each column's view hears
## of exactly the cards a move touched. The listing is taken inside the
## write, from the table the write is handed, so the table keeps one holder
## and is changed in place.
edit : Cell(st, Board.Cards), (Kanban.Listing -> List(Kanban.Edit)) -> List(Engine.Write(st))
edit = |cards, decide| [cards.update(|table| table.apply(decide(table.to_list())))]

## One card in its column's view: its title, its flags, its position line
## and its buttons. `column` is the column the view shows and `size` that
## column's size, so the row reads of the board only its own card: a write
## to another card wakes it only when its column's size changed.
##
## A flag is a write of the row itself. Every other button changes more
## than this card's row, so it is a transition over the cards' cell.
card_row : { cards : Cell(st, Board.Cards), drag : Cell(st, Board.Drag), column : Kanban.Column, size : Signal(Row(ctx, Str), Kanban.Size), marker : Signal(Row(ctx, Str), Marker) }, Signal(Row(ctx, Str), Str), State(Row(ctx, Str), Kanban.Card) -> Elem(Row(ctx, Str))
	where [ctx.store : () -> Engine.Reach(ctx, st)]
card_row = |{ cards, drag, column, size, marker }, title, card| {
	held = card.signal()
	across = |toward| Engine.handle_by(title, |name, _| Board.moved_across(cards, { title: name, toward }))
	within = |toward| Engine.handle_by(title, |name, _| Board.moved_within(cards, { title: name, toward }))
	look = "button button-sm w-8 justify-center px-0"
	Engine.element(
		"section",
		[Html.aria_label_s(title), Html.zone_s(title.map(|name| "card:${name}")), Engine.class_s(marker.map2(title, |now, name| "card min-w-0${if (now.source == name) " opacity-50" else ""}${if (now.over == Before(name)) " border-t-2 border-blue-500" else if (now.over == After(name)) " border-b-2 border-blue-500" else ""}")), Engine.attr_s("data-card", title)],
		[
			Html.div(
				"flex items-start justify-between gap-2",
				[
					Engine.element(
						"span",
						[
							Html.zone_s(title.map(|name| "grip:${name}")),
							Engine.test_id_s(title.map(|name| "grip-${name}")),
							Engine.attr("aria-hidden", "true"),
							Engine.attr("style", "display:inline-flex;width:24px;height:24px;align-items:center;justify-content:center;touch-action:none;user-select:none;cursor:grab"),
							Html.on_pointer_down_capture(Engine.handle_by({ title: title, drag: drag.signal() }.Engine.Signal, |before, pointer| Board.started_drag(drag, { before: before.drag, title: before.title, pointer }))),
							Html.on_pointer_move_paced(Engine.handle_by(drag.signal(), |before, pointer| Board.moved_drag(drag, { before, pointer }))),
							Html.on_pointer_up(Engine.handle_by({ drag: drag.signal(), listing: cards.signal().map(|table| table.to_list()) }.Engine.Signal, |before, pointer| Board.finished_drag({ cards, drag }, { before: before.drag, listing: before.listing, pointer }))),
							Html.on_pointer_cancel(Engine.handle_by(drag.signal(), |before, pointer| Board.cancelled_drag(drag, { before, pointer }))),
						],
						[Engine.text("⠿")],
					),
					Engine.element("h3", [Engine.class("card-title min-w-0")], [Engine.text_s(title)]),
					Engine.when(
						held.map(|now| now.flags > 0),
						|| Html.p_s(held.map(|now| if (now.flags == 1) "1 flag" else "${now.flags.to_str()} flags"), [Engine.class("badge badge-warn shrink-0"), Engine.test_id_s(title.map(|name| "card-flags-${name}"))]),
						|| Engine.text(""),
					),
				],
			),
			Html.p_s(
				held.map2(size, |now, lane_size| "${(now.place + 1).to_str()} of ${lane_size.cards.to_str()} in ${Kanban.Column.to_str(column)}"),
				[Engine.class("hint numeric"), Engine.test_id_s(title.map(|name| "card-position-${name}"))],
			),
			Html.div(
				"flex items-center gap-1",
				[
					card_button({ glyph: "←", action: "Move left", look, title, off: Engine.const(is_edge(Kanban.Column.left(column))) }, across(Leftward)),
					card_button({ glyph: "→", action: "Move right", look, title, off: Engine.const(is_edge(Kanban.Column.right(column))) }, across(Rightward)),
					card_button({ glyph: "↑", action: "Move up", look, title, off: held.map(|now| now.place == 0) }, within(Upward)),
					card_button({ glyph: "↓", action: "Move down", look, title, off: held.map2(size, |now, lane_size| now.place + 1 == lane_size.cards) }, within(Downward)),
					card_button({ glyph: "⚑", action: "Flag", look, title, off: Engine.const(False) }, card.update(Kanban.flag_card)),
					card_button(
						{ glyph: "✕", action: "Delete", look: "button-danger button-sm w-8 justify-center px-0 ml-auto", title, off: Engine.const(False) },
						Engine.handle_by(title, |name, _| Board.deleted(cards, name)),
					),
				],
			),
		],
	)
}

## A card's button: a glyph whose accessible name and tooltip say what it
## does to which card ("Move left: Rotate API keys"), disabled while `off`.
card_button : { glyph : Str, action : Str, look : Str, title : Signal(ctx, Str), off : Signal(ctx, Bool) }, Handler(ctx) -> Elem(ctx)
card_button = |{ glyph, action, look, title, off }, on_press| {
	name = title.map(|card_title| "${action}: ${card_title}")
	Engine.element(
		"button",
		[Engine.attr("type", "button"), Html.aria_label_s(name), Engine.attr_s("title", name), Engine.class(look), Html.disabled(off), Engine.on_click(on_press)],
		[Engine.text(glyph)],
	)
}

## Whether a card has no column to move to on that side.
is_edge : Try(Kanban.Column, [AtEdge]) -> Bool
is_edge = |neighbour|
	match neighbour {
		Ok(_) => False
		Err(AtEdge) => True
	}
