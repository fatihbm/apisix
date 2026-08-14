local core = require("apisix.core")
local resource = require("apisix.admin.resource")

local schema = {
    type = "object",
    properties = {
        mode = {type = "string", enum = {"standalone", "cluster", "sentinel"}},
        host = {type = "string"}, port = {type = "integer", minimum = 1},
        nodes = {type = "array", items = {type = "string"}},
        cluster_name = {type = "string"}, sentinels = {type = "array"},
        master_name = {type = "string"}, username = {type = "string"},
        password = {type = "string"}, database = {type = "integer", minimum = 0},
    },
    required = {"mode"},
    additionalProperties = false,
}

local function check_conf(_, conf)
    local ok, err = core.schema.check(schema, conf)
    if not ok then
        return false, err
    end
    if conf.mode == "standalone" and not conf.host then
        return false, "standalone profile requires host"
    end
    if conf.mode == "cluster" and (not conf.nodes or #conf.nodes == 0) then
        return false, "cluster profile requires nodes"
    end
    if conf.mode == "sentinel" and (not conf.sentinels or #conf.sentinels == 0
        or not conf.master_name) then
        return false, "sentinel profile requires sentinels and master_name"
    end
    return true
end

return resource.new({
    name = "redis_profiles",
    kind = "redis_profile",
    schema = schema,
    checker = check_conf,
})
