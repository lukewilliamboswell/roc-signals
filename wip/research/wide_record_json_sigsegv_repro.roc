app [main] { pf: platform "../../platform/main.roc" }

import pf.Elem exposing [Elem]
import pf.Html

# Repro for Roc compiler SIGSEGV in builtin Json-derived parsing of a 50-field record.
# Command:
#
#   roc check wip/research/wide_record_json_sigsegv_repro.roc
#
# Observed on release-fast-c0cae661: compiler exits 139 with SIGSEGV.
# 2026-07-08: updated to the renamed error type (`Json.ParseErr`, tags now carry
# payloads) after nightly-2026-July-06 removed the bare `Json` error type.

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
}

wide_json : Str
wide_json = "{\"f01\":1,\"f02\":2,\"f03\":3,\"f04\":4,\"f05\":5,\"f06\":6,\"f07\":7,\"f08\":8,\"f09\":9,\"f10\":10,\"f11\":11,\"f12\":12,\"f13\":13,\"f14\":14,\"f15\":15,\"f16\":16,\"f17\":17,\"f18\":18,\"f19\":19,\"f20\":20,\"f21\":21,\"f22\":22,\"f23\":23,\"f24\":24,\"f25\":25,\"f26\":26,\"f27\":27,\"f28\":28,\"f29\":29,\"f30\":30,\"f31\":31,\"f32\":32,\"f33\":33,\"f34\":34,\"f35\":35,\"f36\":36,\"f37\":37,\"f38\":38,\"f39\":39,\"f40\":40,\"f41\":41,\"f42\":42,\"f43\":43,\"f44\":44,\"f45\":45,\"f46\":46,\"f47\":47,\"f48\":48,\"f49\":49,\"f50\":50}"

main : {} -> Elem
main = |_| {
	result : Try(Wide, Json.ParseErr)
	result = Json.parse(wide_json)

	Html.paragraph(wide_text(result))
}

wide_text : Try(Wide, Json.ParseErr) -> Str
wide_text = |result|
	match result {
		Ok(value) =>
			if (value.f01 == 1) and (value.f50 == 50) {
				"wide parse ok"
			} else {
				"wide parse mismatch"
			}
		Err(_) => "wide parse failed"
	}
