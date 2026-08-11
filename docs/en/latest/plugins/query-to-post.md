---
title: Query to Post
keywords:
  - Apache APISIX
  - API Gateway
  - QUERY
  - HTTP method
description: The query-to-post Plugin forwards QUERY requests to POST-only Upstream services.
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

The `query-to-post` Plugin forwards HTTP `QUERY` requests to Upstream services as `POST` requests. It does not read, modify, or re-encode the request body.

Configure the Plugin only on Routes that explicitly match `request_method == QUERY`. Route matching and request security policies run against the client method. The method is changed immediately before APISIX proxies the request to the Upstream service.

## Attributes

| Name | Type | Required | Default | Description |
|------|------|----------|---------|-------------|
| `preserve_original_method_header` | boolean | False | `true` | Forward the original method to Upstream. |
| `original_method_header` | string | False | `X-Original-Method` | Header used to forward the original method. APISIX overwrites an incoming header with the same name. |

## Example

Create a Route that accepts `QUERY` requests and forwards them to a POST-only search service:

```shell
curl "http://127.0.0.1:9180/apisix/admin/routes/query-search" -X PUT \
  -H "X-API-KEY: ${admin_key}" \
  -d '{
    "uri": "/v1/search",
    "vars": [["request_method", "==", "QUERY"]],
    "plugins": {
      "query-to-post": {}
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
- The Plugin does not add request-body-aware caching. Cache policy is a separate concern.
