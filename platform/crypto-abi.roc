# A concrete view of the native runner's actual hosted signature, for roc glue.
# The ordinary platform's generic store has no committed layout until an app
# specializes it, so glue this fixture instead of guessing the record order.
platform ""
	requires {
		main : {}
	}
	exposes []
	packages {}
	provides { "roc_entry": entry }
	hosted {
		"roc_test_crypto": Cli.crypto!,
		"roc_test_file_exists": Cli.file_exists!,
		"roc_test_hold_key": Cli.hold_key!,
		"roc_test_live_allocations": Cli.live_allocations!,
		"roc_test_live_bytes": Cli.live_bytes!,
		"roc_test_live_files": Cli.live_files!,
		"roc_test_live_keys": Cli.live_keys!,
		"roc_test_mint_files": Cli.mint_files!,
		"roc_test_mute_dbg": Cli.mute_dbg!,
		"roc_test_now_ns": Cli.now_ns!,
		"roc_test_read_file": Cli.read_file!,
		"roc_test_sha256": Cli.sha256!,
		"roc_test_stderr": Cli.stderr!,
		"roc_test_stdout": Cli.stdout!,
		"roc_test_work": Cli.work!,
	}

import Cli

entry : {} -> U8
entry = |_| 0
