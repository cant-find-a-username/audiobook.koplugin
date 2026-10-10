--[[--
Kokoro server backend for the Audiobook plugin.

Sends each sentence to a Kokoro-FastAPI server
(POST /v1/audio/speech) and stores the returned WAV for the
existing playback and highlight path.

@module kokoro
--]]

local logger = require("logger")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local _ = require("audiobook_gettext")
local T = require("ffi/util").template

local _dir = debug.getinfo(1, "S").source:match("^@(.*/)[^/]*$") or "./"
local Utils = dofile(_dir .. "utils.lua")

local Kokoro = {}
Kokoro.__index = Kokoro

-- Voices offered in the menu. Any other Kokoro id can be typed in.
Kokoro.VOICES = {
    { id = "af_heart", label = "Heart (US female)" },
    { id = "af_bella", label = "Bella (US female)" },
    { id = "af_nicole", label = "Nicole (US female)" },
    { id = "af_sarah", label = "Sarah (US female)" },
    { id = "af_sky", label = "Sky (US female)" },
    { id = "am_michael", label = "Michael (US male)" },
    { id = "am_fenrir", label = "Fenrir (US male)" },
    { id = "bf_emma", label = "Emma (UK female)" },
    { id = "bm_george", label = "George (UK male)" },
    { id = "bm_fable", label = "Fable (UK male)" },
    { id = "ef_dora", label = "Dora (Spanish female)" },
    { id = "ff_siwis", label = "Siwis (French female)" },
    { id = "if_sara", label = "Sara (Italian female)" },
    { id = "jf_alpha", label = "Alpha (Japanese female)" },
    { id = "zf_xiaobei", label = "Xiaobei (Mandarin female)" },
}

function Kokoro:new(engine)
    return setmetatable({
        engine = engine,
        _gen = 0,
        _inflight_text = nil,
        _error_shown = false,
    }, self)
end

function Kokoro:serverUrl()
    local plugin = self.engine and self.engine.plugin
    local url = plugin and plugin:getSetting("kokoro_url", "") or ""
    url = tostring(url or "")
    url = url:gsub("%s+", "")
    url = url:gsub("[\"'`]", "")
    url = url:gsub("/+$", "")
    url = url:gsub("/v1/audio/speech$", "")
    url = url:gsub("/v1$", "")
    return url
end

function Kokoro:voice()
    local plugin = self.engine and self.engine.plugin
    local voice = plugin and plugin:getSetting("kokoro_voice", "af_heart") or "af_heart"
    if voice == nil or voice == "" then
        voice = "af_heart"
    end
    return voice
end

function Kokoro:speed()
    local rate = (self.engine and self.engine.rate) or 1.0
    if rate < 0.25 then rate = 0.25 end
    if rate > 4.0 then rate = 4.0 end
    return rate
end

--- Build the JSON body. Uses KOReader's json module when it is present.
function Kokoro:encodeBody(text)
    local payload = {
        model = "kokoro",
        input = text,
        voice = self:voice(),
        response_format = "wav",
        stream = false,
        speed = self:speed(),
    }
    local ok, JSON = pcall(require, "json")
    if ok and JSON and JSON.encode then
        local encoded_ok, encoded = pcall(JSON.encode, payload)
        if encoded_ok and type(encoded) == "string" then
            return encoded
        end
    end
    local function esc(s)
        return (tostring(s)
            :gsub("\\", "\\\\")
            :gsub('"', '\\"')
            :gsub("\r", "\\r")
            :gsub("\n", "\\n")
            :gsub("\t", "\\t"))
    end
    return string.format(
        '{"model":"kokoro","input":"%s","voice":"%s","response_format":"wav","stream":false,"speed":%.3f}',
        esc(text), esc(self:voice()), self:speed()
    )
end

function Kokoro:_endpoint()
    local base = self:serverUrl()
    if base == "" then
        return nil
    end
    if not base:match("^https?://") then
        base = "http://" .. base
    end
    return base .. "/v1/audio/speech"
end

function Kokoro:_isWav(path)
    local f = io.open(path, "rb")
    if not f then return false end
    local hdr = f:read(12)
    f:close()
    return hdr and hdr:sub(1, 4) == "RIFF" and hdr:sub(9, 12) == "WAVE"
end

local function le16(n)
    n = math.floor(n) % 65536
    return string.char(n % 256, math.floor(n / 256) % 256)
end

local function le32(n)
    n = math.floor(n)
    if n < 0 then n = 0 end
    return string.char(
        n % 256,
        math.floor(n / 256) % 256,
        math.floor(n / 65536) % 256,
        math.floor(n / 16777216) % 256
    )
end

local function u16(buf, i)
    local b1, b2 = buf:byte(i, i + 1)
    return b1 + b2 * 256
end

local function u32(buf, i)
    local b1, b2, b3, b4 = buf:byte(i, i + 3)
    return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

local function readSample(pcm, index)
    local off = index * 2 + 1
    local b1, b2 = pcm:byte(off, off + 1)
    local sample = b1 + b2 * 256
    if sample >= 32768 then sample = sample - 65536 end
    return sample
end

local function writeSamples(samples)
    local out = {}
    for i, sample in ipairs(samples) do
        if sample < 0 then sample = sample + 65536 end
        out[i] = string.char(sample % 256, math.floor(sample / 256) % 256)
    end
    return table.concat(out)
end

--- Pull PCM out of a Kokoro WAV and write a 44-byte header the Kindle
-- player can skip with `dd bs=44`. Kokoro-FastAPI files often carry extra
-- chunks or a 0xFFFFFFFF data size; those leftover bytes play as a click
-- at the start of every sentence. A short fade removes the vocoder click
-- that remains once the header is clean.
function Kokoro.normalizeFile(path)
    local f = io.open(path, "rb")
    if not f then return false end
    local blob = f:read("*a")
    f:close()
    if not blob or #blob < 44 then return false end
    if blob:sub(1, 4) ~= "RIFF" or blob:sub(9, 12) ~= "WAVE" then
        return false
    end

    local rate, channels, bits = 24000, 1, 16
    local pcm
    local pos = 13
    while pos + 7 <= #blob do
        local id = blob:sub(pos, pos + 3)
        local size = u32(blob, pos + 4)
        local payload = pos + 8
        if id == "fmt " and size >= 16 and payload + 15 <= #blob then
            channels = u16(blob, payload + 2)
            rate = u32(blob, payload + 4)
            bits = u16(blob, payload + 14)
        elseif id == "data" then
            local huge = size == 0 or size == 4294967295
            if huge or payload + size - 1 > #blob then
                pcm = blob:sub(payload)
            else
                pcm = blob:sub(payload, payload + size - 1)
            end
            break
        end
        if size == 4294967295 then break end
        pos = payload + size
        if size % 2 == 1 then pos = pos + 1 end
    end
    if not pcm or #pcm < 4 or channels ~= 1 or bits ~= 16 or rate <= 0 then
        return false
    end
    if #pcm % 2 == 1 then
        pcm = pcm:sub(1, #pcm - 1)
    end

    local nsamples = math.floor(#pcm / 2)
    local fade_in = math.min(math.floor(rate * 0.02), math.floor(nsamples / 4))
    local fade_out = math.min(math.floor(rate * 0.012), math.floor(nsamples / 4))
    if fade_in > 1 then
        local head = {}
        for i = 0, fade_in - 1 do
            head[i + 1] = math.floor(readSample(pcm, i) * (i / fade_in))
        end
        local tail = {}
        if fade_out > 1 then
            for i = 0, fade_out - 1 do
                local src = nsamples - fade_out + i
                tail[i + 1] = math.floor(readSample(pcm, src) * (1 - i / fade_out))
            end
        end
        local mid_end = (fade_out > 1) and ((nsamples - fade_out) * 2) or #pcm
        pcm = writeSamples(head) .. pcm:sub(fade_in * 2 + 1, mid_end) .. writeSamples(tail)
    end

    local data_size = #pcm
    local block = 2
    local header = "RIFF" .. le32(36 + data_size) .. "WAVE"
        .. "fmt " .. le32(16)
        .. le16(1) .. le16(1)
        .. le32(rate) .. le32(rate * block)
        .. le16(block) .. le16(16)
        .. "data" .. le32(data_size)
    local out = io.open(path, "wb")
    if not out then return false end
    out:write(header)
    out:write(pcm)
    out:close()
    return true
end

function Kokoro:_fail(callback, message, show_dialog)
    logger.warn("Kokoro:", message)
    if show_dialog and not self._error_shown then
        self._error_shown = true
        UIManager:show(InfoMessage:new{
            text = message,
            timeout = 6,
        })
    end
    if callback then callback(false, nil) end
end

function Kokoro:_succeed(text, audio_file, callback, for_prefetch)
    local engine = self.engine
    local saved_file = engine.current_audio_file
    local saved_timing = engine.timing_data
    engine:generateTimingEstimates(text)
    local timing = engine.timing_data
    if for_prefetch then
        engine.current_audio_file = saved_file
        engine.timing_data = saved_timing
        engine._prefetch_file = audio_file
        engine._prefetch_timing = timing
        engine._prefetch_text = text
        logger.dbg("Kokoro: prefetched", text:sub(1, 40))
    else
        engine.current_audio_file = audio_file
        logger.dbg("Kokoro: synthesized", text:sub(1, 40))
    end
    self._error_shown = false
    self._inflight_text = nil
    if callback then callback(true, timing) end
end

--- POST in the background with curl so playback highlights keep running.
function Kokoro:_startCurl(endpoint, body_file, audio_file, done_file, log_file)
    local cmd = string.format(
        '(curl -fsS --max-time 90 -X POST -H "Content-Type: application/json" --data-binary @"%s" -o "%s" "%s" > "%s" 2>&1; echo $? > "%s") &',
        body_file, audio_file, endpoint, log_file, done_file
    )
    os.execute(cmd)
end

function Kokoro:_pollCurl(text, audio_file, body_file, done_file, log_file, callback, for_prefetch, gen)
    local poll_count = 0
    local max_polls = 180
    local function poll()
        if gen ~= self._gen then
            os.remove(audio_file)
            os.remove(body_file)
            os.remove(done_file)
            os.remove(log_file)
            return
        end
        poll_count = poll_count + 1
        local mf = io.open(done_file, "r")
        if mf then
            local exit_code = (mf:read("*a") or ""):gsub("%s+", "")
            mf:close()
            os.remove(done_file)
            os.remove(body_file)
            if self:_isWav(audio_file) and self.normalizeFile(audio_file) then
                os.remove(log_file)
                self:_succeed(text, audio_file, callback, for_prefetch)
                return
            end
            local log_f = io.open(log_file, "r")
            local detail = log_f and (log_f:read("*a") or "") or ""
            if log_f then log_f:close() end
            os.remove(log_file)
            os.remove(audio_file)
            self._inflight_text = nil
            self:_fail(callback, T(
                _("Kokoro request failed (exit %1).\n\nCheck the server URL and that the reader is on Wi-Fi.\n%2"),
                exit_code ~= "" and exit_code or "?",
                detail:sub(1, 180)
            ), true)
            return
        end
        if poll_count < max_polls then
            UIManager:scheduleIn(0.5, poll)
        else
            os.remove(body_file)
            os.remove(done_file)
            os.remove(log_file)
            os.remove(audio_file)
            self._inflight_text = nil
            self:_fail(callback, _("Kokoro server timed out."), true)
        end
    end
    UIManager:scheduleIn(0.4, poll)
end

--- Blocking request used when the device has no curl binary.
function Kokoro:_fetchLua(endpoint, body, audio_file)
    local ok_http, http = pcall(require, "socket.http")
    local ok_ltn, ltn12 = pcall(require, "ltn12")
    if not ok_http or not ok_ltn then
        return false, "no HTTP client"
    end
    local out = io.open(audio_file, "wb")
    if not out then
        return false, "cannot write " .. audio_file
    end
    local ok_su, socketutil = pcall(require, "socketutil")
    if ok_su and socketutil and socketutil.set_timeout then
        socketutil:set_timeout(30, 30)
    end
    local req_ok, code_or_err = pcall(function()
        return require("socket").skip(1, http.request({
            url = endpoint,
            method = "POST",
            headers = {
                ["Content-Type"] = "application/json",
                ["Content-Length"] = tostring(#body),
                ["User-Agent"] = "audiobook.koplugin-kokoro",
            },
            source = ltn12.source.string(body),
            sink = ltn12.sink.file(out),
        }))
    end)
    if ok_su and socketutil and socketutil.reset_timeout then
        socketutil:reset_timeout()
    end
    if not req_ok then
        os.remove(audio_file)
        return false, tostring(code_or_err)
    end
    local code = code_or_err
    if type(code) ~= "number" or code < 200 or code >= 300
        or not self:_isWav(audio_file) or not self.normalizeFile(audio_file) then
        os.remove(audio_file)
        return false, "HTTP " .. tostring(code)
    end
    return true
end

--- Synthesize one sentence.
-- Returns nil when the request is still running (async). The callback
-- receives (success, timing).
function Kokoro:synthesize(text, audio_file, callback, for_prefetch)
    if not text or text == "" then
        self:_fail(callback, _("Nothing to read."), false)
        return nil
    end
    local endpoint = self:_endpoint()
    if not endpoint then
        self:_fail(callback, _(
            "Kokoro server URL is not set.\n\nTools → Audiobook Read-Along → Voice settings → Kokoro server."
        ), true)
        return nil
    end
    if #text > 4000 then
        text = text:sub(1, 4000)
    end

    self._gen = (self._gen or 0) + 1
    local gen = self._gen
    if for_prefetch then
        self._inflight_text = text
    end

    local body = self:encodeBody(text)
    if Utils.commandExists("curl") then
        local body_file = audio_file .. ".json"
        local bf = io.open(body_file, "w")
        if not bf then
            self:_fail(callback, _("Could not write the Kokoro request."), true)
            return nil
        end
        bf:write(body)
        bf:close()
        local done_file = audio_file .. ".done"
        local log_file = audio_file .. ".log"
        self:_startCurl(endpoint, body_file, audio_file, done_file, log_file)
        self:_pollCurl(text, audio_file, body_file, done_file, log_file, callback, for_prefetch, gen)
        return nil
    end

    local ok, err = self:_fetchLua(endpoint, body, audio_file)
    if not ok then
        self._inflight_text = nil
        self:_fail(callback, T(_("Kokoro request failed: %1"), tostring(err)), true)
        return nil
    end
    if gen ~= self._gen then
        os.remove(audio_file)
        return nil
    end
    self:_succeed(text, audio_file, callback, for_prefetch)
    return nil
end

--- Start the next sentence while the current one is playing.
function Kokoro:prefetch(text)
    local engine = self.engine
    if not text or text == "" then return false end
    if engine._prefetch_text == text and engine._prefetch_file then
        return true
    end
    if self._inflight_text == text then
        return true
    end
    engine:_cleanPrefetch()
    engine.file_counter = (engine.file_counter or 0) + 1
    local audio_file = "/tmp/audiobook_kokoro_pf_" .. os.time() .. "_"
        .. engine.file_counter .. ".wav"
    self:synthesize(text, audio_file, function() end, true)
    return true
end

function Kokoro:prefetchStatus(text)
    local engine = self.engine
    if engine._prefetch_file and engine._prefetch_text == text then
        return "ready"
    end
    if self._inflight_text == text then
        return "inflight"
    end
    return nil
end

function Kokoro:cancel()
    self._gen = (self._gen or 0) + 1
    self._inflight_text = nil
end

return Kokoro
