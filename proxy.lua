local io = require 'lem.io'
local lfs = require 'lem.lfs'
local utils = require 'lem.utils'
local mbedtls = require 'lem.mbedtls'
local http = require 'lem.http'
local lem_http_client = require 'lem.http.client'

local spawn = utils.spawn

local g_ca_key
local g_ca_crt
local g_generic_key


if lfs.symlinkattributes("crt/ca.key") == nil then
  print('creating ca key..')
  g_ca_key = mbedtls.new_pkey({rsa_keysize=2048})
  io.open("crt/ca.key", "w"):write(g_ca_key)
else
  print('reading ca key..')
  g_ca_key = io.open("crt/ca.key"):read("*a")
end

if lfs.symlinkattributes("crt/ca.crt") == nil then
  print('creating ca crt..')
  g_ca_crt = mbedtls.new_ca_crt(g_ca_key)
  io.open("crt/ca.crt", "w"):write(g_ca_crt)
else
  print('reading ca crt..')
  g_ca_crt = io.open("crt/ca.crt"):read("*a")
end

if lfs.symlinkattributes("crt/generic.key") == nil then
  print('creating generic key..')
  g_generic_key = mbedtls.new_pkey({rsa_keysize=2048})
  io.open("crt/generic.key", "w"):write(g_generic_key)
else
  print('reading generic key..')
  g_generic_key = io.open("crt/generic.key"):read("*a")
end




local ssl_client_base_conf = {
  mode='client',
  crt_file='ca-list.pem',
  ssl_verify_mode=1, -- 0: don't verify
                     -- 1: verify but keep going if certificate is invalid
                     -- 2: if certifacte is invalid abort the connection
}

local g_ssl_client_conf, err = mbedtls.new_tls_config(ssl_client_base_conf)


local module_list = {}

function hooks_init()
  local core = require 'core/init'
  module_list[#module_list+1] = core
  core.init()

  for i, v in pairs(lfs.glob("modules/*/*/init.lua")) do
    local hook = require(v:gsub('.lua', ''))
    module_list[#module_list+1] = hook
    hook.init()
  end
end

hooks_init()

function module_invoke(hook_name, attr)
  local r 
  for i=1, #module_list do
    local f = module_list[i][hook_name]
    if f then
      f = f(r, attr)
    end
  end
  return r
end


local proxy_mt = {}

function proxy(sock)
  local o = {s = sock, http_client=lem_http_client.new()}
  setmetatable(o, {__index = proxy_mt})
  
  o:parse_proxy_req()
end

--local filter = require 'filter/simplify_html'

local format = string.format
local concat = table.concat

function parse_header(socket, full) -- %{
  local h = {
    method='',
    path='',
    version='',
    hlist={},hmap={},hmapv={}}

  if full ~= nil then
    local l, err = socket:read("*l")

    if err then
      return nil, "err0.0 "..err
    end
    if l == "\r" then
      return nil, "err0.1"
    end
    h.method, h.path, h.version = l:match("([^ ]*)[ \t]+([^ ]*)[ \t]+HTTP/([0-9.]+)")
  end

  local hlist_index = 1
  while true do
    local l, err = socket:read("*l")
    if l == "\r" then
      break
    end
    if err then
      return nil, "err1"
    end

    local key, value = l:match("([^:]+):[\t ]*([^\r\n]*)\r?\n?$")

    if key ~= nil then
      h.hlist[hlist_index] = {key, value}
      h.hmap[key:lower()] = value
      h.hmapv[key] = value
      hlist_index = hlist_index + 1
    end
  end

  --print('kvout:', socket:fileno())

  return h
end -- }%

local server_crt_map = {}

function hostname_to_serial(domain)
  local serial = 9999
  for i=1,#domain do
    serial = serial + (i%10 * domain:byte(i))
  end
  serial = serial + #domain

  return serial
end

function proxy_mt:handle_connect(req, sock) -- %{
  local url, http_version = req.path, req.version
  local mitm_ssl = true
  
  local host, port = url:match("([^:]*):(.*)")
  local remote_server_sock, mitm_server_sock
  
  if mitm_ssl == false then -- %{
    remote_server_sock = io.tcp.connect(host, port, "ipv4")
  else
    remote_server_sock, mitm_server_sock = io.unix.socketpair()

    if remote_server_sock == nil or mitm_server_sock == nil then
      sock:close()
      return 
    end
    
    local crt = server_crt_map[host]

    if crt == nil then
      local serial = hostname_to_serial(host)
      crt = mbedtls.new_signed_crt(g_ca_key, g_ca_crt, {
        subject_name = "CN="..host..",O=Bla,C=FR",
        serial = serial,
        subject_key = g_generic_key
      })
      server_crt_map[host] = crt
    end
    
    local conf = mbedtls.new_tls_config({
      crt=crt,
      key=g_generic_key
    })


    spawn(function () -- %{
      local ssl_socket, err = conf:ssl_wrap_socket(mitm_server_sock)
      
      if ssl_socket == nil then
        mitm_server_sock:close()
        remote_server_sock:close()
        return 
      end
      
      local ressource_served = 0
      
      self.http_client.ssl = g_ssl_client_conf
      
      while true do -- %{
        local req, err = parse_header(ssl_socket, true)
        
        if err then 
          break
        end
        
        req.path = 'https://' .. host .. req.path
      
      
        self:handle_method(req, ssl_socket)
      end -- }%
    end) -- }%
  end -- }%

  if remote_server_sock == nil then
    sock:close()
    return 
  end

  local close_sockets = function ()
    if remote_server_sock then
      remote_server_sock:close()
    end
    sock:close()
  end

  sock:write("HTTP/1.1 200 Connection established\r\n\r\n")

  utils.spawn(function ()
    local data, err
    while true do
      data, err = remote_server_sock:read()
      if err then close_sockets() return end
      data, err = sock:write(data)
      if err then close_sockets() return end
    end
  end)

  local data, err
  while true do
    data, err = sock:read()
    if err then close_sockets() return end
    data, err = remote_server_sock:write(data)
    if err then close_sockets() return end
  end
end -- }%

local get_uid
(function () 
  get_uid = function(...)
    return table.concat{ utils.updatenow() .. '|' .. tostring(utils.thisthread()) , ... }
  end
end)()

function proxy_mt:handle_method(req, sock) -- %{
  self.thread_request_nu = self.thread_request_nu + 1
  local url, http_version = req.path, req.version
  local http_client = self.http_client


  --print('http req->', self.thread_request_nu, req.method, url, req.hmap['content-length'])

  local payload
  local payload_len = tonumber(req.hmap['content-length'] or 0)
  if payload_len > 0 then
    payload = sock:read(payload_len)
  end

  url = url:gsub("^[^:]*", string.lower)
  local proto, host_and_port, path = url:match("^(https?)://([^/]*)([^\r]*)")

  if proto == nil or host_and_port == nil then
    sock:close()
    return
  end

  local host, port = host_and_port:match("^([^:]*):?([0-9]*)$")
  local basename = path:match("/([^/]*)$")
  local dirname = path:sub(1, #path-#basename)


  local httpx_request = {
    url=url,
    http_proxy=os.getenv('http_proxy'),
    https_proxy=os.getenv('https_proxy'),
    method=req.method,
    header_list=req.hlist,
    payload=payload,
    ip="ipv4",
  }

  local uid = get_uid(url)
  local meta_http_request = {
    method = req.method,
    proto = proto,
    host = host,
    port = port,
    basename = basename,
    dirname = dirname,
    path = path,
    url = url,
    uid = uid,
    httpx_request = httpx_request,
    starttime = utils.updatenow(),
  }

  module_invoke('pre_httpx_request', meta_http_request)

  local doc
  if meta_http_request.ret and meta_http_request.ret.doc then
    doc = meta_http_request.ret.doc
  else
    local res, err = http_client:request(httpx_request)

    local body 
    if err then
      sock:close()
      return
    else
      body = res:body() or ''
    end

    doc = {res = res, body=body, url=url}

    res.header_list:unset('transfer-encoding')
    res.header_list:set('Content-Length', #body)
  end

  module_invoke('completed_httpx_request', {doc=doc, uid=uid, endtime=utils.updatenow()})

  local rope = {}
  local res = doc.res

  rope[#rope+1] = 'HTTP/' .. http_version.. ' '.. res.status ..' '.. res.text .. "\r\n"
  rope[#rope+1] = res.header_list:toString()
  rope[#rope+1] = doc.body

  sock:write(concat(rope))
end -- }%



function proxy_mt:parse_proxy_req()
  self.thread_request_nu = 0
  local sock = self.s
  local req, err

  while true do
    req, err = parse_header(sock, true)

    if err then
      sock:close()
      return
    end

    --print(utils.thisthread(), req.method, req.path, req.version)

    if req.method == 'CONNECT' then
      self:handle_connect(req, sock)
    else
      self:handle_method(req, sock)
    end
  end
end 

local g_port = 8888

local sock = io.tcp.listen4("*", g_port)
print('listening on :'..g_port)

while true do
  utils.yield()
  print(sock:autospawn(function (client)
    proxy(client)
  end))
end
