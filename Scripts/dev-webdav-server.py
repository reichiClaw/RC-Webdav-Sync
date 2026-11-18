#!/usr/bin/env python3
"""
Minimaler WebDAV-Server (Klasse 1) für Entwicklung und Integrationstests.

Nur Python-Standardbibliothek. Unterstützt OPTIONS, PROPFIND (Depth 0/1),
GET, HEAD, PUT (If-Match, If-None-Match), MKCOL, DELETE, MOVE (Destination,
Overwrite, If-Match) sowie HTTP Basic Auth. ETags sind stark und ändern sich
mit jedem Schreibvorgang. REPORT (sync-collection) wird bewusst nicht
unterstützt, damit der Rückfall auf die vollständige Bestandsaufnahme
getestet wird.

Verwendung:
    python3 Scripts/dev-webdav-server.py --root /tmp/dav --port 8080 --user anna --password geheim

Nicht für den Produktivbetrieb gedacht.
"""
import argparse
import base64
import hashlib
import os
import shutil
import sys
import threading
import urllib.parse
from email.utils import formatdate
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from xml.sax.saxutils import escape

ROOT = "/tmp/dav"
PREFIX = "/dav"
USER = "anna"
PASSWORD = "geheim"
QUIET = False
LOCK = threading.Lock()
ETAG_FILE = ".etags.json"
ETAGS = {}


def log(msg):
    if not QUIET:
        sys.stderr.write(msg + "\n")


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
        self._send(200, b"", {"DAV": "1", "Allow": "OPTIONS, GET, HEAD, PUT, DELETE, MKCOL, PROPFIND, MOVE"})

    def do_PROPFIND(self):
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
                if name == ETAG_FILE:
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

    def do_PUT(self):
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
        if if_match and (not exists or compute_etag(local) != if_match):
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
        if if_match and os.path.isfile(local) and compute_etag(local) != if_match:
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
    args = parser.parse_args()
    ROOT = os.path.abspath(args.root)
    PREFIX = args.prefix.rstrip("/")
    USER = args.user
    PASSWORD = args.password
    QUIET = args.quiet
    os.makedirs(ROOT, exist_ok=True)
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
