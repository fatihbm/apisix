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
local core        = require("apisix.core")
local ngx         = ngx
local plugin_name = "query-rewrite"

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
    },
    additionalProperties = false,
}

local _M = {
    version  = 0.1,
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

    return true
end


function _M.access(conf, ctx)
    local method = ngx.req.get_method()
    if method ~= "QUERY" then
        return
    end

    ctx.query_rewrite_original_method = method

    if conf.preserve_original_method_header ~= false then
        core.request.set_header(ctx, conf.original_method_header or "X-Original-Method", method)
    end

    ngx.req.set_method(ngx.HTTP_POST)
end


return _M
