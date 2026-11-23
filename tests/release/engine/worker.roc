app [main!] { cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst", engine: "https://example.invalid/0.8.0-rc1/ENGINE.tar.zst" }

import Fixture

main! = |_| {
	Fixture.worker_check!()
	Ok({})
}
