#!/usr/bin/env python3
"""
Minimaler WebDAV-Server (Klasse 1) für Entwicklung und Integrationstests.

Nur Python-Standardbibliothek. Unterstützt OPTIONS, PROPFIND (Depth 0/1),
GET, HEAD, PUT (If-Match, If-None-Match), MKCOL, DELETE, MOVE (Destination,
Overwrite, If-Match) sowie HTTP Basic Auth. ETags sind stark und ändern sich
mit jedem Schreibvorgang. REPORT (sync-collection) wird bewusst nicht
unterstützt, damit der Rückfall auf die vollständige Bestandsaufnahme
getestet wird.

Mit `--cloudreve` emuliert der Server zusätzlich die für reichi Sync relevanten
Teile der Cloudreve-v4-REST-API (Ping, Anmeldung/Token, WebDAV-Konten,
Upload-Sitzungen mit Chunks, Freigaben) und verhält sich wie Cloudreve-WebDAV
(ETag = Entity-ID, `If-Match` wird ignoriert). Test-Hooks unter `/__test/…`
erlauben Fehlerinjektion für Wiederaufnahme-Tests.

Verwendung:
    python3 Scripts/dev-webdav-server.py --root /tmp/dav --port 8080 --user anna --password geheim
    python3 Scripts/dev-webdav-server.py --cloudreve --chunk-size 1048576 --root /tmp/cr --port 8080 \
        --user anna@example.org --password geheim

Nicht für den Produktivbetrieb gedacht.
"""
import argparse
import base64
import hashlib
import json
import os
import re
import secrets
import shutil
import signal
import socket
import struct
import sys
import threading
import time
import urllib.parse
from email.utils import formatdate
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from uuid import uuid4
from xml.sax.saxutils import escape

ROOT = "/tmp/dav"
PREFIX = "/dav"
USER = "anna"
PASSWORD = "geheim"
QUIET = False
LOCK = threading.Lock()
ETAG_FILE = ".etags.json"
ETAGS = {}

# Cloudreve-Emulation
CLOUDREVE = False
CHUNK_SIZE = 1024 * 1024
SESSION_TTL = 3600
TWO_FA = None
DAV_ROOT_URI = "cloudreve://my/"
TOKENS = {}          # access_token -> expiry
REFRESH = {}         # refresh_token -> expiry
TWOFA_SESSIONS = {}
DAV_ACCOUNTS = []
UPLOAD_SESSIONS = {}
SHARES = {}
REQUEST_LOG = []
FAIL_CHUNKS = set()   # Chunk-Indizes, bei denen die Verbindung einmalig abgebrochen wird
COUNTER = {"value": 0}


def log(msg):
    if not QUIET:
        sys.stderr.write("%s %s\n" % (time.strftime("%H:%M:%S"), msg))
        sys.stderr.flush()


def compute_etag(path):
    rel = os.path.relpath(path, ROOT)
    with LOCK:
        if rel in ETAGS:
            return ETAGS[rel]
    st = os.stat(path)
    base = f"{st.st_ino}-{int(st.st_mtime * 1000)}-{st.st_size}".encode()
    return '"' + hashlib.sha1(base).hexdigest()[:20] + '"'


def bump_etag(path):
    rel = os.path.relpath(path, ROOT)
    with LOCK:
        counter = ETAGS.get("__counter__", 0) + 1
        ETAGS["__counter__"] = counter
        ETAGS[rel] = '"w%d-%s"' % (counter, hashlib.sha1(rel.encode()).hexdigest()[:8])
        return ETAGS[rel]


def drop_etag(path):
    rel = os.path.relpath(path, ROOT)
    with LOCK:
        for key in list(ETAGS.keys()):
            if key == rel or key.startswith(rel + "/"):
                del ETAGS[key]


def next_id(prefix):
    with LOCK:
        COUNTER["value"] += 1
        return "%s%d" % (prefix, COUNTER["value"])


def uri_to_local(uri):
    """`cloudreve://my/<Pfad>` → lokaler Pfad unterhalb von ROOT (relativ zur DAV-Wurzel)."""
    parsed = urllib.parse.urlparse(uri)
    if parsed.scheme != "cloudreve" or parsed.hostname != "my":
        return None
    path = urllib.parse.unquote(parsed.path)
    root = urllib.parse.unquote(urllib.parse.urlparse(DAV_ROOT_URI).path).strip("/")
    parts = [p for p in path.split("/") if p not in ("", ".")]
    root_parts = [p for p in root.split("/") if p]
    if parts[:len(root_parts)] != root_parts:
        return None
    rel = parts[len(root_parts):]
    if ".." in rel:
        return None
    return os.path.join(ROOT, *rel) if rel else ROOT


def iso(ts):
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(ts)) + "Z"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "DevWebDAV/0.1"

    def log_message(self, fmt, *args):
        log("%s %s" % (self.command, self.path))

    # -- Hilfen -----------------------------------------------------------

    def _auth_ok(self):
        header = self.headers.get("Authorization", "")
        if not header.startswith("Basic "):
            return False
        try:
            decoded = base64.b64decode(header[6:]).decode("utf-8")
        except Exception:
            return False
        return decoded == f"{USER}:{PASSWORD}"

    def _local_path(self, url_path=None):
        raw = url_path if url_path is not None else self.path
        raw = raw.split("?", 1)[0]
        decoded = urllib.parse.unquote(raw)
        if not decoded.startswith(PREFIX):
            return None
        rel = decoded[len(PREFIX):].lstrip("/")
        parts = [p for p in rel.split("/") if p not in ("", ".")]
        if ".." in parts:
            return None
        return os.path.join(ROOT, *parts) if parts else ROOT

    def _href(self, local):
        rel = os.path.relpath(local, ROOT)
        if rel == ".":
            rel = ""
        href = PREFIX + "/" + "/".join(urllib.parse.quote(p, safe="") for p in rel.split("/") if p)
        if os.path.isdir(local) and not href.endswith("/"):
            href += "/"
        return href

    def _send(self, status, body=b"", headers=None):
        self.send_response(status)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body and self.command != "HEAD":
            self.wfile.write(body)

    def _read_body(self):
        length = int(self.headers.get("Content-Length", "0") or 0)
        return self.rfile.read(length) if length else b""

    def _check_auth(self):
        if not self._auth_ok():
            self._send(401, b"Unauthorized", {"WWW-Authenticate": 'Basic realm="DevWebDAV"'})
            return False
        return True

    # -- Cloudreve-Emulation -------------------------------------------------

    def _is_api(self):
        return CLOUDREVE and (self.path.startswith("/api/v4/") or self.path.startswith("/__test/"))

    def _json(self, code=0, data=None, msg="", status=200):
        body = json.dumps({"code": code, "data": data, "msg": msg}).encode("utf-8")
        self._send(status, body, {"Content-Type": "application/json"})

    def _bearer_ok(self):
        header = self.headers.get("Authorization", "")
        if not header.startswith("Bearer "):
            return False
        token = header[7:].strip()
        with LOCK:
            expiry = TOKENS.get(token)
        return expiry is not None and expiry > time.time()

    def _issue_tokens(self):
        now = time.time()
        access = "acc-" + secrets.token_urlsafe(16)
        refresh = "ref-" + secrets.token_urlsafe(16)
        with LOCK:
            TOKENS[access] = now + 3600
            REFRESH[refresh] = now + 180 * 86400
        return {"access_token": access, "refresh_token": refresh,
                "access_expires": iso(now + 3600), "refresh_expires": iso(now + 180 * 86400)}

    def _read_json(self):
        try:
            return json.loads(self._read_body() or b"{}")
        except Exception:
            return {}

    def _api(self):
        """Verteilt /api/v4/* und /__test/*. Gibt True zurück, wenn behandelt."""
        if not self._is_api():
            return False
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        query = urllib.parse.parse_qs(parsed.query)
        REQUEST_LOG.append({"method": self.command, "path": path})

        # Test-Hooks (Body immer vollständig lesen, sonst gerät die Keep-Alive-Verbindung aus dem Takt)
        if path.startswith("/__test/"):
            body = self._read_json()
        if path == "/__test/log":
            self._send(200, json.dumps(REQUEST_LOG).encode(), {"Content-Type": "application/json"})
            return True
        if path == "/__test/reset-log":
            del REQUEST_LOG[:]
            self._send(204)
            return True
        if path == "/__test/fail-chunks":
            with LOCK:
                FAIL_CHUNKS.update(int(i) for i in body.get("indexes", []))
            self._send(204)
            return True
        if path == "/__test/expire-sessions":
            with LOCK:
                UPLOAD_SESSIONS.clear()
            self._send(204)
            return True
        if path == "/__test/expire-tokens":
            with LOCK:
                TOKENS.clear()
            self._send(204)
            return True
        if path == "/__test/sessions":
            with LOCK:
                data = [{"id": k, "received": sorted(v["received"]), "uri": v["uri"]} for k, v in UPLOAD_SESSIONS.items()]
            self._send(200, json.dumps(data).encode(), {"Content-Type": "application/json"})
            return True

        if path == "/api/v4/site/ping":
            self._json(data="4.1.0-dev")
            return True

        if path == "/api/v4/session/token" and self.command == "POST":
            body = self._read_json()
            if body.get("email") != USER or body.get("password") != PASSWORD:
                self._json(code=40020, msg="Incorrect password")
                return True
            if TWO_FA:
                sid = secrets.token_hex(8)
                TWOFA_SESSIONS[sid] = time.time() + 600
                self._json(code=203, data=sid)
                return True
            self._json(data={"user": {"id": "u1", "email": USER}, "token": self._issue_tokens()})
            return True
        if path == "/api/v4/session/token/2fa" and self.command == "POST":
            body = self._read_json()
            if body.get("session_id") not in TWOFA_SESSIONS or body.get("otp") != TWO_FA:
                self._json(code=40022, msg="Incorrect 2FA code")
                return True
            del TWOFA_SESSIONS[body["session_id"]]
            self._json(data={"user": {"id": "u1", "email": USER}, "token": self._issue_tokens()})
            return True
        if path == "/api/v4/session/token/refresh" and self.command == "POST":
            body = self._read_json()
            token = body.get("refresh_token")
            with LOCK:
                valid = token in REFRESH and REFRESH[token] > time.time()
                if valid:
                    del REFRESH[token]
            if not valid:
                self._json(code=40020, msg="Failed to issue token pair")
                return True
            self._json(data=self._issue_tokens())
            return True

        if not self._bearer_ok():
            self._read_body()
            self._json(code=401, msg="Login required", status=401)
            return True

        if path == "/api/v4/devices/dav":
            if self.command == "GET":
                self._json(data={"pagination": {"page": 0, "page_size": 100, "next_token": "", "is_cursor": True}, "accounts": list(DAV_ACCOUNTS)})
                return True
            if self.command == "PUT":
                body = self._read_json()
                account = {"id": next_id("dav"), "created_at": iso(time.time()), "name": body.get("name", ""),
                           "uri": body.get("uri", "cloudreve://my/"), "password": PASSWORD, "options": "AA=="}
                DAV_ACCOUNTS.append(account)
                self._json(data=account)
                return True

        if path == "/api/v4/file/create" and self.command == "POST":
            body = self._read_json()
            local = uri_to_local(body.get("uri", ""))
            if local is None:
                self._json(code=40001, msg="unknown uri")
            elif os.path.exists(local):
                self._json(code=40004, msg="Object existed")
            else:
                os.makedirs(local, exist_ok=True)
                self._json(data={"id": next_id("f"), "name": os.path.basename(local), "type": 1})
            return True

        if path == "/api/v4/file/upload":
            if self.command == "PUT":
                return self._create_upload_session()
            if self.command == "DELETE":
                body = self._read_json()
                with LOCK:
                    session = UPLOAD_SESSIONS.pop(body.get("id", ""), None)
                if session and os.path.exists(session["tmp"]):
                    os.remove(session["tmp"])
                self._json(data=None)
                return True

        m = re.match(r"^/api/v4/file/upload/([^/]+)/(\d+)$", path)
        if m and self.command == "POST":
            return self._upload_chunk(m.group(1), int(m.group(2)))

        if path == "/api/v4/share":
            if self.command == "PUT":
                body = self._read_json()
                local = uri_to_local(body.get("uri", ""))
                if local is None or not os.path.exists(local):
                    self._json(code=40044, msg="File not found")
                    return True
                sid = next_id("s")
                password = body.get("password") or (secrets.token_hex(4) if body.get("is_private") else None)
                base = "http://%s" % self.headers.get("Host", "localhost")
                url = "%s/s/%s" % (base, sid)
                share = {"id": sid, "name": os.path.basename(local) or "/", "url": url, "source_uri": body.get("uri"),
                         "is_private": bool(body.get("is_private")), "password": password,
                         "password_protected": bool(body.get("is_private")),
                         "expires": iso(time.time() + body["expire"]) if body.get("expire") else None,
                         "expired": False, "visited": 0, "downloaded": 0,
                         "remain_downloads": body.get("downloads"), "source_type": 1 if os.path.isdir(local) else 0,
                         "created_at": iso(time.time()), "share_view": bool(body.get("share_view"))}
                SHARES[sid] = share
                self._json(data=url + ("/" + password if password else ""))
                return True
            if self.command == "GET":
                self._json(data={"pagination": {"page": 0, "page_size": 100, "next_token": "", "is_cursor": True}, "shares": list(SHARES.values())})
                return True
        m = re.match(r"^/api/v4/share/([^/]+)$", path)
        if m and self.command == "DELETE":
            if SHARES.pop(m.group(1), None) is None:
                self._json(code=404, msg="not found")
            else:
                self._json(data=None)
            return True

        self._read_body()
        self._json(code=404, msg="Unknown API route %s" % path, status=404)
        return True

    def _create_upload_session(self):
        body = self._read_json()
        local = uri_to_local(body.get("uri", ""))
        if local is None:
            self._json(code=40001, msg="unknown uri")
            return True
        if not os.path.isdir(os.path.dirname(local)):
            self._json(code=40016, msg="Parent folder not exist")
            return True
        exists = os.path.isfile(local)
        if exists and body.get("entity_type") != "version":
            self._json(code=40004, msg="Object existed")
            return True
        previous = body.get("previous")
        if exists and previous and compute_etag(local).strip('"') != previous:
            self._json(code=40076, msg="Stale version")
            return True
        if not exists and previous:
            self._json(code=40077, msg="Entity not exist")
            return True
        size = int(body.get("size", 0))
        sid = str(uuid4())
        expires = time.time() + SESSION_TTL
        session = {"id": sid, "uri": body["uri"], "local": local, "size": size, "received": set(),
                   "tmp": local + ".%s.part" % sid, "last_modified": body.get("last_modified"), "expires": expires}
        with LOCK:
            UPLOAD_SESSIONS[sid] = session
        self._json(data={"session_id": sid, "upload_id": "", "chunk_size": CHUNK_SIZE, "expires": int(expires),
                         "storage_policy": {"id": "P1", "name": "Default storage policy", "type": "local", "max_size": 0,
                                            "relay": False, "chunk_concurrency": 1},
                         "uri": body["uri"], "callback_secret": ""})
        return True

    def _upload_chunk(self, sid, index):
        with LOCK:
            session = UPLOAD_SESSIONS.get(sid)
        length = int(self.headers.get("Content-Length", "0") or 0)
        if session is None or session["expires"] < time.time():
            self.rfile.read(length)
            self._json(code=40011, msg="Upload session expired")
            return True
        total = session["size"]
        chunk_size = CHUNK_SIZE if CHUNK_SIZE > 0 else max(total, 1)
        expected_chunks = max(1, (total + chunk_size - 1) // chunk_size) if total > 0 else 1
        if index >= expected_chunks:
            self.rfile.read(length)
            self._json(code=40012, msg="Invalid chunk index")
            return True
        expected = total - index * chunk_size if index == expected_chunks - 1 else chunk_size
        if length != expected:
            self.rfile.read(length)
            self._json(code=40013, msg="Invalid Content-Length (expected: %d)" % expected)
            return True
        data = self.rfile.read(length) if length else b""
        with LOCK:
            fail = index in FAIL_CHUNKS
            FAIL_CHUNKS.discard(index)
        if fail:
            # Verbindung hart zurücksetzen (RST), damit der Client sofort einen Netzwerkfehler sieht.
            log("TEST: Verbindung bei Chunk %d abgebrochen" % index)
            self.close_connection = True
            try:
                self.connection.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
                self.connection.close()
            except Exception:
                pass
            return True
        tmp = session["tmp"]
        with LOCK:
            with open(tmp, "r+b" if os.path.exists(tmp) else "wb") as f:
                f.seek(index * chunk_size)
                f.write(data)
            session["received"].add(index)
            complete = len(session["received"]) >= expected_chunks
            if complete:
                UPLOAD_SESSIONS.pop(sid, None)
        if complete:
            os.replace(tmp, session["local"])
            if session.get("last_modified"):
                mtime = int(session["last_modified"]) / 1000.0
                os.utime(session["local"], (mtime, mtime))
            bump_etag(session["local"])
        self._json(data=None)
        return True

    def _response_xml(self, local):
        is_dir = os.path.isdir(local)
        st = os.stat(local)
        props = ["<D:resourcetype>%s</D:resourcetype>" % ("<D:collection/>" if is_dir else "")]
        props.append("<D:getlastmodified>%s</D:getlastmodified>" % formatdate(st.st_mtime, usegmt=True))
        props.append("<D:getetag>%s</D:getetag>" % escape(compute_etag(local)))
        missing = []
        if not is_dir:
            props.append("<D:getcontentlength>%d</D:getcontentlength>" % st.st_size)
            props.append("<D:getcontenttype>application/octet-stream</D:getcontenttype>")
        else:
            missing = ["<D:getcontentlength/>", "<D:getcontenttype/>"]
        xml = "<D:response><D:href>%s</D:href>" % escape(self._href(local))
        xml += "<D:propstat><D:prop>%s</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>" % "".join(props)
        if missing:
            xml += "<D:propstat><D:prop>%s</D:prop><D:status>HTTP/1.1 404 Not Found</D:status></D:propstat>" % "".join(missing)
        xml += "</D:response>"
        return xml

    # -- Methoden -----------------------------------------------------------

    def do_OPTIONS(self):
        if self._api():
            return
        self._send(200, b"", {"DAV": "1", "Allow": "OPTIONS, GET, HEAD, PUT, DELETE, MKCOL, PROPFIND, MOVE"})

    def do_PROPFIND(self):
        if self._api():
            return
        if not self._check_auth():
            return
        self._read_body()
        local = self._local_path()
        if local is None or not os.path.exists(local):
            self._send(404, b"Not Found")
            return
        depth = self.headers.get("Depth", "1")
        responses = [self._response_xml(local)]
        if depth != "0" and os.path.isdir(local):
            for name in sorted(os.listdir(local)):
                if name == ETAG_FILE or name.endswith(".part"):
                    continue
                responses.append(self._response_xml(os.path.join(local, name)))
        body = ('<?xml version="1.0" encoding="utf-8"?><D:multistatus xmlns:D="DAV:">%s</D:multistatus>' % "".join(responses)).encode("utf-8")
        self._send(207, body, {"Content-Type": 'application/xml; charset="utf-8"'})

    def do_REPORT(self):
        if not self._check_auth():
            return
        self._read_body()
        self._send(403, b"REPORT not supported")

    def do_GET(self):
        if self._api():
            return
        if not self._check_auth():
            return
        local = self._local_path()
        if local is None or not os.path.isfile(local):
            self._send(404, b"Not Found")
            return
        st = os.stat(local)
        self.send_response(200)
        self.send_header("Content-Length", str(st.st_size))
        self.send_header("ETag", compute_etag(local))
        self.send_header("Last-Modified", formatdate(st.st_mtime, usegmt=True))
        self.send_header("Content-Type", "application/octet-stream")
        self.end_headers()
        if self.command == "HEAD":
            return
        with open(local, "rb") as f:
            shutil.copyfileobj(f, self.wfile)

    do_HEAD = do_GET

    def do_POST(self):
        if self._api():
            return
        self._read_body()
        self._send(405, b"Method Not Allowed")

    def do_PUT(self):
        if self._api():
            return
        if not self._check_auth():
            return
        local = self._local_path()
        if local is None:
            self._send(403, b"Forbidden")
            return
        if not os.path.isdir(os.path.dirname(local)):
            self._read_body()
            self._send(409, b"Conflict: parent missing")
            return
        if os.path.isdir(local):
            self._read_body()
            self._send(405, b"Method Not Allowed")
            return
        exists = os.path.isfile(local)
        if self.headers.get("If-None-Match") == "*" and exists:
            self._read_body()
            self._send(412, b"Precondition Failed")
            return
        if_match = self.headers.get("If-Match")
        if if_match and not CLOUDREVE and (not exists or compute_etag(local) != if_match):
            self._read_body()
            self._send(412, b"Precondition Failed")
            return
        data = self._read_body()
        tmp = local + ".uploading"
        with open(tmp, "wb") as f:
            f.write(data)
        os.replace(tmp, local)
        mtime_header = self.headers.get("X-OC-Mtime")
        if mtime_header and mtime_header.isdigit():
            os.utime(local, (int(mtime_header), int(mtime_header)))
        etag = bump_etag(local)
        self._send(204 if exists else 201, b"", {"ETag": etag})

    def do_MKCOL(self):
        if not self._check_auth():
            return
        self._read_body()
        local = self._local_path()
        if local is None:
            self._send(403, b"Forbidden")
            return
        if os.path.exists(local):
            self._send(405, b"Method Not Allowed")
            return
        if not os.path.isdir(os.path.dirname(local)):
            self._send(409, b"Conflict")
            return
        os.mkdir(local)
        self._send(201, b"")

    def do_DELETE(self):
        if self._api():
            return
        if not self._check_auth():
            return
        local = self._local_path()
        if local is None or local == ROOT:
            self._send(403, b"Forbidden")
            return
        if not os.path.exists(local):
            self._send(404, b"Not Found")
            return
        if_match = self.headers.get("If-Match")
        if if_match and not CLOUDREVE and os.path.isfile(local) and compute_etag(local) != if_match:
            self._send(412, b"Precondition Failed")
            return
        if os.path.isdir(local):
            shutil.rmtree(local)
        else:
            os.remove(local)
        drop_etag(local)
        self._send(204, b"")

    def do_MOVE(self):
        if not self._check_auth():
            return
        source = self._local_path()
        dest_header = self.headers.get("Destination", "")
        parsed = urllib.parse.urlparse(dest_header)
        dest = self._local_path(parsed.path if parsed.scheme else dest_header)
        if source is None or dest is None or source == ROOT:
            self._send(403, b"Forbidden")
            return
        if not os.path.exists(source):
            self._send(404, b"Not Found")
            return
        if_match = self.headers.get("If-Match")
        if if_match and os.path.isfile(source) and compute_etag(source) != if_match:
            self._send(412, b"Precondition Failed")
            return
        overwrite = self.headers.get("Overwrite", "T").upper() != "F"
        existed = os.path.exists(dest)
        if existed and not overwrite:
            self._send(412, b"Precondition Failed")
            return
        if not os.path.isdir(os.path.dirname(dest)):
            self._send(409, b"Conflict")
            return
        if existed:
            if os.path.isdir(dest):
                shutil.rmtree(dest)
            else:
                os.remove(dest)
        os.rename(source, dest)
        drop_etag(source)
        if os.path.isfile(dest):
            bump_etag(dest)
        self._send(204 if existed else 201, b"")


def main():
    global ROOT, PREFIX, USER, PASSWORD, QUIET
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", default="/tmp/dav")
    parser.add_argument("--prefix", default="/dav")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--bind", default="127.0.0.1")
    parser.add_argument("--user", default="anna")
    parser.add_argument("--password", default="geheim")
    parser.add_argument("--quiet", action="store_true")
    parser.add_argument("--cloudreve", action="store_true", help="Cloudreve-API emulieren (/api/v4), If-Match ignorieren")
    parser.add_argument("--chunk-size", type=int, default=1024 * 1024, help="Chunk-Größe der Upload-Sitzungen (0 = kein Chunking)")
    parser.add_argument("--session-ttl", type=int, default=3600, help="Lebensdauer von Upload-Sitzungen in Sekunden")
    parser.add_argument("--twofa", default=None, help="OTP-Code, der bei der Anmeldung verlangt wird")
    parser.add_argument("--dav-root-uri", default="cloudreve://my/", help="Cloudreve-URI, der dem WebDAV-Root entspricht")
    args = parser.parse_args()
    global CLOUDREVE, CHUNK_SIZE, SESSION_TTL, TWO_FA, DAV_ROOT_URI
    ROOT = os.path.abspath(args.root)
    PREFIX = args.prefix.rstrip("/")
    USER = args.user
    PASSWORD = args.password
    QUIET = args.quiet
    CLOUDREVE = args.cloudreve
    CHUNK_SIZE = args.chunk_size
    SESSION_TTL = args.session_ttl
    TWO_FA = args.twofa
    DAV_ROOT_URI = args.dav_root_uri
    if CLOUDREVE:
        DAV_ACCOUNTS.append({"id": "dav0", "created_at": iso(time.time()), "name": "Standardkonto", "uri": DAV_ROOT_URI,
                             "password": PASSWORD, "options": "AA=="})
    os.makedirs(ROOT, exist_ok=True)
    # Wird der Server aus einem Testprozess gestartet, kann eine blockierte Signalmaske
    # vererbt werden – dann käme SIGTERM nie an. Daher explizit entsperren und behandeln.
    try:
        signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGTERM, signal.SIGINT, signal.SIGHUP})
    except (AttributeError, ValueError):
        pass
    signal.signal(signal.SIGTERM, lambda *_: os._exit(0))
    server = ThreadingHTTPServer((args.bind, args.port), Handler)
    server.daemon_threads = True
    log(f"DevWebDAV auf http://{args.bind}:{server.server_address[1]}{PREFIX}/  (Root: {ROOT})")
    sys.stdout.write(f"READY {server.server_address[1]}\n")
    sys.stdout.flush()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
