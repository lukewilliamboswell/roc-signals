# The `signals.roc` tool: create, serve, build and test a roc-signals app.
# Each release bundles this package with its runtime files and its platform's
# URL (`Bundle.roc`), and publishes a small `signals.roc` app that runs it.
package
	[Signals]
	{
		cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.27.0/9yjxqdGTP4xSpSEmDazwTmRsehfRZzA19pwEKkR6fj1g.tar.zst",
	}
