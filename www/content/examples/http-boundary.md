+++
title = "HTTP Boundary"
description = "Package-aligned HTTP request and response payloads at the native/JS boundary."
template = "example.html"
[extra]
slug = "http-boundary"
+++

This example exercises the Signals HTTP task boundary using the pinned
`roc-lang/http` request and response types. Native specs drive deterministic
success, non-2xx, and failure responses through the same task source path the
browser fetch bridge uses.
