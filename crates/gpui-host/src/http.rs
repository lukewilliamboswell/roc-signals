//! The hosted `Http` function: one request performed to completion on the
//! calling effect worker, with its response handed back as C structs the Zig
//! host copies into the Roc `Response`.
use crate::effects::Bytes;
use std::time::Duration;

const MAX_BODY: usize = 8 * 1024 * 1024;

#[repr(C)]
pub(crate) struct HeaderIn {
    name_ptr: *const u8,
    name_len: usize,
    value_ptr: *const u8,
    value_len: usize,
}

#[repr(C)]
pub(crate) struct HeaderOut {
    name: Bytes,
    value: Bytes,
}

#[repr(C)]
pub(crate) struct HeadersOut {
    ptr: *mut HeaderOut,
    len: usize,
    cap: usize,
}

#[repr(C)]
pub(crate) struct HttpErrorOut {
    kind: u32,
    detail: Bytes,
}

enum HttpError {
    InvalidRequest(String),
    Network(String),
    Timeout,
    TooLarge(String),
    Unavailable(String),
}

struct Request {
    method: String,
    uri: String,
    timeout: Option<Duration>,
    headers: Vec<(String, String)>,
    body: Vec<u8>,
}

struct Response {
    status: u16,
    headers: Vec<(String, String)>,
    body: Vec<u8>,
}

/// The kind numbers are the ones `native_services.zig` maps onto the Roc
/// `Http.Error` tags. Detail is bounded like the `Files` errors.
fn error_out(error: HttpError) -> HttpErrorOut {
    let (kind, detail) = match error {
        HttpError::InvalidRequest(detail) => (0, detail),
        HttpError::Network(detail) => (1, detail),
        HttpError::Timeout => (2, String::new()),
        HttpError::TooLarge(detail) => (3, detail),
        HttpError::Unavailable(detail) => (4, detail),
    };
    HttpErrorOut {
        kind,
        detail: Bytes::from_string(crate::file_io::bounded_detail(detail)),
    }
}

fn classify(error: reqwest::Error) -> HttpError {
    if error.is_timeout() {
        HttpError::Timeout
    } else if error.is_builder() {
        HttpError::InvalidRequest(error.to_string())
    } else {
        HttpError::Network(error.to_string())
    }
}

async fn perform(request: Request) -> Result<Response, HttpError> {
    let method = reqwest::Method::from_bytes(request.method.as_bytes())
        .map_err(|_| HttpError::InvalidRequest(format!("unsupported method {}", request.method)))?;
    let url = reqwest::Url::parse(&request.uri)
        .map_err(|error| HttpError::InvalidRequest(format!("{}: {error}", request.uri)))?;
    let client = reqwest::Client::builder().build().map_err(classify)?;
    let mut builder = client.request(method, url);
    for (name, value) in &request.headers {
        builder = builder.header(name, value);
    }
    if let Some(timeout) = request.timeout {
        builder = builder.timeout(timeout);
    }
    let mut response = builder.body(request.body).send().await.map_err(classify)?;
    let status = response.status().as_u16();
    let headers = response
        .headers()
        .iter()
        .map(|(name, value)| {
            (
                name.as_str().to_owned(),
                String::from_utf8_lossy(value.as_bytes()).into_owned(),
            )
        })
        .collect();
    let mut body = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(classify)? {
        if body.len() + chunk.len() > MAX_BODY {
            return Err(HttpError::TooLarge(format!(
                "response body exceeds {MAX_BODY} bytes"
            )));
        }
        body.extend_from_slice(&chunk);
    }
    Ok(Response {
        status,
        headers,
        body,
    })
}

fn run(request: Request) -> Result<Response, HttpError> {
    if request.body.len() > MAX_BODY {
        return Err(HttpError::TooLarge(format!(
            "request body exceeds {MAX_BODY} bytes"
        )));
    }
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|error| HttpError::Unavailable(format!("no async runtime: {error}")))?;
    runtime.block_on(perform(request))
}

unsafe fn text<'a>(ptr: *const u8, len: usize) -> &'a str {
    if len == 0 {
        return "";
    }
    // Roc strings are UTF-8 by construction.
    std::str::from_utf8(unsafe { std::slice::from_raw_parts(ptr, len) }).unwrap_or("")
}

/// Performs one HTTP request for the Zig host's hosted `Http` function. A
/// timeout of `u64::MAX` waits as long as the server does. The return value is
/// 1 when `err` was written instead of the response.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn signals_http_send(
    method: *const u8,
    method_len: usize,
    uri: *const u8,
    uri_len: usize,
    timeout_ms: u64,
    headers: *const HeaderIn,
    header_count: usize,
    body: *const u8,
    body_len: usize,
    out_status: *mut u16,
    out_headers: *mut HeadersOut,
    out_body: *mut Bytes,
    err: *mut HttpErrorOut,
) -> u32 {
    let header_inputs = if header_count == 0 {
        &[][..]
    } else {
        unsafe { std::slice::from_raw_parts(headers, header_count) }
    };
    let request = Request {
        method: unsafe { text(method, method_len) }.to_owned(),
        uri: unsafe { text(uri, uri_len) }.to_owned(),
        timeout: (timeout_ms != u64::MAX).then(|| Duration::from_millis(timeout_ms)),
        headers: header_inputs
            .iter()
            .map(|header| {
                (
                    unsafe { text(header.name_ptr, header.name_len) }.to_owned(),
                    unsafe { text(header.value_ptr, header.value_len) }.to_owned(),
                )
            })
            .collect(),
        body: if body_len == 0 {
            Vec::new()
        } else {
            unsafe { std::slice::from_raw_parts(body, body_len) }.to_vec()
        },
    };
    match run(request) {
        Ok(response) => {
            let mut pairs: Vec<HeaderOut> = response
                .headers
                .into_iter()
                .map(|(name, value)| HeaderOut {
                    name: Bytes::from_string(name),
                    value: Bytes::from_string(value),
                })
                .collect();
            let headers_out = HeadersOut {
                ptr: pairs.as_mut_ptr(),
                len: pairs.len(),
                cap: pairs.capacity(),
            };
            std::mem::forget(pairs);
            unsafe {
                out_status.write(response.status);
                out_headers.write(headers_out);
                out_body.write(Bytes::from_vec(response.body));
            }
            0
        }
        Err(error) => {
            unsafe { err.write(error_out(error)) };
            1
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn signals_headers_release(headers: HeadersOut) {
    if headers.ptr.is_null() {
        return;
    }
    for header in unsafe { Vec::from_raw_parts(headers.ptr, headers.len, headers.cap) } {
        unsafe {
            signals_bytes_release_pair(header);
        }
    }
}

unsafe fn signals_bytes_release_pair(header: HeaderOut) {
    unsafe {
        crate::effects::signals_bytes_release(header.name);
        crate::effects::signals_bytes_release(header.value);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn error_kinds_are_stable_and_bounded() {
        let out = error_out(HttpError::Timeout);
        assert_eq!((out.kind, out.detail.len), (2, 0));
        unsafe { crate::effects::signals_bytes_release(out.detail) };
        let out = error_out(HttpError::Network("x".repeat(5000)));
        assert_eq!(out.kind, 1);
        assert!(out.detail.len <= 4096);
        unsafe { crate::effects::signals_bytes_release(out.detail) };
    }
}
