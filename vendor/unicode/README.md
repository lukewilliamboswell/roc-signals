# Roc Unicode dependency

Unmodified runtime package sources from [roc-lang/unicode](https://github.com/roc-lang/unicode)
at commit `cc2c07d38543d5c7a0c533cb18e836ee25d0cb26`, implementing Unicode 17.0.0.
`upstream.json` records the revision and SHA-256 of each copied source/license.
The upstream test-only entry point `package/test-main.roc` is excluded.

This local package is an application dependency; it adds no host capability or
reactive mechanism. Notes imports it through its app header. Keep upstream
sources unchanged, including generated formatting. For an update, replace the
runtime `.roc` files from one reviewed upstream revision, preserve both licenses,
and regenerate the manifest hashes. Run the Notes pure and GUI semantic tests
with this repository's pinned Roc compiler before committing the update.

Upstream pins a newer compiler; the consumed grapheme, word, and scalar-property
APIs are validated here with `nightly-2026-09-04-c125b82`. That does not establish
compatibility for every unused API in this snapshot.
