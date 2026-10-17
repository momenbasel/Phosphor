"""Windows-safe device transport; no shell interpolation or console flashes."""

import asyncio
import json
import os
import posixpath
import re
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path
import wireless

DEVICE_CACHE = {}
CACHE_LOCK = threading.RLock()


def driver_ready():
    try:
        with socket.create_connection(("127.0.0.1", 27015), timeout=1):
            return True
    except OSError:
        return False


def diagnostic(error):
    text = str(error)
    lower = text.lower()
    if isinstance(error, wireless.WiFiServiceError) or "connected over wi-fi" in lower:
        return text[-1800:]
    if any(
        x in lower
        for x in (
            "connectionreseterror",
            "connection lost",
            "connectionterminatederror",
            "connectionabortederror",
            "incompletereaderror",
        )
    ):
        return "The iPhone connection closed during the operation. Keep it unlocked and connected, then retry. Any incomplete backup remains separate from completed snapshots."
    if any(
        x in lower
        for x in (
            "pairingdialog",
            "notpaired",
            "userdeniedpairing",
            "passwordprotected",
            "device is locked",
        )
    ):
        return "Unlock your iPhone, tap Trust This Computer, enter its passcode, then retry."
    if any(
        x in lower for x in ("connectionfailedtousbmux", "winerror 10061", "connection refused")
    ):
        return "Apple Mobile Device Service is unavailable. Install Apple Devices from Microsoft Store, connect by USB, and retry."
    if any(x in lower for x in ("nodevice", "no device", "devicenotfound")):
        return "No iPhone or iPad detected. Connect a data-capable USB cable, unlock the device, and retry."
    if any(x in lower for x in ("developermode", "invalidservice", "startserviceerror")):
        return "iOS does not expose this service. Some developer features need Developer Mode and a mounted developer disk image."
    return text[-1800:] or "iOS rejected the operation. Unlock the device and try again."


def validate_udid(udid):
    if not re.fullmatch(r"[A-Fa-f0-9-]{12,80}", str(udid)):
        raise ValueError("Select a connected device first.")
    return udid


def child_command():
    if getattr(sys, "frozen", False):
        return [sys.executable, "--cli"]
    return [sys.executable, "-u", str(Path(__file__).with_name("worker.py")), "--cli"]


def run_cli(args, job=None, timeout=60, secrets=()):
    proc = subprocess.Popen(
        child_command(),
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        errors="replace",
        bufsize=1,
        creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0,
        env={**os.environ, "NO_COLOR": "1", "PYTHONIOENCODING": "utf-8", "COLUMNS": "180"},
    )
    handle = None
    if os.name == "nt":
        import win32api, win32con, win32job

        try:
            handle = win32job.CreateJobObject(None, "")
            limits = win32job.QueryInformationJobObject(
                handle, win32job.JobObjectExtendedLimitInformation
            )
            limits["BasicLimitInformation"][
                "LimitFlags"
            ] = win32job.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
            win32job.SetInformationJobObject(
                handle, win32job.JobObjectExtendedLimitInformation, limits
            )
            process_handle = win32api.OpenProcess(win32con.PROCESS_ALL_ACCESS, False, proc.pid)
            try:
                win32job.AssignProcessToJobObject(handle, process_handle)
            finally:
                process_handle.Close()
        except BaseException:
            proc.kill()
            proc.communicate()
            if handle:
                handle.Close()
            raise

    def kill():
        if handle:
            try:
                win32job.TerminateJobObject(handle, 1)
            except Exception:
                proc.kill()
        else:
            proc.kill()

    timer = threading.Timer(timeout, kill)
    timer.daemon = True
    timer.start()
    if job:
        job.kill = kill
    transport = wireless.route(args[args.index("--udid") + 1]) if "--udid" in args else None
    proc.stdin.write(json.dumps({"args": args, "transport": transport}) + "\n")
    proc.stdin.close()
    lines = []
    try:
        for line in proc.stdout:
            line = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", line).strip()
            if line:
                lines.append(line)
                if len(lines) > 5000:
                    lines.pop(0)
                if job:
                    if job.cancelled.is_set():
                        kill()
                    progress = re.search(r"(\d+(?:\.\d+)?)%", line)
                    if "please enter the device passcode" in line.lower():
                        job.progress(
                            None,
                            "Waiting for authorization. Enter your iPhone passcode on the iPhone to continue.",
                        )
                    elif "device passcode prompt dismissed" in line.lower():
                        job.progress(None, "Authorization received. Preparing your backup…")
                    elif progress:
                        job.progress(float(progress.group(1)), "Transferring device data")
                    if getattr(job, "log", None):
                        job.log(line)
        code = proc.wait()
        if job and job.cancelled.is_set():
            raise InterruptedError(
                "Operation cancelled. Incomplete data remains separate from completed backups."
            )
        output = "\n".join(lines)
        for secret in secrets:
            if secret:
                output = output.replace(secret, "[redacted]")
        if code:
            for i, arg in enumerate(args):
                if arg in ("--password", "-p") and i + 1 < len(args):
                    output = output.replace(args[i + 1], "[redacted]")
            raise RuntimeError(diagnostic(output))
        return output
    finally:
        timer.cancel()
        if proc.poll() is None:
            kill()
        if handle:
            handle.Close()
        if job:
            job.kill = None


def json_cli(args):
    output = run_cli(args)
    try:
        return json.loads(output)
    except ValueError:
        decoder = json.JSONDecoder()
        for i, char in enumerate(output):
            if char in "[{":
                try:
                    value, end = decoder.raw_decode(output[i:])
                    if not output[i + end :].strip():
                        return value
                except ValueError:
                    continue
        raise ValueError("The device service returned an unreadable response.")


def app_rows(result):
    """Accept both InstallationProxy lookup maps and browse lists."""
    if result is None:
        return []
    if isinstance(result, dict):
        entries = result.items()
    elif isinstance(result, list):
        entries = [
            (
                (r.get("CFBundleIdentifier", r.get("BundleIdentifier", r.get("id", ""))), r)
                if isinstance(r, dict)
                else (r, {})
            )
            for r in result
        ]
    else:
        raise ValueError("The device returned an unsupported application list.")
    rows = {}
    for bundle, info in entries:
        if not isinstance(bundle, str) or not bundle or not isinstance(info, dict):
            continue
        rows[bundle] = {
            "id": bundle,
            "name": info.get("CFBundleDisplayName") or info.get("CFBundleName") or bundle,
            "version": str(
                info.get("CFBundleShortVersionString") or info.get("CFBundleVersion") or ""
            ),
            "detail": bundle,
        }
    return sorted(rows.values(), key=lambda r: (r["name"].casefold(), r["id"]))


def battery_readings(raw):
    """Keep absent measurements explicit; charge scale is not battery health."""
    raw = raw if isinstance(raw, dict) else {}

    def number(key, low=0, high=None):
        value = raw.get(key)
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            return None
        return value if value >= low and (high is None or value <= high) else None

    return {
        "charge": number("CurrentCapacity", high=100),
        "cycles": number("CycleCount"),
        "charging": raw.get("IsCharging") if isinstance(raw.get("IsCharging"), bool) else None,
        "maximumCapacityPercent": number("MaximumCapacityPercent", low=1, high=100),
        "error": raw.get("error"),
        "raw": raw,
    }


async def _apps(udid):
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.installation_proxy import InstallationProxyService

    transport = wireless.route(validate_udid(udid))
    lockdown = (
        await wireless.connect(transport["address"], udid)
        if transport
        else await create_using_usbmux(udid, autopair=False)
    )
    try:
        async with InstallationProxyService(lockdown=lockdown) as service:
            result = await service.browse(
                options={"ApplicationType": "User"},
                attributes=[
                    "CFBundleIdentifier",
                    "CFBundleDisplayName",
                    "CFBundleName",
                    "CFBundleShortVersionString",
                    "CFBundleVersion",
                ],
            )
            return app_rows(result)
    finally:
        await lockdown.close()


def apps(udid):
    # Request only display metadata through the SDK. Large CLI app inventories
    # can exceed the bounded diagnostic log and leave a partial JSON document.
    return asyncio.run(asyncio.wait_for(_apps(udid), 60))


def has_numeric_storage(raw):
    if not isinstance(raw, dict):
        return False
    for key in ("TotalDataCapacity", "FSTotalBytes", "TotalDiskCapacity"):
        value = raw.get(key)
        if isinstance(value, bool):
            continue
        try:
            if float(value) > 0:
                return True
        except (TypeError, ValueError):
            pass
    return False


async def _storage_info(udid):
    from pymobiledevice3.lockdown import create_using_usbmux
    from device_readouts import collect_storage

    transport = wireless.route(validate_udid(udid))
    lockdown = (
        await wireless.connect(transport["address"], udid)
        if transport
        else await create_using_usbmux(udid, autopair=False)
    )
    try:
        return await collect_storage(lockdown)
    finally:
        await lockdown.close()


def storage_info(udid):
    return asyncio.run(asyncio.wait_for(_storage_info(udid), 60))


def screenshot_capabilities(udid):
    from device_screenshot import screenshot_capabilities as inspect

    return inspect(validate_udid(udid))


def capture_screenshot(udid, path, job=None):
    from device_screenshot import capture_screenshot as capture

    return capture(validate_udid(udid), path, job)


def screenshot_prepare(udid, job=None):
    from device_screenshot import screenshot_prepare as prepare

    return prepare(validate_udid(udid), job)


def validate_media_write(remote):
    if (
        not isinstance(remote, str)
        or not remote.startswith("/")
        or "\\" in remote
        or "\x00" in remote
        or ".." in remote.split("/")
    ):
        raise ValueError("Invalid device file path.")
    parts = [part for part in remote.split("/") if part not in ("", ".")]
    if not parts or parts[0].casefold() in ("dcim", "photodata", "itunes_control"):
        raise ValueError(
            "This folder is managed by iOS. Use Current photos to review media safely; raw library files cannot be changed."
        )
    return "/" + "/".join(parts)


async def _devices(protected=()):
    from pymobiledevice3 import usbmux
    from pymobiledevice3.lockdown import create_using_usbmux

    protected = set(protected)
    with CACHE_LOCK:
        rows = [dict(row) for key, row in DEVICE_CACHE.items() if key in protected]
    try:
        discovered = await usbmux.list_devices()
    except Exception:
        discovered = []
    for dev in sorted(discovered, key=lambda d: d.connection_type != "USB"):
        if any(r["id"] == dev.serial for r in rows):
            continue
        row = {
            "id": dev.serial,
            "name": "iOS device",
            "connection": dev.connection_type,
            "paired": False,
        }
        if dev.serial in protected:
            rows.append(row)
            continue
        lockdown = None
        try:
            lockdown = await create_using_usbmux(
                dev.serial, autopair=False, connection_type=dev.connection_type
            )
            info = lockdown.short_info
            row.update(
                {
                    "name": info.get("DeviceName") or "iOS device",
                    "model": info.get("ProductType"),
                    "ios": info.get("ProductVersion"),
                    "paired": bool(lockdown.paired),
                }
            )
        except Exception as e:
            row["error"] = diagnostic(type(e).__name__ + ": " + str(e))
        finally:
            if lockdown:
                await lockdown.close()
        rows.append(row)
        # Explicit None suppresses a stale saved LAN route when USB is connected.
        wireless.select(dev.serial, None)
    rows.extend(
        await wireless.discover({r["id"] for r in rows} | protected, allow_bonjour=not protected)
    )
    with CACHE_LOCK:
        DEVICE_CACHE.clear()
        DEVICE_CACHE.update({r["id"]: dict(r) for r in rows})
    return rows


def devices(protected=()):
    try:
        return asyncio.run(asyncio.wait_for(_devices(protected), 15))
    except Exception as e:
        raise RuntimeError(diagnostic(type(e).__name__ + ": " + str(e))) from e


async def _files(udid, remote):
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.afc import AfcService

    transport = wireless.route(validate_udid(udid))
    lockdown = (
        await wireless.connect(transport["address"], udid)
        if transport
        else await create_using_usbmux(udid, autopair=False)
    )
    try:
        async with AfcService(lockdown=lockdown) as afc:
            names = await afc.listdir(remote)
            rows = []
            for name in names[:2000]:
                path = posixpath.join(remote, name)
                stat = await afc.stat(path)
                rows.append(
                    {
                        "id": path,
                        "name": name,
                        "path": path,
                        "directory": stat.get("st_ifmt") == "S_IFDIR",
                        "size": stat.get("st_size", 0),
                        "date": str(stat.get("st_mtime", "")),
                    }
                )
            return {
                "rows": sorted(rows, key=lambda r: (not r["directory"], r["name"].lower())),
                "total": len(names),
                "path": remote,
            }
    except Exception as e:
        if transport:
            raise wireless.WiFiServiceError(
                "Your iPhone is connected over Wi-Fi, but file access failed. Keep it unlocked and retry, or reconnect USB. ("
                + type(e).__name__
                + ")"
            ) from e
        raise
    finally:
        await lockdown.close()


def files(udid, remote="/"):
    if not remote.startswith("/") or ".." in remote.split("/") or "\x00" in remote:
        raise ValueError("Invalid device path.")
    return asyncio.run(asyncio.wait_for(_files(udid, remote), 60))
