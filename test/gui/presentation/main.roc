app [main] { pf: platform "../../../platform-gui/main.roc" }
import pf.Elem exposing [Elem]
import pf.Gui
import pf.Ui
import pf.Signal

main : () -> Elem
main = || Ui.state(False, |enabled| {
	Ui.state(0.U64, |clicks| {
		Gui.column({ test_id: "presentation" }, [
			Gui.heading("Native presentation"),
			Gui.checkbox({ label: "Enable action", checked: enabled.signal() }, enabled.on_bool(|_, value| value)),
			Gui.row({
				test_id: "styled-row",
				selected: enabled.signal(),
				overrides: enabled.signal().map(|value| Gui.Style.{ padding: 12, gap: 16, width: Fill, background: if value { Rgb(1193046) } else { Rgb(2236962) } }),
			}, [
				Gui.action_button({
					caption: Signal.const("Run action"),
					enabled: enabled.signal(),
					test_id: "run-action",
				}, clicks.on_unit(|value| value + 1)),
				Gui.text_s(clicks.signal().map(|value| "Runs: ${value.to_str()}")),
			]),
		])
	})
})
