import Core

## The accumulator and catalogue work behind Port's public derivation format.
## Collecting and adding declarations stay in this unexposed namespace, so no
## member of an app-facing type grants catalogue mutation.
PortRegistry := [].{

	## The state passed through a derived record of ports. Applications name
	## this type only in derivation signatures; Port.registrations starts it.
	Walk :: { declarations : List(Core.PortDecl), path : Str }

	## Thread the accumulator through every derived field while preserving
	## the full path for a rejection in a nested record.
	record : Walk, U64, (Walk, (Walk, Str, (Walk -> Try(Walk, err)) -> Try(Walk, err)) -> Try(Walk, err)) -> Try(Walk, err)
	record = |walk, _count, write_fields| {
		parent = walk.path
		write_fields(
			walk,
			|current, name, write_value| {
				path = if (parent.is_empty()) name else "${parent}.${name}"
				next = write_value(Walk.{ declarations: current.declarations, path })?
				Ok(Walk.{ declarations: next.declarations, path: parent })
			},
		)
	}

	## Add the declaration read from an existing port. This namespace is not
	## exposed by the platform; public format hooks cannot mint or rename it.
	append : Walk, Core.PortDecl -> Walk
	append = |{ declarations, path }, declaration| Walk.{ declarations: declarations.append(declaration), path }

	## Derive all declarations, then check the bounded catalogue as a value.
	## Port's public boundary raises the diagnostic; pure tests inspect it here.
	collect : ports, registering -> Try(List(Core.PortDecl), Str)
		where [ports.encoder_for : registering -> (ports, Walk -> Try(Walk, []))]
	collect = |ports, registering| {
		Shape : ports
		encode = Shape.encoder_for(registering)
		match encode(ports, Walk.{ declarations: [], path: "" }) {
			Ok(walk) => Core.port_catalogue(walk.declarations)
		}
	}

	## Reject ordinary data at the path the format is visiting. This stays
	## internal; a public format hook can only report on its supplied walk.
	reject : Walk -> a
	reject = |walk| crash "contract: Port.registrations: field \"${walk.path}\" is not a port; a record of ports holds Port.Command, Port.Call, Port.Subscription or records of them"
}
