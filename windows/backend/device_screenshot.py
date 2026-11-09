"""DVT capture plus a separate, explicit signed developer-support preparation.

Capture/check never prepare an image. Prepare never enables Developer Mode,
pairs, reboots, or starts a daemon. Selected trusted USB/Wi-Fi CoreDeviceProxy
connections can use a scoped userspace tunnel; no kernel interface is created.
"""

import asyncio
import io
import os
import uuid
import threading
from contextlib import asynccontextmanager, suppress
from pathlib import Path

import wireless

CAPTURE_GATE = threading.Lock()


def check_runtime():
    """Load real developer dependencies without opening a device or profile."""
    from importlib.metadata import version
    import pyimg4
    from pymobiledevice3.services.mobile_image_mounter import MobileImageMounterService
    from pymobiledevice3.services.cryptexd import CryptexdService
    from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
    from pymobiledevice3.services.dvt.instruments.screenshot import Screenshot
    from pymobiledevice3.remote.tunnel_service import CoreDeviceTunnelProxy
    from pymobiledevice3.remote.userspace_tunnel import UserspaceDialPlane
    from pymobiledevice3.remote.remote_service_discovery import RemoteServiceDiscoveryService
    from developer_support import secure_tss_class

    if pyimg4.__version__ != version("pyimg4"):
        raise ScreenshotError("Developer image package metadata does not match its code.")
    services = (
        MobileImageMounterService,
        CryptexdService,
        DvtProvider,
        Screenshot,
        CoreDeviceTunnelProxy,
        UserspaceDialPlane,
        RemoteServiceDiscoveryService,
        secure_tss_class(),
    )
    return {
        "status": "ready",
        "pyimg4Version": pyimg4.__version__,
        "services": [service.__name__ for service in services],
        "connectsToDevice": False,
        "changesDeviceSettings": False,
    }


async def _close(provider):
    with suppress(Exception):
        await asyncio.wait_for(provider.close(), 3)


async def _run_cancellable(operation, job, timeout):
    task = asyncio.create_task(operation)

    async def watch():
        while True:
            if job:
                job.check()
            await asyncio.sleep(0.2)

    watcher = asyncio.create_task(watch()) if job else None
    try:
        async with asyncio.timeout(timeout):
            if watcher:
                done, _ = await asyncio.wait((task, watcher), return_when=asyncio.FIRST_COMPLETED)
                if watcher in done:
                    await watcher
            return await task
    finally:
        if watcher:
            watcher.cancel()
            with suppress(asyncio.CancelledError, InterruptedError):
                await watcher
        if not task.done():
            task.cancel()
            with suppress(asyncio.CancelledError):
                await task
        else:
            with suppress(asyncio.CancelledError, Exception):
                task.result()


class ScreenshotError(ValueError):
    pass


async def _connect(udid):
    from pymobiledevice3.lockdown import create_using_usbmux

    route = wireless.route(udid)
    return (
        await wireless.connect(route["address"], udid)
        if route
        else await create_using_usbmux(udid, autopair=False)
    )


async def inspect_prerequisites(lockdown, transport="USB"):
    from pymobiledevice3.services.mobile_image_mounter import (
        MobileImageMounterService,
        image_type_for_device,
    )

    version = str(getattr(lockdown, "product_version", ""))
    major = int(version.split(".")[0]) if version.split(".")[0].isdigit() else 0
    mode = True if major and major < 16 else None
    mounted = None
    image_type = None
    try:
        image_type = image_type_for_device(lockdown)
        async with MobileImageMounterService(lockdown) as mounter:
            if major >= 16:
                try:
                    value = await asyncio.wait_for(mounter.query_developer_mode_status(), 4)
                    mode = value if isinstance(value, bool) else None
                except Exception:
                    pass
            try:
                mounted = bool(await asyncio.wait_for(mounter.is_image_mounted(image_type), 4))
            except Exception:
                pass
    except Exception:
        pass
    if mounted is not True:
        try:
            from pymobiledevice3.services.mobile_image_mounter import uses_cryptex_image

            if uses_cryptex_image(lockdown):
                from pymobiledevice3.services.cryptexd import CryptexdService

                installed = await asyncio.wait_for(CryptexdService(lockdown)._installed_ddi(), 5)
                if installed is not None:
                    mounted = True
        except Exception:
            pass
    requirements = [
        {
            "id": "developerMode",
            "label": "Developer Mode",
            "state": "ready" if mode is True else "missing" if mode is False else "unknown",
            "instruction": "Enable Developer Mode yourself in iPhone Settings → Privacy & Security → Developer Mode. iOS may require a restart; Phosphor never changes this setting.",
        },
        {
            "id": "developerImage",
            "label": "Developer support image",
            "state": "ready" if mounted is True else "missing" if mounted is False else "unknown",
            "instruction": "Use Prepare screenshots to download and install compatible signed developer support. This happens only when you choose Prepare; capture and availability checks never install it.",
        },
    ]
    missing = [
        requirement["label"] for requirement in requirements if requirement["state"] == "missing"
    ]
    blocked = bool(missing)
    message = (
        ("Screenshot is unavailable: " + ", ".join(missing) + " is not ready.")
        if blocked
        else (
            "Developer prerequisites are ready. Phosphor will use the DVT screenshot service."
            if mode is True and mounted is True
            else "Developer prerequisites could not be fully verified. The screenshot service may still be unavailable."
        )
    )
    if major >= 17:
        message += " iOS 17 and later may also require an RSD developer tunnel. If Wi-Fi cannot provide one, connect USB or use an existing configured tunnel."
    return {
        "status": (
            "blocked"
            if blocked
            else "eligible" if mode is True and mounted is True else "unverified"
        ),
        "canAttempt": not blocked,
        "developerMode": mode,
        "developerImageMounted": mounted,
        "imageType": image_type,
        "ios": version,
        "transport": transport,
        "route": "DVT",
        "tunnelRequired": major >= 17,
        "requirements": requirements,
        "message": message,
        "changesDeviceSettings": False,
    }


async def _capabilities(udid):
    lockdown = await _connect(udid)
    try:
        return await _inspect_connection(lockdown, udid, "Wi-Fi" if wireless.route(udid) else "USB")
    finally:
        await _close(lockdown)


def screenshot_capabilities(udid):
    if not CAPTURE_GATE.acquire(timeout=1):
        raise ScreenshotError(
            "Another developer operation is running. Wait for it to finish before checking screenshots."
        )
    try:
        return asyncio.run(asyncio.wait_for(_capabilities(udid), 30))
    finally:
        CAPTURE_GATE.release()


async def _inspect_connection(lockdown, udid, transport):
    result = await inspect_prerequisites(lockdown, transport)
    try:
        from pymobiledevice3.services.mobile_image_mounter import CRYPTEX_IMAGE_MIN_VERSION
        from packaging.version import Version

        if (
            result["developerMode"] is True
            and result["developerImageMounted"] is not True
            and Version(lockdown.product_version) >= CRYPTEX_IMAGE_MIN_VERSION
        ):
            async with developer_provider(udid, lockdown) as provider:
                remote = await inspect_prerequisites(provider, transport)
                if remote["developerImageMounted"] is True:
                    return remote
    except Exception:
        pass
    return result


async def _dvt_bytes(provider):
    from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
    from pymobiledevice3.services.dvt.instruments.screenshot import Screenshot

    async with DvtProvider(provider) as dvt, Screenshot(dvt) as screenshot:
        return await asyncio.wait_for(screenshot.get_screenshot(), 20)


def _service_unavailable(error):
    while error is not None:
        if type(error).__name__ in (
            "InvalidServiceError",
            "StartServiceError",
            "RSDRequiredError",
            "DeveloperModeIsNotEnabledError",
        ):
            return True
        error = error.__cause__
    return False


@asynccontextmanager
async def developer_provider(udid, lockdown, job=None):
    from pymobiledevice3.tunneld.api import get_tunneld_device_by_udid

    rsd = None
    try:
        rsd = await asyncio.wait_for(get_tunneld_device_by_udid(udid), 8)
    except Exception:
        pass
    if rsd is not None:
        try:
            if getattr(rsd, "udid", None) != udid:
                raise ScreenshotError(
                    "The developer tunnel belongs to a different device. Reconnect the selected iPhone."
                )
            if job:
                job.check()
                job.progress(None, "Using the existing developer tunnel")
            yield rsd
        finally:
            await _close(rsd)
        return
    from pymobiledevice3.remote import tunnel_service
    from pymobiledevice3.remote.userspace_tunnel import UserspaceDialPlane
    from pymobiledevice3.remote.remote_service_discovery import RemoteServiceDiscoveryService

    if job:
        job.check()
        job.progress(None, "Opening a temporary developer tunnel for the selected iPhone")
    try:
        proxy = await asyncio.wait_for(tunnel_service.CoreDeviceTunnelProxy.create(lockdown), 12)
    except Exception:
        raise ScreenshotError(
            "The selected connection cannot open Apple’s developer tunnel. Connect this iPhone by USB and retry. On older iOS versions, use an existing configured RSD tunnel."
        ) from None
    previous = tunnel_service.USE_USERSPACE_TUNNEL
    # The pinned SDK's factory flag selects its pure Python network stack. All
    # Phosphor prepare/capture calls hold CAPTURE_GATE; no TLS or HTTP globals
    # change, and no kernel interface, daemon, or new pairing is created.
    tunnel_service.USE_USERSPACE_TUNNEL = True
    try:
        async with proxy.start_tcp_tunnel() as tunnel:
            tunnel.client.tun.set_peer(tunnel.address)
            async with UserspaceDialPlane(tunnel.client.tun, tunnel.address) as dial:
                rsd = RemoteServiceDiscoveryService(
                    (tunnel.address, tunnel.port),
                    open_connection=dial.dial,
                    auxiliary_metadata=tunnel.auxiliary_metadata,
                )
                try:
                    await rsd.connect()
                    if rsd.udid != udid:
                        raise ScreenshotError("The developer tunnel returned a different device.")
                    yield rsd
                finally:
                    await _close(rsd)
    finally:
        tunnel_service.USE_USERSPACE_TUNNEL = previous
        await _close(proxy)


async def _capture(udid, job=None):
    transport = wireless.route(udid)
    lockdown = await _connect(udid)
    try:
        capabilities = await _inspect_connection(lockdown, udid, "Wi-Fi" if transport else "USB")
        if not capabilities["canAttempt"]:
            instructions = " ".join(
                item["instruction"]
                for item in capabilities["requirements"]
                if item["state"] == "missing"
            )
            raise ScreenshotError(capabilities["message"] + " " + instructions)
        if job:
            job.check()
            job.progress(None, "Capturing the iPhone display through DVT")
        try:
            return await _dvt_bytes(lockdown), "DVT · lockdown"
        except Exception as error:
            if not _service_unavailable(error):
                raise
            if not capabilities["tunnelRequired"]:
                raise ScreenshotError(
                    "The DVT screenshot service did not start. Confirm Developer Mode and a compatible mounted developer support image, then reconnect the device."
                ) from None
        async with developer_provider(udid, lockdown, job) as provider:
            return await _dvt_bytes(provider), "DVT · selected-device RSD tunnel"
    finally:
        await _close(lockdown)


def _png(data):
    if not isinstance(data, bytes) or not data or len(data) > 32 * 1024 * 1024:
        raise ScreenshotError("The screenshot service returned an invalid or oversized image.")
    from PIL import Image

    try:
        image = Image.open(io.BytesIO(data))
        if image.width * image.height > 32000000:
            raise ScreenshotError("The screenshot exceeds the supported image resolution.")
        if image.format == "PNG":
            image.verify()
            return data
        output = io.BytesIO()
        image.save(output, "PNG")
        return output.getvalue()
    except ScreenshotError:
        raise
    except Exception:
        raise ScreenshotError("The screenshot service did not return a readable image.") from None


def _capture_screenshot(udid, path, job=None):
    target = Path(path).expanduser().absolute()
    if target.suffix.lower() != ".png":
        raise ScreenshotError("Choose a PNG filename for the screenshot.")
    if not target.parent.is_dir():
        raise ScreenshotError("Choose an existing folder for the screenshot.")
    if target.exists():
        raise ScreenshotError("Choose a new screenshot filename; existing files are preserved.")
    if job:
        job.check()
    try:
        data, source = asyncio.run(_run_cancellable(_capture(udid, job), job, 60))
    except (InterruptedError, ScreenshotError):
        raise
    except Exception as error:
        raise ScreenshotError(
            "Screenshot capture failed through the developer service ("
            + type(error).__name__
            + "). Confirm Developer Mode, a compatible developer support image, and the selected-device RSD tunnel for iOS 17 or later. Use USB if the Wi-Fi developer route is unavailable."
        ) from None
    data = _png(data)
    if job:
        job.check()
    stage = target.with_name(".phosphor-screenshot-" + uuid.uuid4().hex + ".partial")
    try:
        with stage.open("xb") as output:
            output.write(data)
        if job:
            job.check()
        if os.name == "nt":
            stage.rename(target)
        else:
            os.link(stage, target)
            stage.unlink()
    finally:
        stage.unlink(missing_ok=True)
    return {
        "output": str(target),
        "bytes": len(data),
        "route": source,
        "changesDeviceSettings": False,
    }


def capture_screenshot(udid, path, job=None):
    while not CAPTURE_GATE.acquire(timeout=0.2):
        if job:
            job.check()
    try:
        return _capture_screenshot(udid, path, job)
    finally:
        CAPTURE_GATE.release()


async def _prepare(udid, cache, job=None):
    from developer_support import prepare_provider
    from pymobiledevice3.services.mobile_image_mounter import CRYPTEX_IMAGE_MIN_VERSION
    from packaging.version import Version

    lockdown = await _connect(udid)
    try:
        capabilities = await _inspect_connection(
            lockdown, udid, "Wi-Fi" if wireless.route(udid) else "USB"
        )
        if capabilities["developerMode"] is not True:
            raise ScreenshotError(
                "Enable Developer Mode on the iPhone before preparing screenshots. Phosphor does not change Developer Mode or restart your device."
            )
        if capabilities["developerImageMounted"] is True:
            return {"prepared": True, "alreadyReady": True, "capabilities": capabilities}
        if job:
            job.check()
        if Version(lockdown.product_version) >= CRYPTEX_IMAGE_MIN_VERSION:
            async with developer_provider(udid, lockdown, job) as provider:
                source = await prepare_provider(provider, cache, job)
                if job:
                    job.check()
                refreshed = await inspect_prerequisites(
                    provider, "Wi-Fi" if wireless.route(udid) else "USB"
                )
        else:
            source = await prepare_provider(lockdown, cache, job)
            if job:
                job.check()
            refreshed = await inspect_prerequisites(
                lockdown, "Wi-Fi" if wireless.route(udid) else "USB"
            )
        if refreshed["developerImageMounted"] is not True:
            raise ScreenshotError(
                "Developer support installation returned, but the mounted image could not be verified. Check availability before capturing; no compatibility bypass is attempted."
            )
        return {
            "prepared": True,
            "source": source,
            "capabilities": refreshed,
            "developerModeChanged": False,
            "restartPerformed": False,
        }
    finally:
        await _close(lockdown)


def screenshot_prepare(udid, job=None):
    cache = (
        Path(os.environ.get("PHOSPHOR_DATA", Path.home() / "AppData" / "Roaming" / "Phosphor"))
        / "developer-support"
    )
    while not CAPTURE_GATE.acquire(timeout=0.2):
        if job:
            job.check()
    try:
        return asyncio.run(_run_cancellable(_prepare(udid, cache, job), job, 20 * 60))
    except (InterruptedError, ScreenshotError):
        raise
    except Exception as error:
        from developer_support import DeveloperSupportError

        if isinstance(error, DeveloperSupportError):
            raise ScreenshotError(str(error)) from None
        raise ScreenshotError(
            "Developer support could not be prepared ("
            + type(error).__name__
            + "). Apple must provide and sign a compatible image for this iOS build. Retry with USB, or update Phosphor when support for this build is available. No signature or security check is bypassed."
        ) from None
    finally:
        CAPTURE_GATE.release()
