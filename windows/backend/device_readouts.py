"""Read-only storage observations without presenting APFS volume free as Settings free.

Lockdown's legacy disk-usage keys and AFC's statvfs counters describe different
storage scopes. APFS volumes share space; adding their free counts, or deriving
whole-device usage from the media/data volume, is not a supported calculation.
"""

import asyncio
import math
from datetime import datetime, timezone

DISK_KEYS = (
    "TotalDiskCapacity",
    "TotalDataCapacity",
    "TotalDataAvailable",
    "AmountDataAvailable",
    "AmountDataReserved",
    "TotalSystemCapacity",
    "TotalSystemAvailable",
)
AFC_KEYS = ("FSTotalBytes", "FSFreeBytes", "FSBlockSize")


def storage_number(value):
    if isinstance(value, bool):
        return None
    if isinstance(value, str):
        if not value.isdecimal():
            return None
        value = int(value)
    if not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
        return None
    return int(value)


def normalize_storage(lockdown=None, afc=None, errors=None):
    lockdown = lockdown if isinstance(lockdown, dict) else {}
    afc = afc if isinstance(afc, dict) else {}
    raw = {
        "lockdown": {
            key: lockdown[key] for key in (*DISK_KEYS, "CalculateDiskUsage") if key in lockdown
        },
        "afc": {key: afc[key] for key in AFC_KEYS if key in afc},
    }
    values = {key: storage_number(lockdown.get(key)) for key in DISK_KEYS}
    afc_values = {key: storage_number(afc.get(key)) for key in AFC_KEYS}
    available = values["AmountDataAvailable"]
    available_source = "Apple lockdown · AmountDataAvailable"
    available_label = "Data available after iOS reservation"
    if available is None:
        available = afc_values["FSFreeBytes"]
        available_source = "Apple AFC · FSFreeBytes"
        available_label = "Media filesystem free"
    ceiling = (
        values["TotalDiskCapacity"] or afc_values["FSTotalBytes"] or values["TotalDataCapacity"]
    )
    if ceiling is not None and available is not None and available > ceiling:
        available = None
    corroborated = (
        values["AmountDataAvailable"] is not None
        and values["AmountDataReserved"] is not None
        and afc_values["FSFreeBytes"] is not None
        and abs(
            values["AmountDataAvailable"] + values["AmountDataReserved"] - afc_values["FSFreeBytes"]
        )
        <= max(4096, afc_values["FSBlockSize"] or 0)
    )
    definitions = (
        ("TotalDiskCapacity", "Hardware capacity", "hardware"),
        ("TotalDataCapacity", "Data-volume capacity", "data"),
        ("TotalDataAvailable", "Data-volume free", "data"),
        ("AmountDataAvailable", "Data available after reservation", "data"),
        ("AmountDataReserved", "Data reserved", "data"),
        ("TotalSystemCapacity", "System-volume capacity", "system"),
        ("TotalSystemAvailable", "System-volume free", "system"),
    )
    measurements = [
        {
            "key": key,
            "label": label,
            "bytes": values[key],
            "scope": scope,
            "source": "Apple lockdown · com.apple.disk_usage",
        }
        for key, label, scope in definitions
        if values[key] is not None
    ]
    measurements.extend(
        {
            "key": key,
            "label": label,
            "bytes": afc_values[key],
            "scope": "media-filesystem",
            "source": "Apple AFC · GetDeviceInfo",
        }
        for key, label in (
            ("FSTotalBytes", "Media filesystem capacity"),
            ("FSFreeBytes", "Media filesystem free"),
        )
        if afc_values[key] is not None
    )
    inconsistencies = []
    for total, free in (
        ("TotalDataCapacity", "TotalDataAvailable"),
        ("TotalSystemCapacity", "TotalSystemAvailable"),
    ):
        if values[total] is not None and values[free] is not None and values[free] > values[total]:
            inconsistencies.append(f"{free} exceeds {total}; no usage total was derived.")
    if (
        afc_values["FSTotalBytes"] is not None
        and afc_values["FSFreeBytes"] is not None
        and afc_values["FSFreeBytes"] > afc_values["FSTotalBytes"]
    ):
        inconsistencies.append("FSFreeBytes exceeds FSTotalBytes; no usage total was derived.")
    return {
        "status": "partial" if measurements else "unavailable",
        "capacityBytes": values["TotalDiskCapacity"],
        "settingsAvailableBytes": None,
        "availableBytes": available,
        "availableSource": available_source if available is not None else None,
        "availableLabel": available_label,
        "availabilityCorroborated": corroborated,
        "usedBytes": None,
        "dataCapacityBytes": values["TotalDataCapacity"],
        "dataFreeBytes": values["TotalDataAvailable"],
        "dataAvailableBytes": values["AmountDataAvailable"],
        "reservedBytes": values["AmountDataReserved"],
        "systemCapacityBytes": values["TotalSystemCapacity"],
        "systemFreeBytes": values["TotalSystemAvailable"],
        "measurements": measurements,
        "raw": raw,
        "inconsistencies": inconsistencies,
        "source": "Apple lockdown and AFC storage protocols",
        "settingsComparable": False,
        "message": "Available data accounts for iOS reservation when that reading is provided. The older data-volume free value can differ substantially. Settings → General → iPhone Storage uses its own accounting; the original protocol readings are retained below.",
        "checkedAt": datetime.now(timezone.utc).isoformat(),
        "errors": errors or [],
    }


async def collect_storage(lockdown):
    """Only GetValue/GetDeviceInfo; never SetValue/CalculateDiskUsage triggers."""
    raw = {}
    afc = {}
    errors = []
    try:
        value = await asyncio.wait_for(lockdown.get_value(domain="com.apple.disk_usage"), 5)
        if isinstance(value, dict):
            raw = value
    except Exception:
        errors.append("The lockdown storage report was unavailable.")
    # Some devices return only CalculateDiskUsage: OkilyDokily for the whole
    # domain while still answering individual, read-only capacity queries.
    for key in DISK_KEYS:
        if storage_number(raw.get(key)) is not None:
            continue
        try:
            value = await asyncio.wait_for(
                lockdown.get_value(domain="com.apple.disk_usage", key=key), 2
            )
            if storage_number(value) is not None:
                raw[key] = value
        except Exception:
            pass
    try:
        from pymobiledevice3.services.afc import AfcService

        async with AfcService(lockdown=lockdown) as service:
            value = await asyncio.wait_for(service.get_device_info(), 5)
            if isinstance(value, dict):
                afc = value
    except Exception:
        errors.append("The AFC filesystem report was unavailable.")
    return normalize_storage(raw, afc, errors)
