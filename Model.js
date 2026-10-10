.pragma library

// Pure helpers for the Tracearr widget: request building, response parsing
// and display formatting. No QML types in here so it stays easy to reason about.

var MARKER = "@@TRACEARR@@"
var MAX_RESPONSE_BYTES = 2 * 1024 * 1024

function clampInt(value, min, max, fallback) {
    var n = parseInt(value, 10)
    if (isNaN(n)) return fallback
    return Math.max(min, Math.min(max, n))
}

function num(value) {
    var n = Number(value)
    return isFinite(n) ? n : 0
}

function baseUrl(url) {
    var u = String(url || "").trim().replace(/\/+$/, "")
    if (u === "") return ""
    if (!/^https?:\/\//i.test(u)) u = "https://" + u
    return u
}

// The key is handed to curl on stdin (via an env var the shell prints with a
// builtin), so it never shows up in the process list.
function fetchCommand(url) {
    var base = baseUrl(url)
    var api = base + "/api/v1/public"
    var script = 'printf "Authorization: Bearer %s\\n" "$TRACEARR_KEY" | curl -sS --max-time 8'
        + ' --max-filesize ' + MAX_RESPONSE_BYTES
        + ' -H @- -w "\\n' + MARKER + '%{http_code}\\n"'
        + ' "$1/streams" "$1/stats/today"'
    return ["sh", "-c", script, "tracearr", api]
}

// POST /streams/{id}/terminate; `reason` is shown to the viewer by the media server.
function terminateCommand(url, streamId, reason) {
    var api = baseUrl(url) + "/api/v1/public"
    var script = 'printf "Authorization: Bearer %s\\nContent-Type: application/json\\n" "$TRACEARR_KEY"'
        + ' | curl -sS --max-time 10 -X POST -H @- --data-binary "$2"'
        + ' -w "\\n' + MARKER + '%{http_code}\\n"'
        + ' "$1/streams/$3/terminate"'
    var body = JSON.stringify(reason ? { reason: String(reason) } : {})
    return ["sh", "-c", script, "tracearr", api, body, encodeURIComponent(String(streamId))]
}

function parseTerminate(stdout, stderr) {
    var parts = String(stdout || "").split(MARKER)
    if (parts.length < 2) {
        var err = String(stderr || "").trim().split("\n").pop()
        return { ok: false, error: err !== "" ? err : "No response from Tracearr" }
    }
    var code = parseInt(parts[1], 10)
    var j = null
    try { j = JSON.parse(parts[0]) } catch (e) {}
    if (code >= 200 && code < 300 && (!j || j.success !== false)) return { ok: true }
    if (j && j.error && j.success === false) return { ok: false, error: String(j.error) }
    return { ok: false, error: errorFromBody(code, parts[0]) }
}

function errorFromBody(code, body) {
    try {
        var j = JSON.parse(body)
        if (j && j.message) return "HTTP " + code + ": " + j.message
    } catch (e) {}
    if (code === 401) return "Unauthorized: check the API key"
    if (code === 302 || code === 301) return "Redirected (behind a login proxy?)"
    return "HTTP " + code
}

// Output is "<streams body>\n@@TRACEARR@@<code>\n<today body>\n@@TRACEARR@@<code>\n".
function parseOutput(stdout, stderr) {
    var text = String(stdout || "")
    var parts = text.split(MARKER)
    if (parts.length < 3) {
        var err = String(stderr || "").trim().split("\n").pop()
        return { ok: false, error: err !== "" ? err : "No response from Tracearr" }
    }
    var streamsBody = parts[0]
    var streamsCode = parseInt(parts[1], 10)
    var todayBody = parts[1].replace(/^\d+\s*\n?/, "")
    var todayCode = parseInt(parts[2], 10)

    if (streamsCode !== 200) return { ok: false, error: errorFromBody(streamsCode, streamsBody) }

    var streams
    try { streams = JSON.parse(streamsBody) } catch (e) { return { ok: false, error: "Unreadable /streams response" } }

    var today = null
    if (todayCode === 200) {
        try { today = JSON.parse(todayBody) } catch (e) { today = null }
    }

    var list = streams && Array.isArray(streams.data) ? streams.data : []
    list.sort(function(a, b) {
        // Playing first, then most recently started.
        var pa = a.state === "playing" ? 0 : 1
        var pb = b.state === "playing" ? 0 : 1
        if (pa !== pb) return pa - pb
        return String(b.startedAt || "").localeCompare(String(a.startedAt || ""))
    })

    return {
        ok: true,
        streams: list,
        summary: streams.summary || null,
        today: today
    }
}

function pad2(n) { return (n < 10 ? "0" : "") + n }

function formatClock(ms) {
    var s = Math.max(0, Math.floor(num(ms) / 1000))
    var h = Math.floor(s / 3600)
    var m = Math.floor((s % 3600) / 60)
    var sec = s % 60
    return h > 0 ? h + ":" + pad2(m) + ":" + pad2(sec) : m + ":" + pad2(sec)
}

function formatBitrate(kbps) {
    var k = num(kbps)
    if (k <= 0) return ""
    return k >= 1000 ? (k / 1000).toFixed(1) + " Mbps" : Math.round(k) + " kbps"
}

function userName(s) {
    if (!s) return ""
    if (s.username) return String(s.username)
    if (s.user && s.user.username) return String(s.user.username)
    return "Unknown user"
}

function episodeCode(s) {
    if (s.seasonNumber === null || s.seasonNumber === undefined) return ""
    var code = "S" + pad2(num(s.seasonNumber))
    if (s.episodeNumber !== null && s.episodeNumber !== undefined) code += "E" + pad2(num(s.episodeNumber))
    return code
}

// Primary line of a stream card.
function primaryTitle(s) {
    if (!s) return ""
    if (s.mediaType === "episode" && s.showTitle) return String(s.showTitle)
    if (s.mediaType === "track" && s.artistName) return String(s.artistName)
    return String(s.mediaTitle || "Unknown")
}

// Secondary line of a stream card.
function secondaryTitle(s) {
    if (!s) return ""
    if (s.mediaType === "episode" && s.showTitle) {
        var code = episodeCode(s)
        return (code !== "" ? code + " · " : "") + String(s.mediaTitle || "")
    }
    if (s.mediaType === "track") {
        var bits = [String(s.mediaTitle || "")]
        if (s.albumName) bits.push(String(s.albumName))
        return bits.join(" · ")
    }
    return s.year ? String(s.year) : ""
}

function oneLineTitle(s) {
    var sec = secondaryTitle(s)
    if (s.mediaType === "movie" || s.mediaType === undefined) return primaryTitle(s) + (sec ? " (" + sec + ")" : "")
    return primaryTitle(s) + (sec ? " — " + sec : "")
}

// "transcode" | "audio" | "stream" | "play"
function decision(s) {
    var v = String(s.videoDecision || "").toLowerCase()
    var a = String(s.audioDecision || "").toLowerCase()
    if (v === "transcode") return "transcode"
    if (a === "transcode") return "audio"
    if (v === "copy" || a === "copy") return "stream"
    return "play"
}

function decisionLabel(s) {
    switch (decision(s)) {
    case "transcode": return "Transcode"
    case "audio": return "Audio transcode"
    case "stream": return "Direct stream"
    default: return "Direct play"
    }
}

function streamResolution(s) {
    var d = s.streamVideoDetails
    var h = d ? num(d.height) : 0
    var w = d ? num(d.width) : 0
    if (w >= 3200 || h >= 2000) return "4K"
    if (w >= 1800 || h >= 1000) return "1080p"
    if (w >= 1200 || h >= 700) return "720p"
    if (h > 0) return h + "p"
    return ""
}

// "4K HEVC → 1080p H.264 (HW)" for transcodes, "4K HEVC" otherwise.
function qualityLine(s) {
    if (s.mediaType === "track") {
        var codec = s.streamAudioCodecDisplay || s.sourceAudioCodecDisplay || ""
        return [codec, formatBitrate(s.bitrate)].filter(Boolean).join(" · ")
    }
    var src = [s.resolution, s.sourceVideoCodecDisplay].filter(Boolean).join(" ")
    if (decision(s) === "transcode") {
        var dst = [streamResolution(s), s.streamVideoCodecDisplay].filter(Boolean).join(" ")
        var hw = s.transcodeInfo && s.transcodeInfo.hwEncoding ? " (HW)" : ""
        src = src + (dst ? " → " + dst : "") + hw
    }
    var dr = s.sourceVideoDetails && s.sourceVideoDetails.dynamicRange
    if (dr && dr !== "SDR") src += " · " + dr
    return src
}

function deviceLine(s) {
    var parts = []
    if (s.player) parts.push(String(s.player))
    else if (s.device) parts.push(String(s.device))
    if (s.product && s.product !== s.player) parts.push(String(s.product))
    var br = formatBitrate(s.bitrate)
    if (br) parts.push(br)
    return parts.join(" · ")
}

// Interpolate progress between polls while a stream is playing.
function progressMs(s, fetchedAtMs, nowMs) {
    var p = num(s.progressMs)
    if (s.state === "playing") p += Math.max(0, nowMs - fetchedAtMs)
    var d = num(s.durationMs)
    return d > 0 ? Math.min(p, d) : p
}

function progressFraction(s, fetchedAtMs, nowMs) {
    var d = num(s.durationMs)
    if (d <= 0) return 0
    return Math.max(0, Math.min(1, progressMs(s, fetchedAtMs, nowMs) / d))
}

function absoluteUrl(base, path) {
    if (!path) return ""
    var p = String(path)
    if (/^https?:\/\//i.test(p)) return p
    return baseUrl(base) + (p.charAt(0) === "/" ? "" : "/") + p
}

function summaryText(summary) {
    if (!summary) return ""
    var parts = []
    var total = num(summary.total)
    parts.push(total + (total === 1 ? " stream" : " streams"))
    if (num(summary.transcodes) > 0) parts.push(num(summary.transcodes) + " transcoding")
    if (summary.totalBitrate && summary.totalBitrate !== "—" && total > 0) parts.push(String(summary.totalBitrate))
    return parts.join(" · ")
}

function tooltipLines(result, configured, errorText) {
    if (!configured) return "Tracearr: set url and apiKey in shell.json"
    if (errorText !== "") return "Tracearr: " + errorText
    if (!result) return "Tracearr: loading…"
    var lines = []
    if (result.streams.length === 0) lines.push("Nothing playing")
    for (var i = 0; i < result.streams.length; i++) {
        var s = result.streams[i]
        lines.push((s.state === "paused" ? "󰏤 " : "󰐊 ") + userName(s) + ": " + oneLineTitle(s))
    }
    if (result.summary && result.streams.length > 0) lines.push(summaryText(result.summary))
    return lines.join("\n")
}
