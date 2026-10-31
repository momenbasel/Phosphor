"""Local backup cadence, with calendar schedules evaluated in the user's timezone."""

import re
import math
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError


def configure(params, now):
    frequency = params["frequency"]
    intervals = {"hourly": 3600, "daily": 86400, "weekly": 604800, "monthly": 2592000}
    if frequency == "interval":
        hours = params.get("hours", 1)
        if isinstance(hours, bool) or not isinstance(hours, int) or not 1 <= hours <= 720:
            raise ValueError("Choose a whole number of hours between 1 and 720.")
        result = {"frequency": frequency, "hours": hours, "seconds": hours * 3600}
    elif frequency in intervals:
        result = {"frequency": frequency, "seconds": intervals[frequency]}
        if frequency in ("daily", "weekly") and params.get("atTime"):
            if not re.fullmatch(r"(?:[01]\d|2[0-3]):[0-5]\d", params["atTime"]):
                raise ValueError("Choose a valid backup time.")
            zone = params.get("timeZone", "UTC")
            try:
                ZoneInfo(zone)
            except (ZoneInfoNotFoundError, ValueError, TypeError):
                raise ValueError("Choose a supported timezone.") from None
            result.update(atTime=params["atTime"], timeZone=zone)
            if frequency == "weekly":
                day = params.get("weekday", 0)
                if isinstance(day, bool) or not isinstance(day, int) or not 0 <= day <= 6:
                    raise ValueError("Choose a valid day of the week.")
                result["weekday"] = day  # Monday=0, Sunday=6.
    else:
        raise ValueError("Unsupported backup frequency.")
    result["next"] = next_due(result, now)
    if params.get("firstAt") and frequency in ("interval", "monthly", "hourly"):
        try:
            first = datetime.fromisoformat(params["firstAt"].replace("Z", "+00:00"))
            if first.tzinfo is None:
                raise ValueError()
            stamp = first.timestamp()
            if not math.isfinite(stamp) or stamp <= now:
                raise ValueError()
        except (TypeError, ValueError, OverflowError, AttributeError):
            raise ValueError("Choose a future date and time for the first backup.") from None
        result.update(firstAt=first.isoformat(), next=stamp, timeZone=params.get("timeZone", "UTC"))
    return result


def next_due(schedule, now):
    if schedule.get("atTime") and schedule["frequency"] in ("daily", "weekly"):
        zone = ZoneInfo(schedule.get("timeZone", "UTC"))
        current = datetime.fromtimestamp(now, zone)
        hour, minute = map(int, schedule["atTime"].split(":"))
        candidate = current.replace(hour=hour, minute=minute, second=0, microsecond=0)
        if schedule["frequency"] == "weekly":
            candidate += timedelta(days=(schedule.get("weekday", 0) - candidate.weekday()) % 7)
        if candidate.timestamp() <= now:
            candidate += timedelta(days=7 if schedule["frequency"] == "weekly" else 1)
        return candidate.timestamp()
    return now + schedule["seconds"]
