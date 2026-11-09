from PyInstaller.utils.hooks import (
    collect_all,
    collect_submodules,
    collect_data_files,
    copy_metadata,
)

datas = []
binaries = []
hiddenimports = []
for name in [
    "pymobiledevice3",
    "typedstream",
    "pillow_heif",
    "pytun_pmd3",
    "developer_disk_image",
    "rawpy",
]:
    d, b, h = collect_all(name)
    datas += d
    binaries += b
    hiddenimports += h
hiddenimports += [
    "win32api",
    "win32con",
    "win32job",
    "win32com.shell.shell",
    "win32com.shell.shellcon",
    "pythoncom",
    "PIL.Image",
    "PIL.ImageOps",
    "cryptography.hazmat.primitives.ciphers",
    "cryptography.hazmat.primitives.keywrap",
]
# The image mounter imports pyimg4 through Apple's signing/firmware parser.
# pyimg4 reads its installed distribution version at import time; its code
# alone is insufficient in a frozen executable.
datas += copy_metadata("pyimg4")
a = Analysis(
    ["backend/worker.py"],
    pathex=["backend"],
    binaries=binaries,
    datas=datas,
    hiddenimports=hiddenimports,
    excludes=["pytest", "tkinter", "IPython", "jedi", "matplotlib", "test", "tests"],
    noarchive=False,
)
pyz = PYZ(a.pure)
exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name="phosphor-engine",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=True,
    icon="assets/icon.ico",
)
coll = COLLECT(exe, a.binaries, a.datas, strip=False, upx=False, name="phosphor-engine")
