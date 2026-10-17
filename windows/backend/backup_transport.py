"""Preserve the MobileBackup2 protocol result when disconnected cleanup fails."""

import asyncio
from contextlib import asynccontextmanager, suppress

from pymobiledevice3.exceptions import ConnectionTerminatedError
from pymobiledevice3.services.mobilebackup2 import Mobilebackup2Service
from pymobiledevice3.services.device_link import DeviceLink

DISCONNECTED = (ConnectionError, ConnectionTerminatedError, asyncio.IncompleteReadError)


class BackupTransport(Mobilebackup2Service):
    @asynccontextmanager
    async def device_link(self, backup_directory, filter_callback=None, password=""):
        await self.connect()
        dl = DeviceLink(
            self._service,
            backup_directory,
            preserve_file=lambda name, device: self.should_preserve_backup_file(
                name, device, filter_callback
            ),
        )
        await dl.version_exchange()
        await self.version_exchange(dl)
        try:
            yield dl
        except BaseException:
            # Never let a second error in disconnect hide the transfer failure.
            with suppress(Exception):
                await dl.disconnect()
            raise
        else:
            # iOS may close the service after its successful completion message.
            with suppress(*DISCONNECTED):
                await dl.disconnect()

    @asynccontextmanager
    async def _backup_lock(self, afc, notification_proxy):
        manager = super()._backup_lock(afc, notification_proxy)
        await manager.__aenter__()
        try:
            yield
        except BaseException as error:
            with suppress(Exception):
                await manager.__aexit__(type(error), error, error.__traceback__)
            raise
        else:
            with suppress(*DISCONNECTED):
                await manager.__aexit__(None, None, None)

    async def _log_backup_notifications(self, notification_proxy):
        try:
            await super()._log_backup_notifications(notification_proxy)
        except DISCONNECTED:
            # The DeviceLink channel remains authoritative for backup completion.
            pass


def install_backup_transport():
    from pymobiledevice3.cli import backup

    backup.Mobilebackup2Service = BackupTransport
