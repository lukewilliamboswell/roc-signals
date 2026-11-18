import Url
import Web

## Fixed initial routes are immutable program declarations. Their paths select
## deterministic inputs; neither this catalogue nor its lookups own mounted state.
EntryRoutes := [].{

	## A canonical root-relative entry path. Query and fragment facts arrive in
	## later turns; accepting a repaired path here would hide output aliases.
	Path :: Str.{

		## Check a computed entry path without normalizing it into another path.
		## A path is at most 2048 UTF-8 bytes and contains no query or fragment.
		from_str : Str -> Try(Path, [InvalidEntryPath(Str)])
		from_str = |source| {
			if source.count_utf8_bytes() > 2048 {
				return Err(InvalidEntryPath("an entry path exceeds 2048 UTF-8 bytes"))
			}
			parsed = Url.parse(source).map_err(|_| InvalidEntryPath("an entry needs a canonical root-relative URL path"))?
			if parsed.origin() != Relative or parsed.query() != None or parsed.fragment() != None or parsed.to_str() != source {
				return Err(InvalidEntryPath("an entry needs an unchanged canonical root-relative path, without a query or fragment"))
			}
			Ok(Path.(source))
		}

		## Refuse a noncanonical literal where it is declared, before mounting.
		from_quote : Str -> Try(Path, [BadQuotedBytes(Str)])
		from_quote = |source| Path.from_str(source).map_err(|InvalidEntryPath(note)| BadQuotedBytes(note))

		## The canonical path to use in a link or navigation decision.
		text : Path -> Str
		text = |Path.(source)| source

		## Use this checked path with Html.link or Html.href without reparsing app
		## route data. The path constructor already excludes unsupported schemes.
		link : Path -> Web.Link
		link = |Path.(source)| Web.Link.from_str(source) ?? crash "internal: an entry path is not an accepted relative link"

		## Paths compare by their canonical retained spelling.
		is_eq : _

		## Hash the same spelling equality compares.
		to_hash : _
	}

	## The declared mount identity and optional fallback entry. No fallback is
	## inferred from the first path; plain loads of unknown paths must refuse.
	Props := {
		namespace : Web.Namespace ?? Html,
		prefix : Web.Prefix ?? Unprefixed,
		local : Str ?? "div",
		fallback : [None, Some(Path)] ?? None,
	}

	## One reusable catalogue with checked paths and typed route lookup. Reusing
	## it across mounts shares descriptions and route data, never live storage.
	Catalogue(route) :: {
		paths : List(Str),
		values : List(route),
		by_path : Dict(Str, U32),
		by_route : Dict(route, Path),
		fallback : [None, Some(U32)],
		root : { namespace : Web.Namespace, prefix : Web.Prefix, local : Str },
	}.{

		## Find the configured path for a typed route. A route not declared here
		## is a value the caller must handle, rather than an invented URL.
		path : Catalogue(route), route -> Try(Path, [NotAnEntry])
			where [route.is_eq : route, route -> Bool, route.to_hash : route, Hasher -> Hasher]
		path = |catalogue, route| catalogue.by_route.get(route).map_err(|_| NotAnEntry)
	}

	## Build immutable initial-entry metadata. Duplicate paths/routes, an empty
	## catalogue or missing fallback are declaration contracts, not runtime data
	## recovery. Bounds apply before a declaration can overrun its wire section.
	make : Props, List({ path : Path, route : route }) -> Catalogue(route)
		where [route.is_eq : route, route -> Bool, route.to_hash : route, Hasher -> Hasher]
	make = |props, entries| {
		if entries.is_empty() or entries.len() > 4096 {
			crash "contract: an entry catalogue needs 1 to 4096 concrete routes"
		}
		tag = Web.Tag.from_str(props.local) ?? crash "contract: an entry catalogue has an invalid mount local name"
		qualified = tag.in_namespace({ namespace: props.namespace, prefix: props.prefix }) ?? crash "contract: an entry catalogue has an invalid expanded mount identity"
		namespace = match qualified.namespace() {
			Explicit(value) => value
			Inherit => crash "internal: an explicitly qualified mount lost its namespace"
		}
		root = { namespace, prefix: qualified.prefix(), local: qualified.local() }
		var $paths = []
		var $values = []
		var $by_path = Dict.empty()
		var $by_route = Dict.empty()
		var $bytes = 0.U64
		for entry in entries {
			path = entry.path.text()
			if $by_path.contains(path) {
				crash "contract: entry path ${Str.inspect(path)} is declared twice"
			}
			if $by_route.contains(entry.route) {
				crash "contract: a typed initial route is declared twice at path ${Str.inspect(path)}"
			}
			$bytes = $bytes + 4 + path.count_utf8_bytes()
			if $bytes > 65536 {
				crash "resource_limit: entry paths exceed 65536 encoded bytes"
			}
			$by_path = $by_path.insert(path, $paths.len().to_u32_wrap())
			$by_route = $by_route.insert(entry.route, entry.path)
			$paths = $paths.append(path)
			$values = $values.append(entry.route)
		}
		fallback = match props.fallback {
			None => None
			Some(path) => Some($by_path.get(path.text()) ?? crash "contract: entry fallback ${Str.inspect(path.text())} is not declared")
		}
		{ paths: $paths, values: $values, by_path: $by_path, by_route: $by_route, fallback, root }
	}

	## Internal names/root facts for program declarations and build enumeration.
	## Keeping this off Catalogue's members prevents an app seeing engine ids.
	facts : Catalogue(route) -> { paths : List(Str), fallback : [None, Some(U32)], root : { namespace : Web.Namespace, prefix : Web.Prefix, local : Str } }
	facts = |catalogue| { paths: catalogue.paths, fallback: catalogue.fallback, root: catalogue.root }

	## Select a private catalogue index. Only plain mounts use the live pathname;
	## annotated frames supply an already selected index in their boot section.
	select : Catalogue(route), Str -> Try(U32, [UnknownEntry(Str)])
	select = |catalogue, url| {
		path = match Url.parse(url) {
			Ok(parsed) => parsed.path()
			_ => return Err(UnknownEntry(url))
		}
		match catalogue.by_path.get(path) {
			Ok(index) => Ok(index)
			Err(_) => match catalogue.fallback {
				Some(index) => Ok(index)
				None => Err(UnknownEntry(path))
			}
		}
	}

	## Resolve the private selected index without exposing indices as app data.
	at : Catalogue(route), U32 -> route
	at = |catalogue, index| catalogue.values.get(index.to_u64()) ?? crash "contract: startup entry index is not in the compiled catalogue"
}

## Entry spelling is canonical and never includes private or live URL facts.
expect {
	accepted = ["/", "/tasks/", "/tasks/42", "/a%20b/"]
	accepted.all(|path| EntryRoutes.Path.from_str(path).map_ok(|value| value.text()) == Ok(path))
}

## Repairs, queries, fragments and explicit origins cannot become entry aliases.
expect ["tasks", "//host/a", "https://example.com/", "/a/../b", "/a?x=1", "/a#part", "/a b", "/a\\b"].all(|path| EntryRoutes.Path.from_str(path).is_err())

## Typed paths and plain selection share one catalogue; query and hash are later facts.
expect {
	entries = EntryRoutes.make({}, [{ path: "/", route: 0.U64 }, { path: "/tasks/", route: 1 }])
	path = entries.path(1)?
	actual = { path: path.text(), selected: EntryRoutes.select(entries, "/tasks/?live=1#part")?, route: EntryRoutes.at(entries, 1), unknown: EntryRoutes.select(entries, "/missing").is_err(), undeclared: entries.path(2).is_err() }
	actual == { path: "/tasks/", selected: 1, route: 1, unknown: True, undeclared: True }
}

## An authored fallback selects its own fixed route for an unknown live path.
expect {
	entries = EntryRoutes.make({ fallback: Some("/") }, [{ path: "/", route: 7.U64 }])
	EntryRoutes.at(entries, EntryRoutes.select(entries, "/unknown/42?live=1")?) == 7
}

## A plain browser mount supplies an absolute URL; only its path selects UI.
expect {
	entries = EntryRoutes.make({}, [{ path: "/tasks/", route: "tasks" }])
	EntryRoutes.select(entries, "https://example.com/tasks/?q=live#hash") == Ok(0)
}
