import http.Method
import http.Request
import http.Response

## HTTP request helpers backed by the pinned `roc-lang/http` package and the
## engine-scheduled action effects.
Http := [].{
	## Failures of a hosted request. HTTP status codes remain successful
	## responses; text helpers report non-success status and invalid UTF-8.
	Error := [InvalidRequest(Str), Network(Str), Timeout, TooLarge(Str), Status(U16), InvalidUtf8, Unavailable(Str)].{
		is_eq : _
	}

	## Performs one request inside an engine-scheduled action effect. Each call
	## is a distinct occurrence and its result returns through that action.
	send! : Request.Request => Try(Response.Response, Error)

	## Performs a GET with a thirty-second timeout.
	get! : Str => Try(Response.Response, Error)
	get! = |uri| Http.send!(Request.from_method(GET).with_uri(uri).with_timeout(TimeoutMilliseconds(30000)))

	## Reads a successful response as UTF-8, preserving status and decoding
	## failures as typed errors rather than replacing bytes.
	get_text! : Str => Try(Str, Error)
	get_text! = |uri| {
		response = get!(uri)?
		status = Response.status(response)
		if status < 200 or status >= 300 {
			Err(Status(status))
		} else {
			text = Str.from_utf8(Response.body(response)) ? |_| InvalidUtf8
			Ok(text)
		}
	}

	## User-facing HTTP header shape.
	Header : { name : Str, value : Str }

	header_to_tuple : Header -> (Str, Str)
	header_to_tuple = |header| (header.name, header.value)

	header_from_tuple : (Str, Str) -> Header
	header_from_tuple = |(name, value)| { name, value }

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
	request_headers = |request| Request.headers(request).map(header_from_tuple)

	## Read request body bytes.
	request_body = Request.body

	## Read request URI.
	request_uri = Request.uri

	## Read request timeout.
	request_timeout = Request.timeout

	## Set request method.
	with_method = Request.with_method

	## Replace request headers.
	with_headers = |request, headers| Request.with_headers(request, headers.map(header_to_tuple))

	## Add one request header.
	add_header = Request.add_header

	## Set request URI.
	with_uri = Request.with_uri

	## Set request body bytes.
	with_body = Request.with_body

	## Set request timeout. The browser accepts durations through 2147483647
	## milliseconds; larger durations return `InvalidRequest` when sent.
	with_timeout_ms = |request, ms| Request.with_timeout(request, TimeoutMilliseconds(ms))

	## Disable request timeout.
	with_no_timeout = |request| Request.with_timeout(request, NoTimeout)

	## Create a response from a status code.
	response_from_status = Response.from_status

	## Read response status code.
	response_status = Response.status

	## Read response headers.
	response_headers = |response| Response.headers(response).map(header_from_tuple)

	## Read response body bytes.
	response_body = Response.body

	## Set response status code.
	response_with_status = Response.with_status

	## Replace response headers.
	response_with_headers = |response, headers| Response.with_headers(response, headers.map(header_to_tuple))

	## Add one response header.
	response_add_header = Response.add_header

	## Set response body bytes.
	response_with_body = Response.with_body

}
