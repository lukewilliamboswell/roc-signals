import pf.Engine
import Form
import Schema

## A save slot contains a form's field definitions and the next field number.
## The format keeps rule text exactly as typed, including incomplete rules.
Definition := [].{

	## The checked contents of a saved slot, ready to replace the schema.
	Snapshot : { fields : Schema.Fields, next : U64 }

	## One save slot shared by Form Builder pages on this origin.
	storage_key = "roc-signals.form-builder.definition"

	## Encode one definition, within the field and byte bounds of the slot.
	encode : Snapshot -> Try(Str, [TooLarge])
	encode = |{ fields, next }| {
		if fields.len() > max_fields {
			return Err(TooLarge)
		}
		listed = fields.to_list()
		if listed.fold(0, |bytes, { row, .. }| bytes + row.label.count_utf8_bytes() + row.min_text.count_utf8_bytes() + row.max_text.count_utf8_bytes() + row.options_text.count_utf8_bytes()) > max_bytes {
			return Err(TooLarge)
		}
		version = 1.U8
		text = Json.to_str({ version, fields: listed, next })
		if (text.count_utf8_bytes() > max_bytes) Err(TooLarge) else Ok(text)
	}

	## Check the storage envelope and field identities before replacing any
	## live state. Older and unknown formats are rejected as incomplete data.
	decode : Str -> Try(Snapshot, [TooLarge, InvalidDefinition])
	decode = |text| {
		if text.count_utf8_bytes() > max_bytes {
			return Err(TooLarge)
		}
		parsed : { version : U8, fields : Form.Fields, next : U64 }
		parsed = Json.parse(text) ? |_| InvalidDefinition
		{ version, fields, next } = parsed
		if fields.len() > max_fields {
			return Err(TooLarge)
		}
		if version != 1 or next == 0 or !fields.all(|{ key, row }| key > 0 and key < next and row.place > 0 and row.place < next) {
			return Err(InvalidDefinition)
		}
		places = fields.fold(Set.empty(), |used, { row, .. }| used.insert(row.place))
		if places.len() != fields.len() {
			return Err(InvalidDefinition)
		}
		table = Engine.Table.from_list(fields) ? |_| InvalidDefinition
		Ok({ fields: table, next })
	}
}

max_fields : U64
max_fields = 256

max_bytes : U64
max_bytes = 64 * 1024

## A definition round trip keeps read order, IDs and unfinished rules.
expect {
	rows = [
		{ key: 8, row: { ..Form.new_field(Form.number_kind, 8), label: "A \"quoted\" label", min_text: "-", place: 2 } },
		{ key: 2, row: { ..Form.new_field(Form.select_kind, 2), options_text: "small,\nlarge", place: 1 } },
	]
	fields = Engine.Table.from_list(rows)?
	snapshot = Definition.decode(Definition.encode({ fields, next: 12 })?)?
	{
		order: Form.ordered(snapshot.fields.to_list()),
		rows: rows.all(|{ key, row }| snapshot.fields.get(key) == Ok(row)),
		next: snapshot.next,
	} == { order: [2, 8], rows: True, next: 12 }
}

## A malformed slot, an unknown version and invalid field identities cannot
## enter the live table. The storage size is checked before JSON parsing.
expect {
	row = Form.new_field(Form.email_kind, 1)
	bad = [
		"not JSON",
		Json.to_str({ version: 2.U8, fields: [{ key: 1.U64, row }], next: 2.U64 }),
		Json.to_str({ version: 1.U8, fields: [{ key: 1.U64, row }], next: 1.U64 }),
		Json.to_str({ version: 1.U8, fields: [{ key: 1.U64, row }, { key: 2.U64, row }], next: 3.U64 }),
		Json.to_str({ version: 1.U8, fields: [{ key: 1.U64, row }, { key: 1.U64, row: { ..row, place: 2.U64 } }], next: 3.U64 }),
	]
	bad.all(
		|text| match Definition.decode(text) {
			Err(InvalidDefinition) => True
			_ => False
		},
	) and match Definition.decode(Str.repeat(" ", max_bytes + 1)) {
		Err(TooLarge) => True
		_ => False
	}
}
