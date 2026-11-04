app [main] { roc: "nightly-2026-11-01-48d3369", pf: platform "../../main.roc" }

import pf.Elem
import pf.Html
import pf.Rows
import pf.Ui

Item : { id : Str, name : Str }

Group : { id : Str, title : Str, items : Rows(Item) }

GroupCtx : Ui.Site(Ui.Root, Group)

ItemCtx : Ui.Site(GroupCtx, Item)

## Negative: an inner row reads the enclosing row's field without `item.outer`,
## with the row templates annotated as an author following style.md would.
item_view : Ui.RowRef(GroupCtx, Item), Ui.RowRef(Ui.Root, Group) -> Elem(ItemCtx)
item_view = |item, group| Html.element("li", [], [Html.text_s(item.field(|value| value.name)), Html.text_s(group.field(|value| value.title))])

group_view : Ui.RowRef(Ui.Root, Group) -> Elem(GroupCtx)
group_view = |group| Ui.each(group.field(|value| value.items), |item| item_view(item, group))

main : () -> Elem(Ui.Root)
main = || {
	empty : Rows(Group)
	empty = Rows.empty(|group| group.id)
	Ui.state(empty, |model| Ui.each(model.signal(), group_view))
}
