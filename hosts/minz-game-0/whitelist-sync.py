#!/usr/bin/env python3
# Test modes (set before the EnvironmentFile vars are loaded, or inline):
#   USERS_FILE=/path/to/users.json  — skip Authentik, read users from file instead
#   DRY_RUN=1                       — skip writes, print what would change
#   Both together                   — offline/unit-test mode: no external connections
#
# USERS_FILE format: [{"minecraft_uuid": "...", "minecraft_username": "..."}, ...]
import json
import os
import socket
import ssl
import struct
import sys
import urllib.request

USERS_FILE     = os.environ.get("USERS_FILE", "")
DRY_RUN        = os.environ.get("DRY_RUN", "").lower() in ("1", "true", "yes")
offline        = DRY_RUN and bool(USERS_FILE)
WHITELIST_FILE = os.environ.get("WHITELIST_FILE", "/persist/atm10/whitelist.json")

RCON_HOST = "" if offline else os.environ["RCON_HOST"]
RCON_PORT = 25575 if offline else int(os.environ.get("RCON_PORT", "25575"))
RCON_PASS = "" if offline else os.environ["RCON_PASSWORD"]

AUTH_URL   = "" if USERS_FILE else os.environ["AUTHENTIK_URL"].rstrip("/")
AUTH_TOKEN = "" if USERS_FILE else os.environ["AUTHENTIK_TOKEN"]


def _send(sock: socket.socket, req_id: int, ptype: int, body: str) -> None:
    encoded = body.encode("utf-8") + b"\x00\x00"
    sock.sendall(struct.pack("<iii", 4 + 4 + len(encoded), req_id, ptype) + encoded)


def _recv(sock: socket.socket) -> tuple[int, int, str]:
    buf = b""
    while len(buf) < 4:
        buf += sock.recv(4096)
    size = struct.unpack("<i", buf[:4])[0]
    while len(buf) < 4 + size:
        buf += sock.recv(4096)
    req_id = struct.unpack("<i", buf[4:8])[0]
    ptype  = struct.unpack("<i", buf[8:12])[0]
    body   = buf[12:4 + size - 2].decode("utf-8", errors="replace")
    return req_id, ptype, body


def rcon_cmd(sock: socket.socket, cmd: str) -> str:
    _send(sock, 1, 2, cmd)
    _, _, body = _recv(sock)
    return body


# ── 1. Resolve desired whitelist from Authentik ───────────────────────────────
if USERS_FILE:
    with open(USERS_FILE) as f:
        entries = json.load(f)
    desired: dict[str, str] = {e["minecraft_uuid"]: e["minecraft_username"] for e in entries}
else:
    ctx = ssl.create_default_context()
    desired = {}
    page = 1
    while True:
        req = urllib.request.Request(
            f"{AUTH_URL}/api/v3/core/users/?page_size=100&type=internal&page={page}",
            headers={"Authorization": f"Bearer {AUTH_TOKEN}"},
        )
        with urllib.request.urlopen(req, context=ctx, timeout=10) as r:
            data = json.load(r)
        for u in data["results"]:
            attrs = u.get("attributes") or {}
            uuid = attrs.get("minecraft_uuid")
            name = attrs.get("minecraft_username")
            if uuid and name:
                desired[uuid] = name
        if page >= data["pagination"]["total_pages"]:
            break
        page += 1

# ── 2. Read current whitelist.json ────────────────────────────────────────────
try:
    with open(WHITELIST_FILE) as f:
        current_entries: list[dict[str, str]] = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    current_entries = []

# Keyed by UUID so renames and removals are detected correctly.
current: dict[str, str] = {e["uuid"]: e["name"] for e in current_entries}

# ── 3. Diff — Authentik is the source of truth; regenerate entire file on any drift ─
if desired == current:
    print("whitelist up to date")
    sys.exit(0)

for name in sorted(desired[u] for u in desired if u not in current):
    print(f"{'[DRY RUN] would add' if DRY_RUN else 'Adding'} {name}")
for name in sorted(current[u] for u in current if u not in desired):
    print(f"{'[DRY RUN] would remove' if DRY_RUN else 'Removing'} {name}")
for u in (u for u in desired if u in current and desired[u] != current[u]):
    print(f"{'[DRY RUN] would rename' if DRY_RUN else 'Renaming'} {current[u]} -> {desired[u]}")

if DRY_RUN:
    sys.exit(0)

new_entries = [{"uuid": uuid, "name": name} for uuid, name in sorted(desired.items())]
with open(WHITELIST_FILE, "w") as f:
    json.dump(new_entries, f, indent=2)
print(f"wrote {WHITELIST_FILE}")

# ── 4. RCON reload ────────────────────────────────────────────────────────────
if offline:
    sys.exit(0)

conn: socket.socket | None
try:
    conn = socket.create_connection((RCON_HOST, RCON_PORT), timeout=10)
except OSError as e:
    print(f"RCON unavailable ({e}), file written; whitelist reloads on next server start")
    sys.exit(0)

_send(conn, 1, 3, RCON_PASS)
rid, _, _ = _recv(conn)
if rid == -1:
    sys.exit("RCON authentication failed")

rcon_cmd(conn, "whitelist reload")
print("whitelist reloaded via RCON")
conn.close()
