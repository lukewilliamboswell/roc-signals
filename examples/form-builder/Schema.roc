import pf.Engine exposing [Cell, Elem, Row, Signal, State, Table]
import Form

## The form's schema as a store holds it: the fields as a table by number,
## the number the next field takes, the transitions that write them, and
## the list that draws one row per field in the form's order.
##
## The designer and the preview each draw that list with rows of their own,
## over cells of whichever store holds them, so this module never imports
## the app's store. What a field is and how a move is decided are `Form`'s.
Schema := [].{

	## The fields, by number. A field's place in the form's order is a
	## field of its row (`Form.Field`), which the list sorts by.
	Fields : Table(U64, Form.Field)

	## The schema's cells, in a store whose type is `st`:
	## the fields, and the number the next field added will take.
	Cells(st) : { fields : Cell(st, Fields), next : Cell(st, U64) }

	## What "Add" writes for a field of `kind`, given the number the next
	## field takes: the new field under that number, last in the form, and
	## the number after it as the next one. The two are written together so
	## that no number is ever given twice.
	added : Cells(st), { kind : Form.Kind, number : U64 } -> List(Engine.Write(st))
	added = |schema, { kind, number }| [
		schema.fields.update(|table| table.insert(number, Form.new_field(kind, number))),
		schema.next.set(number + 1),
	]

	## What a field's "Move up" and "Move down" write: the field and the
	## one beside it, with their places exchanged. `Form` decides a move
	## from a listing of the fields, which is taken inside the write, from
	## the table the write is handed, so the table keeps one holder and is
	## changed in place.
	moved : Cell(st, Fields), { key : U64, toward : [Earlier, Later] } -> List(Engine.Write(st))
	moved = |fields, move| [fields.update(|table| table.apply(Form.move_field(table.to_list(), move)))]

	## What a field's "Delete" writes: the field gone. Its answer stays
	## behind in the preview's answers, where no field will ask for it.
	deleted : Cell(st, Fields), U64 -> List(Engine.Write(st))
	deleted = |fields, key| [fields.update(|table| table.remove(key))]

	## Whether the form has any field.
	has_fields : Cell(st, Fields) -> Signal(ctx, Bool)
		where [ctx.store : () -> Engine.Reach(ctx, st)]
	has_fields = |fields| fields.signal().map(|table| table.len() > 0)

	## One row for each field, in the form's order: a view of the fields'
	## table. `template` is handed the field's number and its row. A form
	## is short and drawn whole, so the view draws every row.
	each_field : Cell(st, Fields), (Signal(Row(ctx, U64), U64), State(Row(ctx, U64), Form.Field) -> Elem(Row(ctx, U64))) -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, st)]
	each_field = |fields, template| Engine.table_view(
		fields,
		{
			query: Engine.const({}),
			plan: |query| Engine.sort_by(Form.plan(query)),
			window: Engine.const(Engine.every_row),
		},
		template,
	)
}
