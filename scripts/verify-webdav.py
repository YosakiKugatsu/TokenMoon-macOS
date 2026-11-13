#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Run the Swift WebDAV integration test against a disposable, in-memory local HTTP server."""
import hashlib
import json
import os
import re
import subprocess
import threading
from collections import Counter
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parent.parent
PARENT = "/dav%20fixtures/"
DIRECTORY = PARENT + "tokenmoon-v1/"
AUTH = "Basic dG9rZW5tb29uOnRlc3Q="
FILENAME = re.compile(r"[0-9a-f-]{36}--[0-9]{4}-[0-9]{2}\.json")
LOCK = threading.RLock()
OWN_OCTOBER = "11111111-1111-4111-8111-111111111111--2026-10.json"
PEER_NOVEMBER = "22222222-2222-4222-8222-222222222222--2026-11.json"


class Fixture(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def end(self, status, body=b"", **headers):
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        for key, value in headers.items():
            self.send_header(key, value)
        self.end_headers()
        if body:
            self.wfile.write(body)

    def credentials(self):
        if self.headers.get("Authorization") != AUTH:
            self.end(401)
            return False
        return True

    def input(self):
        return self.rfile.read(int(self.headers.get("Content-Length", "0")))

    @property
    def relative_name(self):
        return self.path.removeprefix(DIRECTORY) if self.path.startswith(DIRECTORY) else None

    def do_MKCOL(self):
        if not self.credentials():
            return
        with LOCK:
            if self.path != DIRECTORY:
                return self.end(409)
            if self.server.created:
                return self.end(405)
            self.server.created = True
            self.end(201)

    def do_PROPFIND(self):
        self.input()
        if not self.credentials():
            return
        if self.headers.get("Depth") != "1":
            return self.end(400)
        with LOCK:
            if self.path != DIRECTORY or not self.server.created:
                return self.end(404)
            children = [DIRECTORY, DIRECTORY + "readme.txt", *(DIRECTORY + key for key in self.server.files)]
            # A look-alike name with another origin must never be used for discovery.
            children.append("http://127.0.0.1:1" + DIRECTORY + "33333333-3333-4333-8333-333333333333--2026-11.json")
            def entry(href):
                propstat = ""
                if self.server.resilience and href == DIRECTORY + PEER_NOVEMBER:
                    etag = self.etag(self.server.files[PEER_NOVEMBER])
                    propstat = (f"<D:propstat><D:prop><D:getetag>{escape(etag)}</D:getetag></D:prop>"
                                "<D:status>HTTP/1.1 200 OK</D:status></D:propstat>")
                return f"<D:response><D:href>{escape(href)}</D:href>{propstat}</D:response>"
            responses = "".join(entry(href) for href in children)
            xml = f'<?xml version="1.0"?><D:multistatus xmlns:D="DAV:">{responses}</D:multistatus>'.encode()
        self.end(207, xml, **{"Content-Type": "application/xml"})

    @staticmethod
    def etag(body):
        return '"' + hashlib.sha256(body).hexdigest() + '"'

    def do_GET(self):
        if not self.credentials():
            return
        with LOCK:
            name = self.relative_name
            self.server.gets[name] += 1
            row = self.server.files.get(name)
            weak = not self.server.resilience and self.server.puts == 4 and name == OWN_OCTOBER
        if row is None:
            return self.end(404)
        etag = ("W/" if weak else "") + self.etag(row)
        if self.headers.get("If-None-Match") == etag:
            with LOCK:
                self.server.not_modified += 1
            return self.end(304, ETag=etag)
        self.end(200, row, ETag=etag, **{"Content-Type": "application/json"})

    def do_PUT(self):
        body = self.input()
        if not self.credentials():
            return
        name = self.relative_name
        if name is None or FILENAME.fullmatch(name) is None:
            return self.end(404)
        with LOCK:
            self.server.put_attempts[name] += 1
            prior = self.server.files.get(name)
            if prior is None:
                if self.headers.get("If-None-Match") != "*":
                    return self.end(412)
            elif self.headers.get("If-Match") != self.etag(prior):
                return self.end(412)

            if prior is not None and self.server.inject_race:
                old = json.loads(prior)
                old["messages"] = [{"text": "private fixture body"}]
                old["requests"][0]["sessionTitle"] = "legacy generated title"
                old["requests"][0]["providerExtension"] = {"prompt": "private fixture prompt"}
                concurrent = dict(old["requests"][0], id="concurrent", outputTokens=10)
                old["requests"].append(concurrent)
                self.server.files[name] = json.dumps(old).encode()
                self.server.inject_race = False
                self.server.races += 1
                return self.end(412)

            incoming = json.loads(body)
            assert incoming["month"] == name[38:-5], "request written to wrong month"
            if prior is not None:
                assert "messages" not in incoming, "body was republished"
                assert all("providerExtension" not in record and "sessionTitle" not in record
                           for record in incoming["requests"]), "body or title was republished"
            self.server.files[name] = body
            self.server.puts += 1
            self.end(201 if prior is None else 204, ETag=self.etag(body))

    def do_POST(self):
        command = self.input()
        if not self.server.resilience or self.path != PARENT + "fixture-phase":
            return self.end(404)
        with LOCK:
            if command == b"break":
                saved = {name: self.server.files[name] for name in (OWN_OCTOBER, PEER_NOVEMBER)}
                self.server.saved = saved
                unsupported = dict(json.loads(saved[OWN_OCTOBER]), schemaVersion=2)
                self.server.files[OWN_OCTOBER] = json.dumps(unsupported).encode()
                self.server.files[PEER_NOVEMBER] = b"{"
            elif command == b"restore":
                assert self.server.put_attempts[OWN_OCTOBER] == 1, "attempted to write an unreadable owned shard"
                self.server.files.update(self.server.saved)
            elif command == b"remove-peer":
                del self.server.files[PEER_NOVEMBER]
            else:
                return self.end(400)
        self.end(204)

@contextmanager
def fixture(resilience=False):
    with ThreadingHTTPServer(("127.0.0.1", 0), Fixture) as server:
        server.files = {}
        server.created = False
        server.resilience = resilience
        server.inject_race = not resilience
        server.races = server.puts = server.not_modified = 0
        server.gets = Counter()
        server.put_attempts = Counter()
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield server, f"http://127.0.0.1:{server.server_port}{PARENT}"
        finally:
            server.shutdown()

def main():
    with (fixture() as (server, address), fixture(resilience=True) as (resilient, resilient_address),
          fixture(resilience=True) as (quota, quota_address)):
        args = ["swift", "test"]
        if scratch := os.environ.get("TOKENMOON_TEST_SWIFT_SCRATCH"):
            args += ["--scratch-path", scratch]
        subprocess.run(
            args,
            cwd=ROOT,
            env={**os.environ, "TOKENMOON_TEST_DAV": address, "TOKENMOON_TEST_DAV_RESILIENCE": resilient_address,
                 "TOKENMOON_TEST_DAV_QUOTA": quota_address},
            check=True,
        )
        if (server.puts, server.races, len(server.files)) != (4, 1, 3):
            raise SystemExit(f"Unexpected final state: {server.puts} successful PUTs, {server.races} races, "
                             f"{len(server.files)} shards")
        assert resilient.puts == 5 and resilient.put_attempts[OWN_OCTOBER] == 1, "owned writes did not stay isolated"
        assert resilient.not_modified >= 4, "conditional GET did not reuse validated cache"
        assert resilient.gets[PEER_NOVEMBER] == 2, "DAV:getetag did not skip the recovered peer GET"
        assert all(row["id"] != "obsolete-id" for row in json.loads(
            resilient.files["11111111-1111-4111-8111-111111111111--2026-11.json"]
        )["requests"]), "obsolete ID was not removed from the persisted owned shard"
        assert quota.puts == 3 and len(quota.files) == 2, "quota merge was not idempotent"
        assert len(json.loads(quota.files[OWN_OCTOBER])["quotaObservations"]) == 1
        assert json.loads(quota.files[PEER_NOVEMBER])["requests"][0]["cpaKeyLabel"] == "Team"
        print("Verified device-only writes, CAS retry and weak ETag protection, partial sync, persistent cache, "
              "owned alias removal, quota-only shards, and CPA request metadata.")


if __name__ == "__main__":
    main()
