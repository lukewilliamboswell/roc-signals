app [target] {
	fz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.0/6uc3YKGydgEnS2nrCimSYWDNfT6drYcgU52VAwqrb6DS.tar.zst",
	pf: "../../platform/main-fuzz.roc",
}

import fz.Fuzz
import pf.Core
import pf.PortJson
import pf.Soak
import pf.SpecRunner
import ReadingApp
import ReadingList
import Store

## The Reading List with the walker as its store. The walk plays the
## JavaScript of `ports.mjs` against a model store: it answers `load` with
## the store, `add` by storing the book (or refusing it), applies the `put`
## and `remove` commands in the order the app sent them (or drops one, a
## write that failed), sends the store's copy to the `stored`
## subscription, ends that subscription, and reloads the page; in any
## order, between user events on any live control.
##
## Its properties are the app's promises, checked against the model store
## whenever the store has applied the app's commands (every shelf's count,
## and the books the pressed shelf shows, newest first):
##
## - the page already shows what the store holds, unless the store dropped
##   a write since it last sent its copy, or the page has not yet had the
##   store's books in this document: every change the user made was sent,
##   and every answer the store gave was taken;
## - once the store sends its copy to a live subscription, the page shows
##   exactly what the store holds, whatever the user, the store and the
##   timing did before.
##
## Every step must also leave the engine settled, and the walk must free
## everything it allocated.
##
## - generated: explorer-driven walks (two bytes per step) from a fresh
##   mount.
## - "walk-10k": a seeded walk of 10,000 steps.
## The flat round trip is a spec the native runner soaks
## (`specs/round-trip-finish-and-read-again.scm`).

St : SpecRunner.S(Core.App)

program : SpecRunner.Program(Core.App)
program = Core.driver(ReadingApp.program)

## The walk: the runner's state, the model store, how many of this
## document's commands the store has applied, a clock for the times the
## store gives new books, and what the page's copy of the books should be:
##
## - `Unsynced`: the page has had neither a `load` answer nor a `stored`
##   message in this document;
## - `Synced`: the page's copy is the store's, changed by the commands it
##   sent;
## - `Diverged`: the store dropped a write since it last sent its copy.
W : { s : St, store : List(Store.Book), applied : U64, clock : U64, copy : [Unsynced, Synced, Diverged] }

start : {} -> W
start = |_| { s: SpecRunner.mount(program, "/", []), store: [], applied: 0, clock: 0, copy: Unsynced }

port : Str -> Str
port = |name| "roc-signals.example/reading-list/${name}"

## A port message as the JavaScript would send it, decoded with the
## platform's own codec; the app only ever sends what it declared.
decoded : Str -> a where [a.PortJson.Sendable]
decoded = |json|
	match PortJson.decode({ json, blobs: [], files: [] }) {
		Ok(value) => value
		Err(why) => crash "reading-list walk: the app sent ${json}, which does not decode: ${PortJson.describe(why)}"
	}

encoded : a -> Str where [a.PortJson.Sendable]
encoded = |value| PortJson.encode(value).json

## Answer the pending port call `b` picks (none when `b` points past the
## last): `load` with the store, or a timeout or a throw; `add` by storing
## the book, or a throw that stores nothing.
answer : W, U8 -> W
answer = |w, b| {
	br = w.s.browser
	match br.pending.get(b.to_u64() % (br.pending.len() + 1)) {
		Ok(p) => {
			rest = { ..w.s, browser: { ..br, pending: br.pending.keep_if(|q| q.id != p.id) } }
			match p.kind {
				PortRequest({ port: name, json, .. }) =>
					if name == port("load") {
						if b % 4 == 3 {
							{ ..w, s: SpecRunner.deliver(program, rest, p.id, SpecRunner.encode_reject(Timeout, "")) }
						} else if b % 4 == 2 {
							{ ..w, s: SpecRunner.deliver(program, rest, p.id, [15, 1].concat("the database is closed".to_utf8())) }
						} else {
							# A page still loading takes the store's books.
							copy = if (w.copy == Unsynced) Synced else w.copy
							{ ..w, copy, s: SpecRunner.deliver(program, rest, p.id, SpecRunner.encode_port_reply(encoded(w.store))) }
						}
					} else if name == port("add") {
						if b % 5 == 4 {
							{ ..w, s: SpecRunner.deliver(program, rest, p.id, [15, 1].concat("QuotaExceededError".to_utf8())) }
						} else {
							asked : Store.NewBook
							asked = decoded(json)
							clock = w.clock + 1
							book = { id: "w${clock.to_str()}", title: asked.title, author: asked.author, shelf: WantToRead, added_ms: clock }
							{ ..w, clock, store: w.store.append(book), s: SpecRunner.deliver(program, rest, p.id, SpecRunner.encode_port_reply(encoded(book))) }
						}
					} else {
						crash "reading-list walk: a call on ${name}, which is not a call port"
					}
				_ => crash "reading-list walk: the app issued a request other than a port call"
			}
		}
		Err(_) => w
	}
}

## The store applies the commands the app has sent since it last looked, in
## order; when `b` says so, it drops the first of them, as a write that
## failed.
apply : W, U8 -> W
apply = |w, b| {
	log = w.s.browser.port_log
	var $store = w.store
	var $copy = w.copy
	var $i = w.applied
	while $i < log.len() {
		sent = log.get($i) ?? crash "reading-list walk: command index"
		dropped = $i == w.applied and b % 7 == 6
		if dropped {
			$copy = if ($copy == Synced) Diverged else $copy
		} else {
			if sent.port == port("put") {
				book : Store.Book
				book = decoded(sent.json)
				$store = $store.map(|stored| if (stored.id == book.id) book else stored)
			} else if sent.port == port("remove") {
				removed : { id : Str }
				removed = decoded(sent.json)
				$store = $store.drop_if(|stored| stored.id == removed.id)
			} else {
				crash "reading-list walk: a command on ${sent.port}, which is not a command port"
			}
		}
		$i = $i + 1
	}
	{ ..w, store: $store, applied: log.len(), copy: $copy }
}

## The store applies the app's commands; the page must already show what
## it holds when nothing was dropped. Then the store sends its copy to the
## live subscription, and the page must show exactly what the store holds.
publish : W, U8 -> W
publish = |w0, b| {
	w = apply(w0, b)
	if w.copy == Synced {
		shows(w.s, w.store, "the store applied the page's commands")
	}
	if SpecRunner.port_subscriptions(w.s, port("stored")) == 0 {
		w
	} else {
		s = SpecRunner.broadcast(program, w.s, |x| SpecRunner.on_port(x.sub, port("stored")), SpecRunner.encode_port_reply(encoded(w.store)))
		shows(s, w.store, "the store sent its copy")
		{ ..w, s, copy: Synced }
	}
}

## The page shows exactly the books of `store`, or the walk ends with what
## differs.
shows : St, List(Store.Book), Str -> {}
shows = |s, store, after| {
	check = |op|
		match SpecRunner.one(program, s, op) {
			Ok(_) => {}
			Err(why) => crash "reading-list walk: after ${after}, the page does not show the store's books ${encoded(store)}: ${why}"
		}
	on = |shelf| store.count_if(|book| book.shelf == shelf).to_str()
	check(ExpectText(Label("All"), "All (${store.len().to_str()})"))
	check(ExpectText(Label("Want to read"), "Want to read (${on(WantToRead)})"))
	check(ExpectText(Label("Reading"), "Reading (${on(Reading)})"))
	check(ExpectText(Label("Finished"), "Finished (${on(Finished)})"))
	check(ExpectText(Label("Books"), listed(pressed(s), store)))
}

## Which shelf the page shows: the pressed shelf button.
pressed : St -> ReadingList.Showing
pressed = |s| {
	is_pressed = |label|
		match SpecRunner.find(s.dom, Label(label)) {
			Ok(node) => SpecRunner.attr_value(s.dom, node, "aria-pressed") == Ok("true")
			Err(_) => False
		}
	if is_pressed("Want to read") {
		Only(WantToRead)
	} else if is_pressed("Reading") {
		Only(Reading)
	} else if is_pressed("Finished") {
		Only(Finished)
	} else {
		Everything
	}
}

## The text of the list of books the store holds, as the page shows them on
## `showing`: newest first (the walk's clock gives every book its own time).
listed : ReadingList.Showing, List(Store.Book) -> Str
listed = |showing, store| {
	shown = match showing {
		Everything => store
		Only(shelf) => store.keep_if(|book| book.shelf == shelf)
	}
	Str.join_with(
		shown.sort_with(|a, c| if (a.added_ms > c.added_ms) Before else if (a.added_ms < c.added_ms) After else Same).map(
			|book| {
				author = if (book.author.is_empty()) "Unknown author" else book.author
				"${book.title}${author}${ReadingList.shelf_name(book.shelf)}${ReadingList.next_action(book).label}Remove"
			},
		),
		"",
	)
}

## One step chosen by two bytes: mostly a user event on a live control,
## else the store answering a call, applying the commands and sending its
## copy, ending the subscription, or the page reloading.
walk_step : W, U8, U8 -> W
walk_step = |w, op, b|
	match op % 8 {
		0 | 1 | 2 | 3 => { ..w, s: Soak.step(program, w.s, b, op, Soak.no_jobs) }
		4 | 5 => answer(w, b)
		6 => publish(w, b)
		_ =>
			if b % 8 == 0 {
				match SpecRunner.end_port(program, w.s, port("stored"), [15, 3]) {
					Ok(s) => { ..w, s }
					Err(_) => w
				}
			} else if b % 8 == 1 {
				# The page reloads: the store keeps what it applied, and the
				# new document's commands are counted from its start.
				applied = apply(w, 0)
				match SpecRunner.navigate(program, applied.s, "/?reload=${applied.s.browser.doc.to_str()}") {
					Ok(s) => { ..applied, s, applied: 0, copy: Unsynced }
					Err(why) => crash "reading-list walk: reload: ${why}"
				}
			} else {
				{ ..w, s: Soak.step(program, w.s, b, op, Soak.no_jobs) }
			}
	}

walk : W, List(U8) -> W
walk = |w0, bytes| {
	check = Soak.settled(program)
	var $w = { ..w0, s: check(w0.s) }
	var $i = 0.U64
	while $i + 1 < bytes.len() {
		next = walk_step($w, bytes.get($i) ?? 0, bytes.get($i + 1) ?? 0)
		$w = { ..next, s: check(next.s) }
		$i = $i + 2
	}
	$w
}

## A walk from a fresh mount over the session's bytes, which must free
## everything it allocated.
test! : Soak.Session => Fuzz.Outcome
test! = |session| {
	if !Soak.walkable(session) {
		return Fuzz.reject
	}
	Fuzz.expect_no_leaks!(|| walk(start({}), Soak.session_bytes(session)))
	Fuzz.keep
}

target = Fuzz.target_with!({
	name: "reading-list",
	examples: [
		Fuzz.example({ name: "walk-10k", revision: "1", make: || { program: [], seed: 7, steps: 10000 } }),
	],
	generator: { program: Fuzz.list(Fuzz.u8, 400), seed: Fuzz.constant(0), steps: Fuzz.constant(0) }.Fuzz,
	test!,
	show: Str.inspect,
})
