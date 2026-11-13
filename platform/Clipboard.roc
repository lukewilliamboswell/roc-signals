import Engine

## Clipboard writes use the ordinary effect channel. They are kept on disposal;
## their result tells the app whether the browser accepted the user's copy.
Clipboard := [].{

	## Copy plain text in the current batch, retaining a click's activation.
	text : Str -> Engine.Request
	text = |value| ClipboardWrite({ text: value, html: Plain })

	## Copy one item with both rich HTML and a plain-text representation.
	html : { html : Str, text : Str } -> Engine.Request
	html = |value| ClipboardWrite({ text: value.text, html: Html(value.html) })

	## Read the outcome of a copy, including browser denial and in-flight refusal.
	## Pass only a copy result or Refused; another result is a contract error.
	written : Engine.Result -> Try({}, [NotAllowed, Unavailable, Refused])
	written = |result| match result {
		Copied => Ok({})
		ClipboardFailed(reason) => Err(reason)
		Refused => Err(Refused)
		_ => crash "contract: Clipboard.written needs a clipboard result"
	}
}

## Plain and rich writes retain exactly the app's chosen representations.
expect [Clipboard.text("text"), Clipboard.html({ text: "plain", html: "<b>rich</b>" })] == [ClipboardWrite({ text: "text", html: Plain }), ClipboardWrite({ text: "plain", html: Html("<b>rich</b>") })]

## A copy distinguishes success, browser denial, absence and in-flight refusal.
expect [Clipboard.written(Copied), Clipboard.written(ClipboardFailed(NotAllowed)), Clipboard.written(ClipboardFailed(Unavailable)), Clipboard.written(Refused)] == [Ok({}), Err(NotAllowed), Err(Unavailable), Err(Refused)]
