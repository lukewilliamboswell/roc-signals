app [main] { pf: platform "https://github.com/lukewilliamboswell/roc-signals/releases/download/0.1/3eLQGNMDG9RuL9sn1A7ep1Rtq7QGmemE89y141WSv1XG.tar.zst" }

import pf.Elem exposing [Elem]
import pf.Html
import pf.Ui

Config : {
	service_name : Str,
	replicas : U64,
	regions : List(Str),
	owner : { name : Str, email : Str },
	timeout_seconds : Try(U64, [Missing]),
}

valid_json : Str
valid_json = "{\"serviceName\":\"api-gateway\",\"replicas\":3,\"regions\":[\"melbourne\",\"singapore\"],\"owner\":{\"name\":\"Maya\",\"email\":\"maya@example.com\"},\"timeoutSeconds\":30}"

minimal_json : Str
minimal_json = "{\"serviceName\":\"worker\",\"replicas\":1,\"regions\":[\"melbourne\"],\"owner\":{\"name\":\"Noah\",\"email\":\"noah@example.com\"}}"

incomplete_json : Str
incomplete_json = "{\"serviceName\":\"api-gateway\",\"replicas\":3}"

invalid_json : Str
invalid_json = "{\"serviceName\":\"api-gateway\",\"replicas\":}"

summary : Str -> Str
summary = |source| {
	parse : Str -> Try(Config, [InvalidJson(Str), MissingRequiredField(Str)])
	parse = Json.parser_camel()

	match parse(source) {
		Ok(config) => {
			timeout = match config.timeout_seconds {
				Ok(seconds) => "timeout ${seconds.to_str()}s"
				Err(Missing) => "default timeout"
			}
			"Valid config: ${config.service_name}, ${config.replicas.to_str()} replicas, ${config.regions.len().to_str()} regions, owner ${config.owner.name}, ${timeout}"
		}
		Err(MissingRequiredField(field)) => "Missing required field: ${field}"
		Err(InvalidJson(_)) => "Invalid JSON"
	}
}

page_class = "grid gap-5"

hero_class = "panel grid gap-2 p-5"

editor_class = "panel grid gap-4 p-4"

textarea_class = "min-h-64 w-full rounded-md border border-zinc-300 bg-white px-3 py-2 font-mono text-sm"

toolbar_class = "flex flex-wrap items-center gap-3"

main : () -> Elem
main = ||
	Ui.state(
		valid_json,
		|source| {
			status = source.signal().map(summary)

			Html.div_c(
				page_class,
				[
					Html.section_c(
						"JSON Config Editor",
						hero_class,
						[
							Html.heading_c("JSON Config Editor", "text-3xl font-semibold text-zinc-950"),
							Html.paragraph_c("Edit a deployment configuration and decode it into a typed Roc record with the builtin Json module.", "max-w-3xl text-sm text-zinc-700"),
						],
					),
					Html.section_c(
						"Configuration",
						editor_class,
						[
							Html.textarea_c("Configuration JSON", source.signal(), textarea_class, source.on_str(|_, value| value)),
							Html.div_c(
								toolbar_class,
								[
									Html.button_c("Load complete config", "button", source.on_unit(|_| valid_json)),
									Html.button_c("Load minimal config", "button", source.on_unit(|_| minimal_json)),
									Html.button_c("Load incomplete JSON", "button", source.on_unit(|_| incomplete_json)),
									Html.button_c("Load invalid JSON", "button", source.on_unit(|_| invalid_json)),
								],
							),
							Html.paragraph_s_c(status, "font-medium text-zinc-900"),
						],
					),
				],
			)
		},
	)
