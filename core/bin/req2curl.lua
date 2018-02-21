#!/usr/bin/env lem

local root_path = arg[0]:gsub('core.bin.*', '') 
package.path = root_path .. '?.lua;'.. package.path

local sqlite = require 'lem.sqlite3.queued'
local helper = require 'core.helper'
local g_db, err = sqlite.open(root_path .. 'db/visit.db', sqlite.READ)

local ret = g_db:fetchall([[
select url, request_header, request_payload
from node
where url = :url or uid = :uid]], {[":url"] = arg[1], [":uid"] = arg[1]})

if ret[1] then
  print(helper.build_curl_cmdline(ret[1][1], ret[1][2], ret[1][3]))
end
