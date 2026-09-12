#!/usr/bin/python3 -I
"""Root-only runtime intent primitive. No lock acquisition or public write CLI.

All callers must already hold the authoritative native flock descriptor. The
only command-line operations are fixed read-only check/inspect operations.
Constructor substitutions exist solely for isolated filesystem/network fixtures.
"""
from contextlib import contextmanager
import ctypes
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import stat
import subprocess
import sys
import time
import uuid

PARENT = "run/warp-egress-gateway"
NAME = "intentional-disconnect.json"
MAX_BYTES = 1024
ENV = {"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "HOME": "/root", "LANG": "C", "LC_ALL": "C"}


class IntentError(ValueError):
    """Only the bounded category escapes this implementation."""


def require(condition):
    if not condition:
        raise IntentError("unsafe_intent")


def decode(raw, maximum=MAX_BYTES):
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result)
            result[key] = value
        return result
    require(type(raw) is bytes and 0 < len(raw) <= maximum)
    try:
        return json.loads(raw, object_pairs_hook=pairs,
                          parse_constant=lambda _: require(False))
    except (ValueError, UnicodeError, RecursionError) as exc:
        raise IntentError("unsafe_intent") from exc


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True, allow_nan=False).encode("ascii")


def identity(info):
    # atime can change because of this read; it is not a content/metadata change.
    return (info.st_dev, info.st_ino, info.st_uid, info.st_gid, info.st_mode,
            info.st_nlink, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def main_fingerprint(routes):
    require(type(routes) is list and len(routes) == 1 and type(routes[0]) is dict)
    route = routes[0]
    require(route.get("dst") == "default" and type(route.get("dev")) is str
            and route.get("type", "unicast") == "unicast"
            and not {"nexthops", "nhid", "via"} & set(route))
    return hashlib.sha256(canonical(routes)).hexdigest()


def validate(value):
    require(type(value) is dict and set(value) == {"schema", "request_id", "created_at", "main_default_sha256"})
    require(type(value["schema"]) is int and value["schema"] == 1)
    request = value["request_id"]
    require(type(request) is str and len(request) == 36)
    try:
        parsed = uuid.UUID(request)
        require(parsed.version == 4 and parsed.variant == uuid.RFC_4122 and str(parsed) == request)
        require(type(value["created_at"]) is str and re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", value["created_at"]))
        datetime.datetime.strptime(value["created_at"], "%Y-%m-%dT%H:%M:%SZ")
    except (ValueError, TypeError) as exc:
        raise IntentError("unsafe_intent") from exc
    require(type(value["main_default_sha256"]) is str
            and re.fullmatch(r"[0-9a-f]{64}", value["main_default_sha256"]))
    return value


def rename_no_replace(parent, temporary):
    # Linux renameat2(RENAME_NOREPLACE): even an unexpected root-side competing
    # publisher cannot make us overwrite a newly appeared unsafe intent.
    libc = ctypes.CDLL(None, use_errno=True)
    rename = libc.renameat2
    rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(parent, temporary.encode("ascii"), parent, NAME.encode("ascii"), 1):
        raise OSError(ctypes.get_errno(), "intent publication failed")


class IntentStore:
    def __init__(self, *, root=Path("/"), uid=0, gid=0):
        self.root, self.uid, self.gid = root, uid, gid

    def metadata(self, info, *, directory=False, mode=None):
        require((stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode))
                and info.st_uid == self.uid and info.st_gid == self.gid
                and not stat.S_IMODE(info.st_mode) & 0o022
                and (mode is None or stat.S_IMODE(info.st_mode) == mode))
        if not directory:
            require(info.st_nlink == 1)

    @contextmanager
    def directory(self, relative):
        fds = []
        try:
            fd = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            fds.append(fd)
            self.metadata(os.fstat(fd), directory=True)
            for part in Path(relative).parts:
                fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                fds.append(fd)
                self.metadata(os.fstat(fd), directory=True)
            yield fd
        except OSError as exc:
            raise IntentError("unsafe_intent") from exc
        finally:
            for fd in reversed(fds):
                os.close(fd)

    def locked(self, parent, fd, *, exclusive=False):
        with self.directory(PARENT) as current:
            require((os.fstat(current).st_dev, os.fstat(current).st_ino) ==
                    (os.fstat(parent).st_dev, os.fstat(parent).st_ino))
        self.metadata(os.fstat(parent), directory=True, mode=0o700)
        held, disk = os.fstat(fd), os.stat("admin-mutation.lock", dir_fd=parent, follow_symlinks=False)
        self.metadata(held, mode=0o600)
        self.metadata(disk, mode=0o600)
        require((held.st_dev, held.st_ino) == (disk.st_dev, disk.st_ino))
        # fdinfo proves THIS open-file-description holds flock, not merely that
        # some process holds a lock on the inode. Never acquire/convert/unlock it.
        with open(f"/proc/self/fdinfo/{fd}", encoding="ascii") as stream:
            lines = stream.read(4096).splitlines()
        modes = {line.split()[4] for line in lines if re.match(r"lock:\s+[0-9]+:\s+FLOCK\s+ADVISORY\s+(READ|WRITE)\s", line)}
        require("WRITE" in modes or (not exclusive and "READ" in modes))

    def read_at(self, parent):
        try:
            fd = os.open(NAME, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
        except FileNotFoundError:
            return None
        try:
            before = os.fstat(fd)
            self.metadata(before, mode=0o600)
            require(0 < before.st_size <= MAX_BYTES)
            raw = os.read(fd, MAX_BYTES + 1)
            after = os.fstat(fd)
            disk = os.stat(NAME, dir_fd=parent, follow_symlinks=False)
            require(identity(before) == identity(after) == identity(disk) and len(raw) == before.st_size)
            return validate(decode(raw))
        finally:
            os.close(fd)

    def read(self, lock_fd):
        with self.directory(PARENT) as parent:
            self.locked(parent, lock_fd)
            value = self.read_at(parent)
            self.locked(parent, lock_fd)
            return value

    def create(self, lock_fd, request_id, main_routes):
        """Internal future lifecycle primitive, not reachable from helper/CLI."""
        with self.directory(PARENT) as parent:
            self.locked(parent, lock_fd, exclusive=True)
            if self.read_at(parent) is not None:
                return False
            value = validate({"schema": 1, "request_id": request_id,
                              "created_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                              "main_default_sha256": main_fingerprint(main_routes)})
            raw = canonical(value) + b"\n"
            require(len(raw) <= MAX_BYTES)
            temporary = ".intent-" + uuid.uuid4().hex
            fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=parent)
            try:
                os.fchown(fd, self.uid, self.gid)
                os.fchmod(fd, 0o600)
                self.metadata(os.fstat(fd), mode=0o600)
                require(os.write(fd, raw) == len(raw))
                os.fsync(fd)
                self.locked(parent, lock_fd, exclusive=True)
                rename_no_replace(parent, temporary)
                os.fsync(parent)
            finally:
                os.close(fd)
                try:
                    os.unlink(temporary, dir_fd=parent)
                except FileNotFoundError:
                    pass
            return True

    def config(self):
        keys = {"WARP_IF", "UPLINK_IF", "TRANSIT_IF", "ROUTING_TABLE_ID",
                "ROUTING_TABLE_NAME", "SOURCE_RULE_PRIORITY", "INGRESS_RULE_PRIORITY"}
        with self.directory("etc/warp-egress-gateway") as parent:
            fd = os.open("warp-gateway.env", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
            try:
                before = os.fstat(fd)
                self.metadata(before)
                require(0 < before.st_size <= 65536)
                raw = os.read(fd, 65537)
                require(identity(before) == identity(os.fstat(fd)) and len(raw) == before.st_size)
            finally:
                os.close(fd)
        result = {}
        for line in raw.decode("utf-8", errors="strict").splitlines():
            key, separator, value = line.strip().partition("=")
            if separator and key in keys:
                require(key not in result)
                if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                    value = value[1:-1]
                require(re.fullmatch(r"[A-Za-z0-9_.-]{1,32}", value))
                result[key] = value
        require(set(result) == keys)
        roles = [result[key] for key in ("WARP_IF", "UPLINK_IF", "TRANSIT_IF")]
        require(len(set(roles)) == 3 and all(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,14}", role) and role != "lo" for role in roles))
        require(result["SOURCE_RULE_PRIORITY"] == "100" and result["INGRESS_RULE_PRIORITY"] == "110"
                and result["ROUTING_TABLE_NAME"] == "warp_gateway")
        table = result["ROUTING_TABLE_ID"]
        require(re.fullmatch(r"[1-9][0-9]{0,9}", table) and int(table) <= 4294967295 and int(table) not in {253, 254, 255})
        return result

    def disconnected(self, lock_fd, *, command=None):
        """Read-only postconditions; absence is proven by successful JSON queries."""
        record = self.read(lock_fd)
        require(record is not None)
        config = self.config()
        query = command or query_json
        warp, uplink, transit = (config[k] for k in ("WARP_IF", "UPLINK_IF", "TRANSIT_IF"))
        table = int(config["ROUTING_TABLE_ID"])
        links = query(("/usr/sbin/ip", "-j", "link", "show"))
        require(type(links) is list and links and all(type(x) is dict and type(x.get("ifname")) is str for x in links))
        require(warp not in [link["ifname"] for link in links] and uplink in [link["ifname"] for link in links])
        for unit in (f"wg-quick@{warp}.service", "warp-gateway.service"):
            # Query succeeded and the unit is stopped, not activating/reloading.
            require(query(("/usr/bin/systemctl", "show", "--property=ActiveState", "--value", unit)) in ("inactive", "failed"))
        rules = query(("/usr/sbin/ip", "-j", "-N", "-4", "rule", "show"))
        routes = query(("/usr/sbin/ip", "-j", "-N", "-4", "route", "show", "table", "all"))
        require(type(rules) is list and type(routes) is list)
        def table_number(value):
            aliases = {"main": 254, "local": 255, "default": 253, "warp_gateway": table}
            if type(value) is str:
                if value in aliases:
                    return aliases[value]
                require(re.fullmatch(r"[1-9][0-9]{0,9}", value))
                value = int(value)
            require(type(value) is int and 1 <= value <= 4294967295)
            return value
        for rule in rules:
            require(type(rule) is dict and type(rule.get("priority")) is int)
            require(rule["priority"] not in (100, 110) and table_number(rule.get("table")) != table)
        for route in routes:
            require(type(route) is dict and type(route.get("dst")) is str)
            require(table_number(route.get("table", 254)) != table and route.get("dev") != warp)
            require("dev" not in route or type(route["dev"]) is str)
        main = query(("/usr/sbin/ip", "-j", "-4", "route", "show", "table", "main", "default"))
        require(main_fingerprint(main) == record["main_default_sha256"] and main[0]["dev"] == uplink)
        nft = query(("/usr/sbin/nft", "-j", "list", "table", "inet", "warp_gateway"))
        require(type(nft) is dict and type(nft.get("nftables")) is list)
        chains, forward_rules = [], []
        for item in nft["nftables"]:
            require(type(item) is dict)
            chain, rule = item.get("chain"), item.get("rule")
            if chain is not None:
                require(type(chain) is dict)
                if chain.get("hook") == "forward": chains.append(chain)
            if rule is not None:
                require(type(rule) is dict)
                if rule.get("chain") == "forward": forward_rules.append(rule)
        require(any(c.get("name") == "forward" and c.get("family") == "inet"
                    and c.get("table") == "warp_gateway" and c.get("type") == "filter"
                    and c.get("prio") == 0 for c in chains))
        expected = [{"match": {"op": "==", "left": {"meta": {"key": "iifname"}}, "right": transit}},
                    {"match": {"op": "!=", "left": {"meta": {"key": "oifname"}}, "right": warp}}, {"drop": None}]
        found = False
        for rule in forward_rules:
            require(rule.get("family") == "inet" and rule.get("table") == "warp_gateway")
            expressions = rule.get("expr")
            require(type(expressions) is list and all(type(e) is dict for e in expressions))
            semantic = [e for e in expressions if set(e) != {"counter"}]
            if rule.get("comment") == "WARP_KILL_SWITCH":
                require(semantic == expected and not found)
                found = True
            elif not found:
                require(semantic and semantic[-1] == {"drop": None}
                        and all(set(e) == {"match"} for e in semantic[:-1]))
        require(found)
        # Revalidate intent/config after the coherent observation before success.
        require(self.read(lock_fd) == record and self.config() == config)
        return True


def query_json(argv):
    """Fixed read-only argv only; bound runtime and stdout while draining it."""
    deadline = time.monotonic() + 3
    with subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, cwd="/", env=ENV, close_fds=True) as process:
        output = bytearray()
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ)
                while selector.get_map():
                    require(time.monotonic() < deadline)
                    for key, _ in selector.select(min(0.1, max(0, deadline - time.monotonic()))):
                        chunk = os.read(key.fd, 4096)
                        if not chunk:
                            selector.unregister(key.fd)
                        output.extend(chunk)
                        require(len(output) <= 262144)
            require(process.wait(timeout=max(0.01, deadline - time.monotonic())) == 0)
        finally:
            if process.poll() is None:
                process.kill()
            process.wait()
    if argv[0] == "/usr/bin/systemctl":
        return bytes(output).decode("ascii").strip()
    return decode(bytes(output), 262144)


def main():
    # Only root-owned shell callbacks pass the inherited descriptor. No caller
    # path, environment, interface, command, write or clear operation is accepted.
    if os.geteuid() != 0 or len(sys.argv) != 3 or sys.argv[1] not in {"check", "inspect"} or not re.fullmatch(r"[0-9]{1,4}", sys.argv[2]):
        return 64
    try:
        store, fd = IntentStore(), int(sys.argv[2])
        if sys.argv[1] == "inspect":
            store.disconnected(fd)
            print("intentionally_disconnected")
        else:
            print("absent" if store.read(fd) is None else "valid")
        return 0
    except (OSError, IntentError, ValueError, subprocess.TimeoutExpired):
        print("unsafe")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
