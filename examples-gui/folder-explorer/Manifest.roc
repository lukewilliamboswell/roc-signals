## The compile-time shape of assets/manifest.json. The app ingests the file and
## parses it in a top-level definition, so a malformed manifest, an oversized
## entry list, or a bad digest fails the build with the crash message below.
Manifest :: [].{
	Entry : { name : Str, sha256 : Str }
	Wire : { assets : List(Entry) }

	parse : Str -> Try(Wire, [InvalidJson(Str), MissingRequiredField(Str)])
	parse = Json.parser_camel()

	entries : Str -> List(Entry)
	entries = |text| {
		wire = match parse(text) {
			Ok(value) => value
			Err(_) => crash "assets/manifest.json is not a complete asset manifest document"
		}
		if wire.assets.is_empty() or wire.assets.len() > 256 {
			crash "assets/manifest.json must list 1 to 256 assets"
		}
		for entry in wire.assets {
			if entry.name.is_empty() or entry.name.to_utf8().len() > 1024 {
				crash "Asset names contain 1 to 1024 UTF-8 bytes"
			}
			digest = entry.sha256.to_utf8()
			if digest.len() != 64 or !digest.all(|byte| (byte >= 48 and byte <= 57) or (byte >= 97 and byte <= 102)) {
				crash "Asset digests are 64 lowercase hex characters of SHA-256"
			}
		}
		wire.assets
	}
}

## The canonical generated manifest parses into ordered verification entries.
expect Manifest.entries("{\"assets\":[{\"name\":\"glyphs/folder.png\",\"sha256\":\"${Str.repeat("a", 64)}\"}]}") == [{ name: "glyphs/folder.png", sha256: Str.repeat("a", 64) }]
