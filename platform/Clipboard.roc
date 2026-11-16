import Engine
import Core

## Clipboard writes use the ordinary effect channel. They are kept on disposal;
## their result tells the app whether the browser accepted the user's copy.
Clipboard := [].{

	## Copy plain text in the current batch, retaining a click's activation.
	text : Str -> Engine.Ask({}, [NotAllowed, Unavailable, Refused])
	text = |value| Core.make_ask(ClipboardWrite({ text: value, html: Plain }), read_copy)

	## Copy one item with both rich HTML and a plain-text representation.
	html : { html : Str, text : Str } -> Engine.Ask({}, [NotAllowed, Unavailable, Refused])
	html = |value| Core.make_ask(ClipboardWrite({ text: value.text, html: Html(value.html) }), read_copy)

}

## Read the outcome of a copy, including browser denial and in-flight refusal.
## Pass only a copy result or Refused; another result is a contract error.
read_copy : Engine.Result -> Try({}, [NotAllowed, Unavailable, Refused])
read_copy = |result| match result {
	Copied => Ok({})
	ClipboardFailed(reason) => Err(reason)
	Refused => Err(Refused)
	_ => crash "contract: clipboard ask needs a clipboard result"
}

## Plain and rich writes retain exactly the app's chosen representations.
expect [Clipboard.text("text").sent(), Clipboard.html({ text: "plain", html: "<b>rich</b>" }).sent()] == [ClipboardWrite({ text: "text", html: Plain }), ClipboardWrite({ text: "plain", html: Html("<b>rich</b>") })]

## A copy distinguishes success, browser denial, absence and in-flight refusal.
expect [read_copy(Copied), read_copy(ClipboardFailed(NotAllowed)), read_copy(ClipboardFailed(Unavailable)), read_copy(Refused)] == [Ok({}), Err(NotAllowed), Err(Unavailable), Err(Refused)]
