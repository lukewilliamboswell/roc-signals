app [main] { pf: platform "../../../platform-gui/main.roc" }
import pf.Elem exposing [Elem]
import pf.Gui
import pf.Ui
import pf.Signal

main : () -> Elem
main = || Ui.state(False, |enabled| {
	Ui.state(0.U64, |clicks| {
		Elem.col({ test_id: "presentation" }, [
			Elem.heading("Native presentation"),
			Elem.checkbox({ label: "Enable action", checked: enabled.signal() }, enabled.update_bool(|_, value| value)),
			Elem.row({
				test_id: "styled-row",
				selected: enabled.signal(),
				changes: enabled.read(|value| Gui.Style.{ padding: 12, gap: 16, width: Fill, bg: if value { Rgb(1193046) } else { Rgb(2236962) } }),
			}, [
				Elem.action_button({
					caption: Signal.const("Run action"),
					enabled: enabled.signal(),
					test_id: "run-action",
				}, clicks.update(|value| value + 1)),
				Elem.text_s(clicks.read(|value| "Runs: ${value.to_str()}")),
			]),
		])
	})
})
