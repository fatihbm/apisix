 1 file changed, 1 insertion(+), 1 deletion(-)
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

=== TEST 1: apply virtual Redis profile resolution in the common plugin dispatcher
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugin")
            local redis_profile = require("apisix.core.redis_profile")
            local original_resolve = redis_profile.resolve
            local resolved_calls = 0

            redis_profile.resolve = function(conf)
                if conf.redis_host ~= "redis-profile://limit-req-standalone" then
                    return conf
                end

                resolved_calls = resolved_calls + 1
                return {
                    redis_host = "127.0.0.1",
                    redis_port = 6380,
                    redis_database = conf.redis_database,
                    redis_timeout = 1000,
                    policy = conf.policy,
                    rate = conf.rate,
                    burst = conf.burst,
                    key = conf.key,
                }
            end

            local original_conf = {
                rate = 20,
                burst = 0,
                key = "remote_addr",
                policy = "redis",
                redis_host = "redis-profile://limit-req-standalone",
                redis_database = 9,
            }
            local plugins = plugin.filter({}, {
                value = {plugins = { ["limit-req"] = original_conf }},
            })

            redis_profile.resolve = original_resolve

            assert(resolved_calls == 1)
            assert(#plugins == 2)
            assert(plugins[1].name == "limit-req")
            assert(plugins[2] ~= original_conf)
            assert(original_conf.redis_host == "redis-profile://limit-req-standalone")
            assert(plugins[2].redis_host == "127.0.0.1")
            assert(plugins[2].redis_port == 6380)
            assert(plugins[2].redis_database == 9)
            assert(plugins[2].policy == "redis")
            assert(plugins[2].rate == 20)
            ngx.say("passed")
        }
    }
--- request
GET /t
--- response_body
passed
