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
local pairs = pairs
local type = type

local _M = {
    version = 0.1,
}

local prefix = "redis-profile://"
local profiles
local profile_cache = setmetatable({}, {__mode = "k"})

local schema = {
    type = "object",
    properties = {
        id = {type = "string", minLength = 1},
        -- These fields are injected by the APISIX resource layer before the
        -- etcd watcher validates a persisted profile.
        create_time = {type = "integer"},
        update_time = {type = "integer"},
        mode = {type = "string", enum = {"standalone", "cluster", "sentinel"}},
        redis_host = {type = "string", minLength = 1},
        redis_port = {type = "integer", minimum = 1, maximum = 65535},
        redis_cluster_nodes = {
            type = "array",
            minItems = 1,
            items = {type = "string", minLength = 1},
        },
        redis_sentinels = {type = "array", minItems = 1,
            items = {type = "string", minLength = 1}},
        redis_cluster_name = {type = "string", minLength = 1},
        redis_master_name = {type = "string", minLength = 1},
        redis_username = {type = "string", minLength = 1},
        redis_password = {type = "string", minLength = 0},
        sentinel_username = {type = "string", minLength = 1},
        sentinel_password = {type = "string", minLength = 0},
        redis_database = {type = "integer", minimum = 0},
        redis_timeout = {type = "integer", minimum = 1},
        redis_connect_timeout = {type = "integer", minimum = 1},
        redis_read_timeout = {type = "integer", minimum = 1},
        redis_keepalive_timeout = {type = "integer", minimum = 1},
        redis_keepalive_pool = {type = "integer", minimum = 1},
        redis_ssl = {type = "boolean"},
        redis_ssl_verify = {type = "boolean"},
        redis_cluster_ssl = {type = "boolean"},
        redis_cluster_ssl_verify = {type = "boolean"},
        redis_role = {type = "string", enum = {"master", "slave"}},
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

    if conf.mode == "standalone" and not conf.redis_host then
        return false, "standalone profile requires redis_host"
    end
    if conf.mode == "cluster" and (not conf.redis_cluster_nodes or not conf.redis_cluster_name) then
        return false, "cluster profile requires redis_cluster_nodes and redis_cluster_name"
    end
    if conf.mode == "sentinel" and (not conf.redis_sentinels or not conf.redis_master_name) then
        return false, "sentinel profile requires redis_sentinels and redis_master_name"
    end

    -- Values are encrypted before being stored in etcd. Keep plaintext input
    -- unchanged when no keyring is configured or when it was supplied through
    -- etcd directly, but decrypt values written by this resource for workers.
    if conf.redis_password then
        local password = core.data_encryption.decrypt(conf.redis_password, "redis password")
        if password then
            conf.redis_password = password
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

local function build_resolved_conf(conf, profile)
    -- Profiles contain the same native Redis fields that plugins consume.
    -- Keep topology selection and route-specific overrides in plugin config.
    local resolved = core.table.deepcopy(profile)
    resolved.id = nil
    resolved.create_time = nil
    resolved.update_time = nil
    resolved.mode = nil

    for key, value in pairs(conf) do
        if key ~= "redis_host" then
            resolved[key] = value
        end
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

function _M.resolve(conf, profile_store)
    local profile_name, err = get_profile_name(conf.redis_host)
    if not profile_name then
        if err then
            return nil, err
        end
        return conf
    end

    profile_store = profile_store or profiles
    local item = profile_store and profile_store:get(profile_name)
    local profile = item and item.value
    if not profile then
        return nil, "redis profile not found: " .. profile_name
    end

    local cached = profile_cache[conf]
    if cached and cached.modified_index == item.modifiedIndex then
        return cached.conf
    end

    local resolved = build_resolved_conf(conf, profile)
    profile_cache[conf] = {modified_index = item.modifiedIndex, conf = resolved}
    return resolved
end

return _M
