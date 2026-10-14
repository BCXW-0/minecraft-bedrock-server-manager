#!/usr/bin/env python3
import asyncio
import logging
import signal
import struct

LISTEN = ("0.0.0.0", 10079)
GAME = ("127.0.0.1", 19132)
MAGIC = bytes.fromhex("00ffff00fefefefefdfdfdfd12345678")
MOTD = "我的世界11备份"
VERSION = "1.26.51"
GUID = 0x4D43504553544154

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("raknet-udp-proxy")

def is_ping(data):
    return len(data) >= 33 and data[0] == 1 and data[9:25] == MAGIC

def pong(data):
    fields = ("MCPE", MOTD, "2193", VERSION, "0", "10", str(GUID), MOTD, "Survival", "1", "10079", "10079", "0")
    ad = (";".join(fields) + ";").encode()
    return b"\x1c" + data[1:9] + struct.pack(">Q", GUID) + MAGIC + struct.pack(">H", len(ad)) + ad

class Backend(asyncio.DatagramProtocol):
    def __init__(self, proxy, peer):
        self.proxy, self.peer = proxy, peer
    def datagram_received(self, data, _addr):
        if self.proxy.front: self.proxy.front.sendto(data, self.peer)

class Proxy(asyncio.DatagramProtocol):
    def __init__(self, loop):
        self.loop, self.front, self.backends = loop, None, []
    def connection_made(self, transport):
        self.front = transport
        log.info("UDP %s: RakNet Ping local, other packets -> %s:%s", LISTEN[1], *GAME)
    def datagram_received(self, data, peer):
        if is_ping(data):
            self.front.sendto(pong(data), peer)
            log.info("RakNet Ping from %s", peer)
            return
        self.loop.create_task(self.forward(data, peer))
    async def forward(self, data, peer):
        transport, _ = await self.loop.create_datagram_endpoint(lambda: Backend(self, peer), remote_addr=GAME)
        self.backends.append(transport)
        transport.sendto(data)
    def close(self):
        for transport in self.backends: transport.close()
        if self.front: self.front.close()

async def main():
    loop = asyncio.get_running_loop()
    transport, proxy = await loop.create_datagram_endpoint(lambda: Proxy(loop), local_addr=LISTEN)
    stop = asyncio.Event()
    for sig in (signal.SIGINT, signal.SIGTERM): loop.add_signal_handler(sig, stop.set)
    await stop.wait()
    proxy.close(); transport.close()

asyncio.run(main())
