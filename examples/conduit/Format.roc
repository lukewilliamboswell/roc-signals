## Display formatting helpers: ISO-8601 timestamps from the API rendered as
## "June 1, 2026" article dates.
Format := {}.{
	display_date : Str -> Str
	display_date = |iso|
		match Str.find_first(iso, "-") {
			Ok(year_split) =>
				match Str.find_first(year_split.after, "-") {
					Ok(month_split) => {
						day_raw =
							match Str.find_first(month_split.after, "T") {
								Ok(day_split) => day_split.before
								Err(_) => month_split.after
							}
						day =
							if Str.starts_with(day_raw, "0") {
								Str.drop_prefix(day_raw, "0")
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
