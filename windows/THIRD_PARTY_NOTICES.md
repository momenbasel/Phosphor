# Third-Party Notices

## Windows edition

Phosphor is copyright Moamen Basel and contributors, distributed under MIT. The Windows edition's source files are distributed under the same license.

The separate bundled Python engine uses pymobiledevice3 11.23.1 (GPL-3.0), pyiosbackup 0.2.4 (GPL-3.0), and pytypedstream 0.1.0 (LGPL-3.0). Redistribution of that combined engine is subject to those licenses. Their Python source, unmodified upstream source archives, this edition's backend, and build instructions are supplied under `resources/source`. Full dependency license texts and version records are under `resources/licenses`. PyAV and its bundled FFmpeg libraries retain their upstream notices and LGPL terms; FFmpeg sources are available at https://ffmpeg.org/download.html and PyAV sources at https://github.com/PyAV-Org/PyAV.

The interface uses Electron (MIT, with Chromium and Node third-party notices), React (MIT), Lucide (ISC), and Inter (SIL Open Font License 1.1). Copies of the project license notices accompany the build. Electron's Chromium notices are included with its runtime.

Project sources:

- https://github.com/momenbasel/Phosphor
- https://github.com/doronz88/pymobiledevice3
- https://github.com/KnugiHK/pyiosbackup
- https://github.com/dgelessus/python-typedstream
- https://www.electronjs.org/
- https://react.dev/
- https://lucide.dev/
- https://github.com/rsms/inter


## Madrid TypedStream

Phosphor includes an adapted, namespaced copy of Madrid's `TypedStream` decoder from commit `8f5f4f1`:

- Project: https://github.com/mattt/Madrid
- Copyright 2025 Mattt (https://mat.tt)
- License: MIT

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## Local PDF previews

Mozilla PDF.js/pdfjs-dist 6.4.299 is Apache-2.0. Its license and the bundled font/WASM/ICC resource notices are included under assets/licenses and resources/licenses. The compiled PDF viewer, worker, and local support resources are packaged with the renderer. No remote PDF viewer is used.

## Async developer support

aiohttp 3.14.4 and its locked dependencies provide cancellable HTTPS image downloads and Apple signing requests. Their actual distribution license texts are included in the dependency inventory. Signed developer support is downloaded only on the user’s Prepare screenshots action and is not distributed inside this installer.

## RAW image previews

rawpy 0.27.1 is MIT; its dynamically loaded LibRaw 0.22.1 is LGPL-2.1. The matching preferred source, upstream Windows build recipe, codec notices, and binary/source build receipt are supplied under resources/source/upstream and resources/source/vendor/rawpy/build-receipt. Compatible modified LibRaw libraries can replace rawpy/raw_r.dll. The detailed RAW-PREVIEW-NOTICES.txt is supplied under resources/licenses.

NumPy 2.5.3 includes BSD and composite OpenBLAS/LAPACK/GCC runtime exception notices. The upstream wheel’s codec recipes use zlib, libjpeg-turbo, JasPer, and Little CMS; their full notices accompany this build. This software is based in part on the work of the Independent JPEG Group. Camera support depends on the exact bundled LibRaw version.
