--
-- Licensed to the Apache Software Foundation (ASF) under one or more
-- contributor license agreements.  See the NOTICE file distributed with
-- this work for additional information regarding copyright ownership.
-- The ASF licenses this file to You under the Apache License, Version 2.0
-- (the "License"); you may not use this file except in compliance with
-- the License.  You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--
-- AdArr: dynamic HTTP request routing with dual time-decayed penalty
-- vectors, probabilistic rehabilitation and gradual traffic recovery.
--
-- Every node keeps, besides its in-flight count (Q) and EWMA smoothed
-- latency (S) and volatility (V), two independent penalty vectors: a
-- performance-degradation pool (P), fed by latency overshoot, and a
-- failure pool (F), fed by connection errors weighted per error class.
-- Both decay exponentially on their own clock and only ever inside the
-- background evaluation loop, never on the request path: the data path
-- reads cached base scores and combines them with the live in-flight
-- term over a Power-of-Two-Choices candidate set (plus jitter).
--
-- A node whose penalties cross a threshold becomes DEGRADED: it leaves
-- the normal rotation but is never dropped from the pool. A small,
-- configurable share of the traffic probes the constrained nodes, and a
-- successful probe shrinks their penalties directly. Once the penalties
-- fall back below the recover thresholds a node enters RECOVERING,
-- where its observation count is reset: the confidence term
-- C = 1 - e^(-N/W) in the score then hands its traffic back along a
-- smooth curve instead of in one flood, which is what protects a node
-- with cold caches from the thundering herd.
--
-- Tunables are module-wide, read once per worker from
-- `plugin_attr.adarr` in config.yaml; the defaults below are the
-- shipped behaviour. State lives per worker, keyed by the upstream's
-- resource key, exactly like least_conn's heap: it outlives every
-- picker generation so that in-flight releases always reach the state
-- that counted them.
local core             = require("apisix.core")
local get_last_failure = require("ngx.balancer").get_last_failure

local ipairs = ipairs
local pairs = pairs
local tonumber = tonumber
local tostring = tostring
local ngx = ngx
local ngx_now = ngx.now
local ngx_timer_every = ngx.timer.every
local worker_exiting = ngx.worker.exiting
local get_phase = ngx.get_phase
local math_random = math.random
local math_exp = math.exp
local math_min = math.min
local math_abs = math.abs
local math_floor = math.floor
local str_match = string.match

local module_name = "adarr"
local is_http = ngx.config.subsystem == "http"

local HEALTHY = "healthy"
local DEGRADED = "degraded"
local RECOVERING = "recovering"

-- an out-of-pool node with no in-flight requests and no observation for
-- this long is forgotten; on wall clock its penalties have decayed into
-- insignificance anyway
local STALE_TTL = 600

local defaults = {
    -- score weights; the latency-derived costs are in seconds
    lambda_queue = 1.0,       -- expected queueing cost, lambda_q * Q * S
    lambda_speed = 1.0,       -- smoothed latency
    lambda_volatility = 0.5,  -- smoothed |R - S|
    lambda_perf = 2.0,        -- performance-degradation penalty
    lambda_fail = 4.0,        -- failure penalty
    lambda_conf = 0.5,        -- confidence discount, a credit for trust

    -- penalty decay time constants and ceilings
    perf_decay_time = 5,
    fail_decay_time = 10,
    perf_max = 20,
    fail_max = 60,

    -- failure pool increments per error class
    delta_timeout = 10,
    delta_refused = 6,

    -- state machine thresholds
    degrade_perf = 5,
    degrade_fail = 12,
    recover_perf = 1,
    recover_fail = 2,

    -- confidence window W and the confidence a recovering node must
    -- earn before it is healthy again; a successful probe shrinks both
    -- penalties by this factor
    conf_window = 20,
    healthy_conf = 0.9,
    probe_success_decay = 0.5,

    -- selection
    candidates = 2,           -- the candidate set (k of P2C)
    jitter = 0.02,            -- J(0, Jmax), seconds
    probe_ratio = 0.02,       -- share of traffic probing constrained nodes

    -- EWMA factors
    ewma_alpha = 0.125,
    volatility_alpha = 0.5,

    -- background evaluation loop period, seconds
    eval_interval = 1,
}

local conf = {}

local function load_conf()
    local ok, local_conf = pcall(core.config.local_conf)
    local attr
    if ok then
        attr = core.table.try_read_attr(local_conf, "plugin_attr", module_name)
    end

    for k, v in pairs(defaults) do
        local num = v
        if attr then
            local raw = attr[k]
            if raw ~= nil then
                num = tonumber(raw)
                if not num or num < 0 then
                    core.log.error("adarr: invalid config ", k, ": ", tostring(raw),
                                   ", keeping the default")
                    num = v
                end
            end
        end
        conf[k] = num
    end

    if conf.candidates < 1 then
        conf.candidates = 1
    end
    conf.candidates = math_floor(conf.candidates)
    if conf.conf_window < 1 then
        conf.conf_window = 1
    end
    if conf.eval_interval < 0.1 then
        conf.eval_interval = 0.1
    end
    if conf.healthy_conf > 1 then
        conf.healthy_conf = 1
    end
    if conf.probe_ratio > 1 then
        conf.probe_ratio = 1
    end
    if conf.probe_success_decay <= 0 or conf.probe_success_decay > 1 then
        conf.probe_success_decay = defaults.probe_success_decay
    end
end


-- Per-worker balancing state, shared by every picker built for the same
-- upstream, exactly like least_conn's heap and for the same reason: a
-- picker is thrown away whenever the upstream version or the health
-- status changes, while the requests routed with it still report their
-- outcome against the state they were picked from. The values are weak:
-- a state lives as long as some picker or in-flight request can still
-- touch it, and nothing more.
local states = setmetatable({}, {__mode = "v"})


local function confidence(n)
    return 1 - math_exp(-n / conf.conf_window)
end


-- Bring the stored penalties up to `now` and restamp the update time.
-- Event handlers always mutate these decayed values, so the vectors
-- behave as the exponential memory of the observations, not as an
-- ever-growing counter.
local function decay_penalties(rec, now)
    local dt = now - rec.t0
    if dt > 0 then
        rec.p = rec.p * math_exp(-dt / conf.perf_decay_time)
        rec.f = rec.f * math_exp(-dt / conf.fail_decay_time)
        rec.t0 = now
    end
end


local function refresh_base(rec, prior_speed)
    local speed = rec.s or prior_speed or 0
    rec.base = (conf.lambda_speed * speed
                + conf.lambda_volatility * rec.v
                + conf.lambda_perf * rec.p
                + conf.lambda_fail * rec.f
                - conf.lambda_conf * confidence(rec.n)) * rec.ew
end


local function transition(rec)
    if rec.state == HEALTHY then
        if rec.p >= conf.degrade_perf or rec.f >= conf.degrade_fail then
            rec.state = DEGRADED
            rec.n = 0
        end
    elseif rec.state == DEGRADED then
        if rec.p < conf.recover_perf and rec.f < conf.recover_fail then
            rec.state = RECOVERING
            rec.n = 0
        end
    else
        if rec.p >= conf.degrade_perf or rec.f >= conf.degrade_fail then
            rec.state = DEGRADED
            rec.n = 0
        elseif rec.p < conf.recover_perf and rec.f < conf.recover_fail
               and confidence(rec.n) >= conf.healthy_conf then
            rec.state = HEALTHY
        end
    end
end


local function observe_success(state, rec, rtt, now)
    decay_penalties(rec, now)

    if rec.s then
        local s_old = rec.s
        rec.v = conf.volatility_alpha * math_abs(rtt - s_old)
                + (1 - conf.volatility_alpha) * rec.v
        if rtt > s_old then
            rec.p = math_min(rec.p + (rtt - s_old), conf.perf_max)
        end
        rec.s = conf.ewma_alpha * rtt + (1 - conf.ewma_alpha) * s_old
    else
        rec.s = rtt
        rec.v = 0
    end

    if rec.state == DEGRADED then
        -- a successful probe is the rehabilitation itself: shrink the
        -- vectors directly instead of only waiting for them to decay
        rec.p = rec.p * conf.probe_success_decay
        rec.f = rec.f * conf.probe_success_decay
    end

    rec.n = rec.n + 1
    rec.last = now
    refresh_base(rec, state.prior_s)
end


local function observe_failure(state, rec, delta, now)
    decay_penalties(rec, now)

    rec.f = math_min(rec.f + delta, conf.fail_max)
    rec.n = 0
    rec.last = now

    if rec.state == RECOVERING then
        -- a failed probe is where the recovery restarts
        rec.state = DEGRADED
    elseif rec.state == HEALTHY
           and (rec.p >= conf.degrade_perf or rec.f >= conf.degrade_fail) then
        rec.state = DEGRADED
    end

    refresh_base(rec, state.prior_s)
end


-- One background evaluation pass: decay the vectors of every node the
-- request path has not touched, run the state transitions, and refresh
-- the base scores the pickers read. This is where the exponentials
-- live; the request path only ever adds the in-flight term.
local function evaluate_state(state, now)
    local speed_sum, speed_weight = 0, 0
    for _, rec in pairs(state.nodes) do
        if rec.in_pool then
            decay_penalties(rec, now)
            transition(rec)
            if rec.s then
                speed_sum = speed_sum + rec.s * rec.weight
                speed_weight = speed_weight + rec.weight
            end
        end
    end
    state.prior_s = speed_weight > 0 and speed_sum / speed_weight or nil

    core.table.clear(state.pool)
    for addr, rec in pairs(state.nodes) do
        if rec.in_pool then
            refresh_base(rec, state.prior_s)
            core.table.insert(state.pool, rec)
        elseif rec.q == 0 and now - rec.last > STALE_TTL then
            state.nodes[addr] = nil
        end
    end
end


local function sweep(premature)
    if premature or worker_exiting() then
        return
    end

    local now = ngx_now()
    for _, state in pairs(states) do
        local ok, err = pcall(evaluate_state, state, now)
        if not ok then
            core.log.error("adarr: evaluation failed: ", err)
        end
    end
end


local timer_started = false
local function ensure_timer()
    if timer_started then
        return
    end

    -- a picker can be built from a phase where the timer API is
    -- disabled; the first build that can create the loop starts it, and
    -- in between the base scores the requests read stay those of the
    -- last evaluation, which only ever costs freshness, never correctness
    local pcall_ok, created, err = pcall(ngx_timer_every, conf.eval_interval, sweep)
    if pcall_ok and created and not err then
        timer_started = true
    else
        core.log.warn("adarr: failed to start the evaluation loop: ",
                      tostring(err or created))
    end
end


local function new_state()
    return {
        nodes = {},
        pool = {},
        prior_s = nil,
    }
end


-- Align the long-lived state with the node set of this picker build.
-- Nodes that left the set keep their record while they can still see
-- an in-flight release, and the sweep drops them once that is gone too.
local function sync_nodes(state, up_nodes)
    local now = ngx_now()
    for addr, weight in pairs(up_nodes) do
        local rec = state.nodes[addr]
        if not rec then
            rec = {
                q = 0,
                s = nil,
                v = 0,
                p = 0,
                f = 0,
                t0 = now,
                n = 0,
                base = 0,
                state = HEALTHY,
                last = now,
            }
            state.nodes[addr] = rec
        end
        rec.weight = weight
        rec.ew = weight > 0 and (1 / weight) or 0
        rec.in_pool = weight > 0
    end

    for addr, rec in pairs(state.nodes) do
        if not up_nodes[addr] then
            rec.in_pool = false
        end
    end
end


-- scratch of the selection path; get() never yields between the clear
-- and the last read
local avail = {}


local function collect(state, ctx, up_nodes, only_constrained)
    core.table.clear(avail)
    local tried = ctx.balancer_tried_servers
    for _, rec in ipairs(state.pool) do
        if up_nodes[rec.addr] and not (tried and tried[rec.addr])
           and (rec.state ~= HEALTHY) == only_constrained then
            core.table.insert(avail, rec)
        end
    end
    return avail
end


local function pick_scored(state, ctx, up_nodes)
    local list = collect(state, ctx, up_nodes, false)
    local n = #list
    if n == 0 then
        return nil
    end

    local k = math_min(conf.candidates, n)
    local best, best_score
    for i = 1, k do
        -- partial Fisher-Yates: k distinct candidates, O(k)
        local j = math_random(i, n)
        if j ~= i then
            list[i], list[j] = list[j], list[i]
        end

        local rec = list[i]
        local speed = rec.s or state.prior_s or 0
        local score = rec.base
                      + rec.ew * conf.lambda_queue * rec.q * speed
                      + math_random() * conf.jitter
        if not best_score or score < best_score then
            best, best_score = rec, score
        end
    end

    return best
end


local function pick_constrained(state, ctx, up_nodes)
    local list = collect(state, ctx, up_nodes, true)
    if #list == 0 then
        return nil
    end

    local total = 0
    for _, rec in ipairs(list) do
        total = total + rec.weight
    end
    if total <= 0 then
        return nil
    end

    local tick = math_random() * total
    for _, rec in ipairs(list) do
        tick = tick - rec.weight
        if tick <= 0 then
            return rec
        end
    end
    return list[#list]
end


local function adarr_get(state, up_nodes, ctx)
    local rec
    if math_random() < conf.probe_ratio then
        -- the probe replaces the normal selection for this request
        rec = pick_constrained(state, ctx, up_nodes)
    end
    if not rec then
        rec = pick_scored(state, ctx, up_nodes)
    end
    if not rec then
        -- every eligible node has been tried: hand the request to a
        -- constrained one still untried before giving up, the same
        -- fail-open the rest of the balancer applies to an all
        -- unhealthy set
        rec = pick_constrained(state, ctx, up_nodes)
    end
    if not rec then
        return nil, "all upstream servers tried"
    end

    rec.q = rec.q + 1
    rec.last = ngx_now()
    return rec.addr
end


local function release_tried(ctx)
    if ctx.balancer_tried_servers then
        core.tablepool.release("balancer_tried_servers", ctx.balancer_tried_servers)
        ctx.balancer_tried_servers = nil
    end
end


-- the last entry nginx writes, for the final upstream try
local function last_var(value)
    if not value or value == "" then
        return nil
    end
    return str_match(value, "([^,%s]+)%s*$")
end


local function adarr_after_balance(state, ctx, before_retry)
    -- the release is what makes the request stop holding the server, so
    -- drop the reference here instead of leaving every caller to
    -- remember; a node the attempt never reached is still accounted for
    local server = ctx.balancer_server
    ctx.balancer_server = nil

    local rec = server and state.nodes[server]
    if rec then
        local q = rec.q - 1
        if q < 0 then
            core.log.error("adarr: released a connection never picked on ", server)
            q = 0
        end
        rec.q = q
        rec.last = ngx_now()
    end

    if before_retry then
        if not server then
            return nil
        end

        if not ctx.balancer_tried_servers then
            ctx.balancer_tried_servers = core.tablepool.fetch("balancer_tried_servers", 0, 2)
        end
        ctx.balancer_tried_servers[server] = true
        ctx.balancer_tried_servers_count = (ctx.balancer_tried_servers_count or 0) + 1

        -- the outcome of the failed attempt is only readable in the
        -- balancer phase; paths that drive pick_server from elsewhere
        -- (the websocket proxy) never enter a balancer phase for the
        -- attempt, and there it is reported to the active healthcheck
        -- by the caller instead of to this state
        if rec and get_phase() == "balancer" then
            local last_state, code = get_last_failure()
            if last_state == "failed" then
                -- a status the upstream itself produced is application
                -- level and judged by the active healthcheck; the
                -- passive failure vector tracks only the connection not
                -- being usable, and a timeout among those carries the
                -- heavier class
                local delta = code == 504 and conf.delta_timeout or conf.delta_refused
                observe_failure(state, rec, delta, ngx_now())
            end
        end

        return nil
    end

    release_tried(ctx)

    if not rec then
        -- the final attempt was already released on a retry
        return nil
    end

    local now = ngx_now()

    local status = last_var(ctx.var and ctx.var.upstream_status)
    if status == "499" then
        -- the client hung up. The upstream did not fail: the in-flight
        -- count came down above and nothing else moves
        return nil
    end

    local resp = tonumber(last_var(ctx.var and ctx.var.upstream_response_time))
    if resp then
        local connect = tonumber(last_var(ctx.var and ctx.var.upstream_connect_time)) or 0
        observe_success(state, rec, connect + resp, now)
        return nil
    end

    if not (ctx.var and ctx.var.upstream_addr) then
        -- the request never reached an upstream after this pick (the
        -- peer could not even be set, say): the pick was released above
        -- and the node is not implicated
        return nil
    end

    if not status or status == "-" then
        observe_failure(state, rec, conf.delta_refused, now)
    elseif status == "504" then
        observe_failure(state, rec, conf.delta_timeout, now)
    end
    -- any other status completed at the HTTP level and was measured by
    -- the response-time branch above or by the active healthcheck

    return nil
end


local _M = {}


function _M.new(up_nodes, upstream, priority)
    if not is_http then
        return nil, "adarr balancer requires the http subsystem"
    end

    load_conf()

    local state
    local up_key = upstream.resource_key
    if up_key and priority then
        local state_key = up_key .. "#" .. priority
        state = states[state_key]
        if not state then
            state = new_state()
            states[state_key] = state
        end
    else
        -- no stable identity, fall back to a state private to this picker
        state = new_state()
    end

    sync_nodes(state, up_nodes)
    -- a build is rare (upstream or health status changed), so the decay
    -- pass is affordable here; it also seeds the base scores of nodes
    -- the loop has not evaluated yet, including for a worker whose
    -- timer could not be created from this phase
    evaluate_state(state, ngx_now())
    ensure_timer()

    return {
        upstream = upstream,
        get = function (ctx)
            return adarr_get(state, up_nodes, ctx)
        end,
        after_balance = function (ctx, before_retry)
            return adarr_after_balance(state, ctx, before_retry)
        end,
        before_retry_next_priority = function (ctx)
            release_tried(ctx)
        end,
    }
end

_M.name = module_name

-- for test: the evaluation pass on demand, the live conf table (mutable,
-- the pickers read it through this same reference) and the state registry
_M._evaluate = function ()
    sweep(nil)
end
_M._conf = conf
_M._states = states

return _M
