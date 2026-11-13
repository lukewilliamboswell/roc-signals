import pf.Engine
import pf.Port
import pf.Table
import Store

## The reading list's state, as the cells of the app's store, and every
## change to it, as a pure function from what it reads to the writes it
## makes. The view's handlers and effect sites call them, and the
## `expect`s below test them with no engine and no browser.
##
## Two things here are called a store. `Store` is the module of the ports
## to the browser's IndexedDB, where the books are kept; the comments below
## call that the database. This module builds the app's store, the cells
## the page shares.
##
## The app keeps its own copy of the books, a table by id, and changes it
## in the turn of the click, so the page never waits on the database. Each
## change the database must learn of is posted to an outbox, which an
## `on_post` site sends as commands. The database's own copy wins whenever
## it reports one: once at start (`load`), and after any tab writes
## (`stored`), so every open tab ends up showing what the database holds.
##
## - `books`: the app's copy of the books, by id. The list is a view of
##   it: the books `showing` keeps, newest first.
## - `copy`: whether that copy has come from the database yet, or why it
##   cannot.
## - `showing`: which shelf the list shows, the view's query.
## - `form`: the book being typed.
## - `stamping`: submitted forms whose zero-delay timer will sample the time.
## - `adding`: complete books Roc minted, posted for the database.
## - `id_state`, `clock`: the id stream and last sampled wall-clock time.
## - `writes`: each change's commands, posted for the database.
## - `note`: the latest thing that went wrong, for the reader.
##
## The module's one tag, `Books`, is the store's name. Nothing spells the
## store's type: an annotation that mentions it says `_`.
ReadingList := [Books].{

	## Which books the list shows.
	Showing : [Everything, Only(Store.Shelf)]

	## A change the database must learn of, sent as a command.
	Command : [Put(Store.Book), Delete(Str)]

	## Whether the app's copy of the books has come from the database.
	Copy : [Loading, Loaded, Unreadable(Str)]

	## Where a book stands in the list: newest first, and by id among books
	## added in the same millisecond, so no two books tie and every tab
	## orders them alike.
	Place : { added_ms : I64, id : Str }

	## How many books are on each shelf.
	Tally : { want_to_read : U64, reading : U64, finished : U64 }

	## What the form and the copy say when the reader asks to add a book.
	Asking : { form : Store.NewBook, copy : Copy }

	## The id stream and last sampled time when an add's timer answers.
	StampReading : { state : U64, clock : I64 }

	## A form with nothing typed.
	blank : Store.NewBook
	blank = { title: "", author: "" }

	## The store: its name, and its cells with their starting values:
	## nothing loaded, nothing typed, nothing to send.
	store = Engine.store(
		ReadingList.Books,
		{
			books: Engine.table([]),
			copy: Engine.cell(Loading),
			showing: Engine.cell(Everything),
			form: Engine.cell(ReadingList.blank),
			stamping: Engine.cell(Engine.outbox({})),
			adding: Engine.cell(Engine.outbox({})),
			id_state: Engine.cell(0.U64),
			clock: Engine.cell(0.I64),
			writes: Engine.cell(Engine.outbox({})),
			note: Engine.cell(""),
		}.Engine.Cells,
	)

	## The store's cells.
	cells = ReadingList.store.cells()

	## A document starts its own id stream from the boot seed. The last
	## sampled clock is the mount time until a successful timer reads it again.
	start : Engine.Boot -> Engine.Store(_, _)
	start = |boot|
		ReadingList.store
			.with_initial(ReadingList.cells.id_state, boot.seed.to_u64_wrap().bitwise_xor(boot.seed.shr_zf_wrap(64).to_u64_wrap()))
			.with_initial(ReadingList.cells.clock, boot.now_ms)

	## How a shelf selects and orders the books: the `plan` of the list's
	## view.
	plan : Showing -> Engine.QueryPlan(Str, Store.Book, Place)
	plan = |showing| {
		keep: |_, book| match showing {
			Everything => True
			Only(shelf) => book.shelf == shelf
		},
		sort: |id, book| { added_ms: book.added_ms, id },
		compare: newest_first,
	}

	## The books of a table that `showing` keeps, in the list's order: what
	## the view draws, as a list, for a decision that needs them in order
	## and for a test.
	listed : Table(Str, Store.Book), Showing -> List(Store.Book)
	listed = |table, showing| {
		query = ReadingList.plan(showing)
		kept = table.fold([], |acc, id, book| if ((query.keep)(id, book)) acc.append(book) else acc)
		kept.sort_with(|a, b| (query.compare)((query.sort)(a.id, a), (query.sort)(b.id, b)))
	}

	## The table brought to hold exactly `books`. A book that is new or
	## differs is put and one the database no longer holds is removed, so
	## the table records exactly those; a book that is the same is not
	## written, and its row does no work. The database reports its whole
	## copy after every write, this tab's own included, so most of what
	## arrives is what the table already holds.
	synced : Table(Str, Store.Book), List(Store.Book) -> Table(Str, Store.Book)
	synced = |table, books| {
		stored = Set.from_list(books.map(|book| book.id))
		gone = table.fold([], |acc, id, _| if (stored.contains(id)) acc else acc.append(id))
		# Folds over the keys, not a `while` loop over a `var` that holds
		# the table: the loop copies the table on every pass in an
		# optimised build (roc-lang/roc#12971).
		put = books.fold(table, |acc, book| if (acc.get(book.id) == Ok(book)) acc else acc.put(book.id, book))
		gone.fold(put, |acc, id| acc.remove(id))
	}

	## The database's answer to `load`. It counts only while the app is
	## still loading: a `stored` message that came first is newer.
	loaded : Copy, Try(List(Store.Book), Port.Error) -> List(Engine.Write(_))
	loaded = |copy, answer|
		match copy {
			Loading =>
				match checked(answer) {
					Ok(books) => [restock(books), ReadingList.cells.copy.set(Loaded)]
					Err(why) => [ReadingList.cells.copy.set(Unreadable(why))]
				}
			_ => []
		}

	## A message of `stored`: the books as stored after a write in any tab,
	## which replace the app's copy.
	restocked : Try(List(Store.Book), Port.Error) -> List(Engine.Write(_))
	restocked = |message|
		match message {
			Err(Closed) => [ReadingList.cells.note.set("Changes made in other tabs no longer reach this one. Reload to see them.")]
			_ =>
				match checked(message) {
					Ok(books) => [restock(books), ReadingList.cells.copy.set(Loaded)]
					Err(why) => [ReadingList.cells.note.set("A change made in another tab could not be read: ${why}")]
				}
		}

	## What the reader is asking for, as one reading for `submitted`.
	asking : {} -> Engine.Signal(ctx, Asking)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	asking = |{}| { form: ReadingList.cells.form.signal(), copy: ReadingList.cells.copy.signal() }.Engine.Signal

	## Whether the form can add the book it holds: the shelf is loaded and
	## the book has a title.
	can_add : Asking -> Bool
	can_add = |{ form, copy }| copy == Loaded and !form.title.trim().is_empty()

	## The reader types in the form.
	title_typed : Str -> List(Engine.Write(_))
	title_typed = |text| [ReadingList.cells.form.update(|form| { ..form, title: text })]

	author_typed : Str -> List(Engine.Write(_))
	author_typed = |text| [ReadingList.cells.form.update(|form| { ..form, author: text })]

	## The reader adds the book the form holds: it is posted for the
	## database, and the form and the note are cleared. Nothing happens
	## while it cannot be added.
	submitted : Asking -> List(Engine.Write(_))
	submitted = |at|
		if ReadingList.can_add(at) {
			book = { title: at.form.title.trim(), author: at.form.author.trim() }
			[ReadingList.cells.stamping.update(|box| box.post(book)), ReadingList.cells.form.set(ReadingList.blank), ReadingList.cells.note.set("")]
		} else {
			[]
		}

	## A zero-delay timer supplies the action's time, a task after submission.
	## Refusal uses the last sample instead. Roc supplies the complete book;
	## the database only stores it. Every answer consumes a fresh stream word.
	stamped : { at : StampReading, form : Store.NewBook, result : Engine.Result } -> List(Engine.Write(_))
	stamped = |{ at, form, result }| {
		time = match result {
			Fired(now) => now
			Refused => at.clock
			_ => crash "ReadingList.stamped: Timer(0) returned another result"
		}
		next = next_id(at.state)
		book : Store.Book
		book = { id: next.id, title: form.title, author: form.author, shelf: WantToRead, added_ms: time }
		[
			ReadingList.cells.id_state.set(next.state),
			ReadingList.cells.clock.set(time),
			ReadingList.cells.adding.update(|box| box.post(book)),
		]
	}

	## The database's answer to `add`: the book as stored, which joins the
	## app's copy (or replaces itself there, if a `stored` message brought
	## it first).
	added : Store.Book, Try(Store.Book, Port.Error) -> List(Engine.Write(_))
	added = |asked, answer|
		match answer {
			Ok(book) => [ReadingList.cells.books.update(|table| table.put(book.id, book))]
			Err(error) => [ReadingList.cells.note.set("\"${asked.title}\" was not added: ${explain(error)}")]
		}

	## Move a book to its next shelf: want to read, reading, finished, and
	## from finished back to reading.
	advanced : Store.Book -> List(Engine.Write(_))
	advanced = |book| {
		moved = { ..book, shelf: next_shelf(book.shelf) }
		[ReadingList.cells.books.update(|table| table.replace(moved.id, moved)), ReadingList.send([Put(moved)])]
	}

	## Delete a book.
	removed : Str -> List(Engine.Write(_))
	removed = |id| [ReadingList.cells.books.update(|table| table.remove(id)), ReadingList.send([Delete(id)])]

	## Delete every finished book, given their ids: one write of the table
	## and one post of every command, since an outbox takes one post per
	## turn. No finished book writes nothing.
	finished_removed : List(Str) -> List(Engine.Write(_))
	finished_removed = |ids|
		if ids.is_empty() {
			[]
		} else {
			# A fold over the keys, not a `while` loop over a `var` that
			# holds the table (roc-lang/roc#12971).
			[ReadingList.cells.books.update(|table| ids.fold(table, |acc, id| acc.remove(id))), ReadingList.send(ids.map(|id| Delete(id)))]
		}

	## The ids of the finished books, in the list's order.
	finished_ids : Table(Str, Store.Book) -> List(Str)
	finished_ids = |table| ReadingList.listed(table, Only(Finished)).map(|book| book.id)

	## Show one shelf, or every book.
	shown : Showing -> List(Engine.Write(_))
	shown = |showing| [ReadingList.cells.showing.set(showing)]

	## The write that posts one change's commands, for the `on_post` site
	## to send. A change posts all its commands at once: an outbox takes
	## one post per turn.
	send : List(Command) -> Engine.Write(_)
	send = |commands| ReadingList.cells.writes.update(|box| box.post(commands))

	## The requests for one change's commands.
	requests : List(Command) -> List(Engine.Request)
	requests = |commands|
		commands.map(
			|command| match command {
				Put(book) => Store.put.send(book)
				Delete(id) => Store.remove.send({ id: id })
			},
		)

	## How many books are on each shelf.
	tally : Table(Str, Store.Book) -> Tally
	tally = |table|
		table.fold(
			{ want_to_read: 0, reading: 0, finished: 0 },
			|acc, _, book| match book.shelf {
				WantToRead => { ..acc, want_to_read: acc.want_to_read + 1 }
				Reading => { ..acc, reading: acc.reading + 1 }
				Finished => { ..acc, finished: acc.finished + 1 }
			},
		)

	## How many books are on a shelf, or on any.
	count : Tally, Showing -> U64
	count = |counted, showing|
		match showing {
			Everything => counted.want_to_read + counted.reading + counted.finished
			Only(WantToRead) => counted.want_to_read
			Only(Reading) => counted.reading
			Only(Finished) => counted.finished
		}

	## The line above the list.
	status : { copy : Copy, tally : Tally, showing : Showing } -> Str
	status = |{ copy, tally: counted, showing }|
		match copy {
			Loading => "Opening your shelf…"
			Unreadable(why) => "Your shelf could not be read: ${why}"
			Loaded =>
				match (ReadingList.count(counted, Everything), ReadingList.count(counted, showing)) {
					(0, _) => "No books yet. Add the first one above."
					(_, 0) => "No books on this shelf."
					(_, 1) => "1 book"
					(_, n) => "${n.to_str()} books"
				}
		}

	## A shelf's name, as the list says it.
	shelf_name : Store.Shelf -> Str
	shelf_name = |shelf|
		match shelf {
			WantToRead => "Want to read"
			Reading => "Reading"
			Finished => "Finished"
		}

	## The button that moves a book on: what it says, and its accessible
	## name, which names the book.
	next_action : Store.Book -> { label : Str, name : Str }
	next_action = |book|
		match book.shelf {
			WantToRead => { label: "Start", name: "Start reading ${book.title}" }
			Reading => { label: "Finish", name: "Finish ${book.title}" }
			Finished => { label: "Read again", name: "Read ${book.title} again" }
		}
}

## SplitMix64 belongs to this app, not the platform. Its 64-bit stream is
## deterministic for tests and is not suitable for cryptographic secrets.
next_id : U64 -> { state : U64, id : Str }
next_id = |state| {
	advanced = state.plus_wrap(0x9E3779B97F4A7C15)
	first = advanced.bitwise_xor(advanced.shr_zf_wrap(30)).times_wrap(0xBF58476D1CE4E5B9)
	second = first.bitwise_xor(first.shr_zf_wrap(27)).times_wrap(0x94D049BB133111EB)
	word = second.bitwise_xor(second.shr_zf_wrap(31))
	digits = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"]
	var $parts = []
	var $shift = 64.U8
	while $shift > 0 {
		$shift = $shift - 4
		index = word.shr_zf_wrap($shift).bitwise_and(15)
		$parts = $parts.append(digits.get(index) ?? crash "ReadingList.next_id: a nibble is outside 0 through 15")
	}
	{ state: advanced, id: "b-${Str.join_with($parts, "")}" }
}

## The write that makes the app's copy the database's.
restock : List(Store.Book) -> Engine.Write(_)
restock = |books| ReadingList.cells.books.update(|table| ReadingList.synced(table, books))

next_shelf : Store.Shelf -> Store.Shelf
next_shelf = |shelf|
	match shelf {
		WantToRead => Reading
		Reading => Finished
		Finished => Reading
	}

## The database's books, or why there are none. The port's type guarantees
## each book's shape, but not that ids are distinct, and the table keys
## its rows by id: of two books under one id only one could be a row, so
## they are refused here, at the door.
checked : Try(List(Store.Book), Port.Error) -> Try(List(Store.Book), Str)
checked = |answer|
	match answer {
		Ok(books) =>
			if Set.from_list(books.map(|b| b.id)).len() == books.len() {
				Ok(books)
			} else {
				Err("it holds two books under one id.")
			}
		Err(error) => Err(explain(error))
	}

## Newest first; books added in the same millisecond by id.
newest_first : ReadingList.Place, ReadingList.Place -> [Before, Same, After]
newest_first = |a, b|
	if a.added_ms > b.added_ms {
		Before
	} else if a.added_ms < b.added_ms {
		After
	} else {
		compare_text(a.id, b.id)
	}

## Text in the order of its UTF-8 bytes.
compare_text : Str, Str -> [Before, Same, After]
compare_text = |left, right| {
	l = left.to_utf8()
	r = right.to_utf8()
	var $at = 0
	while $at < l.len() and $at < r.len() {
		# In range: both indices are below the lengths checked above.
		a = l.get($at) ?? 0
		b = r.get($at) ?? 0
		if a != b {
			return if (a < b) Before else After
		}
		$at = $at + 1
	}
	if l.len() < r.len() {
		Before
	} else if l.len() > r.len() {
		After
	} else {
		Same
	}
}

## Why a port gave no answer, for the reader.
explain : Port.Error -> Str
explain = |error|
	match error {
		Timeout => "the store did not answer in time."
		Refused => "too many requests at once."
		Threw(message) => "the store said \"${message}\"."
		TooLarge => "the shelf is larger than the page accepts."
		Closed => "the store stopped answering."
		Undecodable(why) => "it holds something this app does not understand (${why})."
	}

dune : Store.Book
dune = { id: "b1", title: "Dune", author: "Frank Herbert", shelf: WantToRead, added_ms: 10 }

piranesi : Store.Book
piranesi = { id: "b2", title: "Piranesi", author: "Susanna Clarke", shelf: Finished, added_ms: 20 }

## The store after the database answers `load`, as the load's reaction
## decides it: from the copy the store holds when the answer arrives.
after_load : Engine.Store(_, _), Try(List(Store.Book), Port.Error) -> Engine.Store(_, _)
after_load = |at, answer| at.after(ReadingList.loaded(at.read(ReadingList.cells.copy), answer))

## The titles the list shows for a store, in order.
titles : Engine.Store(_, _) -> List(Str)
titles = |at| ReadingList.listed(at.read(ReadingList.cells.books), at.read(ReadingList.cells.showing)).map(|book| book.title)

## The status line of a store.
status_of : Engine.Store(_, _) -> Str
status_of = |at| ReadingList.status({ copy: at.read(ReadingList.cells.copy), tally: ReadingList.tally(at.read(ReadingList.cells.books)), showing: at.read(ReadingList.cells.showing) })

## The list is newest first; a load answer that comes after a `stored`
## message is older than it, so it is ignored; and two books under one id
## are refused rather than shown.
expect {
	first = after_load(ReadingList.store, Ok([dune, piranesi]))
	late = after_load(ReadingList.store.after(ReadingList.restocked(Ok([dune]))), Ok([dune, piranesi]))
	failed = after_load(ReadingList.store, Err(Timeout))
	twice = after_load(ReadingList.store, Ok([dune, { ..piranesi, id: "b1" }]))
	shared = first.after(ReadingList.restocked(Ok([dune, dune])))
	actual =
		\\first: ${Str.inspect(titles(first))} ${Str.inspect(first.read(ReadingList.cells.copy))}
		\\late: ${Str.inspect(titles(late))}
		\\failed: ${status_of(failed)}
		\\one id twice: ${status_of(twice)}
		\\then: ${shared.read(ReadingList.cells.books).len().to_str()} ${shared.read(ReadingList.cells.note)}
	expected =
		\\first: ["Piranesi", "Dune"] Loaded
		\\late: ["Dune"]
		\\failed: Your shelf could not be read: the store did not answer in time.
		\\one id twice: Your shelf could not be read: it holds two books under one id.
		\\then: 2 A change made in another tab could not be read: it holds two books under one id.
	actual == expected
}

## Adding needs a loaded shelf and a title; each add is a new request, even
## of the same book, and the form clears.
expect {
	ready = after_load(ReadingList.store, Ok([]))
	submit = |at, form| at.after(ReadingList.submitted({ form, copy: at.read(ReadingList.cells.copy) }))
	once = submit(ready, { title: " Dune ", author: "Frank Herbert" })
	again = submit(once, { title: "Dune", author: "Frank Herbert" })
	actual =
		\\loading: ${Str.inspect(submit(ReadingList.store, { title: "Dune", author: "" }).read(ReadingList.cells.stamping).last())}
		\\blank: ${Str.inspect(submit(ready, { title: "  ", author: "" }).read(ReadingList.cells.stamping).last())}
		\\once: ${Str.inspect(once.read(ReadingList.cells.stamping).last())} "${once.read(ReadingList.cells.form).title}"
		\\again: ${Str.inspect(again.read(ReadingList.cells.stamping).last())} ${Str.inspect(again.read(ReadingList.cells.stamping) == once.read(ReadingList.cells.stamping))}
	expected =
		\\loading: Unposted
		\\blank: Unposted
		\\once: Posted({ author: "Frank Herbert", title: "Dune" }) ""
		\\again: Posted({ author: "Frank Herbert", title: "Dune" }) False
	actual == expected
}

## A seed fixes the id stream. Timers supply signed time, while refusal
## uses the last sample and still consumes the next id rather than reusing one.
expect {
	ready = after_load(ReadingList.start({ seed: 7, now_ms: -900 }), Ok([]))
	stamp : Engine.Store(_, _), Engine.Result -> Engine.Store(_, _)
	stamp = |at, result| at.after(ReadingList.stamped({ at: { state: at.read(ReadingList.cells.id_state), clock: at.read(ReadingList.cells.clock) }, form: { title: "Dune", author: "" }, result }))
	first = stamp(ready, Fired(10))
	refused = stamp(first, Refused)
	backwards = stamp(refused, Fired(-2))
	actual =
		\\first: ${Str.inspect(first.read(ReadingList.cells.adding).last())}
		\\refused: ${Str.inspect(refused.read(ReadingList.cells.adding).last())}
		\\backwards: ${Str.inspect(backwards.read(ReadingList.cells.adding).last())}
		\\clock: ${backwards.read(ReadingList.cells.clock).to_str()}
	expected =
		\\first: Posted({ added_ms: 10, author: "", id: "b-63cbe1e459320dd7", shelf: WantToRead, title: "Dune" })
		\\refused: Posted({ added_ms: 10, author: "", id: "b-044c3cd7f43c661c", shelf: WantToRead, title: "Dune" })
		\\backwards: Posted({ added_ms: -2, author: "", id: "b-e6984080bab12a02", shelf: WantToRead, title: "Dune" })
		\\clock: -2
	actual == expected
}

## Both halves of the boot seed initialize the stream; refusal before the
## first timer sample uses the actual mount time, including a negative time.
expect {
	seed : U128
	seed = 7
	ready = ReadingList.start({ seed: seed.shl_wrap(64), now_ms: -900 })
	stamped = ready.after(ReadingList.stamped({ at: { state: ready.read(ReadingList.cells.id_state), clock: ready.read(ReadingList.cells.clock) }, form: { title: "Dune", author: "" }, result: Refused }))
	stamped.read(ReadingList.cells.adding).last() == Posted({ id: "b-63cbe1e459320dd7", title: "Dune", author: "", shelf: WantToRead, added_ms: -900 })
}

## Moving and deleting change the app's copy at once and post their
## commands; moving a book back is a command of its own.
expect {
	s = after_load(ReadingList.store, Ok([dune, piranesi]))
	book = |at, id| at.read(ReadingList.cells.books).get(id) ?? dune
	advance = |at, id| at.after(ReadingList.advanced(book(at, id)))
	started = advance(s, "b1")
	finished = advance(started, "b1")
	again = advance(finished, "b1")
	cleared = finished.after(ReadingList.finished_removed(ReadingList.finished_ids(finished.read(ReadingList.cells.books))))
	nothing = s.after(ReadingList.finished_removed([]))
	actual =
		\\started: ${Str.inspect(started.read(ReadingList.cells.writes).last())}
		\\again: ${Str.inspect([book(again, "b2").shelf, book(again, "b1").shelf])} ${Str.inspect(again.read(ReadingList.cells.writes).last())}
		\\cleared: ${Str.inspect(titles(cleared))} ${Str.inspect(cleared.read(ReadingList.cells.writes).last())}
		\\nothing finished: ${Str.inspect(nothing.read(ReadingList.cells.writes).last())}
	expected =
		\\started: Posted([Put({ added_ms: 10, author: "Frank Herbert", id: "b1", shelf: Reading, title: "Dune" })])
		\\again: [Finished, Reading] Posted([Put({ added_ms: 10, author: "Frank Herbert", id: "b1", shelf: Reading, title: "Dune" })])
		\\cleared: [] Posted([Delete("b2"), Delete("b1")])
		\\nothing finished: Unposted
	actual == expected
}

## A database's answer replaces the app's copy; a book the database added
## joins it once, even when `stored` brought it first; a failure says
## which book.
expect {
	s = after_load(ReadingList.store, Ok([dune]))
	echoed = s.after(ReadingList.restocked(Ok([dune, piranesi]))).after(ReadingList.added(piranesi, Ok(piranesi)))
	failed = s.after(ReadingList.added(piranesi, Err(Threw("QuotaExceededError"))))
	closed = s.after(ReadingList.restocked(Err(Closed)))
	actual =
		\\echoed: ${Str.inspect(titles(echoed))}
		\\failed: ${failed.read(ReadingList.cells.note)}
		\\closed: ${closed.read(ReadingList.cells.note)}
	expected =
		\\echoed: ["Piranesi", "Dune"]
		\\failed: "Piranesi" was not added: the store said "QuotaExceededError".
		\\closed: Changes made in other tabs no longer reach this one. Reload to see them.
	actual == expected
}

## The status line counts what the list shows.
expect {
	s = after_load(ReadingList.store, Ok([dune, piranesi]))
	actual =
		\\all: ${status_of(s)}
		\\finished: ${status_of(s.after(ReadingList.shown(Only(Finished))))}
		\\reading: ${status_of(s.after(ReadingList.shown(Only(Reading))))}
		\\empty: ${status_of(after_load(ReadingList.store, Ok([])))}
	expected =
		\\all: 2 books
		\\finished: 1 book
		\\reading: No books on this shelf.
		\\empty: No books yet. Add the first one above.
	actual == expected
}

## Books added in the same millisecond are ordered by id, whichever was
## stored first.
expect {
	twin = { ..dune, id: "b0", title: "Emma", added_ms: 20 }
	titles(after_load(ReadingList.store, Ok([piranesi, twin, dune]))) == ["Emma", "Piranesi", "Dune"]
}

## The database's copy writes only the books that differ: none when it is
## what the table holds, in whatever order, one for a book that moved, and
## one for a book that is gone.
expect {
	table = Table.from_list([{ key: "b1", row: dune }, { key: "b2", row: piranesi }])
	written = |synced| match synced.inverse() {
		Ok(writes) => writes.len().to_str()
		Err(Rewritten) => "every row"
	}
	fewer = ReadingList.synced(table, [dune])
	actual =
		\\same: ${written(ReadingList.synced(table, [piranesi, dune]))}
		\\moved: ${written(ReadingList.synced(table, [{ ..dune, shelf: Reading }, piranesi]))}
		\\fewer: ${written(fewer)}, ${fewer.len().to_str()} left
	expected =
		\\same: 0
		\\moved: 1
		\\fewer: 1, 1 left
	actual == expected
}
