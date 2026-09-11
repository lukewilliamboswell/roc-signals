import pf.Action exposing [Action]
import pf.Http
import pf.Ui

Load := [].{
	State(a) : { generation : U64, value : a }
	Read(a) : { query : Str, current : Load.State(a) }
	Decoder(a) : { loading : a, ready : Str -> a, failed : Str -> a }

	## Admit one request and retain only the newest occurrence's result.
	start : Ui.State(Load.State(a)), Str, Load.Decoder(a), Load.Read(a) -> Action(Load.Read(a))
		where [a.is_eq : a, a -> Bool]
	start = |state, endpoint, decode, read| {
		generation = read.current.generation + 1
		uri = "/api/packages/${endpoint}?q=${Load.query_text(read.query)}"
		Action.then(
			[state.write(|_current| { generation, value: decode.loading })],
			|_| Load.fetch!(state, uri, decode, generation),
		)
	}

	fetch! : Ui.State(Load.State(a)), Str, Load.Decoder(a), U64 => Action(Load.Read(a))
		where [a.is_eq : a, a -> Bool]
	fetch! = |state, uri, decode, generation| {
		ready = decode.ready
		failed = decode.failed
		value = match Http.get_text!(uri) {
			Ok(text) => ready(text)
			Err(err) => failed(Str.inspect(err))
		}
		Action.update([
			state.write(
				|current| if current.generation == generation {
					{ ..current, value }
				} else {
					current
				},
			),
		])
	}

	## Percent-encode UTF-8 bytes so punctuation cannot change query meaning.
	query_text : Str -> Str
	query_text = |text| {
		encoded = text.to_utf8().fold([], |bytes, byte| bytes.concat([37, Load.hex(byte // 16), Load.hex(byte % 16)]))
		Str.from_utf8(encoded) ?? crash "percent encoding produces ASCII"
	}

	hex : U8 -> U8
	hex = |digit| if digit < 10 {
		48 + digit
	} else {
		87 + digit
	}
}

## Query delimiters are data, not extra parameters.
expect Load.query_text("a&b") == "%61%26%62"

## Non-ASCII text is encoded as UTF-8 bytes.
expect Load.query_text("é") == "%c3%a9"
