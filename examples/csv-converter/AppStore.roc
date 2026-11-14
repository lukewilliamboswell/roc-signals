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
		[first, ..] => [AppStore.cells.source.update(|source| { ..source, file: Chosen(first), sample: Idle, note: "" })]
		[] => []
	}

	## The reader asks for the sample: its download starts.
	sample_asked : List(Engine.Write(_))
	sample_asked = [AppStore.cells.source.update(|source| { ..source, sample: Loading, note: "Fetching sample…" })]

	## The sample's download answered: with the file to convert, or with
	## why there is none.
	sample_arrived : Try(File, Engine.FetchError) -> List(Engine.Write(_))
	sample_arrived = |answer| [
		AppStore.cells.source.update(
			|source| match answer {
				Ok(sample) => { ..source, file: Chosen(sample), sample: Idle, note: "" }
				Err(why) => { ..source, sample: Idle, note: "the sample did not load: ${Str.inspect(why)}" }
			},
		),
	]

	## Receiving progress is courtesy text; the sample remains pending until
	## its result arrives, and choosing a different file hides the old text.
	sample_progress : Engine.Transfer -> List(Engine.Write(_))
	sample_progress = |transfer| [AppStore.cells.source.update(|source| if (source.sample == Loading) { ..source, note: AppStore.progress_text(transfer) } else source)]

	## Decimal megabytes keep the transfer figure compact and stable.
	progress_text : Engine.Transfer -> Str
	progress_text = |transfer| match transfer.total {
		Known(total) => "Fetching sample: ${megabytes(transfer.done)} of ${megabytes(total)} MB"
		Unknown => "Fetching sample: ${megabytes(transfer.done)} MB"
	}

	## A current format choice is applied; a foreign value leaves it unchanged.
	format_picked : [Chose(Csv.Format), NotOffered] -> List(Engine.Write(_))
	format_picked = |picked| match picked {
		Chose(format) => [AppStore.cells.format.set(format)]
		NotOffered => []
	}

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

## Both offered formats are selected directly; an unknown choice preserves JSON lines.
expect {
	picked = AppStore.store.after(AppStore.format_picked(Chose(JsonLines)))
	(picked.read(AppStore.cells.format), picked.after(AppStore.format_picked(NotOffered)).read(AppStore.cells.format), picked.after(AppStore.format_picked(Chose(Tsv))).read(AppStore.cells.format)) == (JsonLines, JsonLines, Tsv)
}

## An event that carries no file writes nothing, so the source stays as it was.
expect AppStore.chosen({ files: [], refused: 0 }).len() == 0

## One decimal place states bytes received without floating point rounding.
megabytes : U64 -> Str
megabytes = |bytes| "${(bytes // 1000000).to_str()}.${(bytes // 100000 % 10).to_str()}"

## Progress describes both known and unknown transfer sizes.
expect {
	[Known(4800000), Unknown].map(|total| AppStore.progress_text({ direction: Receiving, done: 1200000, total })) == ["Fetching sample: 1.2 of 4.8 MB", "Fetching sample: 1.2 MB"]
}
