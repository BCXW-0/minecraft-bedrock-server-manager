#!/usr/bin/env python3
"""Merge Bedrock journal events and network endpoints into one live stream."""

import datetime as dt
import os
import re
import selectors
import signal
import subprocess
import sys
import time


JOURNAL_CMD = [
    "journalctl",
    "-f",
    "-u",
    "minecraft-bedrock-19132.service",
    "-o",
    "short-iso",
    "--no-pager",
]

TCPDUMP_CMD = [
    "tcpdump",
    "-ni",
    "any",
    "-nn",
    "-tttt",
    "-l",
    "-U",
    "(tcp port 10079) or (udp portrange 10079-10080) or (udp portrange 7550-7565)",
]
NETWORK_REPEAT_SECONDS = float(os.environ.get("NETWORK_REPEAT_SECONDS", "30"))
ENDPOINT_RE = re.compile(r"\b(?:In|Out)\s+IP(?:6)?\s+(\S+)\s+>\s+(\S+):")


def stamp() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="milliseconds")


def terminate(processes: list[subprocess.Popen]) -> None:
    for process in processes:
        if process.poll() is None:
            process.terminate()
    for process in processes:
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()


def main() -> int:
    journal = subprocess.Popen(
        JOURNAL_CMD,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )
    tcpdump = subprocess.Popen(
        TCPDUMP_CMD,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )
    processes = [journal, tcpdump]
    selector = selectors.DefaultSelector()
    selector.register(journal.stdout, selectors.EVENT_READ, "bds")
    selector.register(tcpdump.stdout, selectors.EVENT_READ, "net")
    endpoint_seen: dict[tuple[str, str], float] = {}

    def stop(_signum, _frame):
        terminate(processes)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    print(f"[{stamp()}] [observer] started", flush=True)

    try:
        while True:
            if all(process.poll() is not None for process in processes):
                break
            for key, _ in selector.select(timeout=1):
                line = key.fileobj.readline()
                if not line:
                    selector.unregister(key.fileobj)
                    continue
                line = line.rstrip("\r\n")
                if line:
                    if key.data == "net":
                        match = ENDPOINT_RE.search(line)
                        if match:
                            endpoint = (match.group(1), match.group(2))
                            now = time.monotonic()
                            previous = endpoint_seen.get(endpoint)
                            if previous is not None and now - previous < NETWORK_REPEAT_SECONDS:
                                continue
                            endpoint_seen[endpoint] = now
                            line = f"[endpoint] {line}"
                    print(f"[{stamp()}] [{key.data}] {line}", flush=True)
    finally:
        selector.close()
        terminate(processes)
        print(f"[{stamp()}] [observer] stopped", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
