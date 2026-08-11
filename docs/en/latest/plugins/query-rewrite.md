---
title: query-rewrite
keywords:
  - Apache APISIX
  - API Gateway
  - QUERY
  - HTTP method
description: The query-rewrite Plugin provides RFC 10008-aware QUERY caching and optional forwarding to POST-only Upstream services.
---

<!--
#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
-->

## Description

The `query-rewrite` Plugin provides a safe cache for HTTP `QUERY` requests and can forward cache misses to POST-only Upstream services. The client-facing method remains `QUERY`; the method is changed only on the upstream hop.

Configure the Plugin only on Routes that explicitly match `request_method == QUERY`. Route matching and request security policies run against the client method. The method is changed immediately before APISIX proxies the request to the Upstream service.

## Attributes

| Name | Type | Required | Default | Description |
|------|------|----------|---------|-------------|
| `preserve_original_method_header` | boolean | False | `true` | Forward the original method to Upstream. |
| `original_method_header` | string | False | `X-Original-Method` | Header used to forward the original method. APISIX overwrites an incoming header with the same name. |
| `cache.enabled` | boolean | False | `false` | Enables body-aware QUERY caching. |
| `cache.backend` | string | False | `local` | `local`, `redis`, or `redis-cluster`. |
| `cache.ttl` | integer | False | `30` | Maximum freshness lifetime in seconds. A shorter upstream max-age is honored. |
| `cache.fallback_ttl` | integer | False | `5` | Node-local cache lifetime while a Redis backend is unavailable. |
| `cache.max_request_body_size` | integer | False | `262144` | Maximum in-memory request body size eligible for cache-key generation. Larger or file-backed bodies bypass cache. |
| `cache.max_response_body_size` | integer | False | `1048576` | Maximum response body size stored in cache. |
| `cache.cookie_names` | array[string] | False | | Explicit request-cookie allowlist. A request containing an unlisted cookie bypasses cache. |
| `cache.redis_*` | object fields | Required for `redis` | | Redis address, TLS, authentication, database, timeout, and keepalive settings. |
| `cache.redis_cluster_*` | object fields | Required for `redis-cluster` | | Redis Cluster name, seed nodes, TLS, authentication, timeout, and keepalive settings. |

## Example

Create a Route that accepts `QUERY` requests and forwards them to a POST-only search service:

```shell
curl "http://127.0.0.1:9180/apisix/admin/routes/query-search" -X PUT \
  -H "X-API-KEY: ${admin_key}" \
  -d '{
    "uri": "/v1/search",
    "vars": [["request_method", "==", "QUERY"]],
    "plugins": {
      "query-rewrite": {}
    },
    "upstream": {
      "type": "roundrobin",
      "nodes": {
        "search.internal:8080": 1
      }
    }
  }'
```

A client can issue a QUERY request with a body:

```shell
curl "http://127.0.0.1:9080/v1/search" \
  -X QUERY \
  -H "Content-Type: application/json" \
  --data '{"query":"apisix"}'
```

The Upstream receives:

```text
POST /v1/search
X-Original-Method: QUERY
Content-Type: application/json

{"query":"apisix"}
```

## Notes

- The Plugin only transforms `QUERY` requests. Requests using other methods are left unchanged.
- Match `QUERY` explicitly with `vars: [["request_method", "==", "QUERY"]]` to prevent POST requests from matching the same Route.
- Enable cache only for query endpoints whose responses are safe to share.
- Cache keys include the QUERY method, route scope, target URI, Content-Type, Content-Encoding, Content-Language, request negotiation headers, consumer identity, allowlisted cookies, and the SHA-256 digest of the unmodified request body.

## Cache Safety

The cache is deliberately conservative. It bypasses cache lookup and storage for requests with `Authorization`, `Range`, `Cookie` unless every cookie is allowlisted, `Cache-Control: no-store` or `no-cache`, `Pragma: no-cache`, oversized bodies, and bodies not available in memory.

It never stores responses with `Set-Cookie`, `WWW-Authenticate`, `Proxy-Authenticate`, `Content-Range`, `Cache-Control: private`, `no-store`, `no-cache`, `max-age=0`, `s-maxage=0`, or unsupported `Vary` values. `Vary: Accept`, `Accept-Encoding`, and `Accept-Language` are included in the key. `Vary: Cookie`, `Authorization`, and `*` bypass cache.

When Redis or Redis Cluster cannot be reached, the Plugin opens a per-node circuit breaker and uses the local shared-memory cache for `cache.fallback_ttl` seconds. It never fails the client request because the cache backend is unavailable.
