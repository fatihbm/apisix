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
local core = require("apisix.core")
local error = error
local ipairs = ipairs
local type = type

local _M = {
    version = 0.1,
}

local prefix = "redis-profile://"
local profiles
local profile_cache = setmetatable({}, {__mode = "k"})

local endpoint_schema = {
    type = "object",
    properties = {
        host = {type = "string", minLength = 1},
        port = {type = "integer", minimum = 1, maximum = 65535},
    },
    required = {"host", "port"},
    additionalProperties = false,
}

local schema = {
    type = "object",
    properties = {
        mode = {type = "string", enum = {"standalone", "cluster", "sentinel"}},
        host = {type = "string", minLength = 1},
        port = {type = "integer", minimum = 1, maximum = 65535},
        nodes = {
            type = "array",
            minItems = 1,
            items = {oneOf = {{type = "string", minLength = 1}, endpoint_schema}},
        },
        sentinels = {type = "array", minItems = 1, items = endpoint_schema},
        cluster_name = {type = "string", minLength = 1},
        master_name = {type = "string", minLength = 1},
        username = {type = "string", minLength = 1},
        password = {type = "string", minLength = 0},
        sentinel_username = {type = "string", minLength = 1},
        sentinel_password = {type = "string", minLength = 0},
        database = {type = "integer", minimum = 0},
        timeout = {type = "integer", minimum = 1},
        connect_timeout = {type = "integer", minimum = 1},
        read_timeout = {type = "integer", minimum = 1},
        keepalive_timeout = {type = "integer", minimum = 1},
        keepalive_pool = {type = "integer", minimum = 1},
        ssl = {type = "boolean"},
        ssl_verify = {type = "boolean"},
        role = {type = "string", enum = {"master", "slave"}},
    },
    required = {"mode"},
    additionalProperties = false,
}
_M.schema = schema

function _M.check_conf(conf)
    local ok, err = core.schema.check(schema, conf)
    if not ok then
        return false, err
    end

    if conf.mode == "standalone" and not conf.host then
        return false, "standalone profile requires host"
    end
    if conf.mode == "cluster" and (not conf.nodes or not conf.cluster_name) then
        return false, "cluster profile requires nodes and cluster_name"
    end
    if conf.mode == "sentinel" and (not conf.sentinels or not conf.master_name) then
        return false, "sentinel profile requires sentinels and master_name"
    end

    -- Values are encrypted before being stored in etcd. Keep plaintext input
    -- unchanged when no keyring is configured or when it was supplied through
    -- etcd directly, but decrypt values written by this resource for workers.
    if conf.password then
        local password = core.data_encryption.decrypt(conf.password, "redis password")
        if password then
            conf.password = password
        end
    end
    if conf.sentinel_password then
        local password = core.data_encryption.decrypt(conf.sentinel_password,
                                                      "redis sentinel password")
        if password then
            conf.sentinel_password = password
        end
    end

    return true
end

local function get_profile_name(host)
    if type(host) ~= "string" or host:sub(1, #prefix) ~= prefix then
        return
    end

    local name = host:sub(#prefix + 1)
    if name == "" then
        return nil, "redis profile name is empty"
    end
    return name
end

local function normalise_cluster_nodes(nodes)
    local result = core.table.new(#nodes, 0)
    for i, node in ipairs(nodes) do
        if type(node) == "string" then
            result[i] = node
        else
            result[i] = node.host .. ":" .. node.port
        end
    end
    return result
end

local function apply_common_fields(resolved, profile)
    resolved.redis_password = profile.password
    resolved.redis_database = profile.database or 0
    resolved.redis_keepalive_timeout = profile.keepalive_timeout
    resolved.redis_keepalive_pool = profile.keepalive_pool
end

local function build_resolved_conf(conf, profile, profile_name)
    local resolved = core.table.deepcopy(conf)
    apply_common_fields(resolved, profile)

    if profile.mode == "standalone" then
        resolved.policy = "redis"
        resolved.redis_host = profile.host
        resolved.redis_port = profile.port or 6379
        resolved.redis_username = profile.username
        resolved.redis_timeout = profile.timeout
        resolved.redis_ssl = profile.ssl
        resolved.redis_ssl_verify = profile.ssl_verify
    elseif profile.mode == "cluster" then
        resolved.policy = "redis-cluster"
        resolved.redis_cluster_nodes = normalise_cluster_nodes(profile.nodes)
        resolved.redis_cluster_name = profile.cluster_name or profile_name
        resolved.redis_timeout = profile.timeout
        resolved.redis_cluster_ssl = profile.ssl
        resolved.redis_cluster_ssl_verify = profile.ssl_verify
    else
        resolved.policy = "redis-sentinel"
        resolved.redis_sentinels = profile.sentinels
        resolved.redis_master_name = profile.master_name
        resolved.redis_username = profile.username
        resolved.sentinel_username = profile.sentinel_username
        resolved.sentinel_password = profile.sentinel_password
        resolved.redis_connect_timeout = profile.connect_timeout or profile.timeout
        resolved.redis_read_timeout = profile.read_timeout or profile.timeout
        resolved.redis_role = profile.role
    end
    return resolved
end

function _M.init_worker()
    local conf, err = core.config.new("/redis_profiles", {
        automatic = true,
        checker = _M.check_conf,
    })
    if not conf then
        error("failed to watch redis profiles: " .. err)
    end
    profiles = conf
end

function _M.resolve(conf)
    local profile_name, err = get_profile_name(conf.redis_host)
    if not profile_name then
        return conf, err
    end

    local item = profiles and profiles:get(profile_name)
    local profile = item and item.value
    if not profile then
        return nil, "redis profile not found: " .. profile_name
    end

    local cached = profile_cache[conf]
    if cached and cached.modified_index == item.modifiedIndex then
        return cached.conf
    end

    local resolved = build_resolved_conf(conf, profile, profile_name)
    profile_cache[conf] = {modified_index = item.modifiedIndex, conf = resolved}
    return resolved
end

return _M
