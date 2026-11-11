import pf.Engine
import pf.Port
import Store

## The reading list's state and every change to it, as pure functions the
## view's handlers and effect sites call, and the `expect`s below test.
##
## The app keeps its own copy of the books and changes it in the turn of the
## click, so the page never waits on the store. Each change the store must
## learn of is posted to an outbox, which an `on_post` site sends as
## commands. The store's own copy wins whenever it reports one: once at
## start (`load`), and after any tab writes (`stored`), so every open tab
## ends up showing what the store holds.
ReadingList := [].{

	## Which books the list shows.
	Showing : [Everything, Only(Store.Shelf)]

	## A change the store must learn of, sent as a command.
	Write : [Put(Store.Book), Delete(Str)]

	## The app's state.
	##
	## - `books`: the app's copy of the shelf, newest first.
	## - `store`: whether that copy has come from the store yet, or why it
	##   cannot.
	## - `adding`: the books the user asks to add, posted for the store.
	## - `writes`: each change's writes, posted for the store as commands.
	## - `note`: the latest thing that went wrong, for the user.
	S : {
		books : List(Store.Book),
		store : [Loading, Loaded, Unreadable(Str)],
		showing : Showing,
		title : Str,
		author : Str,
		adding : Engine.Outbox(Store.NewBook),
		writes : Engine.Outbox(List(Write)),
		note : Str,
	}

	## The state at start: nothing loaded, nothing to send.
	initial : S
	initial = {
		books: [],
		store: Loading,
		showing: Everything,
		title: "",
		author: "",
		adding: Engine.outbox({}),
		writes: Engine.outbox({}),
		note: "",
	}

	## The store's answer to `load`. It counts only while the app is still
	## loading: a `stored` message that came first is newer.
	loaded : S, Try(List(Store.Book), Port.Error) -> S
	loaded = |s, answer|
		match s.store {
			Loading =>
				match checked(answer) {
					Ok(books) => { ..s, books, store: Loaded }
					Err(why) => { ..s, store: Unreadable(why) }
				}
			_ => s
		}

	## A message of `stored`: the books as stored after a write in any tab,
	## which replace the app's copy.
	restocked : S, Try(List(Store.Book), Port.Error) -> S
	restocked = |s, message|
		match message {
			Err(Closed) => { ..s, note: "Changes made in other tabs no longer reach this one. Reload to see them." }
			_ =>
				match checked(message) {
					Ok(books) => { ..s, books, store: Loaded }
					Err(why) => { ..s, note: "A change made in another tab could not be read: ${why}" }
				}
		}

	## Whether the form can add the book it holds: the shelf is loaded and
	## the book has a title.
	can_add : S -> Bool
	can_add = |s| s.store == Loaded and !s.title.trim().is_empty()

	## The user adds the book the form holds, which clears the form. Nothing
	## happens while it cannot be added.
	submit : S -> S
	submit = |s|
		if ReadingList.can_add(s) {
			book = { title: s.title.trim(), author: s.author.trim() }
			{ ..s, adding: s.adding.post(book), title: "", author: "", note: "" }
		} else {
			s
		}

	## The store's answer to `add`: the book as stored, which joins the list
	## (or replaces itself there, if a `stored` message brought it first).
	added : S, Store.NewBook, Try(Store.Book, Port.Error) -> S
	added = |s, asked, answer|
		match answer {
			Ok(book) => { ..s, books: newest_first(s.books.drop_if(|b| b.id == book.id).append(book)) }
			Err(error) => { ..s, note: "\"${asked.title}\" was not added: ${explain(error)}" }
		}

	## Move a book to its next shelf: want to read, reading, finished, and
	## from finished back to reading.
	advance : S, Str -> S
	advance = |s, id|
		match s.books.find_first(|b| b.id == id) {
			Ok(book) => {
				moved = { ..book, shelf: next_shelf(book.shelf) }
				send({ ..s, books: s.books.map(|b| if (b.id == id) moved else b) }, [Put(moved)])
			}
			Err(_) => s
		}

	## Delete a book.
	delete : S, Str -> S
	delete = |s, id| send({ ..s, books: s.books.drop_if(|b| b.id == id) }, [Delete(id)])

	## Delete every finished book.
	clear_finished : S -> S
	clear_finished = |s| {
		finished = s.books.keep_if(|b| b.shelf == Finished)
		if (finished.is_empty()) s else send({ ..s, books: s.books.drop_if(|b| b.shelf == Finished) }, finished.map(|b| Delete(b.id)))
	}

	## The commands for one change's writes.
	requests : List(Write) -> List(Engine.Req)
	requests = |writes|
		writes.map(
			|write| match write {
				Put(book) => Store.put.send(book)
				Delete(id) => Store.remove.send({ id: id })
			},
		)

	## The books the list shows.
	shown : S -> List(Store.Book)
	shown = |s|
		match s.showing {
			Everything => s.books
			Only(shelf) => s.books.keep_if(|b| b.shelf == shelf)
		}

	## How many books are on a shelf, or on any.
	count : S, Showing -> U64
	count = |s, showing|
		match showing {
			Everything => s.books.len()
			Only(shelf) => s.books.count_if(|b| b.shelf == shelf)
		}

	## The line above the list.
	status : S -> Str
	status = |s|
		match s.store {
			Loading => "Opening your shelf…"
			Unreadable(why) => "Your shelf could not be read: ${why}"
			Loaded =>
				match (s.books.len(), ReadingList.shown(s).len()) {
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

## Post the change's writes, for the `on_post` site to send. A change
## posts all its writes at once: an outbox takes one post per turn.
send : ReadingList.S, List(ReadingList.Write) -> ReadingList.S
send = |s, writes| { ..s, writes: s.writes.post(writes) }

next_shelf : Store.Shelf -> Store.Shelf
next_shelf = |shelf|
	match shelf {
		WantToRead => Reading
		Reading => Finished
		Finished => Reading
	}

## The store's books as the list shows them, newest first, or why there
## are none. The port's type guarantees each book's shape, but not that ids
## are distinct, and the list keys its rows by id: two books under one id
## would be a contract error there, so they are refused here, at the door.
checked : Try(List(Store.Book), Port.Error) -> Try(List(Store.Book), Str)
checked = |answer|
	match answer {
		Ok(books) =>
			if Set.from_list(books.map(|b| b.id)).len() == books.len() {
				Ok(newest_first(books))
			} else {
				Err("it holds two books under one id.")
			}
		Err(error) => Err(explain(error))
	}

## Newest first; books added in the same millisecond by id, so every tab
## orders them alike.
newest_first : List(Store.Book) -> List(Store.Book)
newest_first = |books|
	books.sort_with(
		|a, b|
			if a.added_ms > b.added_ms {
				Before
			} else if a.added_ms < b.added_ms {
				After
			} else {
				compare_text(a.id, b.id)
			},
	)

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

## Why a port gave no answer, for the user.
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

## Loading sorts newest first; a load answer that comes after a `stored`
## message is older than it, so it is ignored; and two books under one id
## are refused rather than shown.
expect {
	first = ReadingList.loaded(ReadingList.initial, Ok([dune, piranesi]))
	late = ReadingList.loaded(ReadingList.restocked(ReadingList.initial, Ok([dune])), Ok([dune, piranesi]))
	failed = ReadingList.loaded(ReadingList.initial, Err(Timeout))
	twice = ReadingList.loaded(ReadingList.initial, Ok([dune, { ..piranesi, id: "b1" }]))
	shared = ReadingList.restocked(first, Ok([dune, dune]))
	actual =
		\\first: ${Str.inspect(first.books.map(|b| b.title))} ${Str.inspect(first.store)}
		\\late: ${Str.inspect(late.books.map(|b| b.title))}
		\\failed: ${ReadingList.status(failed)}
		\\one id twice: ${ReadingList.status(twice)}
		\\then: ${shared.books.len().to_str()} ${shared.note}
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
	ready = ReadingList.loaded(ReadingList.initial, Ok([]))
	once = ReadingList.submit({ ..ready, title: " Dune ", author: "Frank Herbert" })
	twice = ReadingList.submit({ ..once, title: "Dune", author: "Frank Herbert" })
	actual =
		\\loading: ${Str.inspect(ReadingList.submit({ ..ReadingList.initial, title: "Dune" }).adding.last())}
		\\blank: ${Str.inspect(ReadingList.submit({ ..ready, title: "  " }).adding.last())}
		\\once: ${Str.inspect(once.adding.last())} "${once.title}"
		\\twice: ${Str.inspect(twice.adding.last())} ${Str.inspect(twice.adding == once.adding)}
	expected =
		\\loading: Unposted
		\\blank: Unposted
		\\once: Posted({ author: "Frank Herbert", title: "Dune" }) ""
		\\twice: Posted({ author: "Frank Herbert", title: "Dune" }) False
	actual == expected
}

## Moving and deleting change the app's copy at once and post their writes;
## moving a book back is a write of its own.
expect {
	s = ReadingList.loaded(ReadingList.initial, Ok([dune, piranesi]))
	started = ReadingList.advance(s, "b1")
	finished = ReadingList.advance(started, "b1")
	again = ReadingList.advance(finished, "b1")
	cleared = ReadingList.clear_finished(finished)
	actual =
		\\started: ${Str.inspect(started.writes.last())}
		\\again: ${Str.inspect(again.books.map(|b| b.shelf))} ${Str.inspect(again.writes.last())}
		\\cleared: ${Str.inspect(cleared.books)} ${Str.inspect(cleared.writes.last())}
		\\missing: ${Str.inspect(ReadingList.advance(s, "b9") == s)}
	expected =
		\\started: Posted([Put({ added_ms: 10, author: "Frank Herbert", id: "b1", shelf: Reading, title: "Dune" })])
		\\again: [Finished, Reading] Posted([Put({ added_ms: 10, author: "Frank Herbert", id: "b1", shelf: Reading, title: "Dune" })])
		\\cleared: [] Posted([Delete("b2"), Delete("b1")])
		\\missing: True
	actual == expected
}

## A store's answer replaces the app's copy; a book the store added joins it
## once, even when `stored` brought it first; a failure says which book.
expect {
	s = ReadingList.loaded(ReadingList.initial, Ok([dune]))
	echoed = ReadingList.added(ReadingList.restocked(s, Ok([dune, piranesi])), { title: "Piranesi", author: "" }, Ok(piranesi))
	failed = ReadingList.added(s, { title: "Piranesi", author: "" }, Err(Threw("QuotaExceededError")))
	closed = ReadingList.restocked(s, Err(Closed))
	actual =
		\\echoed: ${Str.inspect(echoed.books.map(|b| b.title))}
		\\failed: ${failed.note}
		\\closed: ${closed.note}
	expected =
		\\echoed: ["Piranesi", "Dune"]
		\\failed: "Piranesi" was not added: the store said "QuotaExceededError".
		\\closed: Changes made in other tabs no longer reach this one. Reload to see them.
	actual == expected
}

## The status line counts what the list shows.
expect {
	s = ReadingList.loaded(ReadingList.initial, Ok([dune, piranesi]))
	actual =
		\\all: ${ReadingList.status(s)}
		\\finished: ${ReadingList.status({ ..s, showing: Only(Finished) })}
		\\reading: ${ReadingList.status({ ..s, showing: Only(Reading) })}
		\\empty: ${ReadingList.status(ReadingList.loaded(ReadingList.initial, Ok([])))}
	expected =
		\\all: 2 books
		\\finished: 1 book
		\\reading: No books on this shelf.
		\\empty: No books yet. Add the first one above.
	actual == expected
}
