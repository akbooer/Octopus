module(..., package.seeall)

_G.ABOUT = {
  NAME          = "L_OctopusEnergy",
  VERSION       = "2025.02.03",
  DESCRIPTION   = "OctopusEnergy meter reader",
  AUTHOR        = "@akbooer",
  COPYRIGHT     = "(c) 2025-present AKBooer",
  DOCUMENTATION = "",
  DEBUG         = false,
  LICENSE       = [[
  Copyright 2025-present AK Booer

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.
]]
}

-- 2025.02.01  original version
-- 2025.01.02  add asynchronous HTTPS request


--[[
see:
  https://developer.octopus.energy/rest/guides/api-basics#api-basics
  https://www.guylipman.com/octopus/api_guide.html
    
  Note that the multiple variables are used, as defined in the EnergyMetering1 service
  
    HourKWH   1h:90d
    DayKWH    1h:7d,1d:10y  with sum aggregation
   
--]]

local json    = require "openLuup.json"
local API     = require "openLuup.api"              -- new openLuup API
local https   = require "ssl.https"
local ltn12   = require "ltn12"
local base64  = require "mime" .b64
local whisper = require "openLuup.whisper"

local http_async = require "openLuup.http_async"

local luup = _G.luup
--local ABOUT = _G.ABOUT

local _log = luup.log

local devNo

local async

local archive = "%s0.%d.EnergyMetering1.%sKWH.wsp"    -- historian archive filename format

-----


local base = "https://api.octopus.energy/v1/"

-- some end points
--local product = "products/?brand=OCTOPUS_ENERGY&is_green=true"
--local accounts = "accounts/%s/"

-- MPAN, Serial No., page_size, from, to (2020-03-29T01:29Z), 
local consumption = 
    "electricity-meter-points/%s/meters/%s/consumption/?page_size=%d&period_from=%s&period_to=%s&order_by=period&group_by=hour"



local function ISOdateTime (unixTime)       -- return ISO 8601 date/time: YYYY-MM-DDThh:mm:ssZ
  return os.date ("!%Y-%m-%dT%H:%M:%SZ", unixTime)
end

local function epochFromISO(ISO)
  local Y, m, d, H, M, S, Z = ISO: match "(%d+)%-(%d+)%-(%d+).(%d+):(%d+):(%d+)(.?)"
  return os.time {
      year = Y, month = m, day = d,
      hour = H, min = M, sec = S,
      isdst = Z ~= 'Z',
    }
end


local function update_history(info)
  if not info then return end
  
  local D = API[devNo]      -- this device

  local path = luup.attr_get "openLuup.Historian.Directory"
  if not path then return end
  
  local fullpath = archive: format(path, devNo, "%s")   -- don't yet know which archive!
  local winfo = whisper.info(fullpath: format "Hour")
  if not winfo then return end
 
 --[[
  count = 72,
  next = ?,
  previous = ?,
  results = {{
      consumption = 2.098,
      interval_end = "2025-01-31T13:00:00Z",
      interval_start = "2025-01-31T12:30:00Z"
    },{
      consumption = 2.301,
      interval_end = "2025-01-31T13:30:00Z",
      interval_start = "2025-01-31T13:00:00Z"
    },
    ...
  }
 --]]
 
  if not info.results then return end
  
  -- update device variable history
  local v, t = {}, {}
  local latest 
  for i, result in ipairs(info.results) do
    t[i] = epochFromISO(result.interval_start)
    v[i] = result.consumption
    latest = t[i]
  end

  _log("number of hourly readings received: " .. #t)
  
  if latest then
    t[#t+1] = latest + 60 * 60              -- add an hour
    v[#v+1] = 0 
    
    -- different files have different aggregations
    whisper.update_many (fullpath: format "Hour",  v, t)
    whisper.update_many (fullpath: format "Day",   v, t)
--    whisper.update_many (fullpath: format "Week",  v, t)
--    whisper.update_many (fullpath: format "Month", v, t)
    
    D.hadevice.LastUpdate = os.time()
  _log ("OctopusEnergy updated")
  end

end

local function request_callback (response) --, code, headers, statusline)
   update_history(json.decode(response))
end

local function https_request(url, body, key)
 local reply = {}
  local req = {
      url = url,
      sink = ltn12.sink.table(reply),
      method = body and "POST" or "GET",
--      redirect = true,
        headers = {Authorization = "Basic " .. base64(key)},
      source = ltn12.source.string(body),
    }

  if async then
    local ok, err = http_async.request (req, request_callback)
    _log ("async_request, status: " .. ok .. ", " .. (err or ''))
  else
    local _, status, headers, statusLine = https.request(req)
    return status == 200 and table.concat(reply) or nil, status, headers, statusLine
  end
end

------------------------------
--
--  REQUEST INFO FROM SERVER
--

local function request_readings (p)

  local D = API[p.D]      -- this device
  local A = D.attr 
  
  local now = os.time()
  local ago = now - 60 * 60 * 24 * 7    -- 7 days
--  _log "async poll of meter"
  _log "poll of meter"
  
  local request = consumption: format(A.mpan, A.meter, 200, ISOdateTime(ago), ISOdateTime(now))

  if async then
    https_request (base .. request, nil, A.key)  -- history will be updated in request_callback()
  else
    local result = https_request (base .. request, nil, A.key)  
    update_history(json.decode(result))
  end
  
end


local function poll (p)
  request_readings (p)

  -- rechedule 
  API.timers "delay" {
    callback = poll, 
    delay = 3 * 60 * 60,      -- three hours
    parameter = p, 
    name = "OctopusEnergy polling"}
end

------------------------------
--
--  INIT
--

function init (lul_device)
  devNo = tonumber (lul_device)
  local D = API[devNo]
  local A = D.attr
  
  
  do -- create essential attributes if they don't exist
    A.account = A.account or "Account #?"
    A.mpan = A.mpan or "MPAN?"
    A.meter = A.meter or "Meter serial #?"
    A.key = A.key or "API key?"
    
    A.async_polling = A.async_polling or ''
    async = A.async_polling: lower()
    async = async == '1' or async == "yes" or async == "true"
  end
  
  do -- ensure that the key variables exist
    D.energy.HourKWH  = 0
    D.energy.DayKWH   = 0
--    D.energy.WeekKWH  = 0
--    D.energy.MonthKWH = 0
  end
  
  do -- delay polling startup
    API.timers "delay" {
      callback = poll, 
      delay = 10,       -- ten seconds
      parameter = {D = devNo}, 
      name = "OctopusEnergy delayed startup"}
  end

  luup.set_failure (0)
  return true, "OK", "OctopusEnergy"
end

-----
