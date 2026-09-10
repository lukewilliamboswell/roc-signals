# GPUI host test fixture

`SourceCodePro-Regular.ttf` is a regular-file copy used only by the GPUI host's
font-registration unit test. Keeping the fixture at this legacy path avoids
changing production host inputs solely for a test-data relocation and works on
Windows checkouts where Git symlinks may be unavailable.

The activity-monitor example owns the canonical release copy, license, and
provenance under `examples-gui/activity-monitor/assets/`. Platform bundles do
not include this fixture.
