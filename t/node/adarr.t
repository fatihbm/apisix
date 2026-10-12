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
log_level('info');
no_root_location();
worker_connections(1024);
no_shuffle();

add_block_preprocessor(sub {
    my ($block) = @_;

    if (!$block->yaml_config) {
        my $yaml_config = <<_EOC_;
apisix:
    node_listen: 1984
deployment:
    role: data_plane
    role_data_plane:
        config_provider: yaml
plugin_attr:
    adarr:
        jitter: 0
        probe_ratio: 0
        eval_interval: 0.1
_EOC_

        $block->set_value("yaml_config", $yaml_config);
    }

    my $route = <<_EOC_;
routes:
  - upstream_id: 1
    uris:
      - /adarr-node
#END
_EOC_

    $block->set_value("apisix_yaml", $block->apisix_yaml . $route);

    if (!defined $block->request) {
        $block->set_value("request", "GET /adarr-node");
    }
});

run_tests();

__DATA__

=== TEST 1: selects between the nodes of the pool
--- apisix_yaml
upstreams:
  - id: 1
    type: adarr
    nodes:
        "127.0.0.1:1980": 1
        "127.0.0.1:1981": 1
--- upstream_server_config
    location /adarr-node {
        content_by_lua_block {
            ngx.print(ngx.var.server_port)
        }
    }
--- config
    location /t {
        content_by_lua_block {
            local http = require "resty.http"
            local uri = "http://127.0.0.1:" .. ngx.var.server_port .. "/adarr-node"

            local valid = true
            for _ = 1, 12 do
                local httpc = http.new()
                local res, err = httpc:request_uri(uri)
                if not res then
                    ngx.log(ngx.ERR, err)
                    return
                end
                valid = valid and res.status == 200
                        and (res.body == "1980" or res.body == "1981")
            end
            ngx.say(valid and "ok" or "invalid")
        }
    }
--- request
GET /t
--- response_body
ok



=== TEST 2: a node refusing connections fails the request when it is alone
--- apisix_yaml
upstreams:
  - id: 1
    type: adarr
    nodes:
        "127.0.0.1:1999": 1
--- error_code: 502
--- error_log
connect() failed



=== TEST 3: retries the rest of the pool when connections are refused
--- apisix_yaml
upstreams:
  - id: 1
    type: adarr
    nodes:
        "127.0.0.1:1999": 1
        "127.0.0.1:1980": 1
--- upstream_server_config
    location /adarr-node {
        content_by_lua_block {
            ngx.print(ngx.var.server_port)
        }
    }
--- response_body_like eval
qr/^1980\z/
--- error_log
connect() failed



=== TEST 4: all nodes refusing, the request ends up with no server
--- apisix_yaml
upstreams:
  - id: 1
    type: adarr
    nodes:
        "127.0.0.1:1999": 1
        "0.0.0.0:1999": 1
--- error_code: 502
--- error_log
connect() failed



=== TEST 5: the state machine: degrade, probe, recover, and cancel neutrality
--- config
    location /t {
        content_by_lua_block {
            local adarr = require("apisix.balancer.adarr")
            local conf = adarr._conf
            conf.jitter = 0
            conf.probe_ratio = 0

            local up = {resource_key = "t-adarr-unit"}
            local picker = adarr.new({["127.0.0.1:1980"] = 1,
                                      ["127.0.0.1:1999"] = 1}, up, 0)
            local state = adarr._states["t-adarr-unit#0"]
            local good_addr, bad_addr = "127.0.0.1:1980", "127.0.0.1:1999"
            local good, bad = state.nodes[good_addr], state.nodes[bad_addr]

            local failures = {}
            local function check(cond, msg)
                if not cond then
                    table.insert(failures, msg)
                end
            end

            -- an attempt already picked on `addr`, ending in a refused
            -- connection or in a measured success
            local function attempt(addr, success)
                local rec = state.nodes[addr]
                rec.q = rec.q + 1
                local ctx = {var = {upstream_addr = addr}, balancer_server = addr}
                if success then
                    ctx.var.upstream_status = "200"
                    ctx.var.upstream_connect_time = "0.001"
                    ctx.var.upstream_response_time = "0.002"
                end
                picker.after_balance(ctx, false)
            end

            -- a client cancel is not the upstream's failure: it only
            -- gives the in-flight hold back
            local cancel = {var = {upstream_addr = bad_addr, upstream_status = "499"},
                            balancer_server = bad_addr}
            bad.q = bad.q + 1
            picker.after_balance(cancel, false)
            check(bad.q == 0, "cancel releases the inflight")
            check(bad.f == 0 and bad.p == 0, "cancel costs the node nothing")
            check(bad.state == "healthy", "cancel leaves the node healthy")

            for _ = 1, 4 do
                attempt(bad_addr, false)
            end
            check(bad.state == "degraded", "a refused node leaves the rotation")

            for _ = 1, 20 do
                local ctx = {var = {upstream_addr = good_addr, upstream_status = "200",
                                    upstream_connect_time = "0.001",
                                    upstream_response_time = "0.002"}}
                local addr = picker.get(ctx)
                check(addr == good_addr, "degraded node kept out while probing is off")
                ctx.balancer_server = addr
                picker.after_balance(ctx, false)
            end

            -- a probe lands on the degraded node and its success shrinks
            -- the failure pool until the recovery starts
            conf.probe_ratio = 1
            local guard = 0
            while bad.state == "degraded" and guard < 30 do
                guard = guard + 1
                local ctx = {var = {}}
                local addr = picker.get(ctx)
                check(addr == bad_addr, "the probe picks the constrained node")
                ctx.balancer_server = addr
                picker.after_balance({var = {upstream_addr = addr, upstream_status = "200",
                                             upstream_connect_time = "0.001",
                                             upstream_response_time = "0.002"},
                                       balancer_server = addr}, false)
                adarr._evaluate()
            end
            check(bad.state == "recovering", "successful probes rehabilitate the node")
            check(bad.n == 0, "recovery restarts the observation count")

            -- the confidence earned in RECOVERING brings the node back
            local rounds = 0
            while bad.state == "recovering" and rounds < 100 do
                rounds = rounds + 1
                attempt(bad_addr, true)
                adarr._evaluate()
            end
            check(bad.state == "healthy", "confidence completes the gradual recovery")

            -- healthy again: it can be picked once more
            conf.probe_ratio = 0
            local ctx = {var = {upstream_addr = bad_addr},
                         balancer_tried_servers = {[good_addr] = true}}
            bad.q = bad.q + 1
            local addr = picker.get(ctx)
            check(addr == bad_addr, "a recovered node joins the rotation")
            picker.after_balance({var = {}, balancer_server = addr,
                                  balancer_tried_servers = ctx.balancer_tried_servers}, false)

            conf.probe_ratio = 0
            conf.jitter = 0
            if #failures == 0 then
                ngx.say("ok")
            else
                ngx.say("failures: ", table.concat(failures, ", "))
            end
        }
    }
--- request
GET /t
--- response_body
ok



=== TEST 6: a single node upstream still serves
--- apisix_yaml
upstreams:
  - id: 1
    type: adarr
    nodes:
        "127.0.0.1:1980": 1
--- upstream_server_config
    location /adarr-node {
        content_by_lua_block {
            ngx.print(ngx.var.server_port)
        }
    }
--- response_body_like eval
qr/^1980\z/
