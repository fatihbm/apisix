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
                    "redis_host": "redis.internal",
                    "redis_port": 6380,
                    "redis_database": 2
                }]])
            ngx.status = ngx.HTTP_OK
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
                    "redis_master_name": "mymaster"
                }]])
            ngx.status = code
            ngx.say(body)
        }
    }
--- request
GET /t
--- error_code: 400
--- response_body_like: ^sentinel profile requires redis_sentinels and redis_master_name$



=== TEST 3: create, get, patch, list and delete a cluster profile
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t("/apisix/admin/redis_profiles/cluster-a", ngx.HTTP_PUT, [[{
                "mode": "cluster",
                "redis_cluster_name": "cluster-a",
                "redis_cluster_nodes": ["127.0.0.1:7000", "127.0.0.1:7001"],
                "redis_timeout": 1500,
                "redis_cluster_ssl": true
            }]])
            assert(code < 300, body)

            code, body = t("/apisix/admin/redis_profiles/cluster-a", ngx.HTTP_GET, nil, [[{
                "value": {
                    "id": "cluster-a",
                    "mode": "cluster",
                    "redis_cluster_name": "cluster-a"
                }
            }]])
            assert(code < 300, body)

            code, body = t("/apisix/admin/redis_profiles/cluster-a", ngx.HTTP_PATCH, [[{
                "redis_timeout": 2500,
                "redis_keepalive_pool": 64
            }]])
            assert(code < 300, body)

            code, body = t("/apisix/admin/redis_profiles", ngx.HTTP_GET)
            assert(code < 300, body)

            code, body = t("/apisix/admin/redis_profiles/cluster-a", ngx.HTTP_DELETE)
            assert(code < 300, body)
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
                "redis_master_name": "mymaster",
                "redis_sentinels": ["127.0.0.1:26379"],
                "redis_username": "redis-user",
                "sentinel_username": "sentinel-user",
                "redis_connect_timeout": 1000,
                "redis_read_timeout": 2000,
                "redis_role": "slave"
            }]])
            assert(code < 300, body)
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
                [[{"mode":"cluster","redis_cluster_name":"cluster-a"}]],
                [[{"mode":"standalone","redis_host":"redis","redis_port":0}]],
                [[{"mode":"standalone","redis_host":"redis","unexpected":true}]],
                [[{"mode":"sentinel","redis_master_name":"mymaster",
                    "redis_sentinels":[""]}]],
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
                "redis_host": "127.0.0.1",
                "redis_password": "redis-password"
            }]])
            assert(code < 300, body)

            local res = assert(core.etcd.get("/redis_profiles/encrypted"))
            local stored = core.json.decode(res.body.node.value).redis_password
            assert(stored ~= "redis-password")
            assert(core.data_encryption.decrypt(stored, "redis password") == "redis-password")

            code, body = t("/apisix/admin/redis_profiles/encrypted", ngx.HTTP_PATCH,
                [[{"redis_database": 2}]])
            assert(code < 300, body)

            res = assert(core.etcd.get("/redis_profiles/encrypted"))
            stored = core.json.decode(res.body.node.value).redis_password
            assert(core.data_encryption.decrypt(stored, "redis password") == "redis-password")
            ngx.say("passed")
        }
    }
--- request
GET /t
--- response_body
passed
