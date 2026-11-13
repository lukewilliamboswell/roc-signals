import pf.Engine
import pf.Html
import Canvas
import ClipboardRead
import Dates
import Display
import Geolocation
import Media
import Notifications
import Share
import Sockets

## Each browser service has its own typed port and effect site. The page's
## JavaScript owns browser objects; all reconnect decisions live in Roc.
Recipes := [].{
	program : Engine.Program
	program = Engine.program_boot(
		{ media: ["(prefers-reduced-motion: reduce)"] },
		|boot| Html.div(
			"recipes",
			[
				Html.h1("Port recipes", ""),
				Sockets.view({ seed: boot.seed }),
				Notifications.view({}),
				Share.view({}),
				ClipboardRead.view({}),
				Geolocation.view({}),
				Media.view({}),
				Display.view({}),
				Dates.view({ now_ms: boot.now_ms, languages: boot.languages, zone: boot.zone.name }),
				Canvas.view({ reduced: Engine.boot_media(boot, "(prefers-reduced-motion: reduce)") ?? False }),
			],
		),
	).with_ports([
		Sockets.sse.registration(),
		Sockets.websocket.registration(),
		Sockets.send.registration(),
		Notifications.permission.registration(),
		Notifications.show.registration(),
		Share.share.registration(),
		ClipboardRead.read.registration(),
		Geolocation.locate.registration(),
		Geolocation.positions.registration(),
		Media.camera.registration(),
		Display.fullscreen.registration(),
		Display.fullscreen_state.registration(),
		Display.wake.registration(),
		Display.wake_state.registration(),
		Dates.format.registration(),
	])
}
