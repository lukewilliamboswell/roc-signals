import Node

## Shared DOM extraction descriptor bytes. Keep these as module values so the
## larger key-shift descriptor is not allocated directly inside `State.on_key` on
## wasm. This module is internal to the platform; `main.roc` does not expose it.
EventExtraction := [].{

	unit : Node.EventExtractionPlan
	unit = { bytes: [1] }

	target_value : Node.EventExtractionPlan
	target_value = { bytes: [2, 3, 2] }

	target_checked : Node.EventExtractionPlan
	target_checked = { bytes: [3, 3, 3] }

	detail : Node.EventExtractionPlan
	detail = { bytes: [2, 1, 5] }

	key_shift : Node.EventExtractionPlan
	key_shift = { bytes: [4, 2, 3, 107, 101, 121, 2, 1, 1, 9, 115, 104, 105, 102, 116, 95, 107, 101, 121, 3, 1, 4] }
}
