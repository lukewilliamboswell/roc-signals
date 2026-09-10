app [main] { pf: platform "../../../platform-gui/main.roc" }
import pf.Elem exposing [Elem]
import pf.Gui
import pf.Ui
import pf.Signal

## A style value built outside any call, in the type's own nominal spelling.
## Omitted fields keep their neutral defaults, so this is a complete record.
banner_style : Gui.Style
banner_style = { padding: 8, gap: 4, width: Fill, background: Rgb(0x1B2A33) }

main : () -> Elem
main = || Ui.state(False, |enabled| {
	Ui.state(0.U64, |clicks| {
		Gui.column([Gui.test_id("presentation")], [
			Gui.heading("Native presentation"),
			Gui.checkbox({ label: "Enable action", checked: enabled.signal() }, [], enabled.on_bool(|_, value| value)),
			Gui.row([
				Gui.test_id("styled-row"),
				Gui.selected_s(enabled.signal()),
				Gui.style_s(enabled.signal().map(|value| Gui.Style.{ padding: 12, gap: 16, width: Fill, background: if value { Rgb(1193046) } else { Rgb(2236962) } })),
			], [
				Gui.action_button({ label: Signal.const("Run action"), enabled: enabled.signal() }, [Gui.test_id("run-action")], clicks.on_unit(|value| value + 1)),
				Gui.text_s(clicks.signal().map(|value| "Runs: ${value.to_str()}")),
			]),
			# The style signal recomputes on every click but always yields the
			# same value, so equality pruning must stop it before the host.
			Gui.row([
				Gui.test_id("pruned-row"),
				Gui.style_s(clicks.signal().map(|_value| Gui.Style.{ padding: 12, })),
			], [
				Gui.text("Style pruning"),
			]),
			Gui.row([Gui.test_id("banner-row"), Gui.style(banner_style)], [
				Gui.text("Styled outside a call"),
			]),
		])
	})
})
