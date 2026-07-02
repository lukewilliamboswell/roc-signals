import Node
import Signal
import http.Method
import http.Request
import http.Response

## HTTP request helpers backed by the pinned `roc-lang/http` package and the
## Signals task runtime.
Http := [].{

	## Errors returned by platform HTTP task helpers.
	HttpError := [
		Network(Str),
		Timeout,
		Canceled,
		Unsupported(Str),
		ResponseMaterialization(Str),
	]

	## HTTP `GET` method.
	method_get = GET

	## HTTP `POST` method.
	method_post = POST

	## HTTP `PUT` method.
	method_put = PUT

	## HTTP `DELETE` method.
	method_delete = DELETE

	## HTTP `PATCH` method.
	method_patch = PATCH

	## Custom HTTP method.
	method_unknown = |name| Unknown(name)

	## Create a request from a method.
	request_from_method = Request.from_method

	## Read a request's method.
	request_method = Request.method

	## Read a request's method as text.
	request_method_str = Request.method_str

	## Read request headers.
	request_headers = Request.headers

	## Read request body bytes.
	request_body = Request.body

	## Read request URI.
	request_uri = Request.uri

	## Read request timeout.
	request_timeout = Request.timeout

	## Set request method.
	with_method = Request.with_method

	## Replace request headers.
	with_headers = Request.with_headers

	## Add one request header.
	add_header = Request.add_header

	## Set request URI.
	with_uri = Request.with_uri

	## Set request body bytes.
	with_body = Request.with_body

	## Set request timeout.
	with_timeout_ms = |request, ms| Request.with_timeout(request, TimeoutMilliseconds(ms))

	## Disable request timeout.
	with_no_timeout = |request| Request.with_timeout(request, NoTimeout)

	## Create a response from a status code.
	response_from_status = Response.from_status

	## Read response status code.
	response_status = Response.status

	## Read response headers.
	response_headers = Response.headers

	## Read response body bytes.
	response_body = Response.body

	## Set response status code.
	response_with_status = Response.with_status

	## Replace response headers.
	response_with_headers = Response.with_headers

	## Add one response header.
	response_add_header = Response.add_header

	## Set response body bytes.
	response_with_body = Response.with_body

	## Create a task for full HTTP request/response values.
	request_task = |purpose| {
		name = Str.concat("http:send:", purpose)
		Signal.task_source(name, decode_response_payload, decode_error_payload, False)
	}

	## Start a full HTTP request task.
	start = |task, request| Signal.start_str(task, encode_request_payload(request))

	## Create a task that decodes successful responses as text. Starting a new
	## request on the same task cancels any older pending request; late results from
	## canceled requests are ignored by the runtime.
	get_text_task = |purpose| {
		name = Str.concat("http:send:", purpose)
		Signal.task_source(name, decode_text_response_payload, decode_error_text_payload, False)
	}

	## Start a `GET` request and decode a successful response body as text.
	get_text = |task, uri| {
		request0 = request_from_method(method_get)
		request = with_uri(request0, uri)
		Signal.start_str(task, encode_request_payload(request))
	}

	## Start a `GET` request and keep the full response value.
	get = |task, uri| {
		request0 = request_from_method(method_get)
		request = with_uri(request0, uri)
		start(task, request)
	}

	## Convert an HTTP error to user-facing text.
	error_text = |err|
		match err {
			Network(message) => Str.concat("network: ", message)
			Timeout => "timeout"
			Canceled => "canceled"
			Unsupported(message) => Str.concat("unsupported request: ", message)
			ResponseMaterialization(message) => Str.concat("response materialization: ", message)
		}

	encode_request_payload = |request| {
		headers = Request.headers(request)
		base = [
			"roc-http-request-v1",
			encode_str(Request.method_str(request)),
			encode_str(Request.uri(request)),
			encode_timeout(Request.timeout(request)),
			List.len(headers).to_str(),
		]
			request_fields =
			List.fold(
				headers,
				base,
				|acc, (name, value)| List.append(List.append(acc, encode_str(name)), encode_str(value)),
			)
		fields = List.append(request_fields, encode_bytes(Request.body(request)))
		Str.join_with(fields, "\n")
	}

	encode_response_payload = |response| {
		headers = Response.headers(response)
		base = [
			"roc-http-response-v1",
			Response.status(response).to_str(),
			List.len(headers).to_str(),
		]
			response_fields =
			List.fold(
				headers,
				base,
				|acc, (name, value)| List.append(List.append(acc, encode_str(name)), encode_str(value)),
			)
		fields = List.append(response_fields, encode_bytes(Response.body(response)))
		Str.join_with(fields, "\n")
	}

	encode_error_payload = |err| {
			(code, message) =
			match err {
				Network(detail) => ("network", detail)
				Timeout => ("timeout", "")
				Canceled => ("canceled", "")
				Unsupported(detail) => ("unsupported", detail)
				ResponseMaterialization(detail) => ("response-materialization", detail)
			}

		Str.join_with(["roc-http-error-v1", code, encode_str(message)], "\n")
	}

	decode_response_payload = |payload| {
		reader0 = expect_version(Str.split_on(payload, "\n"), "roc-http-response-v1", "response")
		status_line = read_line(reader0, "response status")
		header_count_line = read_line(status_line.rest, "response header count")
			status =
			match U16.from_str(status_line.value) {
				Ok(value) => value
				Err(_) => {
					crash "malformed HTTP response payload"
				}
			}
		header_count = parse_u64(header_count_line.value, "response header count")
		header_result = read_headers(header_count_line.rest, header_count, "response")
		body_line = read_line(header_result.rest, "response body")

		if !List.is_empty(body_line.rest) {
			crash "malformed HTTP response payload: trailing fields"
		}

		response0 = Response.from_status(status)
		response1 = Response.with_headers(response0, header_result.headers)
		Response.with_body(response1, decode_bytes(body_line.value, "response body"))
	}

	decode_text_response_payload = |payload| {
		response = decode_response_payload(payload)
		match Str.from_utf8(Response.body(response)) {
			Ok(text) => text
			Err(_) => Str.from_utf8_lossy(Response.body(response))
		}
	}

	decode_error_payload = |payload| {
		reader0 = expect_version(Str.split_on(payload, "\n"), "roc-http-error-v1", "error")
		code_line = read_line(reader0, "error code")
		message_line = read_line(code_line.rest, "error message")

		if !List.is_empty(message_line.rest) {
			ResponseMaterialization("malformed HTTP error payload: trailing fields")
		} else {
			message = decode_str(message_line.value, "error message")
			if code_line.value == "network" {
				Network(message)
			} else if code_line.value == "timeout" {
				Timeout
			} else if code_line.value == "canceled" {
				Canceled
			} else if code_line.value == "unsupported" {
				Unsupported(message)
			} else if code_line.value == "response-materialization" {
				ResponseMaterialization(message)
			} else {
				ResponseMaterialization("malformed HTTP error payload: unknown code")
			}
		}
	}

	decode_error_text_payload = |payload| error_text(decode_error_payload(payload))

	encode_timeout = |timeout|
		match timeout {
			NoTimeout => "-"
			TimeoutMilliseconds(ms) => ms.to_str()
		}

	encode_str = |text| encode_bytes(Str.to_utf8(text))

	encode_bytes = |bytes| {
		parts = List.map(bytes, |byte| U8.to_u64(byte).to_str())
		Str.join_with(parts, ",")
	}

	decode_str = |field, _label| {
		bytes = decode_bytes(field, "bytes")
		match Str.from_utf8(bytes) {
			Ok(text) => text
			Err(_) => {
				crash "malformed HTTP payload"
			}
		}
	}

	decode_bytes = |field, _label| {
		if Str.is_empty(field) {
			[]
		} else {
			List.map(
				Str.split_on(field, ","),
				|part| {
					match U8.from_str(part) {
						Ok(byte) => byte
						Err(_) => {
							crash "malformed HTTP payload"
						}
					}
				},
			)
		}
	}

	parse_u64 = |text, _label|
		match U64.from_str(text) {
			Ok(value) => value
			Err(_) => {
				crash "malformed HTTP payload"
			}
		}

	read_headers = |lines, count, label| {
		var $remaining = lines
		var $headers = []
		var $left = count

		while $left > 0 {
			name_line = read_line($remaining, Str.concat(label, " header name"))
			value_line = read_line(name_line.rest, Str.concat(label, " header value"))
			$headers = List.append($headers, (decode_str(name_line.value, "header name"), decode_str(value_line.value, "header value")))
			$remaining = value_line.rest
			$left = $left - 1
		}

		{ headers: $headers, rest: $remaining }
	}

	expect_version = |lines, expected, label| {
		version = read_line(lines, Str.concat(label, " version"))
		if version.value == expected {
			version.rest
		} else {
			crash "malformed HTTP payload"
		}
	}

	read_line = |lines, _label|
		match List.first(lines) {
			Ok(value) => { value, rest: List.drop_first(lines, 1) }
			Err(_) => {
				crash "malformed HTTP payload"
			}
		}
}
