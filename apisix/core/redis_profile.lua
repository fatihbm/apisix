local core = require("apisix.core")

local _M = { version = 0.1 }
local profiles
local prefix = "redis-profile://"

function _M.init_worker()
    local conf, err = core.config.new("/redis_profiles", { automatic = true })
    if not conf then
        error("failed to watch redis profiles: " .. err)
    end
    profiles = conf
end

function _M.resolve(conf)
    local host = conf.redis_host
    if type(host) ~= "string" or host:sub(1, #prefix) ~= prefix then
        return conf
    end

    local item = profiles and profiles:get(host:sub(#prefix + 1))
    local profile = item and item.value
    if not profile then
        return conf
    end

    local resolved = core.table.deepcopy(conf)
    if profile.mode == "standalone" then
        resolved.redis_host = profile.host
        resolved.redis_port = profile.port or 6379
        resolved.redis_username = profile.username
        resolved.redis_password = profile.password
        resolved.redis_database = profile.database or 0
    elseif profile.mode == "cluster" then
        resolved.policy = "redis-cluster"
        resolved.redis_cluster_nodes = profile.nodes
        resolved.redis_cluster_name = profile.cluster_name
        resolved.redis_password = profile.password
    elseif profile.mode == "sentinel" then
        resolved.policy = "redis-sentinel"
        resolved.redis_sentinels = profile.sentinels
        resolved.redis_master_name = profile.master_name
        resolved.redis_password = profile.password
    end
    return resolved
end

return _M
