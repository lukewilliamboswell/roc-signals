## Display formatting helpers: ISO-8601 timestamps from the API rendered as
## "June 1, 2026" article dates.
Format := {}.{
	display_date : Str -> Str
	display_date = |iso|
		match iso.split_first("-") {
			Ok(year_split) =>
				match year_split.after.split_first("-") {
					Ok(month_split) => {
						day_raw =
							match month_split.after.split_first("T") {
								Ok(day_split) => day_split.before
								Err(_) => month_split.after
							}
						day =
							if day_raw.starts_with("0") {
								day_raw.drop_prefix("0")
							} else {
								day_raw
							}
						"${month_name(month_split.before)} ${day}, ${year_split.before}"
					}
					Err(_) => iso
				}
			Err(_) => iso
		}

	month_name : Str -> Str
	month_name = |code|
		match code {
			"01" => "January"
			"02" => "February"
			"03" => "March"
			"04" => "April"
			"05" => "May"
			"06" => "June"
			"07" => "July"
			"08" => "August"
			"09" => "September"
			"10" => "October"
			"11" => "November"
			"12" => "December"
			_ => code
		}
}

## Dates render as "Month D, YYYY" with no zero padding on the day.
expect Format.display_date("2026-06-01T12:00:00.000Z") == "June 1, 2026"

## A two-digit day and a second-precision timestamp render the same way.
expect Format.display_date("2026-11-23T00:00:00Z") == "November 23, 2026"

## A timestamp with no date separator is passed through untouched.
expect Format.display_date("yesterday") == "yesterday"
