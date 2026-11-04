app [main] { roc: "nightly-2026-11-01-48d3369", pf: platform "../../main.roc" }

import pf.Elem
import pf.Html
import pf.Rows
import pf.Ui
import pf.Val

Item : { id : Str, name : Str, qty : U64 }

Group : { id : Str, title : Str, items : Rows(Item) }

Model : { groups : Rows(Group), next : U64 }

GroupCtx : Ui.Site(Ui.Root, Group)

ItemCtx : Ui.Site(GroupCtx, Item)

empty_items : Rows(Item)
empty_items = Rows.empty(|item| item.id)

## Edit one group's items by key.
edit_group : Model, Str, (Rows(Item) -> Rows(Item)) -> Model
edit_group = |model, group_id, edit|
	match Rows.get_key(model.groups, group_id) {
		Ok(group) => { ..model, groups: Rows.apply(model.groups, [SetKey({ key: group_id, item: { ..group, items: edit(group.items) } })]) ?? model.groups }
		Err(_) => model
	}

add_item : Model, Str -> Model
add_item = |model, group_id| {
	id = "item-${model.next.to_str()}"
	next_model = edit_group(model, group_id, |items| Rows.apply(items, [Append([{ id, name: "New", qty: 1 }])]) ?? items)
	{ ..next_model, next: model.next + 1 }
}

## An item handler needs both keys: the inner row's and the enclosing group's.
## They arrive together as one context value read when the event fires.
remove_item : Model, { group : Str, item : Str } -> Model
remove_item = |model, { group, item }| edit_group(model, group, |items| Rows.apply(items, [RemoveKey(item)]) ?? items)

item_view : Ui.State(Model), Ui.RowRef(GroupCtx, Item), Ui.RowRef(Ui.Root, Group) -> Elem(ItemCtx)
item_view = |model, item, group| {
	keys = { group: item.outer(group.key()), item: item.key() }.Val
	Html.element(
		"li",
		[],
		[
			Html.text_s(item.field(|value| value.name)),
			Html.text(" in "),
			## A value of the enclosing row, lifted explicitly into this row.
			Html.text_s(item.outer(group.field(|value| value.title))),
			Html.text_s(item.field(|value| " x${value.qty.to_str()}")),
			Html.button("Remove", model.update_by(keys, remove_item)),
		],
	)
}

group_view : Ui.State(Model), Ui.RowRef(Ui.Root, Group) -> Elem(GroupCtx)
group_view = |model, group|
	Html.element(
		"section",
		[],
		[
			Html.element("h2", [], [Html.text_s(group.field(|value| value.title))]),
			Html.button("Add item", model.update_by(group.key(), add_item)),
			Html.element("ul", [], [Ui.each(group.field(|value| value.items), |item| item_view(model, item, group))]),
		],
	)

main : () -> Elem(Ui.Root)
main = || {
	groups = Rows.replace_all(Rows.empty(|group| group.id), [{ id: "g1", title: "Fruit", items: empty_items }, { id: "g2", title: "Tools", items: empty_items }]) ?? crash "duplicate group ids"
	Ui.state(
		{ groups, next: 0 },
		|model| Html.div([], [Ui.each(model.signal().map(|value| value.groups), |group| group_view(model, group))]),
	)
}

## The root description builds; each row template is described once, with holes.
expect {
	actual = Elem.platform_describe(main())
	actual == "<div:0>{each <section:0><h2:0>{val}</h2><button:1>Add item</button><ul:0>{each <li:0>{val} in {val}{val}<button:1>Remove</button></li>}</ul></section>}</div>"
}
