--[[
    SEEKER DSR 2X - ALPR plate lookups

    One scan pipeline, two CADs behind it. client/radar.lua reads plates off the vehicles
    around the patrol car and fires seeker_dsr2x:runAlpr; everything here turns that into a CAD
    query and pushes a normalised record back with seeker_dsr2x:alprResult (and, if configured,
    to Discord).

    Providers hand their record to `done` in the shape below. Nothing downstream — the client
    notification, /alprlog2x, the webhook — knows or cares which CAD answered, so a new provider
    is a new entry in `providers` and nothing else.

        owner              string   registered owner, may be nil
        vin                string   may be nil; only some CADs return one
        make/model/color/year       vehicle description parts, any may be nil
        stolen             boolean
        impounded          boolean
        registration       boolean  true when the reg is in good standing
        registrationStatus string   human-readable status ('Valid', 'Expired', ...)
        insurance          boolean
        insuranceStatus    string
        business           boolean  owner is a business rather than a person (optional)
        alertLevel         string   'alert' | 'caution' | 'none' (optional)
        flags              table    extra CAD flags beyond the four above, e.g. warrants,
                                    BOLOs, dangerous person (optional)

    done(nil)        — nothing came back; the client is told noRecord and stays quiet.
    done(nil, true)  — could not ask (rate limited, CAD down). Same silence, but the client
                       is told to requeue the plate after a short backoff instead of treating
                       the silence as an all-clear for the whole rescanDelay.
]]

local ALPR = Config.alpr or {}

local function sendResult(src, result)
    TriggerClientEvent('seeker_dsr2x:alprResult', src, result)
end

local function buildFlags(r)
    local insValid = r.insurance and (r.insuranceStatus or ''):lower() ~= 'invalid'
    local regStatus = r.registrationStatus or (r.registration and 'Valid' or 'Invalid')
    local regValid  = r.registration and (regStatus:lower() == 'valid' or regStatus:lower() == 'active')
    local flags = {}
    if r.stolen    then flags[#flags+1] = '🚨 STOLEN VEHICLE'     end
    if r.impounded then flags[#flags+1] = '🔒 IMPOUNDED VEHICLE'   end
    if not regValid then flags[#flags+1] = '⚠️ EXPIRED REGISTRATION' end
    if not insValid then flags[#flags+1] = '⚠️ NO INSURANCE'        end
    for _, extra in ipairs(r.flags or {}) do
        flags[#flags+1] = '⚠️ ' .. extra
    end
    return flags, (r.stolen or r.impounded or r.alertLevel == 'alert')
end

--- Built by appending rather than from a table constructor: a provider that returns no
--- vehicle description (ImperialCAD returns none at all) would otherwise leave nils in the
--- middle of the array and truncate the concat at the first hole.
local function vehicleDescription(result)
    local parts = {}
    if result.year  then parts[#parts+1] = tostring(result.year) end
    if result.color then parts[#parts+1] = result.color end
    if result.make  then parts[#parts+1] = result.make end
    if result.model then parts[#parts+1] = result.model end
    return table.concat(parts, ' ')
end

local function sendDiscordWebhook(result)
    local webhook = ALPR.discordWebhook
    if not webhook or webhook == '' then return end

    local flags, isSuspect = buildFlags(result)
    if #flags == 0 then return end

    local vehicle = vehicleDescription(result)
    local color = isSuspect and 15158332 or 16776960  -- red : yellow

    local fields = {
        { name = 'Plate',     value = result.plate     or 'Unknown', inline = true  },
        { name = 'Direction', value = result.direction or 'Unknown', inline = true  },
    }
    if vehicle ~= '' then
        fields[#fields+1] = { name = 'Vehicle', value = vehicle, inline = false }
    end
    if result.owner and result.owner ~= '' then
        local owner = result.business and (result.owner .. ' (Business)') or result.owner
        fields[#fields+1] = { name = 'Owner', value = owner, inline = true }
    end
    if result.vin and result.vin ~= '' then
        fields[#fields+1] = { name = 'VIN', value = result.vin, inline = true }
    end
    fields[#fields+1] = { name = 'Flags', value = table.concat(flags, '\n'), inline = false }

    local payload = json.encode({
        username = ALPR.discordWebhookName or 'ALPR System',
        embeds = {{
            title  = '🚔 ALPR Alert',
            color  = color,
            fields = fields,
            footer = { text = os.date('%Y-%m-%d %H:%M:%S') },
        }},
    })

    PerformHttpRequest(webhook, function() end, 'POST', payload, {
        ['Content-Type'] = 'application/json',
    })
end

-- ─────────────────────────────────────────────────────────────────────────────────────────
-- Lookup cache
--
-- CDE's own integration guidance is to hold plate data locally and re-pull it on a slow
-- timer rather than hitting the API for every read, and Imperial rate limits repeat requests
-- outright — so results are cached here, keyed by plate, and only re-queried once the entry
-- is older than cacheMinutes.
--
-- Misses are cached too, and that is where most of the saving comes from: the overwhelming
-- majority of plates the scanner sees are ambient traffic that will never be in a CAD, and
-- without a negative entry every one of them is a fresh HTTP request every rescan window.
--
-- Persisted so a server restart does not start from cold. KVP is used where the natives
-- exist (this is what CDE recommends); older FXServer builds have no server-side KVP, so
-- there is a resource-file fallback that behaves identically.
-- ─────────────────────────────────────────────────────────────────────────────────────────

local CACHE_KVP_KEY   = 'seeker_dsr2x_alpr_cache'
local CACHE_FILE      = 'data/alpr_cache.json'
local CACHE_SAVE_DEBOUNCE_MS = 30000

local cache = {}          -- [plate] = { at = unixTime, record = table|nil }  (nil record = known miss)
local cacheDirty = false
local cacheSaveQueued = false

local kvpAvailable = type(SetResourceKvp) == 'function' and type(GetResourceKvpString) == 'function'

local function cacheTtlSeconds()
    local minutes = tonumber(ALPR.cacheMinutes)
    if not minutes then minutes = 60 end
    return minutes * 60
end

local function readCacheBlob()
    if kvpAvailable then return GetResourceKvpString(CACHE_KVP_KEY) end
    return LoadResourceFile(GetCurrentResourceName(), CACHE_FILE)
end

local function writeCacheBlob(blob)
    if kvpAvailable then
        SetResourceKvp(CACHE_KVP_KEY, blob)
    else
        SaveResourceFile(GetCurrentResourceName(), CACHE_FILE, blob, -1)
    end
end

--- Drops everything past its TTL. Called on load and before every save, which is also what
--- keeps the store from growing without bound — every plate the scanner has ever seen would
--- otherwise stay in it forever.
local function pruneCache()
    local ttl = cacheTtlSeconds()
    if ttl <= 0 then
        cache = {}
        return
    end

    local now = os.time()
    for plate, entry in pairs(cache) do
        if type(entry) ~= 'table' or type(entry.at) ~= 'number' or (now - entry.at) > ttl then
            cache[plate] = nil
        end
    end
end

local function loadCache()
    if cacheTtlSeconds() <= 0 then return end

    local raw = readCacheBlob()
    if not raw or raw == '' then return end

    local ok, decoded = pcall(json.decode, raw)
    if not ok or type(decoded) ~= 'table' then return end

    cache = decoded
    pruneCache()
end

local function saveCache()
    pruneCache()
    cacheDirty = false
    writeCacheBlob(json.encode(cache))
end

--- Writes are batched: a busy scan can touch the cache several times a second and the store
--- is rewritten whole, so flushing on every change would be pointless churn. Losing up to
--- 30 seconds of cache on a hard crash costs nothing but a few repeat lookups.
local function markCacheDirty()
    cacheDirty = true
    if cacheSaveQueued then return end

    cacheSaveQueued = true
    SetTimeout(CACHE_SAVE_DEBOUNCE_MS, function()
        cacheSaveQueued = false
        if cacheDirty then saveCache() end
    end)
end

--- Returns `false` for a cached miss, a record table for a cached hit, and nil when the plate
--- needs looking up — a miss and an absent entry are different answers and the caller has to
--- be able to tell them apart.
local function cacheGet(plate)
    local ttl = cacheTtlSeconds()
    if ttl <= 0 then return nil end

    local entry = cache[plate]
    if type(entry) ~= 'table' or type(entry.at) ~= 'number' then return nil end

    if (os.time() - entry.at) > ttl then
        cache[plate] = nil
        return nil
    end

    return entry.record or false
end

local function cacheSet(plate, record)
    if cacheTtlSeconds() <= 0 then return end
    cache[plate] = { at = os.time(), record = record or nil }
    markCacheDirty()
end

exports('ClearAlprCache', function()
    cache = {}
    saveCache()
end)

RegisterCommand('alprcache2x', function(source)
    if source ~= 0 then return end  -- console only

    local count = 0
    for _ in pairs(cache) do count = count + 1 end
    print(('[seeker_dsr2x] ALPR cache: %d plate(s), TTL %d min, stored in %s.')
        :format(count, math.floor(cacheTtlSeconds() / 60), kvpAvailable and 'KVP' or CACHE_FILE))
end, true)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    if cacheDirty then saveCache() end
end)

CreateThread(loadCache)

-- ─────────────────────────────────────────────────────────────────────────────────────────
-- Providers
-- ─────────────────────────────────────────────────────────────────────────────────────────

local providers = {}

--- CDE CAD.
---
--- Credentials are read from the server.cfg convars CDE support already has communities set:
---
---     set CDE_CAD_API_URL      "https://your-cdecad-instance.com/api"
---     set CDE_CAD_API_KEY      "fvm_..."
---     set CDE_CAD_COMMUNITY_ID "your-discord-guild-id"
---
--- Keeping the key out of resource files is the point — a convar cannot be committed to a
--- repo by accident and does not travel with the resource folder.
local CDE_DEFAULT_URL = 'https://cdecad.com'
local warnedNoCdeKey = false

--- Both `https://cad.example.com` and `https://cad.example.com/api` are valid values for the
--- URL convar, and the docs use both forms, so the trailing `/api` is normalised off here and
--- added back per-request.
local function cdeBaseUrl()
    local url = GetConvar('CDE_CAD_API_URL', CDE_DEFAULT_URL)
    if url == '' then url = CDE_DEFAULT_URL end
    url = url:gsub('/+$', '')
    url = url:gsub('/api$', '')
    return url
end

local CDE_GOOD_STATUS = { valid = true, active = true, current = true }

--- The four conditions the radar has always alerted on have dedicated fields; everything else
--- CDE can flag (warrants, BOLOs, dangerous or missing person, community-defined flags) is
--- passed through as-is so a new CAD flag shows up in-game without a code change here.
local CDE_COVERED_FLAGS = {
    ['STOLEN'] = true, ['IMPOUNDED'] = true, ['REG EXPIRED'] = true, ['NO INSURANCE'] = true,
}

local function hasFlag(flags, name)
    for _, flag in ipairs(flags) do
        if tostring(flag):upper() == name then return true end
    end
    return false
end

function providers.cde(plate, done)
    local apiKey = GetConvar('CDE_CAD_API_KEY', '')
    if apiKey == '' then
        if not warnedNoCdeKey then
            warnedNoCdeKey = true
            print('[seeker_dsr2x] ALPR provider is "cde" but no API key is set — add `set CDE_CAD_API_KEY "fvm_..."` to server.cfg. Lookups are being skipped.')
        end
        return done(nil)
    end

    -- communityId is required across the CDE API. It is not documented as a parameter of this
    -- particular GET, so it goes on as a query string: the endpoint that needs it gets it, and
    -- one that does not simply ignores it.
    local url = ('%s/api/civilian/fivem-plate-lookup/%s'):format(cdeBaseUrl(), plate)
    local community = GetConvar('CDE_CAD_COMMUNITY_ID', '')
    if community ~= '' then
        url = url .. '?communityId=' .. community
    end

    PerformHttpRequest(url, function(code, body)
        -- 429 is the CAD asking us to back off, 5xx is the CAD being down, and a non-positive
        -- code is the request never having got there at all. None of those is an answer about
        -- this plate, so none of them is worth caching as one.
        code = tonumber(code) or 0
        if code <= 0 or code == 429 or code >= 500 then return done(nil, true) end
        if code ~= 200 or not body then return done(nil) end

        local ok, data = pcall(json.decode, body)
        if not ok or type(data) ~= 'table' then return done(nil) end
        if data.found == false or type(data.vehicle) ~= 'table' then return done(nil) end

        local v = data.vehicle
        local owner = type(data.owner) == 'table' and data.owner or {}
        local cadFlags = type(data.flags) == 'table' and data.flags or {}

        local regStatus = v.registrationStatus
        local insStatus = v.insuranceStatus

        local extra = {}
        for _, flag in ipairs(cadFlags) do
            if not CDE_COVERED_FLAGS[tostring(flag):upper()] then extra[#extra+1] = tostring(flag) end
        end

        done({
            make               = v.make,
            model              = v.model,
            color              = v.color,
            year               = v.year,
            owner              = owner.name,
            stolen             = v.stolen == true or hasFlag(cadFlags, 'STOLEN'),
            impounded          = v.impounded == true or hasFlag(cadFlags, 'IMPOUNDED'),
            registration       = CDE_GOOD_STATUS[tostring(regStatus or ''):lower()] == true
                                     and not hasFlag(cadFlags, 'REG EXPIRED'),
            registrationStatus = regStatus,
            insurance          = CDE_GOOD_STATUS[tostring(insStatus or ''):lower()] == true
                                     and not hasFlag(cadFlags, 'NO INSURANCE'),
            insuranceStatus    = insStatus,
            alertLevel         = data.alertLevel,
            flags              = #extra > 0 and extra or nil,
        })
    end, 'GET', '', { ['x-api-key'] = apiKey })
end

--[[ ImperialCAD — the CAD's own resource owns both the credentials and the transport, so the
     lookup is an export call rather than an HTTP request. CheckPlate wraps
     POST /api/1.1/wf/checkplate and hands the raw response body back as a JSON *string*, with
     the record itself nested one level down under `response`.

     Going through the export rather than calling the workflow ourselves is deliberate: every
     Imperial request has to carry a community ID, and for the POST workflows that value is
     injected by the CAD resource from `imperial_community_id` — there is no documented body
     field for it, so a hand-rolled request comes back NOT_RUN.

     The response body, per Imperial direct (their public docs are behind this shape):

         {
           "status": "success",
           "response": {
             "owner":           "John Doe",
             "plate_number":    "XYZ123",
             "stolen":          false,
             "insurance":       true,
             "insurance_status":"ACTIVE",        -- ACTIVE | EXPIRED | NIL
             "business":        false,
             "expStatus":       true,            -- true = registration NOT expired
             "owner_wanted":    false,
             "owner_dl_status": "ACTIVE",        -- ACTIVE | REVOKED | EXPIRED | NONE
             "vin":             "7IRN4MCS1RZFS315M"
           }
         }

     Two things to know about it. `expStatus` is a boolean and it reads the opposite way round
     to its name — true means the registration date is still in the future, i.e. good. And
     there is no impound field anywhere in the response, so impounds simply cannot surface
     through this provider; the flag is left unset rather than guessed at. ]]
local warnedMissingResource = false

--- ACTIVE is the only insurance status that means covered. EXPIRED is a lapsed policy and
--- NIL is no policy on file — different stories, same answer for the radar.
local IMPERIAL_INSURANCE_TEXT = { ACTIVE = 'Active', EXPIRED = 'Expired', NIL = 'None' }

--- Anything other than ACTIVE on the owner's licence is worth putting in front of the
--- operator, spelled out rather than passed through as a bare enum.
local IMPERIAL_DL_FLAG = {
    REVOKED = 'OWNER DL REVOKED',
    EXPIRED = 'OWNER DL EXPIRED',
    NONE    = 'OWNER HAS NO DL',
}

function providers.imperial(plate, done)
    local resource = (Config.imperialCad and Config.imperialCad.resourceName) or 'ImperialCAD'

    if GetResourceState(resource) ~= 'started' then
        if not warnedMissingResource then
            warnedMissingResource = true
            print(('[seeker_dsr2x] ALPR provider is "imperial" but resource "%s" is not started — plate lookups are being skipped. Check Config.imperialCad.resourceName and your server.cfg start order.'):format(resource))
        end
        return done(nil, true)
    end

    local ok, err = pcall(function()
        exports[resource]:CheckPlate({ plate = plate }, function(success, res)
            if not success then return done(nil, true) end

            local data = res
            if type(data) == 'string' then
                local parsed, value = pcall(json.decode, data)
                data = parsed and value or nil
            end
            if type(data) ~= 'table' then return done(nil) end

            -- A throttled request is not an all-clear: the plate was never actually asked
            -- about, so it goes back in the queue rather than sitting clean for rescanDelay.
            if data.status == 'RATE_LIMIT' or data.status == 'NOT_RUN' then return done(nil, true) end

            local r = data.response
            if data.status ~= 'success' or type(r) ~= 'table' then return done(nil) end

            --[[ expStatus is the registration, and only an explicit false is a bad one.
                 A missing field is not an expired tag - the plate is simply unknown on that
                 point, and reporting it as expired would put a red EXPIRED REGISTRATION in
                 front of an officer over a field the CAD never sent. ]]
            local regKnown = type(r.expStatus) == 'boolean'
            local regValid = r.expStatus ~= false

            local insStatus = tostring(r.insurance_status or ''):upper()
            -- Covered means the flag AND the status agree. An ACTIVE status with insurance
            -- false, or a true flag over an EXPIRED policy, is not cover.
            local insValid = r.insurance == true and (insStatus == '' or insStatus == 'ACTIVE')

            -- Everything Imperial reports about the owner rather than the car. buildFlags
            -- prints these verbatim, so a new one is a new line here and nothing else.
            local extra = {}
            if r.owner_wanted == true then extra[#extra+1] = 'OWNER WANTED' end
            local dlFlag = IMPERIAL_DL_FLAG[tostring(r.owner_dl_status or ''):upper()]
            if dlFlag then extra[#extra+1] = dlFlag end

            done({
                owner              = r.owner,
                vin                = r.vin,
                stolen             = r.stolen == true,
                -- No impound field in the response at all, so nothing to report either way.
                impounded          = false,
                registration       = regValid,
                registrationStatus = regKnown and (regValid and 'Valid' or 'Expired') or nil,
                insurance          = insValid,
                insuranceStatus    = IMPERIAL_INSURANCE_TEXT[insStatus],
                business           = r.business == true,
                -- A wanted owner is a stop-and-approach, so it colours the alert red the way
                -- a stolen plate does rather than sitting in the yellow advisory pile.
                alertLevel         = (r.stolen == true or r.owner_wanted == true) and 'alert' or nil,
                flags              = #extra > 0 and extra or nil,
                -- No make/model/colour/year on this endpoint; alerts show plate + flags only.
            })
        end)
    end)

    if not ok then
        print(('[seeker_dsr2x] ALPR: ImperialCAD CheckPlate export failed: %s'):format(err))
        done(nil, true)
    end
end

-- ─────────────────────────────────────────────────────────────────────────────────────────
-- Dispatch
-- ─────────────────────────────────────────────────────────────────────────────────────────

local inFlight   = {}  -- ['src|plate'] = true, so a plate is only ever being asked about once
local rateWindow = {}  -- [src] = { count, resetAt }
local lastForced = {}  -- [plate] = unix time of the last lock-driven lookup, server-wide

--- How long the client sits on a plate it could not get an answer for. Without a backoff the
--- next scan pass — 200 ms later by default — would ask again, and a CAD that is down or
--- throttling would be hammered by every plate in range at scan speed.
local RETRY_BACKOFF_SECONDS = 10

--- Rolling one-minute budget per player. The scan loop is automatic and this event is a net
--- event either way, so the cap is both politeness towards the CAD and the throttle on a
--- client spamming the event by hand. Returns the seconds left in the window when it denies.
--- Cache hits are free and never counted — the cap exists to limit outbound API calls.
local function withinRateLimit(src)
    local max = tonumber(ALPR.maxQueriesPerMinute) or 60
    if max <= 0 then return true end

    local now = os.time()
    local window = rateWindow[src]
    if not window or now >= window.resetAt then
        window = { count = 0, resetAt = now + 60 }
        rateWindow[src] = window
    end

    if window.count >= max then return false, window.resetAt - now end
    window.count = window.count + 1
    return true
end

AddEventHandler('playerDropped', function()
    rateWindow[source] = nil
end)

--- Copied on the way out so the plate and direction of one sighting never end up stored on
--- the shared cache entry the next sighting reads.
local function deliver(src, plate, direction, record)
    local out = {}
    for k, v in pairs(record) do out[k] = v end
    out.plate = plate
    out.direction = direction

    sendDiscordWebhook(out)
    sendResult(src, out)
end

--- `force` is set when the operator locked this plate by hand rather than the scanner picking
--- it up in passing. A deliberate lock is a decision point — the officer is about to act on
--- what comes back — so it skips the cache and asks the CAD, even if the plate was answered
--- for a minute ago. Background scanning keeps using the cache; that staleness is the price of
--- not hammering the CAD with ambient traffic, and it is only acceptable because this path
--- exists.
RegisterNetEvent('seeker_dsr2x:runAlpr', function(plate, direction, force)
    local src = source

    local provider = providers[ALPR.provider]
    if not provider then return end

    plate = type(plate) == 'string' and plate:gsub('%s+', ''):upper() or ''
    if plate == '' or plate == '--------' or #plate > 16 then return end
    if type(direction) ~= 'string' or #direction > 32 then direction = '' end
    force = force == true

    -- Enforced here rather than trusting the client's own cooldown: `force` arrives over a net
    -- event, so without this a spoofed one could bypass the cache on every scan pass. Demoting
    -- to a normal cached lookup rather than dropping the request keeps a legitimate second lock
    -- inside the window from going unanswered.
    if force then
        local cooldown = tonumber(ALPR.lockCooldown) or 0
        if cooldown > 0 then
            local last = lastForced[plate]
            local now = os.time()
            if last and (now - last) < cooldown then
                force = false
            else
                -- Sweep anything past its cooldown while we're here; entries are dead weight
                -- once expired and nothing else ever walks this table.
                for p, t in pairs(lastForced) do
                    if (now - t) >= cooldown then lastForced[p] = nil end
                end
                lastForced[plate] = now
            end
        end
    end

    -- A forced lookup still writes its answer to the cache on the way back, so a lock also
    -- refreshes what the scanner will see next.
    local cached = nil
    if not force then cached = cacheGet(plate) end
    if cached == false then
        sendResult(src, { plate = plate, direction = direction, noRecord = true })
        return
    elseif cached then
        deliver(src, plate, direction, cached)
        return
    end

    local key = src .. '|' .. plate
    if inFlight[key] then return end

    local allowed, retryAfter = withinRateLimit(src)
    if not allowed then
        sendResult(src, {
            plate = plate, direction = direction,
            noRecord = true, retry = true, retryAfter = retryAfter,
        })
        return
    end

    inFlight[key] = true

    local finished = false
    local function done(record, retry)
        if finished then return end
        finished = true
        inFlight[key] = nil

        if not record then
            -- A retry means the CAD never answered, so there is nothing to remember. A plain
            -- miss is an answer — "not in the CAD" — and caching it is what keeps ambient
            -- traffic from generating an HTTP request every rescan window.
            if not retry then cacheSet(plate, nil) end

            sendResult(src, {
                plate = plate, direction = direction, noRecord = true,
                retry      = retry or nil,
                retryAfter = retry and RETRY_BACKOFF_SECONDS or nil,
            })
            return
        end

        cacheSet(plate, record)
        deliver(src, plate, direction, record)
    end

    -- Backstop for a provider that never calls back at all: without this the plate would stay
    -- pinned in inFlight for the rest of the session and never be looked up again.
    SetTimeout(30000, function() done(nil, true) end)

    provider(plate, done)
end)
