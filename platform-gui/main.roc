platform ""
	requires {
		main : () -> Elem
	}
	exposes [Elem, Signal, Gui, Ui, Rows, Files]
	packages {
		roc: "nightly-2026-09-04-c125b82",
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
        x64glibc: { inputs: ["crt1.o", "crti.o", "libhost.a", app, "libfreetype.so", "libxkbcommon.so", "libxkbcommon-x11.so", "libgcc_s.so", "libutil.so", "librt.so", "libpthread.so", "libm.so", "libdl.so", "libc.so", "crtn.o"] },
    }


import Elem exposing [Elem]
import EachSink
import HostValue
import Signal
import Gui
import Files
import Ui
import Rows

ui_init : () -> Box(Elem)
ui_init = || {
	Box.box(main())
}
