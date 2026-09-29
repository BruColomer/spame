#!/usr/bin/env python3
"""Spame helper: finds newsletter senders in Gmail and unsubscribes from them.

Standard library only. Every command prints JSON to stdout; streaming commands
print one JSON object per line. Expected failures are reported as
{"error": "..."} with exit code 0 so the QML side can show them.
"""

import email.utils
import html
import imaplib
import json
import os
import re
import shutil
import smtplib
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter
from datetime import datetime, timedelta, timezone
from email.message import EmailMessage
from email.parser import BytesHeaderParser
from html.parser import HTMLParser
from pathlib import Path

IMAP_HOST = "imap.gmail.com"
SMTP_HOST = "smtp.gmail.com"
KEYRING_SERVICE = "spame"
HTTP_TIMEOUT = 15
USER_AGENT = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
              "(KHTML, like Gecko) Chrome/130.0 Safari/537.36")

# Sending platforms shared by many brands: group by display name as well.
SHARED_PLATFORMS = {
    "shopifyemail.com", "mailchimpapp.com", "mcsv.net", "mcdlv.net", "brevosend.com",
    "sendinblue.com", "ccsend.com", "convertkit.com", "kit.com", "substack.com",
    "beehiiv.com", "patreon.com", "gumroad.com", "klaviyomail.com", "mailerlite.com",
    "mlsend.com", "sendgrid.net", "amazonses.com", "hubspotemail.net", "squarespace.com",
    "wixemails.com", "ghost.io", "buttondown.email", "gmail.com", "googlemail.com",
}
# Second-level labels under which the registrable domain has three parts.
MULTI_PART_SUFFIXES = {"co", "com", "org", "net", "ac", "gov", "edu", "gob", "nom"}
ALIAS_DOMAINS = {"passmail.net", "passmail.com", "simplelogin.com", "slmails.com", "aleeas.com"}

UNSUB_WORDS = re.compile(
    r"unsubscri|opt[\s-]?out|confirm|remove me|stop (receiving|emails)|"
    r"dar(se)? de baja|darme de baja|baja|cancelar (la )?suscripci|donar-me de baixa|baixa|"
    r"d[ée]sabonn|d[ée]sinscri|abmelden|abbestellen|disiscriv|cancelar inscri",
    re.I,
)
CONFIRMED = re.compile(
    r"(you('ve| have)?|you are|you're|has|have) (been |now )?(successfully |now )?"
    r"(unsubscribed|removed|opted out)"
    r"|successfully unsubscribed|unsubscribe(d)? successful(ly)?|unsubscription (is )?(complete|confirmed)"
    r"|(no longer|won'?t|will not) (be )?receiv"
    r"|removed from (our|the|this|all) (mailing )?list"
    r"|dad[oa] de baja|baja (realizada|correcta|confirmada|completada)|ya no recibir"
    r"|donat de baixa|ja no rebr"
    r"|d[ée]sabonn[ée]|d[ée]sinscrit|ne recevrez plus"
    r"|abgemeldet|erfolgreich abbestellt"
    r"|disiscritto|cancelad[oa] (con [ée]xito|correctamente)",
    re.I,
)


# ---------------------------------------------------------------- paths/state

def _xdg(var, default):
    return Path(os.environ.get(var) or Path.home() / default) / "spame"


def config_path():
    return _xdg("XDG_CONFIG_HOME", ".config") / "config.json"


def cache_path():
    return _xdg("XDG_CACHE_HOME", ".cache") / "scan.json"


def state_path():
    return _xdg("XDG_STATE_HOME", ".local/state") / "state.json"


def _read_json(path, default):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return default


def _write_json(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent=1))
    os.chmod(tmp, 0o600)
    tmp.replace(path)


def load_state():
    data = _read_json(state_path(), {})
    data.setdefault("senders", {})
    return data


def record_results(results):
    state = load_state()
    now = datetime.now(timezone.utc).isoformat(timespec="seconds")
    for r in results:
        if r.get("status") not in ("done", "needs-you"):
            continue
        state["senders"][r["id"]] = {
            "id": r["id"], "name": r.get("name", r["id"]), "domain": r.get("domain", ""),
            "status": r["status"], "method": r.get("method", ""), "http": r.get("http"),
            "url": r.get("url"), "at": now,
        }
    _write_json(state_path(), state)


def forget_sender(sender_id):
    state = load_state()
    state["senders"].pop(sender_id, None)
    _write_json(state_path(), state)


def resubscribe_target(entry):
    url = entry.get("http") or entry.get("url")
    if url and url.startswith(("https://", "http://")):
        return url
    return "https://" + entry.get("domain", "")


# ---------------------------------------------------------------- credentials

def load_email():
    return _read_json(config_path(), {}).get("email", "")


def get_password(address):
    env = os.environ.get("SPAME_APP_PASSWORD")
    if env:
        return env
    if not shutil.which("secret-tool"):
        return ""
    out = subprocess.run(["secret-tool", "lookup", "service", KEYRING_SERVICE, "account", address],
                         capture_output=True, text=True, timeout=20)
    return out.stdout.strip()


def store_password(address, password):
    if not shutil.which("secret-tool"):
        raise RuntimeError("secret-tool not found (install libsecret)")
    subprocess.run(["secret-tool", "store", "--label=Spame Gmail app password",
                    "service", KEYRING_SERVICE, "account", address],
                   input=password, text=True, check=True, timeout=30)


def credentials():
    address = load_email()
    password = get_password(address) if address else ""
    if not address or not password:
        raise RuntimeError("Not connected. Open Spame and add your Gmail app password.")
    return address, password


# ---------------------------------------------------------------- header logic

def parse_list_unsubscribe(value):
    http = mailto = None
    for part in re.findall(r"<([^>]+)>", value or ""):
        part = part.strip()
        low = part.lower()
        if low.startswith("mailto:") and not mailto:
            mailto = part
        elif low.startswith(("https://", "http://")) and not http:
            http = part
    return http, mailto


def parse_mailto(url):
    parsed = urllib.parse.urlparse(url)
    query = urllib.parse.parse_qs(parsed.query)
    to = urllib.parse.unquote(parsed.path)
    subject = (query.get("subject") or ["unsubscribe"])[0]
    body = (query.get("body") or ["unsubscribe"])[0]
    return to, subject, body


def base_domain(host):
    labels = [x for x in (host or "").lower().strip(".").split(".") if x]
    if len(labels) >= 3 and len(labels[-1]) == 2 and labels[-2] in MULTI_PART_SUFFIXES:
        return ".".join(labels[-3:])
    return ".".join(labels[-2:])


def _decode_alias(local):
    match = re.match(r"^(.+?)_at_(.+)_[a-z0-9]+$", local)
    if not match:
        return None
    return match.group(2).replace("_", ".")


def _pretty_domain(domain):
    return domain.split(".")[0].replace("-", " ").title()


def sender_identity(from_header):
    name, addr = email.utils.parseaddr(from_header or "")
    local, _, host = addr.lower().partition("@")
    domain = base_domain(host)
    if domain in ALIAS_DOMAINS:
        real = _decode_alias(local)
        if real:
            domain = base_domain(real)
    name = (name or "").strip().strip('"').strip()
    return name or _pretty_domain(domain), domain


def sender_key(name, domain):
    if domain in SHARED_PLATFORMS:
        return f"{domain}|{name.lower()}"
    return domain


def _date(value):
    try:
        dt = email.utils.parsedate_to_datetime(value)
        return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)
    except (TypeError, ValueError):
        return datetime.fromtimestamp(0, timezone.utc)


def best_method(sender):
    if sender.get("oneClick") and sender.get("http"):
        return "one-click"
    if sender.get("mailto"):
        return "email"
    return "page"


def group_senders(raw_messages):
    parser = BytesHeaderParser()
    groups = {}
    for raw in raw_messages:
        msg = parser.parsebytes(raw)
        lu = msg.get("List-Unsubscribe")
        if not lu:
            continue
        http, mailto = parse_list_unsubscribe(str(lu))
        if not http and not mailto:
            continue
        name, domain = sender_identity(str(msg.get("From", "")))
        if not domain:
            continue
        key = sender_key(name, domain)
        when = _date(msg.get("Date"))
        g = groups.setdefault(key, {"id": key, "domain": domain, "names": Counter(),
                                    "count": 0, "last": None})
        g["count"] += 1
        g["names"][name] += 1
        if g["last"] is None or when >= g["last"]:
            g["last"] = when
            g["http"], g["mailto"] = http, mailto
            g["oneClick"] = "one-click" in str(msg.get("List-Unsubscribe-Post", "")).lower()
    senders = []
    for g in groups.values():
        s = {
            "id": g["id"], "name": g["names"].most_common(1)[0][0], "domain": g["domain"],
            "count": g["count"], "last": g["last"].date().isoformat(),
            "http": g["http"], "mailto": g["mailto"], "oneClick": g["oneClick"],
        }
        s["method"] = best_method(s)
        senders.append(s)
    senders.sort(key=lambda s: (-s["count"], s["name"].lower()))
    return senders


# ---------------------------------------------------------------- HTML logic

class _PageParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.forms, self.links, self._form, self._link = [], [], None, None
        self._select = None

    def handle_starttag(self, tag, attrs):
        a = {k: (v or "") for k, v in attrs}
        if tag == "form":
            self._form = {"action": a.get("action", ""), "method": a.get("method", "get").upper(),
                          "fields": {}, "text": [], "radios": {}, "submits": []}
        elif tag == "a" and a.get("href"):
            self._link = {"href": a["href"], "text": []}
        elif self._form is not None:
            self._form_tag(tag, a)

    def _form_tag(self, tag, a):
        f = self._form
        name = a.get("name", "")
        if tag == "input":
            kind = a.get("type", "text").lower()
            value = a.get("value", "")
            if kind in ("submit", "image"):
                f["submits"].append((name, value))
                f["text"].append(value)
            elif kind == "checkbox":
                if name and "checked" in a:
                    f["fields"][name] = value or "on"
            elif kind == "radio":
                if name:
                    f["radios"].setdefault(name, []).append((value, "checked" in a))
            elif kind != "button" and name:
                f["fields"][name] = value
        elif tag == "button":
            if a.get("type", "submit").lower() == "submit":
                f["submits"].append((name, a.get("value", "")))
        elif tag == "select" and name:
            self._select = name
        elif tag == "option" and self._select:
            if self._select not in f["fields"] or "selected" in a:
                f["fields"][self._select] = a.get("value", "")
        elif tag == "textarea" and name:
            f["fields"].setdefault(name, "")

    def handle_endtag(self, tag):
        if tag == "form" and self._form is not None:
            self.forms.append(self._form)
            self._form = None
        elif tag == "a" and self._link is not None:
            self.links.append(self._link)
            self._link = None
        elif tag == "select":
            self._select = None

    def handle_data(self, data):
        if self._form is not None:
            self._form["text"].append(data)
        if self._link is not None:
            self._link["text"].append(data)


def _parse(page):
    p = _PageParser()
    try:
        p.feed(page or "")
        p.close()
    except Exception:  # malformed markup: use whatever was parsed
        pass
    return p


def find_unsubscribe_form(page, base_url):
    for f in _parse(page).forms:
        blob = " ".join(f["text"]) + " " + f["action"] + " " + " ".join(v for _, v in f["submits"])
        if not UNSUB_WORDS.search(blob):
            continue
        fields = dict(f["fields"])
        for name, options in f["radios"].items():
            pick = next((v for v, _ in options if UNSUB_WORDS.search(v) or re.search(r"all", v, re.I)), None)
            pick = pick or next((v for v, c in options if c), options[0][0])
            fields[name] = pick
        submit = next(((n, v) for n, v in f["submits"] if UNSUB_WORDS.search(v)), None)
        submit = submit or (f["submits"][0] if f["submits"] else None)
        if submit and submit[0]:
            fields[submit[0]] = submit[1]
        return {"action": urllib.parse.urljoin(base_url, f["action"] or base_url),
                "method": "POST" if f["method"] == "POST" else "GET", "fields": fields}
    return None


def find_confirm_link(page, base_url):
    here = urllib.parse.urldefrag(base_url)[0]
    for link in _parse(page).links:
        text = " ".join(link["text"]).strip()
        href = urllib.parse.urljoin(base_url, html.unescape(link["href"]))
        if not href.startswith(("http://", "https://")) or urllib.parse.urldefrag(href)[0] == here:
            continue
        if UNSUB_WORDS.search(text) and not re.search(r"resubscri|preferences|help", text, re.I):
            return href
    return None


def page_text(page):
    page = re.sub(r"(?is)<(script|style)[^>]*>.*?</\1>", " ", page or "")
    return html.unescape(re.sub(r"<[^>]+>", " ", page))


def looks_confirmed(text):
    return bool(CONFIRMED.search(page_text(text)))


# ---------------------------------------------------------------- transports

class Transport:
    """Real network side effects; swapped for a mock in tests."""

    def __init__(self, address, password):
        self.address, self.password = address, password
        self._smtp = None

    def _request(self, url, data=None, method=None):
        headers = {"User-Agent": USER_AGENT, "Accept": "text/html,*/*"}
        if data is not None:
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
            body = resp.read(2_000_000).decode(resp.headers.get_content_charset() or "utf-8", "replace")
            return resp.status, resp.geturl(), body

    def one_click(self, url):
        try:
            status, _, _ = self._request(url, b"List-Unsubscribe=One-Click", "POST")
            return 200 <= status < 400
        except urllib.error.HTTPError as e:
            return 200 <= e.code < 400
        except Exception:
            return False

    def send_mailto(self, url):
        to, subject, body = parse_mailto(url)
        if not to:
            return False
        msg = EmailMessage()
        msg["From"], msg["To"], msg["Subject"] = self.address, to, subject
        msg.set_content(body)
        if self._smtp is None:
            self._smtp = smtplib.SMTP_SSL(SMTP_HOST, 465, timeout=HTTP_TIMEOUT,
                                          context=ssl.create_default_context())
            self._smtp.login(self.address, self.password)
        self._smtp.send_message(msg)
        return True

    def page(self, url):
        try:
            _, final, body = self._request(url)
            if looks_confirmed(body):
                return True
            form = find_unsubscribe_form(body, final)
            if form:
                data = urllib.parse.urlencode(form["fields"])
                if form["method"] == "POST":
                    _, _, body2 = self._request(form["action"], data.encode(), "POST")
                else:
                    sep = "&" if "?" in form["action"] else "?"
                    _, _, body2 = self._request(form["action"] + (sep + data if data else ""))
                if looks_confirmed(body2):
                    return True
            link = find_confirm_link(body, final)
            if link:
                _, _, body3 = self._request(link)
                return looks_confirmed(body3)
        except Exception:
            return False
        return False

    def browser(self, url):
        """Playwright attempt. None = Playwright unavailable, else bool."""
        try:
            from playwright.sync_api import sync_playwright
        except ImportError:
            return None
        try:
            with sync_playwright() as pw:
                exe = shutil.which("chromium") or shutil.which("google-chrome-stable")
                b = pw.chromium.launch(headless=True, executable_path=exe) if exe else pw.chromium.launch()
                pg = b.new_page()
                pg.goto(url, timeout=HTTP_TIMEOUT * 1000)
                if looks_confirmed(pg.content()):
                    return True
                pattern = re.compile(r"unsubscri|confirm|opt.?out|baja|d[ée]sabonn|abmelden", re.I)
                for role in ("button", "link"):
                    target = pg.get_by_role(role, name=pattern)
                    if target.count():
                        target.first.click(timeout=5000)
                        pg.wait_for_load_state("networkidle", timeout=10000)
                        break
                ok = looks_confirmed(pg.content())
                b.close()
                return ok
        except Exception:
            return False

    def close(self):
        if self._smtp is not None:
            try:
                self._smtp.quit()
            except Exception:
                pass


def unsubscribe_one(sender, transport):
    http, mailto = sender.get("http"), sender.get("mailto")
    result = {"id": sender["id"], "name": sender.get("name"), "domain": sender.get("domain"),
              "http": http}

    def done(method):
        return dict(result, status="done", method=method)

    attempts = []
    if http and sender.get("oneClick"):
        attempts.append(("one-click", lambda: transport.one_click(http)))
    if mailto:
        attempts.append(("email", lambda: transport.send_mailto(mailto)))
    if http:
        attempts.append(("page", lambda: transport.page(http)))
        attempts.append(("browser", lambda: transport.browser(http)))
    for method, attempt in attempts:
        try:
            if attempt():
                return done(method)
        except Exception:
            continue
    return dict(result, status="needs-you", method="", url=http or mailto)


# ---------------------------------------------------------------- IMAP scan

def fetch_headers(address, password, months):
    conn = imaplib.IMAP4_SSL(IMAP_HOST, 993, ssl_context=ssl.create_default_context(), timeout=60)
    try:
        conn.login(address, password)
        typ, _ = conn.select('"[Gmail]/All Mail"', readonly=True)
        if typ != "OK":
            conn.select("INBOX", readonly=True)
        since = (datetime.now() - timedelta(days=30 * months)).strftime("%d-%b-%Y")
        typ, data = conn.uid("SEARCH", None, "SINCE", since)
        uids = data[0].split() if typ == "OK" and data and data[0] else []
        fields = "BODY.PEEK[HEADER.FIELDS (FROM DATE LIST-UNSUBSCRIBE LIST-UNSUBSCRIBE-POST)]"
        raws = []
        for i in range(0, len(uids), 500):
            chunk = b",".join(uids[i:i + 500]).decode()
            typ, rows = conn.uid("FETCH", chunk, f"({fields})")
            if typ != "OK":
                continue
            raws.extend(r[1] for r in rows if isinstance(r, tuple) and len(r) > 1)
        return raws
    finally:
        try:
            conn.logout()
        except Exception:
            pass


def with_state(senders):
    unsubscribed = load_state()["senders"]
    for s in senders:
        s["unsubscribed"] = s["id"] in unsubscribed
    return senders


# ---------------------------------------------------------------- commands

def out(obj):
    print(json.dumps(obj), flush=True)


def cmd_status(_args):
    scan = _read_json(cache_path(), {})
    address = load_email()
    configured = bool(address and get_password(address))
    pending = sum(1 for s in with_state(scan.get("senders", [])) if not s["unsubscribed"])
    out({"configured": configured, "email": address, "lastScan": scan.get("at", ""),
         "pending": pending})


def cmd_setup(_args):
    address = sys.stdin.readline().strip()
    password = re.sub(r"\s+", "", sys.stdin.readline())
    if "@" not in address or len(password) < 8:
        return out({"error": "Enter your Gmail address and the 16-character app password."})
    try:
        conn = imaplib.IMAP4_SSL(IMAP_HOST, 993, timeout=30)
        conn.login(address, password)
        conn.logout()
    except imaplib.IMAP4.error:
        return out({"error": "Gmail rejected that. Check the address and app password (and that IMAP is on)."})
    store_password(address, password)
    _write_json(config_path(), {"email": address})
    out({"ok": True, "email": address})


def cmd_forget(_args):
    address = load_email()
    if address and shutil.which("secret-tool"):
        subprocess.run(["secret-tool", "clear", "service", KEYRING_SERVICE, "account", address],
                       timeout=20, check=False)
    try:
        config_path().unlink()
    except FileNotFoundError:
        pass
    out({"ok": True})


def cmd_scan(args):
    months = 6
    if "--months" in args:
        try:
            months = max(1, min(24, int(args[args.index("--months") + 1])))
        except (IndexError, ValueError):
            pass
    address, password = credentials()
    senders = group_senders(fetch_headers(address, password, months))
    at = datetime.now(timezone.utc).isoformat(timespec="seconds")
    _write_json(cache_path(), {"at": at, "months": months, "senders": senders})
    out({"at": at, "senders": with_state(senders)})


def cmd_cached(_args):
    scan = _read_json(cache_path(), {})
    out({"at": scan.get("at", ""), "senders": with_state(scan.get("senders", []))})


def notify(summary, body):
    if shutil.which("notify-send"):
        subprocess.run(["notify-send", "-a", "Spame", summary, body], check=False, timeout=10)


def open_url(url):
    opener = shutil.which("xdg-open")
    if opener and url:
        subprocess.Popen([opener, url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True)


def cmd_unsubscribe(_args):
    wanted = set(json.loads(sys.stdin.readline() or "[]"))
    senders = [s for s in _read_json(cache_path(), {}).get("senders", []) if s["id"] in wanted]
    address, password = credentials()
    transport = Transport(address, password)
    results = []
    try:
        for s in senders:
            out({"id": s["id"], "status": "working"})
            r = unsubscribe_one(s, transport)
            results.append(r)
            record_results([r])
            out(r)
    finally:
        transport.close()
    leftovers = [r for r in results if r["status"] == "needs-you"]
    for r in leftovers:
        open_url(r.get("url") if str(r.get("url", "")).startswith("http") else "")
        time.sleep(0.4)
    done = len(results) - len(leftovers)
    body = f"Unsubscribed from {done} sender{'s' if done != 1 else ''}."
    if leftovers:
        body += f" {len(leftovers)} opened in your browser to confirm."
    notify("Spame", body)
    out({"summary": {"done": done, "needsYou": len(leftovers)}})


def cmd_list_unsubscribed(_args):
    items = sorted(load_state()["senders"].values(), key=lambda s: s.get("at", ""), reverse=True)
    out({"senders": items})


def cmd_resubscribe(args):
    if not args:
        return out({"error": "Missing sender id"})
    entry = load_state()["senders"].get(args[0])
    if not entry:
        return out({"error": "Not in the unsubscribed list"})
    url = resubscribe_target(entry)
    open_url(url)
    forget_sender(args[0])
    out({"ok": True, "url": url})


COMMANDS = {
    "status": cmd_status, "setup": cmd_setup, "forget": cmd_forget, "scan": cmd_scan,
    "cached": cmd_cached, "unsubscribe": cmd_unsubscribe,
    "list-unsubscribed": cmd_list_unsubscribed, "resubscribe": cmd_resubscribe,
}


def main(argv):
    if not argv or argv[0] not in COMMANDS:
        out({"error": "usage: spame.py " + "|".join(COMMANDS)})
        return 0
    try:
        COMMANDS[argv[0]](argv[1:])
    except imaplib.IMAP4.error as e:
        out({"error": f"Gmail login failed: {e}"})
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as e:
        out({"error": str(e)})
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
