import pf.Json

JsonProbe := [].{
	Probe : {
		count : U64,
		label : Str,
		mode : [Warm, Cold],
		nested : { child : Str },
		optional_count : Try(U64, [Missing]),
		token : Json.Token,
	}

	Wide : {
		f01 : U64,
		f02 : U64,
		f03 : U64,
		f04 : U64,
		f05 : U64,
		f06 : U64,
		f07 : U64,
		f08 : U64,
		f09 : U64,
		f10 : U64,
		f11 : U64,
		f12 : U64,
		f13 : U64,
		f14 : U64,
		f15 : U64,
		f16 : U64,
		f17 : U64,
		f18 : U64,
		f19 : U64,
		f20 : U64,
		f21 : U64,
		f22 : U64,
		f23 : U64,
		f24 : U64,
		f25 : U64,
		f26 : U64,
		f27 : U64,
		f28 : U64,
		f29 : U64,
		f30 : U64,
		f31 : U64,
		f32 : U64,
		f33 : U64,
		f34 : U64,
		f35 : U64,
		f36 : U64,
		f37 : U64,
		f38 : U64,
		f39 : U64,
		f40 : U64,
		f41 : U64,
		f42 : U64,
		f43 : U64,
		f44 : U64,
		f45 : U64,
		f46 : U64,
		f47 : U64,
		f48 : U64,
		f49 : U64,
		f50 : U64,
		f51 : U64,
		f52 : U64,
		f53 : U64,
		f54 : U64,
		f55 : U64,
		f56 : U64,
		f57 : U64,
		f58 : U64,
		f59 : U64,
		f60 : U64,
		f61 : U64,
		f62 : U64,
		f63 : U64,
	}

	probe_json : Str
	probe_json = "{\"count\":42,\"label\":\"alpha\",\"nested\":{\"child\":\"beta\"},\"mode\":{\"Warm\":{}},\"token\":\"tok\",\"unknown\":{\"skip\":[1,2,3.5,-2.0e+3,null,false]}}"

	wide_json : Str
	wide_json = "{\"f01\":1,\"f02\":2,\"f03\":3,\"f04\":4,\"f05\":5,\"f06\":6,\"f07\":7,\"f08\":8,\"f09\":9,\"f10\":10,\"f11\":11,\"f12\":12,\"f13\":13,\"f14\":14,\"f15\":15,\"f16\":16,\"f17\":17,\"f18\":18,\"f19\":19,\"f20\":20,\"f21\":21,\"f22\":22,\"f23\":23,\"f24\":24,\"f25\":25,\"f26\":26,\"f27\":27,\"f28\":28,\"f29\":29,\"f30\":30,\"f31\":31,\"f32\":32,\"f33\":33,\"f34\":34,\"f35\":35,\"f36\":36,\"f37\":37,\"f38\":38,\"f39\":39,\"f40\":40,\"f41\":41,\"f42\":42,\"f43\":43,\"f44\":44,\"f45\":45,\"f46\":46,\"f47\":47,\"f48\":48,\"f49\":49,\"f50\":50,\"f51\":51,\"f52\":52,\"f53\":53,\"f54\":54,\"f55\":55,\"f56\":56,\"f57\":57,\"f58\":58,\"f59\":59,\"f60\":60,\"f61\":61,\"f62\":62,\"f63\":63}"

	rows : List(Str)
	rows = {
		probe_result : Try(Probe, Json)
		probe_result = Json.parse(probe_json)

		missing_result : Try({ count : U64 }, Json)
		missing_result = Json.parse("{}")

		invalid_result : Try({ count : U64 }, Json)
		invalid_result = Json.parse("not-json")

		trailing_result : Try({ count : U64 }, Json)
		trailing_result = Json.parse_trailing_commas("{\"count\":7,}")

		trailing_garbage_result : Try({ count : U64 }, Json)
		trailing_garbage_result = Json.parse("{\"count\":7} trailing")

		optional_present_result : Try({ optional_count : Try(U64, [Missing]) }, Json)
		optional_present_result = Json.parse("{\"optional_count\":9}")

		camel_result : Try({ service_name : Str }, Json)
		camel_result = Json.parser_camel({})("{\"serviceName\":\"api\"}")

		encoded_label : Str
		encoded_label = "line1\nline2 \"quote\" \\ path"

		encoded_value : { count : U64, label : Str }
		encoded_value = { count: 7, label: encoded_label }

			encoded_result : Try(Str, _)
			encoded_result = Json.encode(encoded_value)

			escaped_result : Try({ label : Str }, Json)
			escaped_result = Json.parse("{\"label\":\"slash \\/ quote \\\" backslash \\\\ newline\\n\"}")

			[
				probe_text(probe_result),
				missing_text(missing_result),
				invalid_text(invalid_result),
			trailing_text(trailing_result),
			trailing_garbage_text(trailing_garbage_result),
				optional_present_text(optional_present_result),
				camel_text(camel_result),
				encode_text(encoded_result, encoded_label),
				escaped_parse_text(escaped_result),
			]
		}

	probe_text : Try(Probe, Json) -> Str
	probe_text = |result|
		match result {
			Ok(probe) => {
				optional = match probe.optional_count {
					Ok(_) => "present"
					Err(Missing) => "missing"
				}
				mode = match probe.mode {
					Warm => "warm"
					Cold => "cold"
				}
				token_bytes = Json.Token.count_utf8_bytes(probe.token)
				"probe ok ${probe.count.to_str()} ${probe.label} ${probe.nested.child} ${mode} ${optional} token-bytes ${token_bytes.to_str()}"
			}
			Err(_) => "probe failed"
		}

	missing_text : Try({ count : U64 }, Json) -> Str
	missing_text = |result|
		match result {
			Ok(_) => "missing failed"
			Err(MissingRequired) => "missing required"
			Err(InvalidJson) => "missing invalid"
		}

	invalid_text : Try({ count : U64 }, Json) -> Str
	invalid_text = |result|
		match result {
			Ok(_) => "invalid failed"
			Err(InvalidJson) => "invalid json"
			Err(MissingRequired) => "invalid missing"
		}

	trailing_text : Try({ count : U64 }, Json) -> Str
	trailing_text = |result|
		match result {
			Ok(value) => "trailing ok ${value.count.to_str()}"
			Err(_) => "trailing failed"
		}

	trailing_garbage_text : Try({ count : U64 }, Json) -> Str
	trailing_garbage_text = |result|
		match result {
			Ok(_) => "garbage failed"
			Err(InvalidJson) => "trailing garbage invalid"
			Err(MissingRequired) => "trailing garbage missing"
		}

	optional_present_text : Try({ optional_count : Try(U64, [Missing]) }, Json) -> Str
	optional_present_text = |result|
		match result {
			Ok(value) =>
				match value.optional_count {
					Ok(count) => "optional present ${count.to_str()}"
					Err(Missing) => "optional missing unexpectedly"
				}
			Err(_) => "optional present failed"
		}

	camel_text : Try({ service_name : Str }, Json) -> Str
	camel_text = |result|
		match result {
			Ok(value) => "camel ${value.service_name}"
			Err(_) => "camel failed"
		}

		encode_text : Try(Str, _), Str -> Str
		encode_text = |result, expected_label|
			match result {
				Ok(value) => {
					roundtrip_result : Try({ count : U64, label : Str }, Json)
					roundtrip_result = Json.parse(value)
					match roundtrip_result {
						Ok(decoded) =>
							if (decoded.count == 7) and (decoded.label == expected_label) {
								"encode escape ok"
							} else {
								"encode mismatch ${value}"
							}
						Err(_) => "encode parse failed ${value}"
					}
				}
				Err(_) => "encode failed"
			}

		escaped_parse_text : Try({ label : Str }, Json) -> Str
		escaped_parse_text = |result|
			match result {
				Ok(value) =>
					if value.label == "slash / quote \" backslash \\ newline\n" {
						"escaped parse ok"
					} else {
						"escaped parse mismatch"
					}
				Err(_) => "escaped parse failed"
			}
	}
