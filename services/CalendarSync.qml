pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.modules.common
import qs.modules.common.functions
import qs.services
import "calendar_ics.js" as IcsParser

// External calendar sync via ICS/iCal URLs.
// Fetches calendars periodically, parses ICS to JSON, and caches results.
// Zero external deps — uses curl for fetching and JS for parsing.
Singleton {
    id: root

    readonly property bool enabled: Config.options?.calendar?.externalSync?.enable ?? false
    readonly property var sources: Config.options?.calendar?.externalSync?.sources ?? []
    readonly property int fetchIntervalMs: (Config.options?.calendar?.externalSync?.refreshMinutes ?? 15) * 60 * 1000

    // All external events, merged from every enabled source
    property var events: []

    // Querying used to walk all ~2.500 events for every day a calendar drew: the month grid alone asked 42 times.
    // Bucket them by local day once per change and the same query becomes a lookup. All-day events (birthdays) sit
    // under every day they cover; an absurdly long one is kept aside and checked the slow way.
    property var _eventsByDay: ({})
    property var _longAllDay: []
    readonly property int _indexDayLimit: 370

    // The birthdays Google syncs from Contacts, kept apart so the composer can offer a contact picker without
    // walking the whole cache on every keystroke. Filled by the same pass that builds the day index.
    property var contactBirthdays: []

    // The whole address book via the People API (contacts.readonly), so the birthday composer can find a person who
    // has no birthday in Contacts too. Independent of the ICS cache and kept in its own small file.
    property var googleContacts: []
    property bool googleContactsFetching: false
    property bool googleContactsScopeMissing: false
    property bool googlePeopleApiDisabled: false
    property string googleContactsError: ""
    readonly property string googleContactsCachePath: `${Directories.stateUserPath}/google_contacts_cache.json`

    function contactName(title: var): string {
        return String(title ?? "").replace(/\s*[-–—]\s*(cumpleaños|cumpleanos|birthday)\s*$/i, "").trim()
    }

    // The next time this month/day comes around, so a picked contact lands on their coming birthday, not a past one.
    function _upcomingBirthday(month: int, day: int): string {
        const now = new Date()
        const today = new Date(now.getFullYear(), now.getMonth(), now.getDate())
        let when = new Date(now.getFullYear(), month - 1, Math.max(1, day))
        if (when < today)
            when = new Date(now.getFullYear() + 1, month - 1, Math.max(1, day))
        return when.toISOString()
    }

    // A birthday Google already imports as a calendar event, used when People has the person but no birthday.
    function _importedBirthdayDate(name: string): string {
        const key = String(name ?? "").trim().toLowerCase()
        for (const event of root.contactBirthdays ?? []) {
            if (root.contactName(event?.title).toLowerCase() === key)
                return String(event?.startDate ?? "")
        }
        return ""
    }

    // Everyone the composer can offer: the People address book first, then any imported birthday People did not list.
    // Entries without a birthday are still returned, so choosing the person fills the name and the date stays yours.
    function findContacts(query: var): var {
        const needle = String(query ?? "").trim().toLowerCase()
        const out = []
        const seen = ({})
        for (const person of root.googleContacts ?? []) {
            const name = String(person?.name ?? "").trim()
            if (name.length === 0)
                continue
            const key = name.toLowerCase()
            if (seen[key])
                continue
            seen[key] = true
            let date = ""
            const b = person?.birthday
            if (b && b.month)
                date = root._upcomingBirthday(b.month, b.day || 1)
            if (date.length === 0)
                date = root._importedBirthdayDate(name)
            if (needle.length > 0 && key.indexOf(needle) < 0)
                continue
            out.push({ name: name, date: date, birthdayKnown: date.length > 0, photo: person?.photo ?? "" })
            if (out.length >= 8)
                return out
        }
        for (const event of root.contactBirthdays ?? []) {
            const name = root.contactName(event?.title)
            if (name.length === 0)
                continue
            const key = name.toLowerCase()
            if (seen[key])
                continue
            const haystack = (name + " " + String(event?.title ?? "")).toLowerCase()
            if (needle.length > 0 && haystack.indexOf(needle) < 0)
                continue
            seen[key] = true
            out.push({ name: name, date: String(event?.startDate ?? ""), birthdayKnown: true, photo: "" })
            if (out.length >= 8)
                break
        }
        return out
    }

    // Kept for the old picker/IPC; now it simply goes through the merged list.
    function findContactBirthdays(query: var): var {
        return root.findContacts(query).filter(entry => entry.birthdayKnown)
    }

    function loadGoogleContactsCache(): void {
        googleContactsCacheView.reload()
    }

    function saveGoogleContactsCache(): void {
        googleContactsCacheView.setText(JSON.stringify({
            contacts: root.googleContacts,
            savedAt: new Date().toISOString()
        }))
    }

    function _dayKey(date: var): string {
        const d = new Date(date)
        return d.getFullYear() + "-" + (d.getMonth() + 1) + "-" + d.getDate()
    }

    function _reindexEvents(): void {
        const byDay = ({})
        const longAllDay = []
        const contacts = []
        const put = (key, event) => {
            if (byDay[key] === undefined)
                byDay[key] = []
            byDay[key].push(event)
        }
        for (const event of root.events ?? []) {
            const start = new Date(event?.startDate ?? 0)
            if (isNaN(start.getTime()))
                continue
            // Google syncs Contacts' birthdays under this calendar id (addressbook#contacts@group.v.calendar.google.com).
            // A calendar event that merely says "Feliz cumpleaños" is not a person: keep only real contact names.
            if (String(event?.sourceId ?? "").indexOf("addressbook#contacts") >= 0) {
                const contact = root.contactName(event?.title)
                if (contact.length > 0 && !/\b(cumplea(ñ|n)os|birthday)\b/i.test(contact))
                    contacts.push(event)
            }
            if (event.allDay) {
                const end = new Date(event.endDate ?? event.startDate)
                const last = isNaN(end.getTime()) ? start : end
                const day = new Date(start.getFullYear(), start.getMonth(), start.getDate())
                const stop = new Date(last.getFullYear(), last.getMonth(), last.getDate())
                let count = 0
                for (; day <= stop && count < root._indexDayLimit; day.setDate(day.getDate() + 1), ++count)
                    put(root._dayKey(day), event)
                if (count >= root._indexDayLimit)
                    longAllDay.push(event)
            } else {
                put(root._dayKey(start), event)
            }
        }
        root._eventsByDay = byDay
        root._longAllDay = longAllDay
        contacts.sort((a, b) => root.contactName(a?.title).localeCompare(root.contactName(b?.title)))
        root.contactBirthdays = contacts
    }
    onEventsChanged: root._reindexEvents()
    // Per-source metadata (id, name, color, lastFetch, eventCount, error)
    property var sourceStatuses: ({})
    property bool fetching: false
    property bool ready: false

    signal eventsUpdated()
    signal fetchStarted()
    signal fetchFinished(bool success)
    signal sourceError(string sourceId, string error)

    // Cache file for persisting between sessions
    readonly property string cachePath: Directories.calendarSyncCachePath

    Component.onCompleted: {
        // The address book does not depend on ICS sync being on.
        root.loadGoogleContactsCache()
        if (!root.enabled) {
            root.ready = true
            return
        }
        loadCache()
    }

    // The Google token is independent of the ICS sources, so it is checked
    // even when external sync is off.
    Connections {
        target: Config
        ignoreUnknownSignals: true
        function onReadyChanged(): void {
            if (Config.ready && root.googleClientId.length > 0)
                Qt.callLater(() => root.checkGoogleToken())
        }
    }

    // Fetching waits for the cache, or a failed first fetch would save an empty calendar over it.
    property bool _cacheLoaded: false
    function _afterCacheLoad(): void {
        root._cacheLoaded = true
        root.ready = true
        // Clean on the way in too: a cache written before the pruning existed still carries its orphans.
        const pruned = root._pruneEvents(root.events)
        if (pruned.length !== (root.events ?? []).length) {
            root.events = pruned
            root.saveCache()
        }
        if (root.enabled && root.sources.length > 0) Qt.callLater(() => root.fetchAll())
    }

    // React to config changes — re-fetch when sources change
    property string _lastSourcesHash: ""
    onSourcesChanged: {
        const hash = JSON.stringify(root.sources)
        if (hash !== root._lastSourcesHash) {
            root._lastSourcesHash = hash
            if (root.enabled) {
                Qt.callLater(() => root.fetchAll())
            }
        }
    }

    onEnabledChanged: {
        if (root.enabled && !root._cacheLoaded) {
            loadCache()
            return
        }
        if (root.enabled && root.sources.length > 0) {
            Qt.callLater(() => root.fetchAll())
        }
    }

    // Periodic refresh
    Timer {
        id: fetchTimer
        running: root.enabled && Config.ready && root.sources.length > 0
        repeat: true
        interval: root.fetchIntervalMs
        onTriggered: root.fetchAll()
    }

    // Sequential source fetcher — fetches one source at a time to avoid
    // spawning many curl processes simultaneously
    property int _fetchIndex: -1
    property var _pendingSources: []
    property var _fetchedEvents: []

    Connections {
        target: Network
        function onOnlineChanged() {
            if (Network.online && root.enabled && root.sources.length > 0) root.fetchAll()
        }
    }

    function fetchAll(): void {
        if (root.fetching || !root._cacheLoaded || !Network.online) return
        const enabledSources = root.sources.filter(s => s.enabled && s.url && s.url.trim() !== "")
        if (enabledSources.length === 0) {
            root.events = []
            root.ready = true
            root.eventsUpdated()
            return
        }

        root.fetching = true
        root._pendingSources = enabledSources
        root._fetchedEvents = []
        root._fetchIndex = 0
        root.fetchStarted()
        _log("Fetching", enabledSources.length, "calendar sources")
        _fetchNext()
    }

    function _fetchNext(): void {
        if (root._fetchIndex >= root._pendingSources.length) {
            // All done
            root.events = root._fetchedEvents
            root.fetching = false
            root.ready = true
            root.eventsUpdated()
            root.fetchFinished(true)
            root.saveCache()
            _log("Fetch complete:", root.events.length, "events from", root._pendingSources.length, "sources")
            return
        }

        const source = root._pendingSources[root._fetchIndex]
        _log("Fetching source:", source.name, "from", source.url)
        _currentFetchSource = source
        fetchProc.command = ["curl", "-sL", "--max-time", "30",
            "--compressed", "-H", "Accept: text/calendar", source.url]
        fetchProc.running = true
    }

    property var _currentFetchSource: null

    Process {
        id: fetchProc
        running: false
        stdout: SplitParser {
            splitMarker: ""
            onRead: (data) => {
                // Accumulate raw ICS data
                fetchProc._rawData += data
            }
        }
        property string _rawData: ""

        onRunningChanged: {
            if (running) _rawData = ""
        }

        onExited: (code, status) => {
            const source = root._currentFetchSource
            if (!source) {
                root._fetchIndex++
                root._fetchNext()
                return
            }

            if (code !== 0 || fetchProc._rawData.trim() === "") {
                const errMsg = code !== 0 ? `curl exited with code ${code}` : "Empty response"
                _log("Error fetching", source.name, ":", errMsg)
                root._updateSourceStatus(source.id, { error: errMsg, lastFetch: new Date().toISOString() })
                root.sourceError(source.id, errMsg)
                root._keepPrevious(source.id)
            } else {
                try {
                    const parsed = IcsParser.parseICS(fetchProc._rawData, source.id, source.name, source.color)
                    root._fetchedEvents = root._fetchedEvents.concat(parsed)
                    root._updateSourceStatus(source.id, {
                        error: "",
                        lastFetch: new Date().toISOString(),
                        eventCount: parsed.length
                    })
                    _log("Parsed", parsed.length, "events from", source.name)
                } catch (e) {
                    const errMsg = `Parse error: ${e.message}`
                    _log("Parse error for", source.name, ":", e.message)
                    root._updateSourceStatus(source.id, { error: errMsg, lastFetch: new Date().toISOString() })
                    root.sourceError(source.id, errMsg)
                    root._keepPrevious(source.id)
                }
            }

            root._fetchIndex++
            root._fetchNext()
        }
    }

    // A failed fetch keeps what this source had, so a dropped connection never empties the calendar.
    function _keepPrevious(sourceId: string): void {
        root._fetchedEvents = root._fetchedEvents.concat(root.events.filter(e => e.sourceId === sourceId))
    }

    function _updateSourceStatus(sourceId: string, updates: var): void {
        const statuses = Object.assign({}, root.sourceStatuses)
        statuses[sourceId] = Object.assign(statuses[sourceId] || {}, updates)
        root.sourceStatuses = statuses
    }

    // Query: get external events for a specific date
    function getEventsForDate(date: var): var {
        const key = root._dayKey(date)
        const bucket = root._eventsByDay[key]
        const long = root._longAllDay
        if ((long?.length ?? 0) === 0)
            return bucket ?? []
        const target = new Date(date)
        target.setHours(0, 0, 0, 0)
        const targetTime = target.getTime()
        const extra = long.filter(event => {
            const start = new Date(event.startDate)
            start.setHours(0, 0, 0, 0)
            const end = event.endDate ? new Date(event.endDate) : new Date(start)
            end.setHours(0, 0, 0, 0)
            return targetTime >= start.getTime() && targetTime <= end.getTime()
        })
        return extra.length === 0 ? (bucket ?? []) : (bucket ?? []).concat(extra)
    }

    // Query: get all events in a date range (for upcoming view)
    function getUpcomingEvents(days: int): var {
        const now = new Date()
        const future = new Date()
        future.setDate(future.getDate() + (days || 7))

        return root.events.filter(event => {
            const evtDate = new Date(event.startDate)
            return evtDate >= now && evtDate <= future
        }).sort((a, b) => new Date(a.startDate) - new Date(b.startDate))
    }

    // Query: distinct source colors for events on a given date
    function getSourceColorsForDate(date: var): var {
        const dayEvents = getEventsForDate(date)
        const colors = []
        const seen = new Set()
        for (const evt of dayEvents) {
            if (!seen.has(evt.sourceId)) {
                seen.add(evt.sourceId)
                colors.push(evt.sourceColor)
            }
        }
        return colors
    }

    // Source management (called from Settings UI)
    function addSource(name: string, url: string, color: string): void {
        const newSource = {
            id: _generateId(),
            name: name,
            url: url,
            color: color || _nextColor(),
            enabled: true
        }
        const updated = [...(Config.options?.calendar?.externalSync?.sources ?? []), newSource]
        Config.setNestedValue("calendar.externalSync.sources", updated)
    }

    function removeSource(sourceId: string): void {
        const sources = Config.options?.calendar?.externalSync?.sources ?? []
        const at = sources.findIndex(s => s.id === sourceId)
        const gone = sources[at]
        const updated = sources.filter(s => s.id !== sourceId)
        Config.setNestedValue("calendar.externalSync.sources", updated)
        if (gone) Undo.offer(Translation.tr("Removed %1").arg(gone.name ?? gone.url ?? ""), () => {
            const back = [...(Config.options?.calendar?.externalSync?.sources ?? [])]
            if (back.some(s => s.id === gone.id)) return
            back.splice(Math.min(at, back.length), 0, gone)
            Config.setNestedValue("calendar.externalSync.sources", back)
            root.refreshSource(gone.id)
        })
        // Clean cached events from this source
        root.events = root.events.filter(e => e.sourceId !== sourceId)
        root.eventsUpdated()
    }

    function updateSource(sourceId: string, updates: var): void {
        const sources = [...(Config.options?.calendar?.externalSync?.sources ?? [])]
        const idx = sources.findIndex(s => s.id === sourceId)
        if (idx !== -1) {
            sources[idx] = Object.assign({}, sources[idx], updates)
            Config.setNestedValue("calendar.externalSync.sources", sources)
        }
    }

    function toggleSource(sourceId: string, enabled: bool): void {
        updateSource(sourceId, { enabled: enabled })
        if (!enabled) {
            root.events = root.events.filter(e => e.sourceId !== sourceId)
            root.eventsUpdated()
        } else {
            Qt.callLater(() => root.fetchAll())
        }
    }

    // Force refresh a single source or all
    function refreshSource(sourceId: string): void {
        Qt.callLater(() => root.fetchAll())
    }

    function forceRefreshAll(): void {
        Qt.callLater(() => root.fetchAll())
    }

    // Cache persistence
    // Drop the local cache and start over. The calendar settings page calls
    // this when the cached events look wrong (stale source, edited URL, or a
    // half-written file from an interrupted fetch).
    function clearCache(): void {
        root.events = []
        root.sourceStatuses = ({})
        // An empty file is treated as "no cache" by loadCache().
        cacheFileView.setText("")
        _log("Calendar cache cleared")
        if (root.enabled && root.sources.length > 0)
            Qt.callLater(() => root.fetchAll())
    }

    // Keep the cache tidy as it syncs: an event falls away a day after it ends, a feed that no longer exists takes its
    // events with it, and a hard cap keeps a runaway calendar from growing the file without end. Runs on every save,
    // so the file gets cleaner with each sync instead of only ever growing.
    readonly property int cacheEventLimit: 4000
    function _pruneEvents(list): var {
        // Before the config is read, `sources` is empty and every feed event would look like an orphan: prune later.
        if (!Config.ready) return list
        const cutoff = new Date()
        cutoff.setHours(0, 0, 0, 0)
        cutoff.setDate(cutoff.getDate() - 1)
        const alive = []
        for (const event of list ?? []) {
            const id = String(event?.sourceId ?? "")
            const fromGoogle = id.startsWith("google_")
            // Every event here comes from a feed or from Google. A sourceId with no feed behind it is an orphan from
            // a removed source: nothing can refresh it, so it only sat in the file.
            if (!fromGoogle && !(root.sources ?? []).some(source => String(source.id) === id))
                continue
            const ends = new Date(event?.endDate ?? event?.startDate ?? event?.dateTime ?? 0)
            if (!isNaN(ends.getTime()) && ends < cutoff)
                continue
            alive.push(event)
        }
        if (alive.length <= root.cacheEventLimit)
            return alive
        // Too many: keep the soonest, which are the ones anything draws.
        alive.sort((a, b) => new Date(a?.startDate ?? a?.dateTime ?? 0) - new Date(b?.startDate ?? b?.dateTime ?? 0))
        return alive.slice(0, root.cacheEventLimit)
    }

    function saveCache(): void {
        const pruned = root._pruneEvents(root.events)
        if (pruned.length !== (root.events ?? []).length)
            root.events = pruned
        const data = {
            events: root.events,
            sourceStatuses: root.sourceStatuses,
            savedAt: new Date().toISOString()
        }
        cacheFileView.setText(JSON.stringify(data))
    }

    function loadCache(): void {
        cacheFileView.reload()
    }

    Process {
        id: googleContactsProcess
        command: ["/usr/bin/python3", root.googleScript, "list-contacts", root.googleTokenPath]
        onExited: (exitCode) => {
            root.googleContactsFetching = false
            if (exitCode !== 0 && root.googleContactsError.length === 0)
                root.googleContactsError = "Could not read contacts"
        }
        stdout: StdioCollector { id: googleContactsOut }
    }

    // Parsing waits for exit: StdioCollector only has the whole JSON once the process is done.
    Connections {
        target: googleContactsProcess
        function onExited() {
            const raw = String(googleContactsOut.text ?? "").trim()
            if (raw.length === 0) return
            try {
                const data = JSON.parse(raw)
                if (data.error === "insufficient_scope") {
                    root.googleContactsScopeMissing = true
                    root.googleContactsError = "Allow contacts to search the whole address book"
                    return
                }
                if (data.error === "people_api_disabled") {
                    root.googlePeopleApiDisabled = true
                    root.googleContactsError = "People API is off in the Google Cloud project"
                    return
                }
                if (data.error) {
                    root.googleContactsError = String(data.error)
                    return
                }
                if (Array.isArray(data.contacts)) {
                    root.googleContacts = data.contacts
                    root.googleContactsError = ""
                    root.googlePeopleApiDisabled = false
                    root.saveGoogleContactsCache()
                }
            } catch (e) {
                root.googleContactsError = "Could not parse contacts"
            }
        }
    }

    FileView {
        id: googleContactsCacheView
        path: root.googleContactsCachePath
        watchChanges: false
        printErrors: false
        onLoaded: {
            const content = googleContactsCacheView.text()
            if (!content || content.trim() === "") return
            try {
                const data = JSON.parse(content)
                root.googleContacts = Array.isArray(data.contacts) ? data.contacts : []
            } catch (e) { /* a corrupt cache is rebuilt on the next sync */ }
        }
    }

    FileView {
        id: cacheFileView
        path: root.cachePath
        watchChanges: false
        printErrors: false
        onLoaded: {
            const content = cacheFileView.text()
            if (content && content.trim() !== "") {
                try {
                    const data = JSON.parse(content)
                    root.events = data.events || []
                    root.sourceStatuses = data.sourceStatuses || {}
                    _log("Loaded cache:", root.events.length, "events")
                } catch (e) {
                    _log("Cache parse error:", e.message)
                }
            }
            root._afterCacheLoad()
        }
        onLoadFailed: (error) => {
            if (error === FileViewError.FileNotFound) {
                _log("No cache file, starting fresh")
            }
            root._afterCacheLoad()
        }
    }

    // Preset colors for calendar sources
    readonly property var presetColors: [
        "#4285F4", // Google Blue
        "#EA4335", // Google Red
        "#34A853", // Google Green
        "#FBBC05", // Google Yellow
        "#FF6D01", // Orange
        "#46BDC6", // Teal
        "#7986CB", // Indigo
        "#E67C73", // Flamingo
        "#F6BF26", // Banana
        "#33B679", // Sage
        "#8E24AA", // Grape
        "#D81B60", // Lavender
    ]

    property int _colorIndex: 0

    function _nextColor(): string {
        const color = root.presetColors[root._colorIndex % root.presetColors.length]
        root._colorIndex++
        return color
    }

    function _generateId(): string {
        return "cal_" + Date.now().toString(36) + "_" + Math.random().toString(36).substring(2, 6)
    }

    // Handy from a terminal while testing the birthday composer: `inir ipc calendar contacts "mar"`.
    IpcHandler {
        target: "calendar"
        function contacts(query: string): string { return JSON.stringify(root.findContactBirthdays(query)) }
        function birthdayCount(): int { return root.contactBirthdays.length }
        function findContacts(query: string): string { return JSON.stringify(root.findContacts(query)) }
        function contactCount(): int { return root.googleContacts.length }
        function contactsScopeMissing(): bool { return root.googleContactsScopeMissing }
        function syncContacts(): string { root.fetchGoogleContacts(); return "started" }
        function authorize(): string {
            if (root.googleClientId.length === 0) return "no_client_id"
            root.startGoogleAuth()
            return "opened"
        }
    }

    function _log(...args): void {
        if (Quickshell.env("QS_DEBUG") === "1")
            console.log("[CalendarSync]", ...args)
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Google Calendar (OAuth device flow) — pull birthdays/contacts and
    //  push locally created events to the user's Google Calendar.
    // ═══════════════════════════════════════════════════════════════════

    readonly property string googleTokenPath: `${Directories.stateUserPath}/google_calendar_token.json`
    readonly property string googleScript: `${Directories.scriptsPath}/google_calendar.py`

    // OAuth configuration (from Settings, optional client secret)
    readonly property string googleClientId: Config.options?.calendar?.googleOAuth?.clientId ?? ""
    onGoogleClientIdChanged: { if (Config.ready && root.googleClientId.length > 0) Qt.callLater(() => root.checkGoogleToken()) }
    readonly property string googleClientSecret: Config.options?.calendar?.googleOAuth?.clientSecret ?? ""
    readonly property bool googlePushEnabled: Config.options?.calendar?.googleOAuth?.pushEnabled ?? false
    readonly property int googleImportDays: Config.options?.calendar?.googleOAuth?.importDays ?? 365

    // Runtime state
    property bool googleConnected: false
    property bool googleChecking: false
    property bool googleFetching: false
    property var googleAccount: ({})
    property int googleEventCount: 0
    property string googleError: ""

    // Device flow state
    property string googleVerificationUrl: ""
    property string googleUserCode: ""
    property var _googleDevice: null
    property bool _googlePolling: false
    property int _googlePollAttempts: 0


    // ── Token status ──────────────────────────────────────────────────
    function checkGoogleToken(): void {
        if (root.googleClientId.length === 0) { root.googleConnected = false; return }
        if (root.googleChecking) return
        root.googleChecking = true
        googleTokenInfoProcess.running = true
    }

    // ── Sign-in: device flow for a "TV and Limited Input" client, loopback for a Desktop-app one ──
    // A Desktop client carries a secret and only speaks the browser redirect; a TV client has no secret and is the
    // one the device code exists for. The secret decides, so the person never has to know which they made.
    function startGoogleAuth(): void {
        if (root.googleClientId.length === 0) return
        root.googleError = ""
        root.googleVerificationUrl = ""
        root.googleUserCode = ""
        root._googleDevice = null
        root._googlePolling = false
        if (root.googleClientSecret.length > 0) {
            root.googleLoopbackRunning = true
            googleLoopbackProcess._accum = ""
            googleLoopbackProcess.command = [
                "/usr/bin/python3", root.googleScript, "oauth-loopback",
                root.googleClientId, root.googleClientSecret, root.googleTokenPath
            ]
            googleLoopbackProcess.running = true
            return
        }
        googleOAuthRequestProcess.command = [
            "/usr/bin/python3", root.googleScript, "oauth-request", root.googleClientId
        ]
        googleOAuthRequestProcess.running = true
    }

    function cancelGoogleAuth(): void {
        root._googlePolling = false
        root._googleDevice = null
        googlePollTimer.stop()
        googleLoopbackProcess.running = false
        root.googleLoopbackRunning = false
        root.googleVerificationUrl = ""
        root.googleUserCode = ""
    }

    property bool googleLoopbackRunning: false

    // ── Pull Google calendars (birthdays/contacts + any) ─────────────
    function importGoogleCalendar(calendarId: string): void {
        if (!root.googleConnected) return
        // One process at a time: a second calendar waits for the first, or its command would overwrite a run in flight.
        if (googleImportProcess.running) {
            root._googleImportQueue.push(calendarId)
            return
        }
        root.googleFetching = true
        root.googleError = ""
        googleImportProcess.calendarId = calendarId
        googleImportProcess.command = [
            "/usr/bin/python3", root.googleScript, "import",
            root.googleTokenPath, calendarId, String(root.googleImportDays)
        ]
        googleImportProcess.running = true
    }

    // The birthday calendar and the primary one are what a fresh connection wants; the next queued run starts here.
    function importGoogleCalendars(): void {
        root.importGoogleCalendar("addressbook#contacts@group.v.calendar.google.com")
        root.importGoogleCalendar("primary")
    }

    property var _googleImportQueue: []

    // ── Pull the whole address book (People API) ─────────────────────
    function fetchGoogleContacts(): void {
        if (!root.googleConnected || root.googleContactsFetching)
            return
        if (root.googleContactsScopeMissing) {
            root.googleContactsError = "Contacts access was not granted"
            return
        }
        root.googleContactsFetching = true
        root.googleContactsError = ""
        googleContactsProcess.running = true
    }

    // ── Push one event to Google primary calendar ─────────────────────
    function pushGoogleEvent(payload: var): void {
        if (!root.googlePushEnabled || !root.googleConnected) return
        const eventKey = payload.startDate + "|" + payload.title
        if (root._pushedEvents[eventKey]) return

        let startIso = payload.startDate
        let endIso = payload.endDate || startIso
        if (payload.allDay) {
            startIso = startIso.slice(0, 10)
            endIso = (endIso || startIso).slice(0, 10)
        }
        googlePushProcess.rawArgs = [
            "/usr/bin/python3", root.googleScript, "create-event", root.googleTokenPath,
            JSON.stringify({
                title: payload.title,
                description: payload.description || "",
                location: payload.location || "",
                start: startIso,
                end: endIso,
                allDay: payload.allDay || false,
                recurrence: payload.recurrence || "none"
            })
        ]
        googlePushProcess.running = true
        root._pushedEvents[eventKey] = true
    }

    property var _pushedEvents: ({})
    property int _pushIndex: -1
    property var _pushQueue: []
    property bool _pushPending: false

    // Push locally created events to the user's Google Calendar.
    Connections {
        target: Events
        function onEventAdded(event): void {
            if (!root.googlePushEnabled || !root.googleConnected) return
            root.pushGoogleEvent({
                title: event.title ?? "",
                description: event.description ?? "",
                location: "",
                startDate: event.dateTime ?? new Date().toISOString(),
                endDate: event.dateTime ?? new Date().toISOString(),
                // A birthday is a whole day in Google and returns every year: push it that way, not as a one-off.
                allDay: event.category === "birthday",
                recurrence: event.recurrence ?? "none"
            })
        }
    }

    // ── Processes ─────────────────────────────────────────────────────
    Process {
        id: googleTokenInfoProcess
        property bool _ok: false
        command: ["/usr/bin/python3", root.googleScript, "token-info", root.googleTokenPath]
        onRunningChanged: if (running) _ok = false
        onExited: (exitCode) => {
            root.googleChecking = false
            root.googleConnected = exitCode === 0 && googleTokenInfoProcess._ok
            // A fresh install (or a cleared cache) has the token but no events yet: pull them now, not on the next
            // press of Sync. Otherwise the desktop widget stays empty although the account is connected.
            if (root.googleConnected && !(root.events ?? []).some(event => String(event.sourceId ?? "").startsWith("google_")))
                root.importGoogleCalendars()
        }
        stdout: SplitParser {
            onRead: data => {
                try {
                    const info = JSON.parse(data)
                    googleTokenInfoProcess._ok = !info.error && String(info.email ?? "").length > 0
                    root.googleAccount = info.error ? ({}) : info
                    root.googleContactsScopeMissing = !info.error && info.hasContacts === false
                    if (root.googleConnected && !root.googleContactsScopeMissing)
                        Qt.callLater(() => root.fetchGoogleContacts())
                } catch(e) { /* partial line */ }
            }
        }
    }

    Process {
        id: googleOAuthRequestProcess
        onExited: (exitCode) => {
            if (exitCode !== 0) {
                root.googleError = "Request failed"
                return
            }
        }
        stdout: SplitParser {
            onRead: data => {
                try {
                    const res = JSON.parse(data)
                    root.googleVerificationUrl = res.verification_url
                    root.googleUserCode = res.user_code
                    root._googleDevice = res
                    root._googlePolling = true
                    root._googlePollAttempts = 0
                    googlePollTimer.interval = Math.max(1000, (res.interval || 5) * 1000)
                    googlePollTimer.start()
                } catch(e) { /* partial line */ }
            }
        }
    }

    Process {
        id: googleLoopbackProcess
        property string _accum: ""
        onRunningChanged: if (running) _accum = ""
        stdout: SplitParser {
            splitMarker: ""
            onRead: data => {
                googleLoopbackProcess._accum += data
                let nl = googleLoopbackProcess._accum.indexOf("\n")
                while (nl >= 0) {
                    const line = googleLoopbackProcess._accum.slice(0, nl)
                    googleLoopbackProcess._accum = googleLoopbackProcess._accum.slice(nl + 1)
                    nl = googleLoopbackProcess._accum.indexOf("\n")
                    if (line.trim().length === 0) continue
                    try {
                        const msg = JSON.parse(line)
                        if (msg.auth_url) {
                            root.googleVerificationUrl = String(msg.auth_url)
                            Quickshell.execDetached(["xdg-open", String(msg.auth_url)])
                        } else if (msg.status === "ok") {
                            root.googleConnected = true
                            root.googleError = ""
                            root.checkGoogleToken()
                            root.importGoogleCalendars()
                        } else if (msg.status === "error") {
                            root.googleError = String(msg.error ?? "Sign-in failed")
                        }
                    } catch (e) { /* partial line */ }
                }
            }
        }
        stderr: SplitParser {
            onRead: data => {
                const text = String(data ?? "").trim()
                if (text.length > 0) root.googleError = text.slice(0, 300)
            }
        }
        onExited: (exitCode) => {
            root.googleLoopbackRunning = false
            root.googleVerificationUrl = ""
            if (exitCode !== 0 && root.googleError.length === 0)
                root.googleError = "Sign-in was cancelled"
        }
    }

    Process {
        id: googleOAuthPollProcess
        onExited: (exitCode) => {
            if (!root._googlePolling) return
            if (exitCode !== 0) { googlePollTimer.stop(); root._googlePolling = false; return }
        }
        stdout: SplitParser {
            onRead: data => {
                try {
                    const res = JSON.parse(data)
                    if (res.status === "ok") {
                        googlePollTimer.stop()
                        root._googlePolling = false
                        root._googleDevice = null
                        root.googleVerificationUrl = ""
                        root.googleUserCode = ""
                        // The token is on disk now: mark it before importing, or the import sees "not connected".
                        root.googleConnected = true
                        root.checkGoogleToken()
                        root.importGoogleCalendars()
                    } else if (res.status === "error") {
                        googlePollTimer.stop()
                        root._googlePolling = false
                        root.googleError = res.error || "Auth failed"
                    }
                } catch(e) { /* partial line */ }
            }
        }
    }

    Timer {
        id: googlePollTimer
        repeat: true
        onTriggered: {
            if (!root._googlePolling || !root._googleDevice) { stop(); return }
            root._googlePollAttempts++
            if (root._googlePollAttempts > 300) { stop(); root._googlePolling = false; return }
            googleOAuthPollProcess.command = [
                "/usr/bin/python3", root.googleScript, "oauth-poll",
                root.googleClientId, root.googleClientSecret || "n/a",
                root._googleDevice.device_code, root.googleTokenPath
            ]
            googleOAuthPollProcess.running = true
        }
    }

    Process {
        id: googleImportProcess
        property string calendarId: "primary"
        property string _accum: ""
        onRunningChanged: { if (running) _accum = "" }
        onExited: (exitCode) => {
            if (exitCode === 0) {
                try {
                    const res = JSON.parse(googleImportProcess._accum)
                    const events = res.events ?? []
                    _mergeGoogleEvents(events, googleImportProcess.calendarId)
                    root.googleEventCount = (root._googleEvents ?? []).length
                    root.eventsUpdated()
                } catch(e) {
                    _log("Google import parse error:", e.message)
                }
            }
            root.googleFetching = false
            if (root._googleImportQueue.length > 0) {
                const next = root._googleImportQueue[0]
                root._googleImportQueue = root._googleImportQueue.slice(1)
                Qt.callLater(() => root.importGoogleCalendar(next))
            }
        }
        stdout: SplitParser {
            splitMarker: ""
            onRead: (data) => {
                googleImportProcess._accum += data
            }
        }
    }

    property var _googleEvents: []

    function _mergeGoogleEvents(events: var, calendarId: string): void {
        const mapped = events.map(ev => {
            const allDay = !!ev.allDay
            const startDate = allDay ? new Date(ev.start + "T00:00:00") : new Date(ev.start)
            const endDate = allDay ? new Date((ev.end || ev.start) + "T00:00:00") : new Date(ev.end || ev.start)
            return {
                title: ev.title,
                description: ev.description || "",
                location: ev.location || "",
                startDate: isNaN(startDate.getTime()) ? new Date().toISOString() : startDate.toISOString(),
                endDate: isNaN(endDate.getTime()) ? new Date().toISOString() : endDate.toISOString(),
                allDay: allDay,
                recurrence: ev.recurrence || "none",
                uid: ev.uid || ev.eventId || "",
                sourceId: "google_" + calendarId,
                sourceName: root.googleAccount?.email || "Google",
                sourceColor: "#4285F4"
            }
        })
        // Keep both the Google-specific list (birthdays) and the merged view.
        if (calendarId.indexOf("addressbook") !== -1) {
            root._googleEvents = mapped
        }
        const other = (root.events ?? []).filter(e => e.sourceId !== "google_" + calendarId)
        root.events = other.concat(mapped)
        root.saveCache()
    }

    // Navigate the user to Google's devices / OAuth setup in the default browser.
    function openGoogleAuthLink(): void {
        Quickshell.execDetached(["xdg-open", "https://console.cloud.google.com/apis/credentials"])
    }

    function openGoogleDeviceUrl(): void {
        if (root.googleVerificationUrl.length > 0)
            Quickshell.execDetached(["xdg-open", root.googleVerificationUrl])
    }

    // Forget the account: drop the token on disk and everything it brought in. The client ID stays, so signing
    // back in is one press; the next sync fills the events again.
    function forgetGoogle(): void {
        root.cancelGoogleAuth()
        root.googleChecking = false
        root.googleConnected = false
        root.googleAccount = ({})
        root.googleError = ""
        root.googleEventCount = 0
        root._googleEvents = []
        root._googleImportQueue = []
        root.events = (root.events ?? []).filter(event => !String(event.sourceId ?? "").startsWith("google_"))
        root.saveCache()
        googleForgetProcess.running = true
    }

    Process {
        id: googleForgetProcess
        command: ["/usr/bin/rm", "-f", root.googleTokenPath]
    }

    Process {
        id: googlePushProcess
        onExited: (exitCode) => {
            if (exitCode !== 0)
                _log("Google push failed", exitCode)
        }
    }
}
