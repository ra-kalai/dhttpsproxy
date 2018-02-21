local hathaway = require 'lem.hathaway'
local io       = require 'lem.io'
local os       = require 'lem.os'
local utils    = require 'lem.utils'
local mlist = require 'ext.mlist'
local websocketHandler = require 'lem.websocket.handler'
local sqlite = require 'lem.sqlite3.queued'

package.path = package.path .. "ext/lua-MessagePack/src5.3/"
local mp = require 'MessagePack'
mp.set_string('binary')

local format = string.format
local concat = table.concat

local spawn = utils.spawn

local M = {}

local g_http_fifo = new_mlist()
local g_db
local g_insert_stm
local g_update_stm

local g_http_request_list = {}
local g_http_request_map = {}

local g_ws_res_list = new_mlist()


local g_terminal_proc_map = {}


function do_cmd(cmd, after)
  local process = io.spawnp(
    { '/bin/bash', '--norc', '-c', cmd}
    ,{
      {fds={0,1,2}, kind='pty', name='stdstream'}
    }
    ,{
      TERM='xterm',
      LANG='en_US.UTF-8',
      EDIT_FILE=file,
      PATH="./core/bin:" .. os.getenv('PATH')
    }
    ,{
      LEM_SPAWN_SETSID=1,
      LEM_SPAWN_SCTTY=1
    }
  )
  os.waitpid(process.pid, 0)
  return
end


function edit_file(file, after)
  local process = io.spawnp(
    { '/bin/bash', '-init-file', 'bash/editfile.rc' }
    ,{
      {fds={0,1,2}, kind='pty', name='stdstream'}
    }
    ,{
      TERM='xterm',
      LANG='en_US.UTF-8',
      EDIT_FILE=file
    }
    ,{
      LEM_SPAWN_SETSID=1,
      LEM_SPAWN_SCTTY=1
    }
  )

  g_terminal_proc_map[process.pid] = process

  io.tty.set_window_size(process.stream.stdstream, {col=80, row=20})

  if (after) then
    spawn(function ()
      os.waitpid(process.pid, 0)

      after()
    end)
  end

  return process
end

function broadcast_event(event)
  print('broadcast '.. event[1]..' ' .. g_ws_res_list:len())
  local c = 0
  g_ws_res_list:each(function (k, v)
    if v:sendBinary(mp.pack(event)) == true then
      c = c + 1
    end
  end)
  print('broadcast ' .. c)
end

function headerlist_to_string(httpx_request)
  local header = {}

  for i=1,#httpx_request do
    header[#header+1] = httpx_request[i][1]
    header[#header+1] = ':'
    header[#header+1] = httpx_request[i][2]
    header[#header+1] = '\r\n'
  end

  return table.concat(header)
end

function M.pre_httpx_request(last_ret, request)
  g_http_fifo:push_kv(request.uid, request)

  broadcast_event({'pre_httpx_request', request})

  local header = headerlist_to_string(request.httpx_request.header_list)

  spawn(function ()
    local raw = g_insert_stm:get()
    local v = { uid = { sqlite.bindkind.TEXT, request.uid },
                url = { sqlite.bindkind.TEXT, request.url },
                request_time_start = { sqlite.bindkind.NUMBER, request.starttime },
                request_header = { sqlite.bindkind.BLOB, header },
                request_payload = { sqlite.bindkind.BLOB, request.httpx_request.payload },
              }
    raw:bind(v)
    raw:step()
    raw:reset()
    g_insert_stm:put()
  end)
end

function table_slice(tbl, first, last, step)
  local sliced = {}
  step = step or 1

  for i = first or 1, last or #tbl, step  do
    sliced[#sliced+1] = tbl[i]
  end

  return sliced
end

function M.completed_httpx_request(last_ret, request)
  local doc = request.doc

  local answer = {
    endtime = request.endtime,
    body = doc.body,
    header_list = doc.res.header_list,
    status = doc.res.status,
    status_text = doc.res.text,
  }

  broadcast_event({'completed_httpx_request', {uid=request.uid, answer=answer}})

  local m = g_http_fifo:value(request.uid)
  if m == nil then
    return
  end

  m.answer = answer

  local max_request = 300
  if g_http_fifo:len() >  max_request then
    g_http_fifo:pop_front_t(math.ceil(max_request/2))
  end

  local header = headerlist_to_string(answer.header_list)

  spawn(function ()
    local raw = g_update_stm:get()
    local v = { uid = { sqlite.bindkind.TEXT, request.uid },
                body = { sqlite.bindkind.BLOB, answer.body },
                answer_header = { sqlite.bindkind.BLOB, header },
                request_time_end = {sqlite.bindkind.NUMBER, answer.endtime} ,
                status = { sqlite.bindkind.INT, answer.status },
              }

    raw:bind(v)
    raw:step()
    raw:reset()
    g_update_stm:put()
  end)
end

M.init = function ()
  local err
  g_db, err = sqlite.open('db/visit.db', sqlite.READWRITE + sqlite.CREATE)
  g_db:exec[[
DROP TABLE IF EXISTS node;
CREATE TABLE node (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  uid TEXT UNIQUE,
  url TEXT,
  body BLOB,
  answer_header BLOB,
  request_payload BLOB,
  request_header BLOB,
  request_time_start NUMBER,
  request_time_end NUMBER,
  status INT
);
  ]]

  g_update_stm = g_db:prepare('\z
UPDATE node SET \z
body = @body, \z
answer_header = @answer_header, \z
request_time_end = @request_time_end, \z
status = @status \z 
WHERE uid=@uid;')

  g_insert_stm = g_db:prepare('\z
INSERT INTO node(uid, url, request_time_start, request_header, request_payload) VALUES (@uid, @url, @request_time_start, @request_header, @request_payload);')
  
  local sock = io.tcp.listen4("*", 8000)
  hathaway.debug = function () end
  hathaway = hathaway.import()

  GET('/', function (req, res)
    res.status = 302
    res.headers['Location'] = '/dashboard'
  end)

  GET('/ext/msgpack-lite/dist/msgpack.min.js', function (req, res)
    res.headers['Content-Type'] = 'text/javascript'
    res.file = 'ext/msgpack-lite/dist/msgpack.min.js'
  end)

  GET('/favicon.ico', function (req, res)
    res.file = 'www/favicon.ico'
  end)
  GETM('/www/(.*)', function (req, res, f)
    if f:match('.js$') then
      res.headers['Content-Type'] = 'text/javascript'
    elseif f:match('.css') then
      res.headers['Content-Type'] = 'text/css'
    end
    res.file = 'www/' .. f
  end)
  GET('/dashboard', function (req, res)
    res.headers['Content-Type'] = 'text/html; charset=utf-8'
    res.file = 'core/www/dashboard.html'
  end)
  GET('/ws/request-log', function (req, res)
    local err, err_msg = websocketHandler.serverHandler(req, res)
    if (err ~= nil) then
      res.status = 400
      res.headers['Content-Type'] = 'text/plain'
      res:add('Websocket Failure!\n' .. err_msg .. "\n")
      return
    end


    local current_k = res.client:fileno() .. '+' .. utils.now()
    g_ws_res_list:push_kv(current_k, res)
    res.detach = true

    while true do
      err, payload = res:getFrame()
      if err ~= nil then
        local mlist = new_mlist()
        for k, v in pairs(g_ws_res_list:map()) do
          if k ~= current_k then
            mlist:push_kv(k, v)
          end
        end
        g_ws_res_list = mlist
        res:close()
        return
      end
    end
  end)

  function fixUTF8(s, replacement)
    local p, len, invalid = 1, #s, {}
    while p <= len do
      if     p == s:find("[%z\1-\127]", p) then p = p + 1
      elseif p == s:find("[\194-\223][\128-\191]", p) then p = p + 2
      elseif p == s:find("\224[\160-\191][\128-\191]", p)
          or p == s:find("[\225-\236][\128-\191][\128-\191]", p)
          or p == s:find("\237[\128-\159][\128-\191]", p)
          or p == s:find("[\238-\239][\128-\191][\128-\191]", p) then p = p + 3
      elseif p == s:find("\240[\144-\191][\128-\191][\128-\191]", p)
          or p == s:find("[\241-\243][\128-\191][\128-\191][\128-\191]", p)
          or p == s:find("\244[\128-\143][\128-\191][\128-\191]", p) then p = p + 4
      else
        s = s:sub(1, p-1)..replacement..s:sub(p+1)
        table.insert(invalid, p)
      end
    end
    return s, invalid
  end

  GETM('/ws/terminals/(.*)', function (req, res, pid)
    local err, err_msg = websocketHandler.serverHandler(req, res)
    if (err ~= nil) then
      res.status = 400
      res.headers['Content-Type'] = 'text/plain'
      res:add('Websocket Failure!\n' .. err_msg .. "\n")
      return
    end

    pid = tonumber(pid)

    if g_terminal_proc_map[pid] == nil then
      print('no pid', pid)
      return
    end
    local stdstream = g_terminal_proc_map[pid].stream.stdstream

    res.detach = true

    spawn(function ()
      while true do
        local payload, err = stdstream:read()
        if err then
          stdstream:close()
          res:close()
          return
        end
        res:sendText(fixUTF8(payload, '.'))
      end
    end)

    spawn(function ()
      while true do
        local err, payload = res:getFrame()
        if err ~= nil then
          res:close()
          stdstream:close()
          return
        end
        stdstream:write(payload)
      end
    end)
  end)

  POST('/ajax/resize-terminal', function (req, res)
    local body =req:body()
    local payload = mp.unpack(body)

    local process = g_terminal_proc_map[payload.pid]
    if process == nil then
      return
    end

    io.tty.set_window_size(process.stream.stdstream, {col=payload.size.cols, row=payload.size.rows})

    res:add(mp.pack({'ok'}))
  end)

  GET('/ajax/request-log', function (req, res)
    res.headers['Content-Type'] = 'text/javascript'
    res:add(mp.pack(g_http_fifo:list()))
  end)

  POST('/ajax/cmd', function (req, res)
    local body = req:body()
    local payload = mp.unpack(body);

    if payload.stdin == '' or payload.cmd == '' then
      res:add(mp.pack{'nok'})
      return
    end


    local fd = io.popen(payload.cmd, "3s")
    utils.spawn(function ()
      fd.stdin:write(payload.stdin)
      fd.stdin:close()
    end)

    local stdout = fd.stdout:read("*a")

    print(payload.cmd, #payload.stdin)
    print(#stdout)
    res:add(mp.pack{'ok', stdout})
  end)

  POST('/ajax/replay-req', function (req, res)
    res.headers['Content-Type'] = 'text/javascript'

    local body =req:body()
    local payload = mp.unpack(body)

    local filename = os.tmpname()

    do_cmd('req2curl.lua "' .. payload.uid .. '" > ' .. filename)

    print('edit filename', filename)
    local process = edit_file(filename, function () print('edit finish') end)
    print('edit pid', process.pid)

    local ret = mp.pack({'ok', process.pid})

    res:add(ret)
  end)

  utils.spawn(function ()
    Hathaway(sock)
  end)

  return {
    name="core",
  }
end

return M
