"""Trusted LAN routes, independent of Apple's Windows USB discovery service.

Only addresses and device identities are persisted. Apple pairing records are read
in memory from their existing system locations, and never sent to the renderer.
"""

import asyncio
import ipaddress
import os
import threading
import time
from contextlib import suppress
from pathlib import Path

from pymobiledevice3.lockdown import TcpLockdownClient, _known_lockdown_pair_records
from pymobiledevice3.service_connection import ServiceConnection

LOCK = threading.RLock()
SAVED = {}
ROUTES = {}
LAST_BROWSE = 0


class WiFiServiceError(RuntimeError):
    pass


def address(value):
    value = str(value).strip()
    try:
        ip = ipaddress.ip_address(value)
    except ValueError:
        raise ValueError(
            "Enter the IP address from iPhone Settings → Wi-Fi → ⓘ → IP Address."
        ) from None
    if (
        not (ip.is_private or ip.is_link_local)
        or ip.is_loopback
        or ip.is_unspecified
        or ip.is_multicast
    ):
        raise ValueError("Use your iPhone’s local network IP address.")
    return str(ip)


def configure(rows):
    with LOCK:
        SAVED.clear()
        ROUTES.clear()
        for row in rows:
            try:
                SAVED[row["id"]] = {**row, "address": address(row["address"])}
            except (KeyError, ValueError, TypeError):
                continue


def route(udid):
    with LOCK:
        row = ROUTES.get(udid, SAVED.get(udid))
        return {"address": row["address"], "udid": udid} if row else None


def select(udid, row):
    with LOCK:
        # A USB connection takes precedence over a saved Wi-Fi route.
        ROUTES[udid] = row


class WiFiLockdownClient(TcpLockdownClient):
    async def start_heartbeat(self):
        """Exchange Marco/Polo before opening AFC, and retain it for the session.

        Recent iOS accepts lockdown authentication but tears down other wireless
        services until the trusted host responds to this connection handshake.
        """
        service = await asyncio.wait_for(
            super().start_lockdown_service("com.apple.mobile.heartbeat"), 10
        )
        self._heartbeat_service = service
        try:
            await asyncio.wait_for(service.recv_plist(), 5)
            await service.send_plist({"Command": "Polo"})
        except BaseException:
            await service.close()
            self._heartbeat_service = None
            raise

        async def keep_alive():
            try:
                while True:
                    await service.recv_plist()
                    await service.send_plist({"Command": "Polo"})
            except Exception:
                # A lost heartbeat is reflected by the next device operation.
                pass

        self._heartbeat_task = asyncio.create_task(keep_alive())

    async def close(self):
        task = getattr(self, "_heartbeat_task", None)
        if task:
            task.cancel()
            with suppress(asyncio.CancelledError):
                await task
            self._heartbeat_task = None
        heartbeat = getattr(self, "_heartbeat_service", None)
        if heartbeat:
            await heartbeat.close()
            self._heartbeat_service = None
        await super().close()

    async def start_lockdown_service(self, name, include_escrow_bag=False):
        try:
            return await asyncio.wait_for(
                super().start_lockdown_service(name, include_escrow_bag), 12
            )
        except Exception as e:
            raise WiFiServiceError(
                "Your iPhone is connected over Wi-Fi, but its "
                + name
                + " service could not open. Keep it unlocked and retry. If this continues, "
                "reconnect the USB cable; Phosphor will switch automatically. ("
                + type(e).__name__
                + ")"
            ) from e


async def connect(value, expected=None):
    host = address(value)
    records = await _known_lockdown_pair_records(expected, None)
    if not records:
        raise ValueError("Trust this PC with a USB cable once before connecting over Wi-Fi.")
    cache = (
        Path(os.environ.get("PHOSPHOR_DATA", Path.home() / "AppData" / "Roaming" / "Phosphor"))
        / "pairing-cache"
    )
    cache.mkdir(parents=True, exist_ok=True)
    for record in records[:8]:
        service = await asyncio.wait_for(
            ServiceConnection.create_using_tcp(host, 62078, keep_alive=True), 4
        )
        client = None
        try:
            client = await asyncio.wait_for(
                WiFiLockdownClient.create(
                    service,
                    hostname=host,
                    identifier=expected,
                    pair_record=record,
                    pairing_records_cache_folder=cache,
                    autopair=False,
                    keep_alive=True,
                ),
                5,
            )
            if client.paired:
                if expected and client.udid != expected:
                    raise ValueError(
                        "This IP address now belongs to a different device. Reconnect the intended iPhone."
                    )
                await client.start_heartbeat()
                return client
        except BaseException:
            if client:
                await client.close()
            else:
                await service.close()
            raise
        if client:
            await client.close()
        else:
            await service.close()
    raise ValueError(
        "This iPhone has not trusted this PC. Connect by USB, unlock it, and tap Trust."
    )


def describe(client, host):
    info = client.short_info
    return {
        "id": client.udid,
        "address": address(host),
        "connection": "Network",
        "name": info.get("DeviceName") or "iOS device",
        "model": info.get("ProductType"),
        "ios": info.get("ProductVersion"),
        "paired": True,
    }


async def attach(host):
    host = address(host)
    with LOCK:
        expected = next((row["id"] for row in SAVED.values() if row["address"] == host), None)
    client = await connect(host, expected)
    try:
        row = describe(client, host)
        from pymobiledevice3.services.afc import AfcService

        try:
            async with AfcService(client) as afc:
                await asyncio.wait_for(afc.listdir("/"), 5)
            row["filesAvailable"] = True
        except Exception as e:
            row["filesAvailable"] = False
            row["serviceWarning"] = (
                "Wi-Fi connection verified. File access is unavailable right now. "
                "Keep your iPhone unlocked and retry, or reconnect USB. (" + type(e).__name__ + ")"
            )
        with LOCK:
            SAVED[row["id"]] = row
            ROUTES[row["id"]] = row
        return row
    finally:
        await client.close()


async def discover(excluded, allow_bonjour=True):
    global LAST_BROWSE
    with LOCK:
        saved = list({**SAVED, **{k: v for k, v in ROUTES.items() if v}}.values())
        # SDK Bonjour discovery authenticates before yielding a device identity.
        # Pause it entirely while a job owns a session, including unknown adverts.
        browse = allow_bonjour and time.monotonic() - LAST_BROWSE > 30
        if browse:
            LAST_BROWSE = time.monotonic()

    async def check(row):
        if row["id"] in excluded:
            return None
        client = None
        try:
            client = await asyncio.wait_for(connect(row["address"], row["id"]), 7)
            result = {**row, **describe(client, row["address"])}
            select(result["id"], result)
            return result
        except Exception:
            return None
        finally:
            if client:
                await client.close()

    async def bonjour():
        from pymobiledevice3.lockdown import get_mobdev2_lockdowns

        found = []
        if not browse:
            return found
        try:
            async for host, client in get_mobdev2_lockdowns(only_paired=True, timeout=2):
                try:
                    if client.paired and client.udid not in excluded:
                        row = describe(client, host)
                        found.append(row)
                finally:
                    await client.close()
        except Exception:
            pass
        return found

    results = await asyncio.gather(*(check(r) for r in saved[:8]), bonjour())
    rows = {r["id"]: r for r in results[:-1] if r}
    for row in results[-1]:
        rows[row["id"]] = row
        select(row["id"], row)
    return list(rows.values())


def install_cli_route(payload):
    """Bind the helper's dependency injection to the selected, authenticated route.

    Called before SDK command modules are imported. The child receives no keys;
    it resolves the existing Apple trust record itself.
    """
    from typing import Annotated, Optional
    import typer
    from typer_injector import Depends
    from pymobiledevice3.cli import cli_common as common
    from pymobiledevice3.lockdown import LockdownClient
    from pymobiledevice3.lockdown_service_provider import LockdownServiceProvider

    host = address(payload["address"])
    expected = payload["udid"]

    def provider(
        udid: Annotated[Optional[str], typer.Option(help="Selected device identity.")] = None,
    ):
        if udid != expected:
            raise ValueError("The selected Wi-Fi device changed. Refresh and retry.")
        return common.cli_loop.run_until_complete(connect(host, expected))

    common.ServiceProviderDep = Annotated[LockdownServiceProvider, Depends(provider)]
    common.NoAutoPairServiceProviderDep = Annotated[LockdownServiceProvider, Depends(provider)]
    common.LockdownClientDep = Annotated[LockdownClient, Depends(provider)]
    common.NoAutoPairLockdownClientDep = Annotated[LockdownClient, Depends(provider)]
