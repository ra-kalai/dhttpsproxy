local format = string.format

function build_curl_cmdline(url, request_url, request_payload)
  local cmd = format("curl %q", url)

  local header = {}

  local content_len_comment = ''
  for k, v in request_url:gmatch("([^\r\n:]*):([^\r]*)") do
    if k:lower() == 'content-length' then
      content_len_comment = '\n #' .. format(' -H%q', k .. ': '..v) .. ' \\\n'
    else
      header[#header+1] = format(' -H%q', k .. ': '..v) .. ' \\\n'
    end
  end


  local header_concat = table.concat(header)
  local extra = ''
  if request_payload then
    extra = format(' --data-raw %q', request_payload)
  else
    header_concat = header_concat:gsub('\\\n$', '')
  end

  return cmd .. " \\\n" .. header_concat .. extra .. content_len_comment
end

return {build_curl_cmdline = build_curl_cmdline}
