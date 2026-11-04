import DUi exposing [Elem, Root, In, Site, State, RowRef, Val]

## The 0b nested-each app on representation D's API.
NegLift := [].{
	Item : { id : Str, name : Str, qty : U64 }

	Group : { id : Str, title : Str, items : List(Item) }

	Model : { groups : List(Group), next : U64 }

	ModelCtx : In(Root, Model)

	GroupCtx : Site(ModelCtx, Group)

	ItemCtx : Site(GroupCtx, Item)

	edit_group : Model, Str, (List(Item) -> List(Item)) -> Model
	edit_group = |model, group_id, edit| {
		groups: model.groups.map(|g| if g.id == group_id { id: g.id, title: g.title, items: edit(g.items) } else g),
		next: model.next,
	}

	add_item : Model, Str -> Model
	add_item = |model, group_id| {
		id = "item-${model.next.to_str()}"
		next_model = NegLift.edit_group(model, group_id, |items| items.append({ id, name: "New", qty: 1 }))
		{ groups: next_model.groups, next: model.next + 1 }
	}

	## Both keys arrive together as one context value read when the event fires.
	remove_item : Model, { group : Str, item : Str } -> Model
	remove_item = |model, { group, item }| NegLift.edit_group(model, group, |items| items.keep_if(|i| i.id != item))

	## The state handle, the group key and the group title all cross the inner
	## row boundary with `lift_row`.
	item_view : State(GroupCtx, Model), RowRef(GroupCtx, Item), Val(GroupCtx, Str), Val(GroupCtx, Str) -> Elem(ItemCtx)
	item_view = |model, item, group_key, group_title| {
		keys = Val.map2(group_key.lift_row(), item.key(), |group, it| { group, item: it })
		DUi.element(
			"li",
			[],
			[
				DUi.text_v(item.field(|value| value.name)),
				DUi.text(" in "),
				DUi.text_v(group_title),
				DUi.text_v(item.field(|value| " x${value.qty.to_str()}")),
				DUi.button("Remove", model.lift_row().update_by(keys, NegLift.remove_item)),
			],
		)
	}

	group_view : State(ModelCtx, Model), RowRef(ModelCtx, Group) -> Elem(GroupCtx)
	group_view = |model, group| {
		in_group = model.lift_row()
		DUi.element(
			"section",
			[],
			[
				DUi.element("h2", [], [DUi.text_v(group.field(|value| value.title))]),
				DUi.button("Add item", in_group.update_by(group.key(), NegLift.add_item)),
				DUi.element("ul", [], [DUi.each(group.field(|value| value.items), |i| i.id, |item| NegLift.item_view(in_group, item, group.key(), group.field(|value| value.title)))]),
			],
		)
	}

	main : {} -> Elem(Root)
	main = |_| {
		groups = [{ id: "g1", title: "Fruit", items: [] }, { id: "g2", title: "Tools", items: [] }]
		DUi.state(
			{ groups, next: 0 },
			|model| DUi.element("div", [], [DUi.each(model.val().map(|value| value.groups), |g| g.id, |group| NegLift.group_view(model, group))]),
		)
	}
}

expect {
	actual = DUi.describe(NegLift.main({}))
	actual == "{state <div:0>{each <section:0><h2:0>{val}</h2><button:1>Add item</button><ul:0>{each <li:0>{val} in {val}{val}<button:1>Remove</button></li>}</ul></section>}</div>}"
}
