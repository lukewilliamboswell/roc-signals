import http.Method
import http.Request exposing [Request]
import http.Response exposing [Response]

## Native HTTP requests as effectful functions, called from an action's
## effect. Requests and responses are the `roc-lang/http` package's values, so
## packages built on those types work unchanged. Each call runs to completion
## on the effect's worker; bodies are bounded at 8 MiB in each direction.
Http := [].{
	Error := [
		InvalidRequest(Str),
		Network(Str),
		Timeout,
		TooLarge(Str),
		Status(U16),
		InvalidUtf8,
		Unavailable(Str),
	].{
		is_eq : _
	}

	## Hosted: perform one request to completion and return the response or
	## error packet; `failed` selects the decoder. Callable only from an effect.
	run! : List(U8) => { failed : Bool, bytes : List(U8) }

	## Send a request and wait for its response. Redirects are followed; a
	## response with any status is a success, and `NoTimeout` waits as long as
	## the server does.
	send! : Request => Try(Response, Error)
	send! = |request| {
		result = Http.run!(encode_request(request))
		if result.failed {
			Err(decode_error(result.bytes))
		} else {
			Ok(decode_response(result.bytes))
		}
	}

	## `GET` a URL with a 30 second timeout.
	get! : Str => Try(Response, Error)
	get! = |uri| send!(Request.from_method(Method.GET).with_uri(uri).with_timeout(TimeoutMilliseconds(30000)))

	## `GET` a URL and return a successful response body as text; a status
	## outside 200-299 is `Status`, and a body that is not UTF-8 is `InvalidUtf8`.
	get_text! : Str => Try(Str, Error)
	get_text! = |uri| match get!(uri) {
		Err(error) => Err(error)
		Ok(response) => {
			status = Response.status(response)
			if status >= 200 and status < 300 {
				match Str.from_utf8(Response.body(response)) {
					Ok(text) => Ok(text)
					Err(_) => Err(InvalidUtf8)
				}
			} else {
				Err(Status(status))
			}
		}
	}

	## Describe a failure without losing its typed case.
	error_text : Error -> Str
	error_text = |error| match error {
		InvalidRequest(detail) => "Invalid request: ${detail}"
		Network(detail) => "Network error: ${detail}"
		Timeout => "The request timed out"
		TooLarge(detail) => "Too large: ${detail}"
		Status(status) => "HTTP status ${status.to_str()}"
		InvalidUtf8 => "The response body is not valid UTF-8"
		Unavailable(detail) => "Native service unavailable: ${detail}"
	}

	# A private, bounded sequence of byte frames: decimal byte length, colon,
	# bytes. The first frame is the codec version.
	encode_request : Request -> List(U8)
	encode_request = |request| {
		timeout = match Request.timeout(request) {
			TimeoutMilliseconds(ms) => ms.to_str()
			NoTimeout => "none"
		}
		headers = Request.headers(request)
		head = ["http1", Request.method_str(request), Request.uri(request), timeout, headers.len().to_str()]
		pairs = headers.fold([], |acc, (name, value)| acc.append(name).append(value))
		head.concat(pairs).fold([], |acc, text| acc.concat(frame(text.to_utf8()))).concat(frame(Request.body(request)))
	}

	frame : List(U8) -> List(U8)
	frame = |bytes| "${bytes.len().to_str()}:".to_utf8().concat(bytes)

	decode_response : List(U8) -> Response
	decode_response = |bytes| {
		status = read_text(reader(bytes))
		count = read_text(status.rest)
		headers = read_headers(count.rest, number(count.value), [])
		body = read_frame(headers.rest)
		finish(body.rest)
		Response.from_status(status_code(status.value)).with_headers(headers.value).with_body(body.value)
	}

	read_headers : List(U8), U64, List((Str, Str)) -> { value : List((Str, Str)), rest : List(U8) }
	read_headers = |bytes, remaining, acc| if remaining == 0 {
		{ value: acc, rest: bytes }
	} else {
		name = read_text(bytes)
		value = read_text(name.rest)
		read_headers(value.rest, remaining - 1, acc.append((name.value, value.value)))
	}

	decode_error : List(U8) -> Error
	decode_error = |bytes| {
		code = read_text(reader(bytes))
		detail = read_text(code.rest)
		finish(detail.rest)
		match code.value {
			"invalid-request" => Error.InvalidRequest(detail.value)
			"network" => Error.Network(detail.value)
			"timeout" => Error.Timeout
			"too-large" => Error.TooLarge(detail.value)
			"unavailable" => Error.Unavailable(detail.value)
			_ => crash "malformed Http error kind"
		}
	}

	status_code : Str -> U16
	status_code = |text| match U16.from_str(text) {
		Ok(value) if value.to_str() == text => value
		_ => crash "malformed Http status"
	}

	number : Str -> U64
	number = |text| match U64.from_str(text) {
		Ok(value) if value.to_str() == text => value
		_ => crash "malformed Http unsigned number"
	}

	utf8 : List(U8) -> Str
	utf8 = |bytes| match Str.from_utf8(bytes) {
		Ok(value) => value
		Err(_) => crash "malformed Http UTF-8 frame"
	}

	read_text : List(U8) -> { value : Str, rest : List(U8) }
	read_text = |bytes| {
		result = read_frame(bytes)
		{ value: utf8(result.value), rest: result.rest }
	}

	read_frame : List(U8) -> { value : List(U8), rest : List(U8) }
	read_frame = |bytes| {
		var $end = 0.U64
		while $end < bytes.len() and bytes.get($end) != Ok(58) {
			$end = $end + 1
		}
		if $end == bytes.len() {
			crash "malformed Http frame length"
		}
		count = number(utf8(bytes.take_first($end)))
		start = $end + 1
		if count > bytes.len() - start {
			crash "truncated Http frame"
		}
		{ value: bytes.drop_first(start).take_first(count), rest: bytes.drop_first(start + count) }
	}

	reader : List(U8) -> List(U8)
	reader = |bytes| {
		if bytes.len() > 8388608 + 65536 {
			crash "Http payload limit exceeded"
		}
		version = read_text(bytes)
		if version.value != "http1" {
			crash "unsupported Http payload version"
		}
		version.rest
	}

	finish : List(U8) -> {}
	finish = |rest| {
		if !rest.is_empty() {
			crash "unexpected Http payload fields"
		}
		{}
	}
}
