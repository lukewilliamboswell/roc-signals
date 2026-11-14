app [main] { pf: platform "../../../platform/main.roc" }

import pf.Engine
import pf.Html

Command : [Focus(Str), ApplyValue(Str)]

Editor : { text : Str, commands : Engine.Outbox(List(Command)) }

initial : Editor
initial = { text: "Original", commands: Engine.outbox({}) }

main = Engine.program(
	|| Engine.state(
		initial,
		|editor| {
			posted = |state, command| { ..state, commands: state.commands.post([command]) }
			Engine.element(
				"main",
				[
					# region shortcuts
					Engine.on_document_key(
						{ keymap: Engine.const(Engine.Keymap.prevent(Engine.Chord.plain("k").primary())) },
						editor.update(|state| posted(state, Focus("first"))),
					),
					# endregion shortcuts
				],
				[
					Engine.on_post(
						editor.signal().map(|state| state.commands),
						|commands| commands.map(
							|command| Engine.command(
								match command {
									Focus(name) => Focus(name)
									ApplyValue(name) => ApplyValue(name)
								},
							),
						),
						Engine.ignore({}),
					),
					Html.text_input(
						Engine.const("Draft"),
						"text",
						editor.signal().map(|state| state.text),
						[
							Engine.ref("editor"),
							# region keymap
							Engine.on_key(
								{ keymap: Engine.const(Engine.Keymap.prevent([Engine.Chord.plain("Escape")])) },
								# region revert
								editor.update(|state| posted({ ..state, text: "Original" }, ApplyValue("editor"))),
								# endregion revert
							),
							# endregion keymap
						],
						editor.set_value(|state, text| { ..state, text }),
					),
					# region focus-trap
					Engine.element(
						"section",
						[Engine.attr("role", "dialog"), Html.aria_label("Tab loop")],
						[
							Html.button(
								"First",
								[
									Engine.ref("first"),
									Engine.on_key(
										{ keymap: Engine.const(Engine.Keymap.prevent([Engine.Chord.plain("Tab").with_shift()])) },
										editor.update(|state| posted(state, Focus("last"))),
									),
								],
								editor.update(|state| state),
							),
							Html.button(
								"Last",
								[
									Engine.ref("last"),
									Engine.on_key(
										{ keymap: Engine.const(Engine.Keymap.prevent([Engine.Chord.plain("Tab")])) },
										editor.update(|state| posted(state, Focus("first"))),
									),
								],
								editor.update(|state| state),
							),
						],
					),
					# endregion focus-trap
				],
			)
		},
	),
)

## The instance holds this store beside its site tree.
Store : {}

## Check that the default first page mounts while this app compiles.
mounted : U64
mounted = Engine.mounts(main)
