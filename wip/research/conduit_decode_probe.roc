app [main] { pf: platform "../../platform/main.roc" }

import pf.Elem exposing [Elem]
import pf.Html

# Temporary probe for the conduit Phase 2 article decode failure.

Author : { username : Str, bio : Str, image : Str, following : Bool }

Inner : {
	slug : Str,
	title : Str,
	description : Str,
	body : Str,
	tag_list : List(Str),
	created_at : Str,
	favorited : Bool,
	favorites_count : U64,
	author : Author,
}

label : Str, Try(a, Json.ParseErr) -> Str
label = |name, result|
	match result {
		Ok(_) => "${name} ok"
		Err(MissingRequiredField(field)) => "${name} missing ${field}"
		Err(InvalidJson(msg)) => "${name} invalid: ${msg}"
	}

main : () -> Elem
main = || {
	p1 : Str -> Try({ created_at : Str }, Json.ParseErr)
	p1 = Json.parser_camel()

	p2 : Str -> Try({ article : { slug : Str } }, Json.ParseErr)
	p2 = Json.parser_camel()

	p3 : Str -> Try({ body : Str }, Json.ParseErr)
	p3 = Json.parser_camel()

	p4 : Str -> Try({ article : Inner }, Json.ParseErr)
	p4 = Json.parser_camel()

	p5 : Str -> Try({ tag_list : List(Str) }, Json.ParseErr)
	p5 = Json.parser_camel()

	Html.div(
		[],
		[
			Html.paragraph(label("p1", p1("{\"createdAt\":\"2026-06-01T08:00:00.000Z\"}"))),
			Html.paragraph(label("p2", p2("{\"article\":{\"slug\":\"x\"}}"))),
			Html.paragraph(label("p3", p3("{\"body\":\"a\\nb\"}"))),
			Html.paragraph(label("p5", p5("{\"tagList\":[\"signals\",\"webdev\"]}"))),
			Html.paragraph(
				label(
					"p4",
					p4(
						"{\"article\":{\"slug\":\"s\",\"title\":\"t\",\"description\":\"d\",\"body\":\"b\",\"tagList\":[\"x\"],\"createdAt\":\"c\",\"favorited\":false,\"favoritesCount\":2,\"author\":{\"username\":\"u\",\"bio\":\"\",\"image\":\"\",\"following\":false}}}",
					),
				),
			),
		],
	)
}
