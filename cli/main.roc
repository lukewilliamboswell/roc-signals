# The `signals.roc` tool: create, serve, build and test a roc-signals app.
# Each release bundles this package with its runtime files and its platform's
# URL (`Bundle.roc`), and publishes a small `signals.roc` app that runs it.
package
	[Signals]
	{
		cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.0/2yhxoR7cZPSYbyUzPWULFw8AA6QEcdsgFNRmzu7pZbst.tar.zst",
	}
