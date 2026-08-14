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
local resource = require("apisix.admin.resource")
local redis_profile = require("apisix.core.redis_profile")

local function check_conf(_, conf)
    return redis_profile.check_conf(conf)
end

local function encrypt_conf(_, conf)
    if conf.redis_password then
        conf.redis_password = core.data_encryption.encrypt(conf.redis_password)
    end
    if conf.sentinel_password then
        conf.sentinel_password = core.data_encryption.encrypt(conf.sentinel_password)
    end
end

return resource.new({
    name = "redis_profiles",
    kind = "redis_profile",
    schema = redis_profile.schema,
    checker = check_conf,
    encrypt_conf = encrypt_conf,
})
