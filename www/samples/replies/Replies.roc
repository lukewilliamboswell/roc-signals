import pf.Engine exposing [Elem, In, Root, State, Val]
import pf.Html

## A small mail reader: which message is open, and a reply to it. Both are
## local state, since no other part of an app would read either.
Replies := [].{
	# region open
	Message : { id : Str, subject : Str }

	inbox : List(Message)
	inbox = [{ id: "m1", subject: "Welcome" }, { id: "m2", subject: "Invoice" }]

	## Inside the state that holds the open message.
	Mail : In(Root, Message)

	program : Engine.Program
	program = Engine.program(|| Engine.state({ id: "m1", subject: "Welcome" }, Replies.view))

	## A button for each message, and the reply to the open one. The reply
	## is built again whenever the open message's id changes.
	view : State(Mail, Message) -> Elem(Mail)
	view = |open|
		Html.div(
			"mail",
			Replies.inbox
				.map(|message| Html.button(message.subject, [], open.update(|_| message)))
				.append(Engine.remount_on(open.val().map(|message| message.id), || Replies.reply(open.val()))),
		)
	# endregion open

	# region reply
	## The reply to the message `to`. The draft is the reply's own state: it
	## is created with the reply and goes with it, so each message the
	## reader opens gets a draft that starts empty.
	reply : Val(ctx, Message) -> Elem(ctx)
	reply = |to|
		Engine.state(
			"",
			|draft|
				Html.div(
					"reply",
					[
						Html.p_v(to.lift().map(|message| "Reply to ${message.subject}"), [Engine.test_id("to")]),
						Html.textarea(Engine.const("Reply"), draft.val(), [], draft.set_value(|_, typed| typed)),
						Html.p_v(draft.val().map(Replies.length), [Engine.test_id("length")]),
					],
				),
		)
	# endregion reply

	## How long a draft is, as its reader is told.
	length : Str -> Str
	length = |text|
		match text.count_utf8_bytes() {
			1 => "1 byte"
			count => "${count.to_str()} bytes"
		}
}

## A draft's length is counted in bytes, with a singular for one.
expect {
	actual =
		\\empty: ${Replies.length("")}
		\\one: ${Replies.length("a")}
		\\more: ${Replies.length("Thanks!")}
	expected =
		\\empty: 0 bytes
		\\one: 1 byte
		\\more: 7 bytes
	actual == expected
}
