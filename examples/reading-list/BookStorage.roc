import pf.Engine
import pf.Port

## Where the reading list keeps its books: the browser's IndexedDB, which the
## platform does not model, reached through five ports. This module is the
## Roc side of them, their names and the types that cross; `ports.mjs`,
## beside it, is the JavaScript side, which the page passes when it mounts
## the app. Each port here has exactly one handler there.
##
## - `load` is a call: the books as stored, once, when the app starts.
## - `add` is a call: Roc supplies a complete new book, including its id and
##   capture time, and the store answers with the book as stored.
## - `put` and `remove` are commands: the app has already shown the change,
##   and nothing it would do differs with the answer.
## - `stored` is a subscription: the books as stored, after any tab
##   (this one included) changes them, so every open tab converges on what
##   the store holds.
BookStorage := [].{

	## Which shelf a book is on. It crosses as its tag's name
	## (`"WantToRead"`), and IndexedDB keeps it that way.
	Shelf : [WantToRead, Reading, Finished]

	## A book as the store keeps it, which is exactly the object the
	## JavaScript reads and writes: `added_ms` is an `I64`, so it crosses as a
	## signed decimal string (`"1731200000000"`).
	Book : { id : Str, title : Str, author : Str, shelf : Shelf, added_ms : I64 }

	## What the user typed for a new book.
	NewBook : { title : Str, author : Str }

	## The module's named ports, declared once and registered together.
	Ports : {
		## Every book in the store.
		load : Port.Call({}, List(Book)),

		## Store the complete book Roc minted, returning it after the write commits.
		add : Port.Call(Book, Book),

		## Store a book as it now is (a move to another shelf).
		put : Port.Command(Book),

		## Delete a book from the store.
		remove : Port.Command({ id : Str }),

		## The books as stored, after any tab writes. Only the newest matters,
		## so a busy tab skips to it.
		stored : Port.Subscription({}, List(Book)),
	}

	## The same values serve requests and the derived program catalogue.
	ports : Ports
	ports = {
		load: Port.call({ name: "roc-signals.example/reading-list/load", timeout: Ms(10000) }),
		add: Port.call({ name: "roc-signals.example/reading-list/add", timeout: Ms(10000) }),
		put: Port.command({ name: "roc-signals.example/reading-list/put" }),
		remove: Port.command({ name: "roc-signals.example/reading-list/remove" }),
		stored: Port.subscription({ name: "roc-signals.example/reading-list/stored", delivery: Latest }),
	}

	## Every port in the module's record, checked where this list is built.
	registrations : List(Engine.PortRegistration)
	registrations = Port.registrations(BookStorage.ports)
}
