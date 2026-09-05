app [main] { pf: platform "../../../platform/main.roc" }

import pf.Browser
import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

storage_label : Str, Browser.StorageText -> Str
storage_label = |label, value|
	match value {
		StorageMissing => "${label}: missing"
		StorageValue(text) => "${label}: ${text}"
		StorageUnavailable(message) => "${label}: unavailable ${message}"
	}

main : () -> Elem
main = || {
	local_draft = Browser.local_storage_text("checkout:draft")
	session_flash = Browser.session_storage_text("checkout:flash")
	missing_draft = Browser.local_storage_text("checkout:missing")

	Html.div_c(
		"grid gap-2",
		[
			Html.heading("Storage Commands"),
			Html.text_s(local_draft.map(|value| storage_label("Local draft", value))),
			Html.text_s(session_flash.map(|value| storage_label("Session flash", value))),
			Html.text_s(missing_draft.map(|value| storage_label("Missing draft", value))),
			Ui.on_mount(|| Browser.set_local_storage_text("checkout:draft", "mount saved")),
			Ui.on_mount(|| Browser.remove_session_storage("checkout:flash")),
			Ui.on_mount(|| Browser.set_local_storage_text("checkout:coalesced", "old")),
			Ui.on_mount(|| Browser.set_local_storage_text("checkout:coalesced", "new")),
		],
	)
}
