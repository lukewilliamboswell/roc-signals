import Dashboard

DashboardRemote(a) := [RemoteLoading, RemoteReady(a), RemoteEmpty, RemoteFailed(Str)].{
	is_eq : DashboardRemote(a), DashboardRemote(a) -> Bool
		where [
			a.is_eq : a, a -> Bool,
		]
	is_eq = |left, right|
		match left {
			RemoteLoading => match right {
				RemoteLoading => True
				_ => False
			}
			RemoteReady(left_value) => match right {
				RemoteReady(right_value) => left_value.is_eq(right_value)
				_ => False
			}
			RemoteEmpty => match right {
				RemoteEmpty => True
				_ => False
			}
			RemoteFailed(left_message) => match right {
				RemoteFailed(right_message) => left_message == right_message
				_ => False
			}
		}

	from_state : Dashboard.State, (Dashboard -> a) -> DashboardRemote(a)
	from_state = |state, select|
		match state {
			Loading => RemoteLoading
			Ready(dashboard) => RemoteReady(select(dashboard))
			RequestFailed(err) => RemoteFailed("Request failed: ${err}")
			DecodeFailed(err) => RemoteFailed("Decode failed: ${parse_error_text(err)}")
		}

	from_state_with : Dashboard.State, b, (Dashboard, b -> a) -> DashboardRemote(a)
	from_state_with = |state, extra, select|
		match state {
			Loading => RemoteLoading
			Ready(dashboard) => RemoteReady(select(dashboard, extra))
			RequestFailed(err) => RemoteFailed("Request failed: ${err}")
			DecodeFailed(err) => RemoteFailed("Decode failed: ${parse_error_text(err)}")
		}

	is_ready : DashboardRemote(a) -> Bool
	is_ready = |remote|
		match remote {
			RemoteReady(_) => True
			_ => False
		}

	is_failed : DashboardRemote(a) -> Bool
	is_failed = |remote|
		match remote {
			RemoteFailed(_) => True
			_ => False
		}

	message : DashboardRemote(a) -> Str
	message = |remote|
		match remote {
			RemoteLoading => "Waiting for first server response"
			RemoteReady(_) => ""
			RemoteEmpty => "No data returned"
			RemoteFailed(detail) => detail
		}

	text : DashboardRemote(Str) -> Str
	text = |remote|
		match remote {
			RemoteReady(value) => value
			_ => DashboardRemote.message(remote)
		}
}

parse_error_text : Dashboard.ParseErr -> Str
parse_error_text = |err|
	match err {
		BadJson => "response was not valid dashboard JSON"
		MissingData(label) => "response was missing dashboard ${label} data"
		BadCode(name) => "response had an invalid dashboard code for ${name}"
		UnsupportedSchema(schema) => "unsupported dashboard schema ${schema.to_str()}"
	}
