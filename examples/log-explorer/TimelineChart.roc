import plume.Axis
import plume.Chart
import plume.Color
import plume.Coordinate
import plume.Font
import plume.Layout
import plume.Line
import plume.Scatter
import plume.Size
import plume.Time
import plume.Title
import Log

## The Log Explorer's timeline, drawn with Plume: entries over time, a line
## for each level the log has, and a line for the matches of a search. It
## is built on the page from the timeline the overview task answers (at
## most `Log.most_buckets` points a line) and drawn by the `plume-chart`
## element, which reports a click on a point as the point's time.
TimelineChart := [].{

	## What a figure shows: a log's timeline, how many lines a search
	## matched in each of its buckets (`NotCounted` with no search), and
	## the name under which a viewer's zoom is kept while the figure
	## changes.
	Props : { timeline : Log.Timeline, matches : [NotCounted, Counted(List(U64))], revision : Str, theme : Theme }

	## The media preference selects a presentation, not another dataset.
	Theme : [Light, Dark]

	## Decode the declared browser preference once at its boundary.
	preferred_theme : Bool -> Theme
	preferred_theme = |matches| if matches {
		Dark
	} else {
		Light
	}

	## Both Plotly backgrounds use this authored color.
	background : Theme -> Str
	background = |theme| match theme {
		Light => "rgb(255,255,255)"
		Dark => "rgb(15,23,42)"
	}

	## The chart's Plotly figure as JSON, for the element's `data-figure`.
	## A log with no dated entries has no timeline, and its figure is
	## absent, which the element draws as nothing.
	figure : Props -> [Absent, Present(Str)]
	figure = |props|
		match TimelineChart.chart(props) {
			Ok(figure_chart) => Present(figure_chart.to_json())
			Err(_) => Absent
		}

	## The chart itself. It cannot fail for a timeline the index built
	## (every minute it holds is a real time of years 1 to 9999, and every
	## count is finite); a timeline with no buckets is `NoEntries`.
	chart : Props -> Try(Chart, _)
	chart = |{ timeline, matches, revision, theme }| {
		if timeline.buckets.is_empty() {
			return Err(NoEntries)
		}
		var $times = []
		var $at = timeline.start
		for _bucket in timeline.buckets {
			$times = $times.append(Coordinate.from_time(TimelineChart.time_of($at * timeline.width)?))
			$at = $at + 1
		}
		times = $times
		series = |name, color, width, counts| {
			points = List.map2(times, counts, |x, count| { x, count }).map_try(|{ x, count }| Coordinate.from_number(count.to_f64()).map_ok(|y| { x, y }))?
			Ok(Scatter(Scatter.new({ data: points, name, line: Line.new({ color, width })? })))
		}
		var $traces = []
		for level in Log.levels {
			counts = timeline.buckets.map(|bucket| Log.tally_of(bucket.tally, level))
			if counts.any(|count| count > 0) {
				$traces = $traces.append(series(Log.level_name(level), TimelineChart.level_color(level, theme), 1.5, counts)?)
			}
		}
		traces = match matches {
			Counted(counts) => $traces.append(series("Matches", TimelineChart.ink(theme), 3, counts)?)
			NotCounted => $traces
		}
		Ok(
			Chart.new({
				traces,
				layout: Layout.new({
					global_font: Font.new({ color: TimelineChart.ink(theme) })?,
					size: Size.new({ height: Pixels(300), margin: Pixels({ left: 56, right: 16, top: 32, bottom: 40 }) })?,
					x_axis: Axis.new({ type: Date, color: TimelineChart.ink(theme) })?,
					y_axis: Axis.new({ title: Title.new({ text: "Entries per ${TimelineChart.width_name(timeline.width)}" }), range: FromZero, color: TimelineChart.ink(theme) })?,
					legend: Shown,
					legend_position: Above,
					hover_mode: XUnified,
					ui_revision: Preserve(revision),
				}),
			}),
		)
	}

	## The instant a minute (counted as `Log.minute_of` counts) starts.
	time_of : U64 -> Try(Time, [TimeOutOfRange(I64)])
	time_of = |minute| Time.from_epoch_millis((minute.to_i64_wrap() - Log.epoch_minute.to_i64_wrap()) * 60000)

	## A level's line colour, in the tone of its badge.
	level_color : Log.Level, Theme -> Color
	level_color = |level, theme|
		match (theme, level) {
			(Dark, Trace) => Color.rgb({ red: 148, green: 163, blue: 184 })
			(Dark, Debug) => Color.rgb({ red: 203, green: 213, blue: 225 })
			(Dark, Info) => Color.rgb({ red: 96, green: 165, blue: 250 })
			(Dark, Warn) => Color.rgb({ red: 251, green: 191, blue: 36 })
			(Dark, Error) => Color.rgb({ red: 248, green: 113, blue: 113 })
			(Dark, Fatal) => Color.rgb({ red: 192, green: 132, blue: 252 })
			(Light, Trace) => Color.rgb({ red: 203, green: 213, blue: 225 })
			(Light, Debug) => Color.rgb({ red: 148, green: 163, blue: 184 })
			(Light, Info) => Color.rgb({ red: 37, green: 99, blue: 235 })
			(Light, Warn) => Color.rgb({ red: 217, green: 119, blue: 6 })
			(Light, Error) => Color.rgb({ red: 220, green: 38, blue: 38 })
			(Light, Fatal) => Color.rgb({ red: 126, green: 34, blue: 206 })
		}

	## Text and the matches line retain contrast against the chosen background.
	ink : Theme -> Color
	ink = |theme| match theme {
		Light => Color.rgb({ red: 15, green: 23, blue: 42 })
		Dark => Color.rgb({ red: 226, green: 232, blue: 240 })
	}

	## A bucket's width in words: `minute`, `30 minutes`, `6 hours`, `day`.
	width_name : U64 -> Str
	width_name = |width|
		if width == 1 {
			"minute"
		} else if width % 10080 == 0 {
			if (width == 10080) "week" else "${(width // 10080).to_str()} weeks"
		} else if width % 1440 == 0 {
			if (width == 1440) "day" else "${(width // 1440).to_str()} days"
		} else if width % 60 == 0 {
			if (width == 60) "hour" else "${(width // 60).to_str()} hours"
		} else {
			"${width.to_str()} minutes"
		}

	## The bucket where a count is highest, the earliest of equals: its time
	## (`2026-11-11 12:14`) and the count. A timeline where every count is
	## zero has no peak.
	peak : List(U64), { timeline : Log.Timeline } -> [NoPeak, Peak({ time : Str, count : U64 })]
	peak = |counts, { timeline }| {
		var $best = NoPeak
		var $at = timeline.start
		for count in counts {
			$best = match $best {
				Peak(best) if best.count >= count => $best
				_ if count == 0 => $best
				_ =>
					match TimelineChart.time_of($at * timeline.width) {
						Ok(time) => Peak({ time: time.to_str(), count })
						Err(TimeOutOfRange(_)) => $best
					}
			}
			$at = $at + 1
		}
		$best
	}
}

## A timeline of three minutes, with an error burst in the second.
three_minutes : Log.Timeline
three_minutes = {
	width: 1,
	start: Log.minute_of("2026-11-11T12:13".to_utf8()) ?? 0,
	buckets: [
		{ tally: { trace: 0, debug: 0, info: 5, warn: 0, error: 1, fatal: 0 }, first: Line(0) },
		{ tally: { trace: 0, debug: 0, info: 4, warn: 2, error: 9, fatal: 0 }, first: Line(6) },
		{ tally: { trace: 0, debug: 0, info: 6, warn: 0, error: 0, fatal: 0 }, first: Line(21) },
	],
}

## The figure has a line for each level the log has, at each minute's
## start, and a line for a search's matches; its zoom is kept under the
## revision given.
expect {
	json = match TimelineChart.figure({ timeline: three_minutes, matches: Counted([0, 7, 1]), revision: "app.log", theme: Light }) {
		Present(figure) => figure
		Absent => crash "expected timeline figure"
	}
	actual = {
		lines: ["\"INFO\"", "\"WARN\"", "\"ERROR\"", "\"Matches\""].map(|name| json.contains(name)),
		absent: ["\"TRACE\"", "\"DEBUG\"", "\"FATAL\""].map(|name| json.contains(name)),
		first_minute: json.contains("2026-11-11 12:13"),
		revision: json.contains("\"uirevision\":\"app.log\""),
	}
	actual == { lines: [Bool.True, Bool.True, Bool.True, Bool.True], absent: [Bool.False, Bool.False, Bool.False], first_minute: Bool.True, revision: Bool.True }
}

## A log with no dated entries draws nothing.
expect TimelineChart.figure({ timeline: Log.no_timeline, matches: NotCounted, revision: "", theme: Light }) == Absent

## The peak is the earliest highest bucket; all zeros have none.
expect {
	errors = three_minutes.buckets.map(|b| b.tally.error)
	actual = {
		errors: TimelineChart.peak(errors, { timeline: three_minutes }),
		tie: TimelineChart.peak([3, 3, 1], { timeline: three_minutes }),
		none: TimelineChart.peak([0, 0, 0], { timeline: three_minutes }),
	}
	actual == { errors: Peak({ time: "2026-11-11 12:14", count: 9 }), tie: Peak({ time: "2026-11-11 12:13", count: 3 }), none: NoPeak }
}

## Widths are named as a reader says them.
expect [1, 5, 30, 60, 360, 1440, 10080, 20160].map(TimelineChart.width_name) == ["minute", "5 minutes", "30 minutes", "hour", "6 hours", "day", "week", "2 weeks"]

## A media change redraws colors while preserving the dataset's zoom identity.
expect {
	json = match TimelineChart.figure({ timeline: three_minutes, matches: Counted([0, 7, 1]), revision: "app.log", theme: Dark }) {
		Present(figure) => figure
		Absent => crash "TimelineChart test: nonempty timeline has no figure"
	}
	actual = {
		info: json.contains("rgb(96, 165, 250)"),
		ink: json.contains("rgb(226, 232, 240)"),
		revision: json.contains("\"uirevision\":\"app.log\""),
		background: TimelineChart.background(Dark),
	}
	actual == { info: Bool.True, ink: Bool.True, revision: Bool.True, background: "rgb(15,23,42)" }
}
