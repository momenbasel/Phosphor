"""Package license text and corresponding Python dependency source for offline builds."""

import importlib.metadata
import shutil
import json
import hashlib
import urllib.request
import tarfile
import re
from pathlib import Path

root = Path(__file__).resolve().parents[1]
destination = root / "assets" / "licenses"
destination.mkdir(parents=True, exist_ok=True)
for old in destination.glob("*.pyc"):
    old.unlink()
records = []
for distribution in importlib.metadata.distributions():
    name = distribution.metadata.get("Name", "unknown")
    license_paths = [
        p
        for p in distribution.files or []
        if any(token in str(p).lower() for token in ("license", "copying"))
        and ".dist-info" in str(p)
    ]
    for index, p in enumerate(license_paths):
        source = distribution.locate_file(p)
        if source.is_file() and source.suffix != ".pyc":
            shutil.copyfile(source, destination / (name + "-" + str(index) + "-" + source.name))
    records.append(
        name
        + " "
        + distribution.version
        + " — "
        + (
            distribution.metadata.get("License-Expression")
            or distribution.metadata.get("License")
            or "See included license/source metadata"
        )
    )
(destination / "DEPENDENCIES.txt").write_text("\n".join(records), encoding="utf-8")
for name in ["electron", "react", "react-dom", "lucide-react", "@fontsource-variable/inter"]:
    module = root / "node_modules" / name
    for filename in ["LICENSE", "LICENSE.md", "LICENSE.txt", "OFL.txt"]:
        src = module / filename
        if src.is_file():
            shutil.copyfile(src, destination / (name.replace("/", "-") + "-" + filename))
vendor = root / "assets" / "python-source"
vendor.mkdir(parents=True, exist_ok=True)
for name in ["pymobiledevice3", "pyiosbackup", "pytypedstream", "rawpy", "defusedxml"]:
    d = importlib.metadata.distribution(name)
    for relative in d.files or []:
        if str(relative).endswith(
            (".py", ".pyx", ".pyi", ".h", ".proto", ".pem", ".crt", ".txt", ".toml", ".md", ".dat")
        ):
            src = Path(d.locate_file(relative))
            dst = vendor / name / str(relative).replace("..", "_")
            if src.is_file():
                dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(src, dst)
archives = root / "assets" / "source-archives"
archives.mkdir(parents=True, exist_ok=True)
for name in ["pymobiledevice3", "pyiosbackup", "pytypedstream", "av", "rawpy"]:
    version = importlib.metadata.version(name)
    if name != "rawpy" and any(archives.glob(name + "-" + version + ".tar.*")):
        continue
    with urllib.request.urlopen(
        "https://pypi.org/pypi/" + name + "/" + version + "/json", timeout=60
    ) as response:
        metadata = json.load(response)
    package = next(p for p in metadata["urls"] if p["packagetype"] == "sdist")
    archive_path = archives / package["filename"]
    if archive_path.exists():
        data = archive_path.read_bytes()
    else:
        with urllib.request.urlopen(package["url"], timeout=60) as response:
            data = response.read()
    if hashlib.sha256(data).hexdigest() != package["digests"]["sha256"]:
        raise RuntimeError("Source archive checksum mismatch: " + name)
    archive_path.write_bytes(data)

# rawpy's Windows wheel loads a replaceable LibRaw DLL. Its sdist supplies
# matching LibRaw and CMake preferred sources, but the wheel's metadata only
# carries rawpy/MIT and LibRaw/LGPL notices. Include the linked codec notices
# from the exact upstream Windows build recipe, rather than omit them.
import rawpy

if rawpy.__version__ != "0.27.1":
    raise RuntimeError(
        "Update RAW source/codec build receipts before changing the pinned rawpy version."
    )
raw_archive = archives / ("rawpy-" + rawpy.__version__ + ".tar.gz")
with tarfile.open(raw_archive) as archive:
    prefix = "rawpy-" + rawpy.__version__ + "/external/LibRaw/"
    header = archive.extractfile(prefix + "libraw/libraw_version.h").read().decode("utf-8")
    source_version = tuple(
        int(re.search(r"#define\s+LIBRAW_" + part + r"_VERSION\s+(\d+)", header)[1])
        for part in ("MAJOR", "MINOR", "PATCH")
    )
    if source_version != rawpy.libraw_version or source_version != rawpy.libraw_version_compiled:
        raise RuntimeError("Bundled LibRaw preferred source does not match the RAW wheel.")
    for filename in ("LICENSE.LGPL", "LICENSE.CDDL", "COPYRIGHT"):
        data = archive.extractfile(prefix + filename).read()
        (
            destination / ("LibRaw-" + ".".join(map(str, source_version)) + "-" + filename)
        ).write_bytes(data)

recipe = vendor / "rawpy" / "build-receipt"
recipe.mkdir(parents=True, exist_ok=True)
raw_urls = {
    "rawpy-build-windows.ps1": "https://raw.githubusercontent.com/letmaik/rawpy/v0.27.1/.github/scripts/build-windows.ps1",
    "zlib-1.3.2-LICENSE": "https://raw.githubusercontent.com/madler/zlib/v1.3.2/LICENSE",
    "libjpeg-turbo-3.2.0-LICENSE.md": "https://raw.githubusercontent.com/libjpeg-turbo/libjpeg-turbo/3.2.0/LICENSE.md",
    "libjpeg-turbo-3.2.0-README.ijg": "https://raw.githubusercontent.com/libjpeg-turbo/libjpeg-turbo/3.2.0/README.ijg",
    "JasPer-4.2.9-LICENSE.txt": "https://raw.githubusercontent.com/jasper-software/jasper/version-4.2.9/LICENSE.txt",
    "Little-CMS-2.19.1-LICENSE": "https://raw.githubusercontent.com/mm2/Little-CMS/lcms2.19.1/LICENSE",
}
for port in ("zlib", "libjpeg-turbo", "jasper", "lcms"):
    for filename in ("vcpkg.json", "portfile.cmake"):
        raw_urls["vcpkg-2026.07.29-" + port + "-" + filename] = (
            "https://raw.githubusercontent.com/microsoft/vcpkg/2026.07.29/ports/"
            + port
            + "/"
            + filename
        )
receipt = []
for filename, url in raw_urls.items():
    target = (recipe if filename.startswith(("rawpy-build", "vcpkg-")) else destination) / filename
    if not target.exists():
        with urllib.request.urlopen(url, timeout=60) as response:
            data = response.read(4 * 1024 * 1024 + 1)
        if len(data) > 4 * 1024 * 1024:
            raise RuntimeError("RAW notice/build record exceeds expected size: " + filename)
        target.write_bytes(data)
    receipt.append(
        {
            "filename": filename,
            "url": url,
            "sha256": hashlib.sha256(target.read_bytes()).hexdigest(),
        }
    )
raw_root = Path(rawpy.__file__).parent
manifest = {
    "rawpy": rawpy.__version__,
    "numpy": importlib.metadata.version("numpy"),
    "libraw": ".".join(map(str, rawpy.libraw_version)),
    "sourceArchive": raw_archive.name,
    "sourceSha256": hashlib.sha256(raw_archive.read_bytes()).hexdigest(),
    "features": rawpy.flags,
    "upstreamWindowsRecipeVcpkgTag": "2026.07.29",
    "recipeCodecVersions": {
        "zlib": "1.3.2",
        "libjpeg-turbo": "3.2.0",
        "JasPer": "4.2.9",
        "Little-CMS": "2.19.1",
    },
    "codecVersionEvidence": "Versions in the upstream pinned build recipe; individual static codec versions are not exposed by the installed DLL.",
    "binaryFiles": [
        {"filename": path.name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
        for path in raw_root.iterdir()
        if path.suffix in (".dll", ".pyd")
    ],
    "records": receipt,
}
(recipe / "RAW-BUILD-RECEIPT.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
(destination / "RAW-PREVIEW-NOTICES.txt").write_text(
    "RAW previews use rawpy "
    + rawpy.__version__
    + " (MIT) and LibRaw "
    + manifest["libraw"]
    + " (LGPL-2.1).\n"
    "The exact unmodified rawpy source archive, including LibRaw and CMake sources, accompanies the engine in resources/source/upstream.\n"
    "The upstream Windows build script and pinned codec recipes are in resources/source/vendor/rawpy/build-receipt.\n"
    "LibRaw is loaded from rawpy/raw_r.dll and is not statically linked into the Python wrapper. Modified compatible libraries may be rebuilt and substituted.\n"
    "Codec license texts, the complete NumPy/OpenBLAS/LAPACK/GCC-runtime notices, and LibRaw copyright/dual-license texts accompany this build.\n"
    "This software is based in part on the work of the Independent JPEG Group.\n"
    "The unmodified vcomp140.dll supplied by the rawpy wheel is Microsoft Visual C++ OpenMP runtime code.\n"
    "RAW camera support and rendering depend on the bundled LibRaw version; not every proprietary or computational RAW variant is supported.\n",
    encoding="utf-8",
)
import av

ffmpeg = archives / ("ffmpeg-" + av.ffmpeg_version_info + ".tar.xz")
if not ffmpeg.exists():
    with urllib.request.urlopen(
        "https://ffmpeg.org/releases/" + ffmpeg.name, timeout=60
    ) as response:
        ffmpeg.write_bytes(response.read())
