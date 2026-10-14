#!/usr/bin/env python3
"""Proxy the public Bedrock NetherNet ports to loopback listeners."""

import asyncio
import logging
import signal
import time


TCP_LISTEN = ("0.0.0.0", 19132)
TCP_TARGET = ("127.0.0.1", 29132)
UDP_LISTEN = ("0.0.0.0", 7551)
UDP_TARGET = ("127.0.0.1", 27551)
UDP_IDLE_SECONDS = 180

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
LOG = logging.getLogger("minecraft-bedrock-forward")


async def copy_stream(reader, writer):
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except (ConnectionError, asyncio.IncompleteReadError):
        pass


async def proxy_tcp(client_reader, client_writer):
    peer = client_writer.get_extra_info("peername")
    target_writer = None
    try:
        target_reader, target_writer = await asyncio.open_connection(*TCP_TARGET)
        await asyncio.gather(
            copy_stream(client_reader, target_writer),
            copy_stream(target_reader, client_writer),
        )
    except (ConnectionError, OSError) as exc:
        LOG.debug("TCP %s closed: %s", peer, exc)
    finally:
        for writer in (client_writer, target_writer):
            if writer is not None:
                writer.close()
                try:
                    await writer.wait_closed()
                except (ConnectionError, OSError):
                    pass


class UdpBackend(asyncio.DatagramProtocol):
    def __init__(self, frontend, client):
        self.frontend = frontend
        self.client = client
        self.transport = None
        self.last_seen = time.monotonic()

    def connection_made(self, transport):
        self.transport = transport

    def datagram_received(self, data, _addr):
        self.last_seen = time.monotonic()
        if self.frontend.transport is not None:
            self.frontend.transport.sendto(data, self.client)

    def error_received(self, exc):
        LOG.debug("UDP backend %s: %s", self.client, exc)

    def connection_lost(self, _exc):
        self.frontend.clients.pop(self.client, None)


class UdpFrontend(asyncio.DatagramProtocol):
    def __init__(self, loop):
        self.loop = loop
        self.transport = None
        self.clients = {}
        self.pending = {}
        self.creating = set()

    def connection_made(self, transport):
        self.transport = transport
        LOG.info("UDP listening on %s:%s -> %s:%s", *UDP_LISTEN, *UDP_TARGET)

    def datagram_received(self, data, client):
        self.loop.create_task(self.dispatch(bytes(data), client))

    async def dispatch(self, data, client):
        entry = self.clients.get(client)
        if entry is not None:
            _transport, backend = entry
            backend.last_seen = time.monotonic()
            _transport.sendto(data)
            return

        self.pending[client] = data
        if client in self.creating:
            return
        self.creating.add(client)
        try:
            transport, backend = await self.loop.create_datagram_endpoint(
                lambda: UdpBackend(self, client),
                local_addr=("127.0.0.1", 0),
                remote_addr=UDP_TARGET,
            )
            self.clients[client] = (transport, backend)
            first = self.pending.pop(client, None)
            if first is not None:
                transport.sendto(first)
            LOG.info("UDP client connected: %s", client)
        except (ConnectionError, OSError) as exc:
            self.pending.pop(client, None)
            LOG.warning("UDP backend for %s failed: %s", client, exc)
        finally:
            self.creating.discard(client)

    async def reap_idle(self):
        while True:
            await asyncio.sleep(30)
            cutoff = time.monotonic() - UDP_IDLE_SECONDS
            for client, (transport, backend) in list(self.clients.items()):
                if backend.last_seen < cutoff:
                    LOG.info("UDP client expired: %s", client)
                    transport.close()
                    self.clients.pop(client, None)

    def close(self):
        if self.transport is not None:
            self.transport.close()
        for transport, _backend in self.clients.values():
            transport.close()
        self.clients.clear()


async def run():
    loop = asyncio.get_running_loop()
    tcp_server = await asyncio.start_server(proxy_tcp, *TCP_LISTEN)
    udp_transport, udp_frontend = await loop.create_datagram_endpoint(
        lambda: UdpFrontend(loop),
        local_addr=UDP_LISTEN,
    )
    reaper = asyncio.create_task(udp_frontend.reap_idle())
    stopped = asyncio.Event()

    def stop():
        stopped.set()

    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop)

    LOG.info("TCP forwarding %s:%s -> %s:%s", *TCP_LISTEN, *TCP_TARGET)
    LOG.info("UDP forwarding %s:%s -> %s:%s", *UDP_LISTEN, *UDP_TARGET)
    await stopped.wait()
    reaper.cancel()
    tcp_server.close()
    await tcp_server.wait_closed()
    udp_frontend.close()
    udp_transport.close()
    await asyncio.gather(reaper, return_exceptions=True)


if __name__ == "__main__":
    try:
        asyncio.run(run())
    except KeyboardInterrupt:
        pass
