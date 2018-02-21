local mlist_mt = {}

mlist_mt.__index = function (t, k)
	local v
	v = mlist_mt[k]
	if v then
		return v
	end

  return t:value(k)
end

mlist_mt.value = function (t, k)
	local v
	v = t.m[k]
	if v then
		return v[2]
	end
end

mlist_mt.__newindex = function (t, k, v)
	t:push_kv(k, v)
end

mlist_mt.prepend = function (t, v)
	t:prepend_kv(nil, v)
end

mlist_mt.prepend_kv = function (t, k, v)
  local pair = {k, v}
	t.start = t.start - 1
	t.l[t.start] = pair
  if k then
	  t.m[k] = pair
  end
end

mlist_mt.push = function (t, v)
	t:push_kv(nil, v)
end

mlist_mt.insert = function (t, k, v)
  t:push_kv(k, v)
end

mlist_mt.push_kv = function (t, k, v)
  local pair = {k, v}
	t.l[t.last] = pair
  if k then
	  t.m[k] = pair
  end
	t.last = t.last + 1
end

local table_unpack = rawget(_G, 'unpack') or table.unpack

mlist_mt.tail_t = function (t, count)
	count = count or 1
	local ret = {}
	local i
	local start = t.last - count 

	if start < t.start then
		start = t.start 
	end
	local last = t.last 
	local kv

	i = start
	repeat
		kv = t.l[i]
		ret[#ret+1] = kv[2]
		i = i+1
	until i == last

	return ret
end

mlist_mt.tail = function (t, count)
	return table_unpack(t:tail_t(count))
end

mlist_mt.list = function (t)
	local ret = {}
	local i
	local start = t.start
	local last = t.last -1
  local kv

  for i = start, last do
		kv = t.l[i]
    ret[#ret+1] = kv[2]
  end

  return ret
end

mlist_mt.map = function (t)
  local ret = {}
  for k, v in pairs(t.m) do
    ret[k] = v[2]
  end
  return ret
end

mlist_mt.pop_tail_t = function (t, count)
	count = count or 1
	local ret = {}
	local i
	local start = t.last - count 

	if start < t.start then
		start = t.start 
	end
	local last = t.last 
	local kv

	i = start
	repeat
		kv = t.l[i]
		ret[#ret+1] = kv[2]
    if kv[1] then
		  t.m[kv[1]] = nil 
    end
		t.l[i] = nil
		i = i+1
	until i == last

	t.last = start

	return ret
end

mlist_mt.pop_tail = function (t, count)
	return table_unpack(t:pop_tail_t(count))
end

mlist_mt.pop_front_t = function (t, count)
	count = count or 1
	local ret = {}
	local i
	local last = t.start + count - 1

	if last > t.last-1 then
		last = t.last-1 
	end

	local kv
	for i = t.start, last, 1 do
		kv = t.l[i]
		ret[#ret+1] = kv[2]
    if kv[1] then
		  t.m[kv[1]] = nil 
    end
		t.l[i] = nil
	end

	t.start = last + 1

	return ret
end

mlist_mt.pop_front = function (t, count)
	return table_unpack(t:pop_front_t(count))
end

mlist_mt.front_t = function (t, count)
	count = count or 1
	local ret = {}
	local i
	local last = t.start + count - 1


	if last > t.last-1 then
		last = t.last-1 
	end
	local kv

	for i = t.start, last, 1 do
		kv = t.l[i]
		ret[#ret+1] = kv[2]
	end

	return ret
end

mlist_mt.front = function (t, count)
	return table_unpack(t:front(count))
end

mlist_mt.len = function (t)
	return t.last - t.start
end

mlist_mt.at = function (t, idx)
	local kv = t.l[idx-1 + t.start]
	if kv then
		return kv[2]
	end
end

mlist_mt.kat = function (t, idx)
	local kv = t.l[idx-1 + t.start]
	if kv then
		return kv[1]
	end
end

mlist_mt.each = function (t, fun)
	local i
	local kv
	local r 

  local last = t.last - 1
	local vindex = 1
	for i = t.start, last do
		kv = t.l[i]
		r = fun(kv[1], kv[2], vindex)
		if r == false then
			break
		end
		vindex = vindex + 1
	end
end

function new_mlist()
	return setmetatable({last=0, start=0, m={}, l={}}, mlist_mt)
end

return {new_mlist=new_mlist}
