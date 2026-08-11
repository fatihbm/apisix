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
local cache = require("apisix.plugins.query-rewrite.cache")
local core  = require("apisix.core")
local ngx   = ngx

local plugin_name = "query-rewrite"

local cache_schema = {
    type = "object",
    properties = {
        enabled = {type = "boolean", default = false},
        backend = {
            type = "string",
            enum = {"local", "redis", "redis-cluster"},
            default = "local",
        },
        ttl = {type = "integer", minimum = 1, default = 30},
        fallback_ttl = {type = "integer", minimum = 1, default = 5},
        max_request_body_size = {type = "integer", minimum = 1, default = 262144},
        max_response_body_size = {type = "integer", minimum = 1, default = 1048576},
        cookie_names = {
            type = "array",
            uniqueItems = true,
            items = {type = "string", minLength = 1, maxLength = 256},
        },
        redis_host = {type = "string", minLength = 1},
        redis_port = {type = "integer", minimum = 1, maximum = 65535, default = 6379},
        redis_timeout = {type = "integer", minimum = 1, default = 1000},
        redis_username = {type = "string", minLength = 1},
        redis_password = {type = "string", minLength = 1},
        redis_database = {type = "integer", minimum = 0, default = 0},
        redis_ssl = {type = "boolean", default = false},
        redis_ssl_verify = {type = "boolean", default = false},
        redis_keepalive_timeout = {type = "integer", minimum = 1, default = 10000},
        redis_keepalive_pool = {type = "integer", minimum = 1, default = 100},
        redis_cluster_name = {type = "string", minLength = 1},
        redis_cluster_nodes = {
            type = "array",
            minItems = 1,
            items = {type = "string", minLength = 1},
        },
        redis_cluster_ssl = {type = "boolean", default = false},
        redis_cluster_ssl_verify = {type = "boolean", default = false},
    },
    additionalProperties = false,
}

local schema = {
    type = "object",
    properties = {
        preserve_original_method_header = {
            description = "whether to forward the original request method",
            type = "boolean",
            default = true,
        },
        original_method_header = {
            description = "header used to forward the original request method",
            type = "string",
            default = "X-Original-Method",
            minLength = 1,
            maxLength = 128,
        },
        cache = cache_schema,
    },
    additionalProperties = false,
}

local _M = {
    version  = 0.2,
    priority = -1001,
    name     = plugin_name,
    schema   = schema,
}

function _M.check_schema(conf)
    local ok, err = core.schema.check(schema, conf)
    if not ok then
        return false, err
    end

    if conf.preserve_original_method_header ~= false
        and not core.utils.validate_header_field(conf.original_method_header
            or "X-Original-Method") then
        return false, "invalid original_method_header"
    end

    local cache_conf = conf.cache
    if cache_conf and cache_conf.enabled then
        if cache_conf.backend == "redis" and not cache_conf.redis_host then
            return false, "cache.redis_host is required for the redis backend"
        end

        if cache_conf.backend == "redis-cluster"
            and (not cache_conf.redis_cluster_name or not cache_conf.redis_cluster_nodes) then
            return false, "cache.redis_cluster_name and cache.redis_cluster_nodes are required " ..
                          "for the redis-cluster backend"
        end
    end

    return true
end

function _M.access(conf, ctx)
    local method = ngx.req.get_method()
    if method ~= "QUERY" then
        return
    end

    local cache_conf = conf.cache
    if cache_conf and cache_conf.enabled then
        local entry, status = cache.fetch(cache_conf, ctx)
        if entry then
            return cache.serve(entry)
        end

        if status == "missing content-type" then
            return 400
        end
    end

    ctx.query_rewrite_original_method = method

    if conf.preserve_original_method_header ~= false then
        core.request.set_header(ctx, conf.original_method_header or "X-Original-Method", method)
    end

    ngx.req.set_method(ngx.HTTP_POST)
end

function _M.header_filter(conf, ctx)
    if conf.cache and conf.cache.enabled then
        cache.header_filter(conf.cache, ctx)
    end
end

function _M.body_filter(conf, ctx)
    if conf.cache and conf.cache.enabled then
        cache.body_filter(conf.cache, ctx)
    end
end

return _M
