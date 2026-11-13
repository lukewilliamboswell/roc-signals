import pf.Engine
import pf.Html
import pf.Port
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

	## Every recipe module supplies its own complete record of ports.
	Ports : {
		sockets : Sockets.Ports,
		notifications : Notifications.Ports,
		share : Share.Ports,
		clipboard : ClipboardRead.Ports,
		geolocation : Geolocation.Ports,
		media : Media.Ports,
		display : Display.Ports,
		dates : Dates.Ports,
	}

	## Composing these records keeps each module's registrations complete.
	ports : Ports
	ports = {
		sockets: Sockets.ports,
		notifications: Notifications.ports,
		share: Share.ports,
		clipboard: ClipboardRead.ports,
		geolocation: Geolocation.ports,
		media: Media.ports,
		display: Display.ports,
		dates: Dates.ports,
	}

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
	).with_ports(Port.registrations(Recipes.ports))
}
