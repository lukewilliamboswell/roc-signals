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
Store := [].{

	## Which shelf a book is on. It crosses as its tag's name
	## (`"WantToRead"`), and IndexedDB keeps it that way.
	Shelf : [WantToRead, Reading, Finished]

	## A book as the store keeps it, which is exactly the object the
	## JavaScript reads and writes: `added_ms` is an `I64`, so it crosses as a
	## signed decimal string (`"1731200000000"`).
	Book : { id : Str, title : Str, author : Str, shelf : Shelf, added_ms : I64 }

	## What the user typed for a new book.
	NewBook : { title : Str, author : Str }

	## Every book in the store.
	load : Port.Call({}, List(Book))
	load = Port.call({ name: "roc-signals.example/reading-list/load", timeout: Ms(10000) })

	## Store the complete book Roc minted, returning it after the write commits.
	add : Port.Call(Book, Book)
	add = Port.call({ name: "roc-signals.example/reading-list/add", timeout: Ms(10000) })

	## Store a book as it now is (a move to another shelf).
	put : Port.Command(Book)
	put = Port.command({ name: "roc-signals.example/reading-list/put" })

	## Delete a book from the store.
	remove : Port.Command({ id : Str })
	remove = Port.command({ name: "roc-signals.example/reading-list/remove" })

	## The books as stored, after any tab writes. Only the newest matters,
	## so a busy tab skips to it.
	stored : Port.Subscription({}, List(Book))
	stored = Port.subscription({ name: "roc-signals.example/reading-list/stored", delivery: Latest })

	## The program's entry for `Program.with_ports`: every port, once.
	registrations : List(Engine.PortRegistration)
	registrations = [
		Store.load.registration(),
		Store.add.registration(),
		Store.put.registration(),
		Store.remove.registration(),
		Store.stored.registration(),
	]
}
