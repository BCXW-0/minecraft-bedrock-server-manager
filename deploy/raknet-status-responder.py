#!/usr/bin/env python3
"""Minimal RakNet unconnected-ping responder for Bedrock server lists.

This service only answers RakNet offline pings; it does not accept game sessions.
"""

import os
import socket
import struct
import time


MAGIC = bytes.fromhex("00ffff00fefefefefdfdfdfd12345678")
UNCONNECTED_PING = 0x01
UNCONNECTED_PONG = 0x1C
PORT = int(os.environ.get("RAKNET_STATUS_PORT", "19132"))
GAME_PORT = int(os.environ.get("RAKNET_GAME_PORT", "10079"))
MOTD = os.environ.get("RAKNET_STATUS_MOTD", "我的世界11备份")
VERSION = os.environ.get("RAKNET_STATUS_VERSION", "1.26.51")
ONLINE = os.environ.get("RAKNET_STATUS_ONLINE", "0")
MAX_PLAYERS = os.environ.get("RAKNET_STATUS_MAX", "10")
SERVER_GUID = 0x4D43504553544154


def advertisement() -> bytes:
    fields = [
        "MCPE", MOTD, "2193", VERSION, ONLINE, MAX_PLAYERS,
        str(SERVER_GUID), MOTD,
        "Survival", "1", str(GAME_PORT), str(GAME_PORT), "0",
    ]
    return (";".join(fields) + ";").encode()


def main() -> None:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("0.0.0.0", PORT))
    pong_ad = advertisement()
    print(f"listening on UDP {PORT}", flush=True)
    while True:
        packet, address = sock.recvfrom(2048)
        if len(packet) >= 33 and packet[0] == UNCONNECTED_PING and packet[9:25] == MAGIC:
            timestamp = packet[1:9]
            response = bytes([UNCONNECTED_PONG]) + timestamp + struct.pack(">Q", SERVER_GUID) + MAGIC
            response += struct.pack(">H", len(pong_ad)) + pong_ad
            sock.sendto(response, address)


if __name__ == "__main__":
    main()
