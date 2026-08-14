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
BEGIN {
    $ENV{REDIS_HOST} = "127.0.0.1";

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
no_root_location();
no_shuffle();

add_block_preprocessor(sub {
    my ($block) = @_;
    my $extra_init_worker_by_lua = $block->extra_init_worker_by_lua // "";
    $extra_init_worker_by_lua .= <<_EOC_;
        require("lib.test_redis").flush_all()
_EOC_
    $block->set_value("extra_init_worker_by_lua", $extra_init_worker_by_lua);
});

run_tests;

__DATA__

=== TEST 1: create standalone profile and routes for redis plugins
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t("/apisix/admin/redis_profiles/standalone", ngx.HTTP_PUT, [[{
                "mode": "standalone",
                "redis_host": "$ENV://REDIS_HOST",
                "redis_port": 6379,
                "redis_database": 0,
                "redis_timeout": 1000
            }]])
            assert(code < 300, body)

            local routes = {
                ["/profile-limit-req"] = {
                    "limit-req", {
                        rate = 20, burst = 0, key = "remote_addr", policy = "redis",
                        redis_host = "redis-profile://standalone",
                    },
                },
                ["/profile-limit-conn"] = {
                    "limit-conn", {
                        conn = 20, burst = 0, default_conn_delay = 0.01, key = "remote_addr",
                        policy = "redis", redis_host = "redis-profile://standalone",
                    },
                },
                ["/profile-limit-count"] = {
                    "limit-count", {
                        count = 20, time_window = 60, key = "remote_addr", policy = "redis",
                        redis_host = "redis-profile://standalone",
                    },
                },
            }

            for uri, route in pairs(routes) do
                local name, plugin = route[1], route[2]
                code, body = t("/apisix/admin/routes" .. uri, ngx.HTTP_PUT, {
                    uri = uri,
                    plugins = {[name] = plugin},
                    upstream = {type = "roundrobin", nodes = {["127.0.0.1:1980"] = 1}},
                })
                assert(code < 300, body)
            end
            ngx.sleep(0.2)
            ngx.say("passed")
        }
    }
--- request
GET /t
--- response_body
passed



=== TEST 2: standalone profile is used by limit-req, limit-conn and limit-count
--- pipelined_requests eval
["GET /profile-limit-req", "GET /profile-limit-conn", "GET /profile-limit-count"]
--- error_code eval
[200, 200, 200]



=== TEST 3: update standalone profile without route change
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t("/apisix/admin/redis_profiles/standalone", ngx.HTTP_PATCH, [[{
                "redis_keepalive_pool": 32,
                "redis_keepalive_timeout": 30000
            }]])
            assert(code < 300, body)
            ngx.sleep(0.2)
            ngx.say("passed")
        }
    }
--- request
GET /t
--- response_body
passed



=== TEST 4: requests still succeed after profile update
--- pipelined_requests eval
["GET /profile-limit-req", "GET /profile-limit-conn", "GET /profile-limit-count"]
--- error_code eval
[200, 200, 200]



=== TEST 5: create native cluster and sentinel profiles
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t("/apisix/admin/redis_profiles/cluster", ngx.HTTP_PUT, [[{
                "mode": "cluster",
                "redis_cluster_name": "test",
                "redis_cluster_nodes": ["127.0.0.1:7000", "127.0.0.1:7001", "127.0.0.1:7002"],
                "redis_cluster_ssl": true,
                "redis_cluster_ssl_verify": false
            }]])
            assert(code < 300, body)

            code, body = t("/apisix/admin/redis_profiles/sentinel", ngx.HTTP_PUT, [[{
                "mode": "sentinel",
                "redis_master_name": "mymaster",
                "redis_sentinels": ["127.0.0.1:26379"],
                "redis_username": "master",
                "redis_password": "master-password",
                "redis_role": "master"
            }]])
            assert(code < 300, body)

            code, body = t("/apisix/admin/routes/profile-cluster", ngx.HTTP_PUT, [[{
                "uri": "/profile-cluster",
                "plugins": {
                    "limit-req": {
                        "rate": 20,
                        "burst": 0,
                        "key": "remote_addr",
                        "policy": "redis-cluster",
                        "redis_host": "redis-profile://cluster"
                    }
                },
                "upstream": {"type": "roundrobin", "nodes": {"127.0.0.1:1980": 1}}
            }]])
            assert(code < 300, body)

            ngx.sleep(0.2)
            ngx.say("passed")
        }
    }
--- request
GET /t
--- response_body
passed



=== TEST 6: standalone profile remains usable after other topology profiles exist
--- pipelined_requests eval
["GET /profile-limit-req", "GET /profile-limit-count"]
--- error_code eval
[200, 200]
