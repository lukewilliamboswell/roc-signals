import pf.Engine exposing [File]
import Csv

## The CSV Converter's store: what the page has been given to convert and
## what to convert it to. The chooser and the format's select write them,
## and the conversion follows both, so they are the state the page shares.
##
## - `source`: the file to convert, and how the sample's download stands.
##   They are one value: an arriving sample replaces the file, and a file
##   the reader chooses clears what the last download reported.
## - `format`: what the file is converted to.
##
## What the result panel alone cares about (the file a click asks to save,
## the lines of the preview) is that panel's own state, not a cell.
##
## The store stands apart from the page (`ConverterApp`) so that what the
## app shares and how it changes are read, and tested, without the markup.
##
## The module's one tag, `Converter`, is the store's name. Nothing spells
## the store's contents type: an annotation that mentions it says `_`.
AppStore := [Converter].{

	## What the page has to convert. `note` is why the last download of the
	## sample gave no file, or `""`.
	Source : { file : [Nothing, Chosen(File)], sample : [Idle, Loading], note : Str }

	## Nothing chosen and nothing asked for.
	no_source : Source
	no_source = { file: Nothing, sample: Idle, note: "" }

	## The store: its name, and its cells with their starting values.
	store = Engine.store(
		AppStore.Converter,
		{
			source: Engine.cell(AppStore.no_source),
			format: Engine.cell(Tsv),
		}.Engine.Cells,
	)

	## The store's cells.
	cells = AppStore.store.cells()

	## The reader chose or dropped files: the first becomes the file to
	## convert, and what the last download reported is cleared. An event
	## that carried no file changes nothing.
	chosen : Engine.Received -> List(Engine.Write(_))
	chosen = |{ files, refused: _ }| match files {
		[first, ..] => [AppStore.cells.source.update(|source| { ..source, file: Chosen(first), note: "" })]
		[] => []
	}

	## The reader asks for the sample: its download starts.
	sample_asked : List(Engine.Write(_))
	sample_asked = [AppStore.cells.source.update(|source| { ..source, sample: Loading })]

	## The sample's download answered: with the file to convert, or with
	## why there is none.
	sample_arrived : Try(File, Engine.FetchError) -> List(Engine.Write(_))
	sample_arrived = |answer| [
		AppStore.cells.source.update(
			|source| match answer {
				Ok(sample) => { ..source, file: Chosen(sample), sample: Idle }
				Err(why) => { ..source, sample: Idle, note: "the sample did not load: ${Str.inspect(why)}" }
			},
		),
	]

	## The reader picks a format by the value of its option.
	format_picked : Str -> List(Engine.Write(_))
	format_picked = |value| [AppStore.cells.format.set(AppStore.format_of(value))]

	## The format an option's value names, and the value of a format's
	## option.
	format_of : Str -> Csv.Format
	format_of = |value| if (value == "jsonl") JsonLines else Tsv

	option_of : Csv.Format -> Str
	option_of = |format| match format {
		Tsv => "tsv"
		JsonLines => "jsonl"
	}
}

## The page starts with nothing to convert, to TSV.
expect (AppStore.store.read(AppStore.cells.source), AppStore.store.read(AppStore.cells.format)) == (AppStore.no_source, Tsv)

## Asking for the sample starts its download, and a download that fails
## ends it with a note and no file.
expect {
	asked = AppStore.store.after(AppStore.sample_asked)
	failed = asked.after(AppStore.sample_arrived(Err(Status(404))))
	(asked.read(AppStore.cells.source).sample, failed.read(AppStore.cells.source)) == (Loading, { file: Nothing, sample: Idle, note: "the sample did not load: Status(404)" })
}

## A format is picked by its option's value; a value no option has is TSV.
expect {
	picked = |value| AppStore.store.after(AppStore.format_picked(value)).read(AppStore.cells.format)
	actual =
		\\jsonl: ${Str.inspect(picked("jsonl"))}
		\\tsv: ${Str.inspect(picked("tsv"))}
		\\another value: ${Str.inspect(picked("?"))}
		\\options: ${Str.inspect([Tsv, JsonLines].map(AppStore.option_of))}
	expected =
		\\jsonl: JsonLines
		\\tsv: Tsv
		\\another value: Tsv
		\\options: ["tsv", "jsonl"]
	actual == expected
}

## An event that carries no file writes nothing, so the source stays as it was.
expect AppStore.chosen({ files: [], refused: 0 }).len() == 0
