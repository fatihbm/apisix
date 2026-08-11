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

BEGIN {
    if ($ENV{TEST_NGINX_CHECK_LEAK}) {
        $SkipReason = "unavailable for the hup tests";
    } else {
        $ENV{TEST_NGINX_USE_HUP} = 1;
        undef $ENV{TEST_NGINX_USE_STAP};
    }
}

use t::APISIX 'no_plan';

repeat_each(1);
no_long_string();
no_shuffle();
no_root_location();
run_tests;

__DATA__

=== TEST 1: validate plugin schema
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.query-rewrite")
            local ok, err = plugin.check_schema({
                original_method_header = "X-Original-Method",
            })
            if not ok then
                ngx.say(err)
            end

            ngx.say("done")
        }
    }
--- request
GET /t
--- response_body
done



=== TEST 2: reject an invalid original method header
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.query-rewrite")
            local ok, err = plugin.check_schema({
                original_method_header = "Bad:Header",
            })
            ngx.say(ok)
            ngx.say(err)
        }
    }
--- request
GET /t
--- response_body_like eval
qr/false
invalid original_method_header/



=== TEST 3: add a QUERY route
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 [=[{
                    "vars": [["request_method", "==", "QUERY"]],
                    "plugins": {
                        "proxy-rewrite": {
                            "uri": "/uri/plugin_proxy_rewrite"
                        },
                        "query-rewrite": {}
                    },
                    "upstream": {
                        "nodes": {
                            "127.0.0.1:1980": 1
                        },
                        "type": "roundrobin"
                    },
                    "uri": "/query-rewrite"
                }]=]
            )

            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }
--- request
GET /t
--- response_body
passed



=== TEST 4: transform QUERY to POST and preserve the original method
--- request
QUERY /query-rewrite
--- response_body
uri: /uri/plugin_proxy_rewrite
host: localhost
x-original-method: QUERY
x-real-ip: 127.0.0.1



=== TEST 5: update route to forward the request body
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 [=[{
                    "vars": [["request_method", "==", "QUERY"]],
                    "plugins": {
                        "proxy-rewrite": {
                            "uri": "/echo"
                        },
                        "query-rewrite": {}
                    },
                    "upstream": {
                        "nodes": {
                            "127.0.0.1:1980": 1
                        },
                        "type": "roundrobin"
                    },
                    "uri": "/query-rewrite/body"
                }]=]
            )

            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }
--- request
GET /t
--- response_body
passed



=== TEST 6: preserve QUERY request body
--- more_headers
Content-Type: application/json
--- request
QUERY /query-rewrite/body
{"query":"apisix"}
--- response_body_like eval
qr/{"query":"apisix"}/



=== TEST 7: do not match POST on a QUERY-only route
--- request
POST /query-rewrite/body
{"query":"apisix"}
--- error_code: 404
