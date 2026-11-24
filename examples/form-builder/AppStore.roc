import pf.Engine
import Definition
import Designer
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
## - `confirm` and `focus`: a page-level deletion choice and its focus post.
## - `preview`: whether submission was attempted, whether its problem summary
##   is wanted, and the address of the first problem to reveal.
## - `storage_status` and `storage_intent`: one browser save or reopen in
##   progress at a time, with a status for the reader.
##
## The designer receives the fields and its confirmation cells, and never
## the answers. The preview receives the answers and feedback cells, and
## reads the fields without redefining them.
##
## The module's one tag is the store's name: it is part of the type of every
## handle, so a cell of another store is a type error here.
AppStore := [FormBuilder].{
	StorageIntent : [Save, Reopen]

	## Only an in-progress save holds encoded text. Its readback confirms
	## that the browser stored the value requested by that save.
	StorageStatus : [Ready, Saving(Str), Reopening, Saved, Reopened, NoSavedDefinition, InvalidSavedDefinition, TooLarge, SaveFailed, ReopenRefused]

	## The fields a form starts with, by field number. A top-level constant
	## is evaluated while compiling, so a number `Form.initial_fields` gave
	## twice would be a compile error naming it.
	initial_fields : Engine.Table(U64, Form.Field)
	initial_fields = match Engine.Table.from_list(Form.initial_fields) {
		Ok(table) => table
		Err(DuplicateKey(key)) => crash "AppStore.initial_fields: the field number ${key.to_str()} is listed twice"
	}

	## The store: its name, and its cells with their starting values.
	store = Engine.store(
		AppStore.FormBuilder,
		{
			schema: {
				fields: Engine.table(AppStore.initial_fields),
				next: Engine.cell(Form.initial_next),
			}.Engine.Cells,
			answers: Engine.cell(Form.no_answers),
			submissions: Engine.cell(0.U64),
			confirm: Engine.cell(Designer.idle),
			focus: Engine.cell(Engine.outbox({})),
			storage_status: Engine.cell(Ready),
			storage_intent: Engine.cell(Engine.outbox({})),
			preview: {
				attempted: Engine.cell(False),
				problems_open: Engine.cell(False),
				reveal: Engine.cell(Engine.outbox({})),
			}.Engine.Cells,
		}.Engine.Cells,
	)

	## The store's cells.
	cells = AppStore.store.cells()

	## Block another storage action until the current one has answered.
	is_storage_busy : AppStore.StorageStatus -> Bool
	is_storage_busy = |status| match status {
		Saving(_) | Reopening => True
		_ => False
	}

	## Give a storage action its pending state and post it in the same turn.
	storage_requested : AppStore.StorageIntent, { status : AppStore.StorageStatus, definition : Definition.Snapshot } -> List(Engine.Write(_))
	storage_requested = |intent, { status, definition }| {
		if AppStore.is_storage_busy(status) {
			return []
		}
		pending = match intent {
			Save => match Definition.encode(definition) {
				Ok(text) => Saving(text)
				Err(TooLarge) => return [AppStore.cells.storage_status.set(TooLarge)]
			}
			Reopen => Reopening
		}
		[AppStore.cells.storage_status.set(pending), AppStore.cells.storage_intent.update(|outbox| outbox.post(intent))]
	}

	## A save issues the command before reading back the slot. A reopen
	## reads the current browser slot without turning that value into boot data.
	storage_plan : AppStore.StorageStatus, AppStore.StorageIntent -> List(Engine.Ask(Str, [Missing, Refused]))
	storage_plan = |status, intent| match (status, intent) {
		(Saving(text), Save) => [Engine.command(StorageSet(Definition.storage_key, text)), Engine.storage_get(Definition.storage_key)]
		(Reopening, Reopen) => [Engine.storage_get(Definition.storage_key)]
		_ => []
	}

	## Replace the schema and reset transient preview state in one turn.
	## Keep this instance's field number monotonic across reinstated definitions.
	storage_answered : { status : AppStore.StorageStatus, next : U64 }, AppStore.StorageIntent, Try(Str, [Missing, Refused]) -> List(Engine.Write(_))
	storage_answered = |{ status, next }, intent, result| match (status, intent) {
		(Saving(text), Save) => [AppStore.cells.storage_status.set(if (result == Ok(text)) Saved else SaveFailed)]
		(Reopening, Reopen) => match result {
			Err(Missing) => [AppStore.cells.storage_status.set(NoSavedDefinition)]
			Err(Refused) => [AppStore.cells.storage_status.set(ReopenRefused)]
			Ok(text) => match Definition.decode(text) {
				Err(InvalidDefinition) => [AppStore.cells.storage_status.set(InvalidSavedDefinition)]
				Err(TooLarge) => [AppStore.cells.storage_status.set(TooLarge)]
				Ok(snapshot) => [
					AppStore.cells.schema.fields.set(snapshot.fields),
					AppStore.cells.schema.next.set(if (next < snapshot.next) snapshot.next else next),
					AppStore.cells.answers.set(Form.no_answers),
					AppStore.cells.submissions.set(0),
					AppStore.cells.confirm.set(Designer.idle),
					AppStore.cells.preview.attempted.set(False),
					AppStore.cells.preview.problems_open.set(False),
					AppStore.cells.storage_status.set(Reopened),
				]
			}
		}
		_ => []
	}

	## The status belongs to the most recent completed or pending action.
	storage_caption : AppStore.StorageStatus -> Str
	storage_caption = |status| match status {
		Ready => "Save one definition in this browser. Reopening replaces the current fields and clears preview answers."
		Saving(_) => "Saving definition…"
		Reopening => "Opening saved definition…"
		Saved => "Definition saved in this browser."
		Reopened => "Saved definition reopened."
		NoSavedDefinition => "No saved definition is available in this browser."
		InvalidSavedDefinition => "The saved definition could not be read. The current form is unchanged."
		TooLarge => "This definition is too large for the browser save slot."
		SaveFailed => "The browser could not save this definition."
		ReopenRefused => "The saved definition could not be opened. Try again."
	}
}

## The store's fields after `writes`, as their numbers in the form's order.
order_after : List(Engine.Write(_)) -> List(U64)
order_after = |writes| Form.ordered(AppStore.store.after(writes).read(AppStore.cells.schema.fields).to_list())

## Adding a field writes it last under the next number, and the number after it as the next one.
expect {
	schema = AppStore.cells.schema
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
	fields = AppStore.cells.schema.fields
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
	schema = AppStore.cells.schema
	after = AppStore.store.after(Schema.deleted(schema.fields, 1))
	(Form.ordered(after.read(schema.fields).to_list()), after.read(schema.next)) == ([2], 3)
}

## An answer is written under its field's number, and clearing the answers leaves the fields as they were.
expect {
	answers = AppStore.cells.answers
	typed = AppStore.store.after(Preview.answered_text(answers, { key: 1, text: "Ada" }).concat(Preview.answered_flag(answers, { key: 2, flag: True })))
	cleared = typed.after(Preview.cleared(answers))
	actual =
		\\typed: ${Str.inspect(Form.answer_of(typed.read(answers), 1))}, ${Str.inspect(Form.answer_of(typed.read(answers), 2))}
		\\cleared: ${Str.inspect(Form.answer_of(cleared.read(answers), 1))}
		\\fields: ${cleared.read(AppStore.cells.schema.fields).len().to_str()}
	expected =
		\\typed: { flag: False, text: "Ada" }, { flag: True, text: "" }
		\\cleared: { flag: False, text: "" }
		\\fields: 2
	actual == expected
}

## A valid submission is counted; an invalid one reveals its first problem
## without counting it, and dismissing feedback leaves the attempt visible.
expect {
	props = { fields: AppStore.cells.schema.fields, answers: AppStore.cells.answers, submissions: AppStore.cells.submissions, ui: AppStore.cells.preview }
	ready = AppStore.store.after(Preview.submitted(props, { totals: { fields: 2, problems: 0 }, first: NoProblem }))
	blocked = AppStore.store.after(Preview.submitted(props, { totals: { fields: 2, problems: 1 }, first: FirstProblem(2) }))
	{
		submissions: ready.read(props.submissions),
		accepted: (ready.read(props.ui.attempted), ready.read(props.ui.problems_open)),
		blocked: (blocked.read(props.submissions), blocked.read(props.ui.attempted), blocked.read(props.ui.problems_open)),
		reveal: blocked.read(props.ui.reveal).last(),
	} == {
		submissions: 1,
		accepted: (True, False),
		blocked: (0, True, True),
		reveal: Posted("answer-f2"),
	}
}

## An empty form reports why it cannot submit without naming a missing field.
expect {
	props = { fields: AppStore.cells.schema.fields, answers: AppStore.cells.answers, submissions: AppStore.cells.submissions, ui: AppStore.cells.preview }
	empty = AppStore.store.after(Preview.submitted(props, { totals: Form.empty_totals, first: NoProblem }))
	(empty.read(props.submissions), empty.read(props.ui.problems_open), empty.read(props.ui.reveal).last()) == (0, True, Unposted)
}

## Confirmation keeps the schema until accepted, then removes the row,
## clears the choice and posts focus to a surviving toolbar element.
expect {
	props = { fields: AppStore.cells.schema.fields, confirm: AppStore.cells.confirm, focus: AppStore.cells.focus }
	requested = AppStore.store.after(Designer.requested(props.confirm, 1))
	kept = requested.after(Designer.kept(props.confirm))
	deleted = requested.after(Designer.confirmed(props, requested.read(props.confirm)))
	{
		before: requested.read(props.fields).len(),
		kept: (kept.read(props.fields).len(), kept.read(props.confirm).is_idle()),
		remaining: Form.ordered(deleted.read(props.fields).to_list()),
		idle: deleted.read(props.confirm).is_idle(),
		focus: deleted.read(props.focus).last(),
		next: deleted.read(AppStore.cells.schema.next),
	} == {
		before: 2,
		kept: (2, True),
		remaining: [2],
		idle: True,
		focus: Posted("add-text-field"),
		next: 3,
	}
}

## A choice removed between drawing and delivery preserves the existing answer.
expect {
	answers = AppStore.cells.answers
	before = AppStore.store.after(Preview.answered_choice(answers, { key: 1, picked: Chose("Ada") }))
	before.after(Preview.answered_choice(answers, { key: 1, picked: NotOffered })).read(answers) == before.read(answers)
}

## Reopening replaces the definition while clearing answers and feedback.
## Allocations since the save still count toward the next field number.
expect {
	cells = AppStore.cells
	saved = AppStore.store.after(Schema.moved(cells.schema.fields, { key: 2, toward: Earlier }))
	text = Definition.encode({ fields: saved.read(cells.schema.fields), next: saved.read(cells.schema.next) })?
	edited = saved.after([
		cells.schema.next.set(6),
		cells.answers.update(|answers| answers.insert(1, { text: "Ada", flag: False })),
		cells.submissions.set(1),
		cells.preview.attempted.set(True),
		cells.preview.problems_open.set(True),
	])
	definition = { fields: edited.read(cells.schema.fields), next: edited.read(cells.schema.next) }
	opening = edited.after(AppStore.storage_requested(Reopen, { status: edited.read(cells.storage_status), definition }))
	reopened = opening.after(AppStore.storage_answered({ status: opening.read(cells.storage_status), next: opening.read(cells.schema.next) }, Reopen, Ok(text)))
	{
		order: Form.ordered(reopened.read(cells.schema.fields).to_list()),
		next: reopened.read(cells.schema.next),
		answers: reopened.read(cells.answers),
		submissions: reopened.read(cells.submissions),
		feedback: (reopened.read(cells.preview.attempted), reopened.read(cells.preview.problems_open)),
		status: reopened.read(cells.storage_status),
	} == { order: [2, 1], next: 6, answers: Form.no_answers, submissions: 0, feedback: (False, False), status: Reopened }
}

## A stale or refused readback cannot confirm a save of different text.
expect {
	status = AppStore.cells.storage_status
	at = { status: Saving("new"), next: Form.initial_next }
	saved = AppStore.store.after(AppStore.storage_answered(at, Save, Ok("new")))
	different = AppStore.store.after(AppStore.storage_answered(at, Save, Ok("old")))
	refused = AppStore.store.after(AppStore.storage_answered(at, Save, Err(Refused)))
	(saved.read(status), different.read(status), refused.read(status)) == (Saved, SaveFailed, SaveFailed)
}
