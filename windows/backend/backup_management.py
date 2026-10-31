"""Backup labels and explicitly confirmed, recoverable Windows deletion."""

import ctypes
import os
import re
from pathlib import Path


def label(value):
    value = str(value).strip()
    if not value or len(value) > 120 or any(ord(c) < 32 for c in value):
        raise ValueError("Use a backup name between 1 and 120 characters.")
    return value


def deletion_target(store, backup):
    path = store.path(backup)
    if not re.fullmatch(r"[A-Fa-f0-9-]{12,80}", path.name) or not all(
        (path / f).is_file() for f in ("Info.plist", "Manifest.plist", "Manifest.db")
    ):
        raise ValueError(
            "Only a discovered device backup folder can be deleted. Its parent folder is never deleted."
        )
    if path.is_symlink() or (hasattr(path, "is_junction") and path.is_junction()):
        raise ValueError("Delete backup links through Explorer instead.")
    return path


def recycle(path):
    path = Path(path).resolve(strict=True)
    if os.name != "nt" or ctypes.windll.kernel32.GetDriveTypeW(path.anchor) != 3:
        raise ValueError(
            "Recycle Bin deletion is available for backups on local fixed drives. Manage this location in Explorer."
        )
    import pythoncom
    from win32com.shell import shell, shellcon

    pythoncom.CoInitialize()
    operation = item = None
    try:
        operation = pythoncom.CoCreateInstance(
            shell.CLSID_FileOperation,
            None,
            pythoncom.CLSCTX_INPROC_SERVER,
            shell.IID_IFileOperation,
        )
        # Windows 8+ recycle-only and user undo record flags. Never fall back to
        # permanent deletion if the shell cannot recycle this backup.
        operation.SetOperationFlags(
            shellcon.FOF_ALLOWUNDO
            | shellcon.FOF_NOCONFIRMATION
            | shellcon.FOF_SILENT
            | shellcon.FOF_NOERRORUI
            | 0x00080000
            | 0x20000000
        )
        item = shell.SHCreateItemFromParsingName(str(path), None, shell.IID_IShellItem)
        operation.DeleteItem(item, None)
        operation.PerformOperations()
        if operation.GetAnyOperationsAborted() or path.exists():
            raise ValueError(
                "Windows could not move this backup to the Recycle Bin. Close any files open in other apps and retry."
            )
    finally:
        operation = item = None
        pythoncom.CoUninitialize()
