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
use t::APISIX 'no_plan';

repeat_each(1);
no_long_string();
no_root_location();
no_shuffle();
log_level('info');

run_tests;

__DATA__

=== TEST 1: create standalone redis profile
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t("/apisix/admin/redis_profiles/rate-limit",
                ngx.HTTP_PUT,
                [[{
                    "mode": "standalone",
                    "host": "redis.internal",
                    "port": 6380,
                    "database": 2
                }]])
            ngx.status = code
            ngx.say(body)
        }
    }
--- request
GET /t
--- response_body
passed



=== TEST 2: reject incomplete sentinel profile
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t("/apisix/admin/redis_profiles/rate-limit-ha",
                ngx.HTTP_PUT,
                [[{
                    "mode": "sentinel",
                    "master_name": "mymaster"
                }]])
            ngx.status = code
            ngx.say(body)
        }
    }
--- request
GET /t
--- error_code: 400
--- response_body_like: ^{"error_msg":".*sentinels and master_name.*"}$



=== TEST 3: create, get, patch, list and delete a cluster profile
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t("/apisix/admin/redis_profiles/cluster-a", ngx.HTTP_PUT, [[{
                "mode": "cluster",
                "cluster_name": "cluster-a",
                "nodes": ["127.0.0.1:7000", {"host": "127.0.0.1", "port": 7001}],
                "timeout": 1500,
                "ssl": true
            }]])
            assert(code == 200, body)

            code, body = t("/apisix/admin/redis_profiles/cluster-a", ngx.HTTP_GET, nil, [[{
                "value": {
                    "id": "cluster-a",
                    "mode": "cluster",
                    "cluster_name": "cluster-a"
                }
            }]])
            assert(code == 200, body)

            code, body = t("/apisix/admin/redis_profiles/cluster-a", ngx.HTTP_PATCH, [[{
                "timeout": 2500,
                "keepalive_pool": 64
            }]])
            assert(code == 200, body)

            code, body = t("/apisix/admin/redis_profiles", ngx.HTTP_GET)
            assert(code == 200, body)

            code, body = t("/apisix/admin/redis_profiles/cluster-a", ngx.HTTP_DELETE)
            assert(code == 200, body)
            ngx.say("passed")
        }
    }
--- request
GET /t
--- response_body
passed



=== TEST 4: accept complete sentinel profile
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t("/apisix/admin/redis_profiles/sentinel-a", ngx.HTTP_PUT, [[{
                "mode": "sentinel",
                "master_name": "mymaster",
                "sentinels": [{"host": "127.0.0.1", "port": 26379}],
                "username": "redis-user",
                "sentinel_username": "sentinel-user",
                "connect_timeout": 1000,
                "read_timeout": 2000,
                "role": "slave"
            }]])
            assert(code == 200, body)
            ngx.say("passed")
        }
    }
--- request
GET /t
--- response_body
passed



=== TEST 5: reject incomplete cluster, invalid endpoint and unknown fields
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local cases = {
                [[{"mode":"cluster","cluster_name":"cluster-a"}]],
                [[{"mode":"standalone","host":"redis","port":0}]],
                [[{"mode":"standalone","host":"redis","unexpected":true}]],
                [[{"mode":"sentinel","master_name":"mymaster","sentinels":[{"host":"redis","port":0}]}]],
            }
            for i, conf in ipairs(cases) do
                local code, body = t("/apisix/admin/redis_profiles/invalid-" .. i,
                    ngx.HTTP_PUT, conf)
                assert(code == 400, body)
            end
            ngx.say("passed")
        }
    }
--- request
GET /t
--- response_body
passed



=== TEST 6: encrypt passwords at rest and preserve them across patch
--- yaml_config
apisix:
    data_encryption:
        enable: true
        keyring:
            - edd1c9f0985e76a2
--- config
    location /t {
        content_by_lua_block {
            local core = require("apisix.core")
            local t = require("lib.test_admin").test
            local code, body = t("/apisix/admin/redis_profiles/encrypted", ngx.HTTP_PUT, [[{
                "mode": "standalone",
                "host": "127.0.0.1",
                "password": "redis-password"
            }]])
            assert(code == 200, body)

            local res = assert(core.etcd.get("/redis_profiles/encrypted"))
            local stored = res.body.node.value.password
            assert(stored ~= "redis-password")
            assert(core.data_encryption.decrypt(stored, "redis password") == "redis-password")

            code, body = t("/apisix/admin/redis_profiles/encrypted", ngx.HTTP_PATCH,
                [[{"database": 2}]])
            assert(code == 200, body)

            res = assert(core.etcd.get("/redis_profiles/encrypted"))
            stored = res.body.node.value.password
            assert(core.data_encryption.decrypt(stored, "redis password") == "redis-password")
            ngx.say("passed")
        }
    }
--- request
GET /t
--- response_body
passed
