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

run_tests;

__DATA__

=== TEST 1: validate all supported profile topologies
--- config
    location /t {
        content_by_lua_block {
            local profile = require("apisix.core.redis_profile")

            assert(profile.check_conf({
                id = "cache-primary",
                create_time = 1,
                update_time = 2,
                mode = "standalone",
                redis_host = "127.0.0.1",
                redis_port = 6380,
            }))
            assert(profile.check_conf({
                mode = "cluster",
                redis_cluster_name = "test",
                redis_cluster_nodes = {"127.0.0.1:7000", "127.0.0.1:7001"},
            }))
            assert(profile.check_conf({
                mode = "sentinel",
                redis_master_name = "mymaster",
                redis_sentinels = {"127.0.0.1:26379"},
            }))

            ngx.say("passed")
        }
    }
--- request
GET /t
--- response_body
passed



=== TEST 2: reject invalid profile definitions
--- config
    location /t {
        content_by_lua_block {
            local profile = require("apisix.core.redis_profile")
            local cases = {
                {},
                {mode = "standalone"},
                {mode = "cluster", redis_cluster_name = "test"},
                {mode = "sentinel", redis_master_name = "mymaster"},
                {mode = "standalone", redis_host = "redis", redis_port = 0},
                {mode = "invalid", redis_host = "redis"},
                {mode = "standalone", redis_host = "redis", unknown = true},
            }

            for _, conf in ipairs(cases) do
                local ok = profile.check_conf(conf)
                assert(not ok)
            end
            ngx.say("passed")
        }
    }
--- request
GET /t
--- response_body
passed



=== TEST 3: resolve standalone profile without mutating original config
--- config
    location /t {
        content_by_lua_block {
            local profile = require("apisix.core.redis_profile")
            local conf = {
                policy = "redis",
                redis_host = "redis-profile://rate-limit",
                redis_database = 9,
            }
            local store = {
                get = function()
                    return {modifiedIndex = 1, value = {
                        mode = "standalone",
                        redis_host = "127.0.0.1",
                        redis_port = 6380,
                        redis_username = "alice",
                        redis_password = "secret",
                        redis_database = 2,
                        redis_timeout = 2000,
                        redis_keepalive_timeout = 30000,
                        redis_keepalive_pool = 50,
                        redis_ssl = true,
                        redis_ssl_verify = true,
                    }}
                end,
            }

            local resolved = assert(profile.resolve(conf, store))
            assert(conf.redis_host == "redis-profile://rate-limit")
            assert(resolved ~= conf)
            assert(resolved.policy == "redis")
            assert(resolved.redis_host == "127.0.0.1")
            assert(resolved.redis_port == 6380)
            assert(resolved.redis_username == "alice")
            assert(resolved.redis_password == "secret")
            assert(resolved.redis_database == 9)
            assert(resolved.redis_timeout == 2000)
            assert(resolved.redis_keepalive_timeout == 30000)
            assert(resolved.redis_keepalive_pool == 50)
            assert(resolved.redis_ssl)
            assert(resolved.redis_ssl_verify)
            ngx.say("passed")
        }
    }
--- request
GET /t
--- response_body
passed



=== TEST 4: resolve cluster and sentinel profiles
--- config
    location /t {
        content_by_lua_block {
            local profile = require("apisix.core.redis_profile")
            local values = {
                cluster = {
                    modifiedIndex = 1,
                    value = {
                        mode = "cluster",
                        redis_cluster_name = "cluster-a",
                        redis_cluster_nodes = {"127.0.0.1:7000", "127.0.0.1:7001"},
                        redis_password = "secret",
                        redis_cluster_ssl = true,
                    },
                },
                sentinel = {
                    modifiedIndex = 1,
                    value = {
                        mode = "sentinel",
                        redis_master_name = "mymaster",
                        redis_sentinels = {"127.0.0.1:26379"},
                        redis_username = "redis-user",
                        redis_password = "redis-password",
                        sentinel_username = "sentinel-user",
                        sentinel_password = "sentinel-password",
                        redis_connect_timeout = 1000,
                        redis_read_timeout = 2000,
                        redis_role = "slave",
                    },
                },
            }
            local store = {get = function(_, name) return values[name] end}

            local cluster = assert(profile.resolve({policy = "redis-cluster",
                                                    redis_host = "redis-profile://cluster"}, store))
            assert(cluster.policy == "redis-cluster")
            assert(cluster.redis_cluster_name == "cluster-a")
            assert(cluster.redis_cluster_nodes[1] == "127.0.0.1:7000")
            assert(cluster.redis_cluster_nodes[2] == "127.0.0.1:7001")
            assert(cluster.redis_cluster_ssl)

            local sentinel = assert(profile.resolve({
                policy = "redis-sentinel",
                redis_host = "redis-profile://sentinel",
            }, store))
            assert(sentinel.policy == "redis-sentinel")
            assert(sentinel.redis_master_name == "mymaster")
            assert(sentinel.redis_sentinels[1] == "127.0.0.1:26379")
            assert(sentinel.redis_username == "redis-user")
            assert(sentinel.sentinel_username == "sentinel-user")
            assert(sentinel.redis_connect_timeout == 1000)
            assert(sentinel.redis_read_timeout == 2000)
            assert(sentinel.redis_role == "slave")
            ngx.say("passed")
        }
    }
--- request
GET /t
--- response_body
passed



=== TEST 5: preserve direct config and invalidate cache on profile update
--- config
    location /t {
        content_by_lua_block {
            local profile = require("apisix.core.redis_profile")
            local direct = {redis_host = "127.0.0.1"}
            assert(profile.resolve(direct) == direct)

            local value = {
                modifiedIndex = 1,
                value = {mode = "standalone", redis_host = "127.0.0.1"},
            }
            local store = {get = function() return value end}
            local conf = {redis_host = "redis-profile://rate-limit"}
            local first = assert(profile.resolve(conf, store))
            assert(profile.resolve(conf, store) == first)

            value.modifiedIndex = 2
            value.value.redis_host = "127.0.0.2"
            local updated = assert(profile.resolve(conf, store))
            assert(updated ~= first)
            assert(updated.redis_host == "127.0.0.2")

            local missing, err = profile.resolve({redis_host = "redis-profile://missing"},
                {get = function() return nil end})
            assert(not missing)
            assert(err == "redis profile not found: missing")

            missing, err = profile.resolve({redis_host = "redis-profile://"})
            assert(not missing)
            assert(err == "redis profile name is empty")
            ngx.say("passed")
        }
    }
--- request
GET /t
--- response_body
passed
