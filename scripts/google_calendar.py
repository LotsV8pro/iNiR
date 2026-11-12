#!/usr/bin/env python3
"""Google Calendar OAuth (device flow) + sync helpers for the shell.

Commands (all JSON on stdout, errors JSON on stderr):
  oauth-request <client_id>                    -> {verification_url,user_code,device_code,interval,expires_in,client_id}
  oauth-poll <client_id> <client_secret> <device_code> <token_path>
                                               -> {status:"ok",access_token,...} token also saved to token_path
                                               -> {status:"pending"} | {status:"error",error}
  token-info <token_path>                      -> {email,expiry} or error
  list-calendars <token_path>                  -> {calendars:[{id,summary,accessRole}]}
  import <token_path> <calendar_id> <days>     -> {events:[...]} events resolved single, allday-aware
  create-event <token_path> <json>             -> {event:{id,htmlLink}}
  list-contacts <token_path>                   -> {contacts:[{name,birthday,emails,photo}]}
  refresh <token_path>                         -> writes new access token, {ok:true}
"""
import base64
import hashlib
import json
import os
import secrets
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

SCOPES = ("https://www.googleapis.com/auth/calendar "
          "https://www.googleapis.com/auth/contacts.readonly")
CALENDAR_API = "https://www.googleapis.com/calendar/v3"
PEOPLE_API = "https://people.googleapis.com/v1"


def read_token(path):
    if not os.path.exists(path):
        return None
    with open(path) as f:
        return json.load(f)


def write_token(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, path)


def http_json(url, data=None, headers=None, method=None, timeout=30):
    body = None
    hdrs = dict(headers or {})
    if data is not None:
        if isinstance(data, dict):
            body = urllib.parse.urlencode(data).encode()
            hdrs.setdefault("Content-Type", "application/x-www-form-urlencoded")
        else:
            body = data
            hdrs.setdefault("Content-Type", "application/json")
    req = urllib.request.Request(url, data=body, headers=hdrs, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
            return json.loads(raw) if raw.strip() else {}
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            info = json.loads(raw) if raw else {}
        except Exception:
            info = {"error": raw.decode(errors="replace")[:500]}
        info["_http_code"] = e.code
        raise GoogleApiError(json.dumps(info))


class GoogleApiError(Exception):
    pass


def api_url(base, path, token_path, **kwargs):
    tok = read_token(token_path)
    if not tok or not tok.get("access_token"):
        raise GoogleApiError(json.dumps({"error": "no_token"}))
    hdrs = {"Authorization": "Bearer " + tok["access_token"]}
    try:
        return http_json(base + path, headers=hdrs, **kwargs)
    except GoogleApiError as e:
        info = json.loads(str(e))
        # A 403 can mean an expired token or a missing OAuth scope. Refresh once; a scope problem stays 403.
        if info.get("_http_code") in (401, 403) and tok.get("refresh_token"):
            refresh_token(token_path)
            tok = read_token(token_path)
            hdrs = {"Authorization": "Bearer " + tok["access_token"]}
            return http_json(base + path, headers=hdrs, **kwargs)
        raise


def api(path, token_path, **kwargs):
    return api_url(CALENDAR_API, path, token_path, **kwargs)


def refresh_token(token_path):
    tok = read_token(token_path)
    if not tok or not tok.get("refresh_token"):
        raise GoogleApiError(json.dumps({"error": "no_refresh_token"}))
    res = http_json("https://oauth2.googleapis.com/token", data={
        "client_id": tok["client_id"],
        "client_secret": tok.get("client_secret", ""),
        "refresh_token": tok["refresh_token"],
        "grant_type": "refresh_token",
    })
    tok["access_token"] = res["access_token"]
    if "expires_in" in res:
        tok["expires_in"] = res["expires_in"]
        tok["expiry"] = time.time() + res["expires_in"]
    write_token(token_path, tok)
    return tok


# ── Device flow ──────────────────────────────────────────────────────────────

def oauth_request(client_id):
    res = http_json("https://oauth2.googleapis.com/device/code", data={
        "client_id": client_id, "scope": SCOPES,
    })
    res["client_id"] = client_id
    print(json.dumps(res))


def oauth_poll(client_id, client_secret, device_code, token_path):
    try:
        res = http_json("https://oauth2.googleapis.com/token", data={
            "client_id": client_id,
            "client_secret": client_secret or None,
            "device_code": device_code,
            "grant_type": "urn:ietf:params:oauth:grant_type:device_code",
        })
        tok = {
            "client_id": client_id,
            "client_secret": client_secret or "",
            "access_token": res["access_token"],
            "refresh_token": res.get("refresh_token", ""),
            "expires_in": res.get("expires_in", 3600),
            "expiry": time.time() + res.get("expires_in", 3600),
            # What Google actually granted: a re-consent is needed when contacts were never allowed.
            "scope": res.get("scope", SCOPES),
        }
        write_token(token_path, tok)
        res["status"] = "ok"
        print(json.dumps(res))
    except GoogleApiError as e:
        info = json.loads(str(e))
        if info.get("error") in ("authorization_pending", "slow_down"):
            print(json.dumps({"status": "pending"}))
        else:
            print(json.dumps({"status": "error", "error": info.get("error", "unknown")}))


# ── Loopback flow (Desktop-app clients: no device code, a local redirect instead) ──

LOOPBACK_HTML = """<!doctype html><meta charset="utf-8"><title>iNiR</title>
<body style="font-family:system-ui;background:#111;color:#eee;display:grid;place-items:center;height:100vh;margin:0">
<div style="text-align:center"><h2>Listo</h2><p>Ya puedes cerrar esta pestaña y volver a iNiR.</p></div>""".encode("utf-8")


def oauth_loopback(client_id, client_secret, token_path, timeout=300):
    verifier = base64.urlsafe_b64encode(secrets.token_bytes(64)).decode().rstrip("=")
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
    state = secrets.token_urlsafe(16)
    result = {"code": None, "error": None, "state": None}
    answered = threading.Event()

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            query = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            if "code" in query:
                result["code"] = query["code"][0]
                result["state"] = (query.get("state") or [""])[0]
            elif "error" in query:
                result["error"] = query["error"][0]
            else:
                # A stray request (favicon, a second tab) must not end the wait.
                self.send_response(204)
                self.end_headers()
                return
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(LOOPBACK_HTML)
            answered.set()

        def log_message(self, *args):
            pass

    server = HTTPServer(("127.0.0.1", 0), Handler)
    server.timeout = 1
    port = server.server_address[1]
    redirect_uri = f"http://127.0.0.1:{port}"
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()

    auth_url = "https://accounts.google.com/o/oauth2/v2/auth?" + urllib.parse.urlencode({
        "client_id": client_id,
        "redirect_uri": redirect_uri,
        "response_type": "code",
        "scope": SCOPES,
        "access_type": "offline",
        "prompt": "consent",
        "code_challenge": challenge,
        "code_challenge_method": "S256",
        "state": state,
    })
    print(json.dumps({"auth_url": auth_url, "redirect_uri": redirect_uri, "status": "waiting"}), flush=True)

    try:
        if not answered.wait(timeout):
            print(json.dumps({"status": "error", "error": "timed out waiting for the browser"}))
            return
    finally:
        server.shutdown()
        server.server_close()

    if result["error"]:
        print(json.dumps({"status": "error", "error": result["error"]}))
        return
    if result["state"] != state:
        print(json.dumps({"status": "error", "error": "state mismatch"}))
        return

    try:
        res = http_json("https://oauth2.googleapis.com/token", data={
            "client_id": client_id,
            "client_secret": client_secret,
            "code": result["code"],
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirect_uri,
        })
    except GoogleApiError as e:
        print(json.dumps({"status": "error", "error": str(e)}))
        return

    tok = {
        "client_id": client_id,
        "client_secret": client_secret or "",
        "access_token": res.get("access_token", ""),
        "refresh_token": res.get("refresh_token", ""),
        "expires_in": res.get("expires_in", 3600),
        "expiry": time.time() + res.get("expires_in", 3600),
        "scope": res.get("scope", SCOPES),
    }
    if not tok["access_token"]:
        print(json.dumps({"status": "error", "error": "no access token returned"}))
        return
    write_token(token_path, tok)
    print(json.dumps({"status": "ok"}), flush=True)


# ── Introspection ────────────────────────────────────────────────────────────

def cmd_token_info(token_path):
    tok = read_token(token_path)
    if not tok or not tok.get("access_token"):
        print(json.dumps({"error": "no_token", "path": token_path}))
        return
    # The primary calendar's id is the account's address, and it needs only the calendar scope this token has.
    # Asking the userinfo endpoint would fail: iNiR never asked for the email scope.
    granted = str(tok.get("scope", ""))
    # Older tokens were saved without a scope: assume calendar-only, which is what they were.
    has_contacts = "contacts" in granted
    try:
        res = api("/calendars/primary", token_path)
        print(json.dumps({"email": res.get("id", ""), "name": res.get("summary", ""), "picture": "",
                          "scopes": granted.split(), "hasContacts": has_contacts}))
    except GoogleApiError:
        print(json.dumps({"error": "token_invalid", "path": token_path}))


def cmd_list_calendars(token_path):
    res = api("/users/me/calendarList", token_path)
    out = []
    for cal in res.get("items", []):
        out.append({
            "id": cal["id"],
            "summary": cal["summary"],
            "accessRole": cal.get("accessRole", "reader"),
            "backgroundColor": cal.get("backgroundColor", "#4285F4"),
        })
    out.sort(key=lambda c: c["summary"].lower())
    print(json.dumps({"calendars": out}))


def cmd_import(token_path, calendar_id, days):
    time_min = time.strftime("%Y-%m-%dT00:00:00Z", time.gmtime(time.time()))
    time_max = time.strftime("%Y-%m-%dT00:00:00Z", time.gmtime(time.time() + int(days) * 86400))
    params = ("singleEvents=true&orderBy=startTime&maxResults=2500"
              "&timeMin=" + urllib.parse.quote(time_min) + "&timeMax=" + urllib.parse.quote(time_max))
    res = api("/calendars/" + urllib.parse.quote(calendar_id, safe="") + "/events?" + params, token_path)
    events = []
    for ev in res.get("items", []):
        start = ev.get("start", {})
        end = ev.get("end", {})
        all_day = "date" in start
        start_val = start.get("date") or start.get("dateTime")
        end_val = end.get("date") or end.get("dateTime")
        recurrence = "none"
        if ev.get("recurringEventId") or ev.get("recurrence"):
            recurrence = "recurring"
        events.append({
            "uid": ev.get("id", ""),
            "title": ev.get("summary", "(No title)"),
            "description": ev.get("description", ""),
            "location": ev.get("location", ""),
            "start": start_val,
            "end": end_val or start_val,
            "allDay": all_day,
            "recurrence": recurrence,
            "eventId": ev.get("id", ""),
        })
    print(json.dumps({"events": events}))


def cmd_create_event(token_path, payload):
    body = {
        "summary": payload.get("title", "(No title)"),
        "description": payload.get("description", ""),
        "location": payload.get("location", ""),
    }
    if payload.get("allDay"):
        d = payload["start"][:10]
        body["start"] = {"date": d}
        end_d = payload.get("end", payload["start"])[:10]
        body["end"] = {"date": end_d or d}
    else:
        body["start"] = {"dateTime": payload["start"]}
        body["end"] = {"dateTime": payload.get("end") or payload["start"]}
    # Recurrence so a birthday added here comes back every year in Google too, not just on this machine.
    rule = {
        "daily": "RRULE:FREQ=DAILY",
        "weekly": "RRULE:FREQ=WEEKLY",
        "monthly": "RRULE:FREQ=MONTHLY",
        "yearly": "RRULE:FREQ=YEARLY",
    }.get(str(payload.get("recurrence") or "none"))
    if rule:
        body["recurrence"] = [rule]
    res = api("/calendars/primary/events", token_path, data=json.dumps(body), method="POST")
    print(json.dumps({"event": {"id": res.get("id", ""), "htmlLink": res.get("htmlLink", "")}}))


def cmd_list_contacts(token_path):
    """Every contact in the account, with birthday when the person has one.

    Google returns birthdays as {date:{year,month,day}} (year may be absent) or {text:"..."}.
    Paginated 1.000 at a time; `syncToken` is not used because a full list keeps deletions honest.
    """
    contacts = []
    page_token = None
    while True:
        params = {
            "personFields": "names,birthdays,emailAddresses,photos",
            "pageSize": "1000",
            "sortOrder": "LAST_MODIFIED_ASCENDING",
        }
        if page_token:
            params["pageToken"] = page_token
        try:
            res = api_url(PEOPLE_API, "/people/me/connections?" + urllib.parse.urlencode(params), token_path)
        except GoogleApiError as e:
            info = json.loads(str(e))
            detail = str(info.get("error", {}).get("message", "")) if isinstance(info.get("error"), dict) else ""
            if "insufficient" in detail.lower() or info.get("_http_code") == 403:
                print(json.dumps({"error": "insufficient_scope", "detail": detail[:300]}))
                return
            if "has not been used" in detail or "disabled" in detail.lower():
                print(json.dumps({"error": "people_api_disabled", "detail": detail[:300]}))
                return
            raise
        for person in res.get("connections", []):
            names = person.get("names") or []
            display = ""
            for n in names:
                if n.get("metadata", {}).get("primary"):
                    display = n.get("displayName", "")
                    break
            if not display and names:
                display = names[0].get("displayName", "")
            if not display:
                continue
            birthday = None
            for b in person.get("birthdays") or []:
                d = b.get("date") or {}
                if d.get("month"):
                    birthday = {"year": d.get("year"), "month": d["month"], "day": d.get("day", 1),
                                "text": b.get("text", "")}
                    break
                if b.get("text"):
                    birthday = {"year": None, "month": None, "day": None, "text": b.get("text", "")}
                    break
            emails = [e.get("value", "") for e in (person.get("emailAddresses") or []) if e.get("value")]
            photos = [ph.get("url", "") for ph in (person.get("photos") or []) if ph.get("url")]
            contacts.append({
                "resourceName": person.get("resourceName", ""),
                "name": display,
                "birthday": birthday,
                "emails": emails,
                "photo": photos[0] if photos else "",
            })
        page_token = res.get("nextPageToken")
        if not page_token:
            break
    contacts.sort(key=lambda c: c["name"].lower())
    print(json.dumps({"contacts": contacts}))


# ── Dispatcher ───────────────────────────────────────────────────────────────

def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    try:
        if cmd == "oauth-request":
            oauth_request(sys.argv[2])
        elif cmd == "oauth-poll":
            oauth_poll(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5])
        elif cmd == "oauth-loopback":
            oauth_loopback(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else "",
                           sys.argv[4] if len(sys.argv) > 4 else "")
        elif cmd == "token-info":
            cmd_token_info(sys.argv[2])
        elif cmd == "refresh":
            refresh_token(sys.argv[2])
            print(json.dumps({"ok": True}))
        elif cmd == "list-calendars":
            cmd_list_calendars(sys.argv[2])
        elif cmd == "import":
            cmd_import(sys.argv[2], sys.argv[3], int(sys.argv[4]) if len(sys.argv) > 4 else 365)
        elif cmd == "create-event":
            payload = json.loads(sys.argv[3])
            cmd_create_event(sys.argv[2], payload)
        elif cmd == "list-contacts":
            cmd_list_contacts(sys.argv[2])
        else:
            print(json.dumps({"error": "unknown_command", "usage": __doc__}), file=sys.stderr)
            sys.exit(2)
    except GoogleApiError as e:
        print(json.dumps({"error": str(e)}), file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(json.dumps({"error": str(e)}), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()