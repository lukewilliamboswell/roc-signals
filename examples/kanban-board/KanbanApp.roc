import pf.Engine exposing [Comp, Elem, In, Root, Row, RowRef, State, Val]
import pf.Html
import Kanban

## Kanban Board on the Roc-owned engine: ported from the previous engine.
##
## Three sources as in the original (board, filter text, WIP limit text),
## each its own state layer. One memoised `derive` computes all four columns'
## views, counts and WIP states from them; each column is the same component
## (one specialisation for all four), whose card buttons route actions out to
## the board through a sink.
KanbanApp := [].{
	C1 : In(Root, Kanban.Board)
	C2 : In(C1, Str)
	C3 : In(C2, Str)
	C4 : In(C3, Columns)

	ColumnProp : { column : Kanban.Column, views : List(Kanban.CardView), count : U64, wip : Kanban.WipState }

	Columns : { backlog : ColumnProp, progress : ColumnProp, review : ColumnProp, done : ColumnProp }

	CardAct : [MoveLeft(Str), MoveRight(Str), MoveUp(Str), MoveDown(Str), Flag(Str), Delete(Str)]

	apply_card : Kanban.Board, CardAct -> Kanban.Board
	apply_card = |b, act| match act {
		MoveLeft(k) => Kanban.move_across(b, k, Leftward)
		MoveRight(k) => Kanban.move_across(b, k, Rightward)
		MoveUp(k) => Kanban.move_within(b, k, Upward)
		MoveDown(k) => Kanban.move_within(b, k, Downward)
		Flag(k) => Kanban.flag_card(b, k)
		Delete(k) => Kanban.delete_card(b, k)
	}

	column_prop : List(Kanban.Card), Str, Kanban.Limit, Kanban.Column -> ColumnProp
	column_prop = |cards, query, limit, column| {
		group = Kanban.cards_in(cards, column)
		views = Kanban.column_views(group, column).keep_if(|v| Kanban.matches_filter(v, query))
		count = group.len()
		{ column, views, count, wip: Kanban.WipState.of(count, limit) }
	}

	columns_of : List(Kanban.Card), Str, Str -> Columns
	columns_of = |cards, filter, wip| {
		q = filter.trim()
		l = Kanban.Limit.from_str(wip)
		{
			backlog: KanbanApp.column_prop(cards, q, l, Backlog),
			progress: KanbanApp.column_prop(cards, q, l, InProgress),
			review: KanbanApp.column_prop(cards, q, l, Review),
			done: KanbanApp.column_prop(cards, q, l, Done),
		}
	}

	## ------------------------------------------------------------------
	## Column component.

	CC : Comp(ColumnProp, CardAct)

	icon_button : Str, Str, Str, Val(Row(CC, Kanban.CardView), Bool), Engine.Handler(Row(CC, Kanban.CardView)), Val(Row(CC, Kanban.CardView), Str) -> Elem(Row(CC, Kanban.CardView))
	icon_button = |glyph, label, cls, disabled, h, key| {
		name = key.map(|k| "${label}: ${k}")
		Engine.element("button", [Engine.attr("type", "button"), Engine.attr_v("aria-label", name), Engine.attr_v("title", name), Engine.class(cls), Html.flag("disabled", disabled), Engine.on_click(h)], [Engine.text(glyph)])
	}

	card_row : State(CC, List(CardAct)), RowRef(CC, Kanban.CardView) -> Elem(Row(CC, Kanban.CardView))
	card_row = |out0, row| {
		out = out0.lift_row()
		key = row.key()
		icon = "button button-sm w-8 justify-center px-0"
		Engine.element(
			"section",
			[Engine.attr_v("aria-label", key), Engine.class("card min-w-0"), Engine.attr_v("data-card", key)],
			[
				Html.div(
					"flex items-start justify-between gap-2",
					[
						Engine.element("h3", [Engine.class("card-title min-w-0")], [Engine.text_v(key)]),
						Engine.when(
							row.field(|v| v.flags > 0),
							|| Html.p_v(row.field(|v| if (v.flags == 1) "1 flag" else "${v.flags.to_str()} flags"), [Engine.class("badge badge-warn shrink-0"), Engine.test_id_v(key.map(|k| "card-flags-${k}"))]),
							|| Engine.text(""),
						),
					],
				),
				Html.p_v(row.field(|v| "${v.position.to_str()} of ${v.total.to_str()} in ${Kanban.Column.to_str(v.column)}"), [Engine.class("hint numeric"), Engine.test_id_v(key.map(|k| "card-position-${k}"))]),
				Html.div(
					"flex items-center gap-1",
					[
						KanbanApp.icon_button("←", "Move left", icon, row.field(|v| !v.can_left), out.push_by(key, |k| MoveLeft(k)), key),
						KanbanApp.icon_button("→", "Move right", icon, row.field(|v| !v.can_right), out.push_by(key, |k| MoveRight(k)), key),
						KanbanApp.icon_button("↑", "Move up", icon, row.field(|v| v.is_first), out.push_by(key, |k| MoveUp(k)), key),
						KanbanApp.icon_button("↓", "Move down", icon, row.field(|v| v.is_last), out.push_by(key, |k| MoveDown(k)), key),
						KanbanApp.icon_button("⚑", "Flag", icon, Engine.const(False), out.push_by(key, |k| Flag(k)), key),
						KanbanApp.icon_button("✕", "Delete", "button-danger button-sm w-8 justify-center px-0 ml-auto", Engine.const(False), out.push_by(key, |k| Delete(k)), key),
					],
				),
			],
		)
	}

	## Compiler workaround: a local closure here that captures `cp` (in a
	## component body with an `each` over a record item) makes monotype
	## lowering take ~100 s and 6 GB. A top-level function capturing nothing
	## does not. https://github.com/roc-lang/roc/issues/12869. Remove once the
	## pinned compiler is fixed.
	slug_of : Val(CC, ColumnProp), Str -> Val(CC, Str)
	slug_of = |cp, prefix| cp.map(|p| "${prefix}-${Kanban.Column.slug(p.column)}")

	column_view : Val(CC, ColumnProp), State(CC, List(CardAct)) -> Elem(CC)
	column_view = |cp, out| {
		heading = cp.map(|p| Kanban.Column.to_str(p.column))
		matching = cp.map(|p| p.views.len())
		Engine.element(
			"section",
			[Engine.attr_v("aria-label", heading), Engine.class("panel min-w-0"), Engine.attr_v("data-wip", cp.map(|p| Kanban.WipState.attr(p.wip)))],
			[
				Html.div(
					"panel-head",
					[
						Html.div(
							"flex min-w-0 items-baseline gap-2",
							[
								Engine.element("h2", [Engine.class("card-title")], [Engine.text_v(heading)]),
								Html.p_v(cp.map(|p| if (p.count == 1) "1 card" else "${p.count.to_str()} cards"), [Engine.class("hint numeric"), Engine.test_id_v(KanbanApp.slug_of(cp, "count"))]),
							],
						),
						Html.p_v(cp.map(|p| Kanban.WipState.to_str(p.wip)), [Engine.class_v(cp.map(|p| Kanban.WipState.class(p.wip))), Engine.test_id_v(KanbanApp.slug_of(cp, "wip"))]),
					],
				),
				Html.div(
					"panel-body",
					[
						Html.p_v(matching.map(|n| "${n.to_str()} shown"), [Engine.class("hint numeric"), Engine.test_id_v(KanbanApp.slug_of(cp, "matching"))]),
						Engine.each(cp.map(|p| p.views), |v| v.title, |row| KanbanApp.card_row(out, row)),
						Engine.when(
							matching.map(|n| n == 0),
							|| Engine.element("p", [Engine.class("empty-state"), Engine.test_id_v(KanbanApp.slug_of(cp, "empty"))], [Engine.text("No cards")]),
							|| Engine.text(""),
						),
					],
				),
			],
		)
	}

	## ------------------------------------------------------------------
	## Page.

	labelled_field : Str, Str, Elem(ctx) -> Elem(ctx)
	labelled_field = |label, classes, control| Html.div("field ${classes}", [Html.p(label, "field-label"), control])

	stat_tile : Str, Val(ctx, Str), Str -> Elem(ctx)
	stat_tile = |label, value, id| Html.div("stat", [Html.p(label, "stat-label"), Html.p_v(value, [Engine.class("stat-value"), Engine.test_id(id)])])

	page : State(C4, Kanban.Board), State(C4, Str), State(C4, Str), Val(C4, Columns) -> Elem(C4)
	page = |board, filter, wip, cols| {
		bv = board.val()
		status = bv.map(Kanban.add_status)
		all = cols.map(|c| [c.backlog, c.progress, c.review, c.done])
		over_count = all.map(|l| l.count_if(|c| Kanban.WipState.is_over(c.wip)))
		snk = Engine.sink(board, KanbanApp.apply_card)
		Html.div(
			"app-shell app-shell-wide",
			[
				Html.section(
					"Kanban Board",
					"app-header",
					[
						Html.h1("Kanban Board", "app-title"),
						Html.p("Move cards across columns, reorder within a column, filter by title, and watch derived per-column counts and WIP limits.", "app-subtitle"),
					],
				),
				Html.section(
					"Board controls",
					"panel grid gap-4 p-5",
					[
						Html.div(
							"toolbar",
							[
								KanbanApp.labelled_field("Filter cards", "min-w-0 flex-1 basis-56", Html.text_input(Engine.const("Filter cards"), "text", filter.val(), [Engine.class("input"), Engine.attr("placeholder", "Search titles, e.g. billing")], filter.set_value(|_, v| v))),
								KanbanApp.labelled_field("WIP limit", "w-28 shrink-0", Html.text_input(Engine.const("WIP limit"), "number", wip.val(), [Engine.class("input"), Engine.attr("placeholder", "3"), Engine.attr("min", "0")], wip.set_value(|_, v| v))),
								KanbanApp.labelled_field(
									"New card title",
									"min-w-0 flex-1 basis-56",
									Html.text_input(
										Engine.const("New card title"),
										"text",
										bv.map(|b| b.draft),
										[Engine.class("input"), Engine.attr("placeholder", "Write release notes")],
										board.set_value(
											|b, v| {
												{ cards, draft: _ } = b
												{ cards, draft: v }
											},
										),
									),
								),
								Engine.element("button", [Engine.attr("type", "button"), Engine.class("button-primary shrink-0"), Html.flag("disabled", bv.map(|b| !Kanban.can_add(b))), Engine.on_click(board.update(Kanban.add_card))], [Engine.text("Add card")]),
							],
						),
						Html.p_v(status.map(Kanban.AddStatus.to_str), [Engine.class_v(status.map(Kanban.AddStatus.class)), Engine.test_id("add-status")]),
					],
				),
				Html.section(
					"Board summary",
					"panel grid gap-4 p-5",
					[
						Html.div(
							"stat-grid",
							[
								KanbanApp.stat_tile("Board total", bv.map(|b| b.cards.len().to_str()), "board-total"),
								KanbanApp.stat_tile("Matching filter", all.map(|l| l.fold(0, |n, c| n + c.views.len()).to_str()), "board-matching"),
								KanbanApp.stat_tile("Columns over WIP", over_count.map(|n| n.to_str()), "board-over"),
							],
						),
						Engine.when(
							over_count.map(|n| n > 0),
							|| Html.p("Rebalance the board: at least one column is over its WIP limit.", "notice notice-warn"),
							|| Engine.text(""),
						),
					],
				),
				Html.div(
					"grid gap-4 md:grid-cols-2 xl:grid-cols-4",
					[
						Engine.component(cols.map(|c| c.backlog), snk, KanbanApp.column_view),
						Engine.component(cols.map(|c| c.progress), snk, KanbanApp.column_view),
						Engine.component(cols.map(|c| c.review), snk, KanbanApp.column_view),
						Engine.component(cols.map(|c| c.done), snk, KanbanApp.column_view),
					],
				),
			],
		)
	}

	## The program `main.roc` binds for the browser module and the native spec
	## runner, and `main-fuzz.roc` drives on the fuzz platform.
	program : Engine.Program
	program = Engine.program(|| KanbanApp.main({}))

	main : {} -> Elem(Root)
	main = |_| KanbanApp.main_with(Kanban.initial_board)

	main_with : Kanban.Board -> Elem(Root)
	main_with = |board0| Engine.state(
		board0,
		|board| Engine.state(
			"",
			|filter| Engine.state(
				"1",
				|wip| {
					bd = board.lift().lift()
					fl = filter.lift()
					cols = bd.val().map2(fl.val().map2(wip.val(), |f, w| (f, w)), |b, (f, w)| KanbanApp.columns_of(b.cards, f, w))
					Engine.derive(cols, |cv| KanbanApp.page(bd.lift(), fl.lift(), wip.lift(), cv))
				},
			),
		),
	)
}
