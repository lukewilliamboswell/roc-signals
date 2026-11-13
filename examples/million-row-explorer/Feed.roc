import pf.Engine
import pf.Port
import Orders

## The live order feed: orders placed today, from a service the platform
## does not model, reached through one port. `ports.mjs`, beside this
## module, is the JavaScript side; the site passes it when it mounts the
## app. Here the service is simulated in the browser at the pace the app
## asks for.
Feed := [].{

	## One order as the feed sends it: a category by its tag's name
	## (`"Books"`), a region by its name, and the value in cents.
	Sale : { category : Orders.Category, region : Str, cents : U32 }

	## What arrives in one message: the orders since the last one, and how
	## many orders the JavaScript has dropped since the feed started,
	## because the page fell more than a few seconds behind.
	Batch : { sales : List(Sale), dropped : U32 }

	## The module's named ports, declared once and registered together.
	Ports : {
		## Live orders, `per_second` of them, in batches about four times a
		## second. Every batch carries orders the page must count, so none may
		## be replaced by a newer one: up to four wait while the page is busy,
		## and beyond them the JavaScript holds its orders back and sends them
		## with the next batch.
		orders : Port.Subscription({ per_second : U32 }, Batch),
	}

	## The same values serve requests and the derived program catalogue.
	ports : Ports
	ports = {
		orders: Port.subscription({ name: "roc-signals.example/million-row-explorer/orders", delivery: Every(4) }),
	}

	## The program's entry for `Program.with_ports`.
	registrations : List(Engine.PortRegistration)
	registrations = Port.registrations(Feed.ports)
}
