import pf.Engine
import Form
import Preview
import Schema

## The Form Builder's store: the state the whole page shares, held at the
## root and reached from any depth with no `lift` and no prop.
##
## - `schema`: the form's definition, two cells that are written together
##   (`Schema`): `fields`, the field definitions as a table by field number,
##   of which the designer and the preview each draw a view, and `next`,
##   the number the next field added will take.
## - `answers`: what has been typed into the preview, by field number.
##   Nothing draws a list of answers (each preview row reads its own), so
##   it is a plain cell holding a map, not a table.
## - `submissions`: how often the generated form has been submitted.
##
## The fields and the answers are two cells, so the designer is handed one
## and cannot write the other.
##
## The module's one tag is the store's name: it is part of the type of every
## handle, so a cell of another store is a type error here.
AppStore := [FormBuilder].{

	## The store: its name, and its cells with their starting values.
	store = Engine.store(
		AppStore.FormBuilder,
		{
			schema: {
				fields: Engine.table(Form.initial_fields),
				next: Engine.cell(Form.initial_next),
			}.Engine.Cells,
			answers: Engine.cell(Form.no_answers),
			submissions: Engine.cell(0.U64),
		}.Engine.Cells,
	)

	## The handles on the store's cells.
	h = AppStore.store.handles()
}

## The store's fields after `writes`, as their numbers in the form's order.
order_after : List(Engine.Write(_)) -> List(U64)
order_after = |writes| Form.ordered(AppStore.store.after(writes).read(AppStore.h.schema.fields).to_list())

## Adding a field writes it last under the next number, and the number after it as the next one.
expect {
	schema = AppStore.h.schema
	after = AppStore.store.after(Schema.added(schema, { kind: Form.number_kind, number: 3 }))
	label = after.read(schema.fields).get(3).map_ok(|field| field.label)
	actual =
		\\order: ${Str.inspect(Form.ordered(after.read(schema.fields).to_list()))}
		\\label: ${Str.inspect(label)}
		\\next: ${after.read(schema.next).to_str()}
	expected =
		\\order: [1, 2, 3]
		\\label: Ok("Number 3")
		\\next: 4
	actual == expected
}

## A move exchanges two fields, a move past either end writes nothing, and the two moves of one event apply in order.
expect {
	fields = AppStore.h.schema.fields
	up = Schema.moved(fields, { key: 2, toward: Earlier })
	actual =
		\\up: ${Str.inspect(order_after(up))}
		\\past the top: ${Str.inspect(order_after(Schema.moved(fields, { key: 1, toward: Earlier })))}
		\\past the end: ${Str.inspect(order_after(Schema.moved(fields, { key: 2, toward: Later })))}
		\\up and back: ${Str.inspect(order_after(up.concat(Schema.moved(fields, { key: 2, toward: Later }))))}
	expected =
		\\up: [2, 1]
		\\past the top: [1, 2]
		\\past the end: [1, 2]
		\\up and back: [1, 2]
	actual == expected
}

## Deleting a field removes its row and leaves the next number alone, so the number is never given again.
expect {
	schema = AppStore.h.schema
	after = AppStore.store.after(Schema.deleted(schema.fields, 1))
	(Form.ordered(after.read(schema.fields).to_list()), after.read(schema.next)) == ([2], 3)
}

## An answer is written under its field's number, and clearing the answers leaves the fields as they were.
expect {
	answers = AppStore.h.answers
	typed = AppStore.store.after(Preview.answered_text(answers, { key: 1, text: "Ada" }).concat(Preview.answered_flag(answers, { key: 2, flag: True })))
	cleared = typed.after(Preview.cleared(answers))
	actual =
		\\typed: ${Str.inspect(Form.answer_of(typed.read(answers), 1))}, ${Str.inspect(Form.answer_of(typed.read(answers), 2))}
		\\cleared: ${Str.inspect(Form.answer_of(cleared.read(answers), 1))}
		\\fields: ${cleared.read(AppStore.h.schema.fields).len().to_str()}
	expected =
		\\typed: { flag: False, text: "Ada" }, { flag: True, text: "" }
		\\cleared: { flag: False, text: "" }
		\\fields: 2
	actual == expected
}

## Submitting counts a form that can be submitted, and writes nothing for one that cannot.
expect {
	submissions = AppStore.h.submissions
	ready = AppStore.store.after(Preview.submitted(submissions, { fields: 2, problems: 0 }))
	writes = [Preview.submitted(submissions, { fields: 2, problems: 1 }).len(), Preview.submitted(submissions, Form.empty_totals).len()]
	(ready.read(submissions), writes) == (1, [0, 0])
}
