import Runtime
import Elem exposing [Elem]
import Bridge

Experiment := {}.{
	init : Elem -> Runtime.Model
	init = |root| {
		model = Runtime.init(root)
		assert_text(model, "Count: 0")
		assert_text(model, "First: a heap-backed title from an independently defined component (open)")
		assert_text(model, "Second: a heap-backed title from an independently defined component (open)")
		model
	}

	assert_text : Runtime.Model, Str -> {}
	assert_text = |model, text| if !Runtime.contains_text(model, text) { crash "experimental render text mismatch" } else { {} }

	step : Runtime.Model, U64 -> Runtime.Model
	step = |model, action| {
		if action == 8 {
			first = Runtime.node(model, 3)
			second = Runtime.node(model, 7)
			_ = Bridge.require_owners(first.cap, first.value, second.value)
			crash "same-type foreign capability was not rejected"
		}
		if action == 6 {
			stale = Runtime.event_id(model, "Toggle First")
			retired = Runtime.click(model, "Show/hide First")
			_ = Runtime.event(retired, stale)
			crash "stale event was not rejected"
		}
		if action == 7 {
			flag = Runtime.node(model, 0)
			count = Runtime.node(model, 1)
			_ = Bridge.require_owners(flag.cap, flag.value, count.value)
			crash "mismatched capability was not rejected"
		}
		label = match action { 0 => "Toggle First", 1 => "Increment", 2 => "Keep count", 3 => "Toggle Second", 4 => "Show/hide First", 5 => "Show/hide First", _ => crash "unknown test action" }
		next = Runtime.click(model, label)
		match action {
			0 => {
				assert_text(next, "First: a heap-backed title from an independently defined component (done)")
				assert_text(next, "Second: a heap-backed title from an independently defined component (open)")
				if next.calls != 3 or next.sets != 1 or next.created != 0 or next.disposed != 0 { crash "diamond work mismatch" }
			}
			1 => {
				assert_text(next, "Count: 1")
				if next.calls != 1 or next.sets != 1 { crash "counter work mismatch" }
			}
			2 => {
				assert_text(next, "Count: 1")
				if next.calls != 0 or next.sets != 0 { crash "equal source propagated" }
			}
			3 => {
				assert_text(next, "Second: a heap-backed title from an independently defined component (done)")
				assert_text(next, "First: a heap-backed title from an independently defined component (done)")
				if next.calls != 3 or next.sets != 1 { crash "second diamond work mismatch" }
			}
			4 => {
				assert_text(next, "First hidden")
				if Runtime.contains_text(next, "First: a heap-backed title from an independently defined component (done)") { crash "retired component still rendered" }
			}
			5 => {
				assert_text(next, "First: a heap-backed title from an independently defined component (open)")
				assert_text(next, "Second: a heap-backed title from an independently defined component (done)")
				assert_text(next, "Count: 1")
			}
			_ => crash "unknown action"
		}
		next
	}
}
