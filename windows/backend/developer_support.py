"""Explicit developer-image preparation, normal SDK signing with bounded HTTPS.

Generic image assets cache under the app profile. Signed per-device tickets stay
in memory. No TLS/request globals are modified; SDK request-building functions
receive a local SecureTSSRequest in a copied function namespace.
"""

import asyncio
import json
import os
import plistlib
import shutil
import types
import uuid
from pathlib import Path

from backup import safe_target

IMAGE_LIMIT = 1024 * 1024 * 1024
SMALL_LIMIT = 16 * 1024 * 1024
REPOSITORY = "https://raw.githubusercontent.com/doronz88/DeveloperDiskImage/main/"


class DeveloperSupportError(ValueError):
    pass


def secure_sdk_function(function, request_class):
    """Keep pinned SDK signing parameters; replace only this call's HTTP client."""
    cloned = types.FunctionType(
        function.__code__,
        dict(function.__globals__, TSSRequest=request_class),
        function.__name__,
        function.__defaults__,
        function.__closure__,
    )
    cloned.__kwdefaults__ = function.__kwdefaults__
    return cloned


def secure_tss_class(job=None):
    from pymobiledevice3.restore.tss import TSSRequest, TSSResponse

    class SecureTSSRequest(TSSRequest):
        async def send_receive(self):
            import aiohttp

            if job:
                job.check()
                job.progress(None, "Requesting Apple’s developer-image signature")
            timeout = aiohttp.ClientTimeout(total=45, connect=10, sock_read=20)
            async with aiohttp.ClientSession(timeout=timeout) as session:
                async with session.post(
                    "https://gs.apple.com/TSS/controller?action=2",
                    data=plistlib.dumps(self._request),
                    headers={
                        "Content-Type": "text/xml; charset=utf-8",
                        "User-Agent": "InetURL/1.0",
                    },
                    ssl=True,
                    allow_redirects=False,
                ) as response:
                    if response.status != 200:
                        raise DeveloperSupportError(
                            "Apple’s signing server did not accept this developer support request."
                        )
                    content = bytearray()
                    async for chunk in response.content.iter_chunked(65536):
                        if job:
                            job.check()
                        content.extend(chunk)
                        if len(content) > 4 * 1024 * 1024:
                            raise DeveloperSupportError(
                                "Apple’s developer-image signature response exceeded its supported size."
                            )
            if job:
                job.check()
            if b"MESSAGE=SUCCESS" not in content or b"REQUEST_STRING=" not in content:
                raise DeveloperSupportError(
                    "Apple did not sign this developer image for the selected iPhone. A compatible image may not yet be available for its iOS build."
                )
            try:
                return TSSResponse(plistlib.loads(bytes(content).split(b"REQUEST_STRING=", 1)[1]))
            except Exception:
                raise DeveloperSupportError(
                    "Apple’s developer-image signature response could not be read."
                ) from None

    return SecureTSSRequest


async def _download(relative, target, job=None):
    """Static SDK repository paths; fresh HTTPS session, no account credentials."""
    import aiohttp

    maximum = IMAGE_LIMIT if relative.endswith(".dmg") else SMALL_LIMIT
    timeout = aiohttp.ClientTimeout(total=15 * 60, connect=10, sock_read=30)
    target.parent.mkdir(parents=True, exist_ok=True)
    async with aiohttp.ClientSession(timeout=timeout) as session:
        async with session.get(
            REPOSITORY + relative,
            headers={"Accept-Encoding": "identity"},
            ssl=True,
            allow_redirects=False,
        ) as response:
            if response.status != 200:
                raise DeveloperSupportError(
                    "A compatible developer support image is not available from the SDK image repository. Retry later or use developer support supplied by Apple’s tools."
                )
            length = response.content_length
            if length is not None and length > maximum:
                raise DeveloperSupportError(
                    "The developer support asset exceeds its download limit."
                )
            if shutil.disk_usage(target.parent).free < (length or maximum) + 64 * 1024 * 1024:
                raise DeveloperSupportError(
                    "Not enough free space to cache developer support in Phosphor’s profile."
                )
            count = 0
            with target.open("xb") as output:
                async for chunk in response.content.iter_chunked(1024 * 1024):
                    if job:
                        job.check()
                    count += len(chunk)
                    if count > maximum:
                        raise DeveloperSupportError(
                            "The developer support asset exceeded its download limit."
                        )
                    output.write(chunk)
                    if job:
                        job.progress(None, f"Downloading developer support · {count:,} bytes")
            # Content-Length describes the encoded HTTP body. aiohttp decodes
            # gzip/deflate while streaming, so comparing it to decoded bytes
            # falsely rejects a complete manifest. Payload errors still raise;
            # decoded limits above and the SDK manifest/signature checks apply.
            encoded = response.headers.get("Content-Encoding", "identity").lower() not in (
                "",
                "identity",
            )
            if not count or (not encoded and length is not None and count != length):
                raise DeveloperSupportError("The developer support asset download was incomplete.")


async def assets(cache, kind, version, job=None):
    from pymobiledevice3.services.mobile_image_mounter import LATEST_DDI_BUILD_ID

    key = version if kind == "classic" else LATEST_DDI_BUILD_ID
    root = Path(cache).resolve()
    root.mkdir(parents=True, exist_ok=True)
    final = safe_target(root, kind + "/" + key)
    marker = final / "complete.json"
    if marker.is_file():
        try:
            metadata = json.loads(marker.read_text("utf-8"))
            if (
                metadata.get("build") == key
                and metadata.get("files")
                and all(safe_target(final, name).is_file() for name in metadata["files"])
            ):
                return final
        except (OSError, ValueError, TypeError):
            pass
        raise DeveloperSupportError(
            "The cached developer image is incomplete. Remove its developer-support cache folder and retry."
        )
    stage = root / (".download-" + uuid.uuid4().hex)
    stage.mkdir()
    files = []
    try:
        if kind == "classic":
            for name in ("DeveloperDiskImage.dmg", "DeveloperDiskImage.dmg.signature"):
                await _download(f"DeveloperDiskImages/{version}/{name}", stage / name, job)
                files.append(name)
        else:
            prefix = "PersonalizedImages/Xcode_iOS_DDI_" + (
                "Cryptex" if kind == "cryptex" else "Personalized"
            )
            await _download(prefix + "/BuildManifest.plist", stage / "BuildManifest.plist", job)
            files.append("BuildManifest.plist")
            manifest = plistlib.loads((stage / "BuildManifest.plist").read_bytes())
            if manifest.get("ProductBuildVersion") != LATEST_DDI_BUILD_ID:
                raise DeveloperSupportError(
                    "The available developer image does not match the bundled SDK. Update Phosphor before preparing this iOS build."
                )
            if kind == "cryptex":
                from pymobiledevice3.services.cryptexd import (
                    _cryptex_build_identity,
                    CRYPTEX1_PAYLOAD_KEYS,
                )

                identity = _cryptex_build_identity(manifest, stage / "BuildManifest.plist")
                source_names = {
                    "image": "Image.dmg",
                    "trustcache": "Image.dmg.trustcache",
                    "cryptex_info": "Image.dmg.cryptex_info",
                    "root_hash": "Image.dmg.root_hash",
                }
                for payload_key, field in CRYPTEX1_PAYLOAD_KEYS.items():
                    name = identity["Manifest"][payload_key]["Info"]["Path"]
                    target = safe_target(stage, name)
                    await _download(prefix + "/" + source_names[field], target, job)
                    files.append(name)
            else:
                for source, name in (
                    ("Image.dmg", "Image.dmg"),
                    ("Image.dmg.trustcache", "Image.trustcache"),
                ):
                    await _download(prefix + "/" + source, stage / name, job)
                    files.append(name)
        if job:
            job.check()
        (stage / "complete.json").write_text(
            json.dumps({"kind": kind, "build": key, "files": files}), "utf-8"
        )
        final.parent.mkdir(parents=True, exist_ok=True)
        os.rename(stage, final)
        return final
    finally:
        if (
            stage.exists()
            and stage.resolve().parent == root
            and stage.name.startswith(".download-")
            and not stage.is_symlink()
        ):
            shutil.rmtree(stage)


async def prepare_provider(provider, cache, job=None):
    from pymobiledevice3.services import mobile_image_mounter as mounter

    request_class = secure_tss_class(job)
    if mounter.uses_cryptex_image(provider):
        from pymobiledevice3.services.cryptexd import CryptexdService

        folder = await assets(cache, "cryptex", provider.product_version, job)
        secure_install = secure_sdk_function(CryptexdService.auto_install_ddi, request_class)
        if job:
            job.check()
            job.progress(None, "Installing Apple-signed developer support")
        service = CryptexdService(provider)
        await secure_install(service, folder)
        return "Apple-signed Cryptex developer image"
    if mounter.uses_personalized_image(provider):
        folder = await assets(cache, "personalized", provider.product_version, job)
        request_signature = secure_sdk_function(
            mounter.request_personalization_manifest, request_class
        )

        class SecurePersonalizedMounter(mounter.PersonalizedImageMounter):
            async def get_manifest_from_tss(self, manifest):
                return await request_signature(
                    manifest,
                    await self.query_personalization_identifiers(),
                    self.lockdown.ecid,
                    await self.query_nonce("DeveloperDiskImage"),
                    logger=self.logger,
                )

        if job:
            job.check()
            job.progress(None, "Mounting Apple-signed developer support")
        async with SecurePersonalizedMounter(provider) as image:
            await image.mount(
                folder / "Image.dmg", folder / "BuildManifest.plist", folder / "Image.trustcache"
            )
        return "Apple-signed personalized developer image"
    version = ".".join(provider.product_version.split(".")[:2])
    folder = await assets(cache, "classic", version, job)
    if job:
        job.check()
        job.progress(None, "Mounting Apple-signed developer support")
    async with mounter.DeveloperDiskImageMounter(provider) as image:
        await image.mount(
            folder / "DeveloperDiskImage.dmg", folder / "DeveloperDiskImage.dmg.signature"
        )
    return "Apple-signed developer image"
