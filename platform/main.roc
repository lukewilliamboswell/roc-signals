platform ""
	requires {
		main : () -> Elem
	}
	exposes [Elem, Signal, Html, Ui, Http, Browser, Rows]
	packages {
		http: "https://github.com/roc-lang/http/releases/download/0.1/6LcdNq2r7xTBwj972ecYWUkMWobJr94yL2NyJpHRAXap.tar.zst",
	}
	provides { "roc_ui_init": ui_init }
	hosted {
		"roc_each_bool_sink_push": EachSink.push_bool!,
		"roc_rows_delta_clear_sink_push": EachSink.push_delta_clear!,
		"roc_rows_delta_description_sink_push": EachSink.push_delta_description!,
		"roc_rows_delta_insert_sink_push": EachSink.push_delta_insert!,
		"roc_rows_delta_move_range_sink_push": EachSink.push_delta_move_range!,
		"roc_rows_delta_remove_range_sink_push": EachSink.push_delta_remove_range!,
		"roc_rows_delta_update_sink_push": EachSink.push_delta_update!,
		"roc_rows_snapshot_description_sink_push": EachSink.push_snapshot_description!,
		"roc_rows_snapshot_sink_push": EachSink.push_snapshot!,
		"roc_host_value_clone": HostValue.clone!,
		"roc_host_value_get_with_capability": HostValue.get_with_capability!,
		"roc_host_value_get_with_split": HostValue.get_with_split!,
		"roc_host_value_store_with_capability": HostValue.store_with_capability!,
		"roc_host_value_store_with_existing_capability": HostValue.store_with_existing_capability!,
		"roc_host_value_take_with_capability": HostValue.take_with_capability!,
		"roc_host_value_take_with_split": HostValue.take_with_split!,
		"roc_rows_same_generation_callable": Rows.same_generation_callable!,
	}
	targets: {
		inputs_dir: "targets/",
		wasm32: {
			inputs: ["host.wasm", app],
			output: Shared,
			exports: [
				"roc_alloc",
				"roc_dealloc",
				"roc_ui_debug_live_allocation_bytes",
				"roc_ui_debug_live_allocation_count",
				"roc_ui_debug_live_allocation_phase",
				"roc_ui_debug_live_allocation_size",
				"roc_ui_command_buffer_len",
				"roc_ui_command_buffer_ptr",
				"roc_ui_command_record_words",
				"roc_ui_dynamic_buffer_len",
				"roc_ui_dynamic_buffer_ptr",
				"roc_ui_event",
				"roc_ui_last_error_len",
				"roc_ui_last_error_ptr",
				"roc_ui_live_host_values",
				"roc_ui_mount",
				"roc_ui_prepare_mount",
				"roc_ui_protocol_features",
				"roc_ui_protocol_version",
				"roc_ui_resolve",
				"roc_ui_set_entropy_seed",
				"roc_ui_set_location",
				"roc_ui_set_online",
				"roc_ui_set_storage_payload",
				"roc_ui_set_visibility",
				"roc_ui_storage_declaration_area",
				"roc_ui_storage_declaration_count",
				"roc_ui_storage_declaration_key_len",
				"roc_ui_storage_declaration_key_ptr",
				"roc_ui_string_buffer_len",
				"roc_ui_string_buffer_ptr",
				"roc_ui_timer",
				"roc_ui_unmount",
				"roc_ui_update_location",
				"roc_ui_update_online",
				"roc_ui_update_visibility",
			],
		},
		x64mac: { inputs: ["libhost.a", app] },
		x64musl: { inputs: ["crt1.o", "libhost.a", app, "libc.a"] },
		arm64mac: { inputs: ["libhost.a", app] },
		arm64musl: { inputs: ["crt1.o", "libhost.a", app, "libc.a"] },
	}

import Elem exposing [Elem]
import EachSink
import HostValue
import Signal
import Html
import Ui
import Http
import Browser
import Rows

ui_init : () -> Box(Elem)
ui_init = || {
	Box.box(main())
}
