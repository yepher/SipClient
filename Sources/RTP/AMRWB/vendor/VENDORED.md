# vo-amrwbenc (vendored)

AMR-WB (G.722.2) **encoder**. macOS ships an AMR-WB decoder in AudioToolbox
(`kAudioFormatAMR_WB`) but no encoder, so the send path needs this; the
receive path uses the system decoder and links nothing extra.

- Upstream: https://sourceforge.net/projects/opencore-amr/ (vo-amrwbenc)
- Version:  0.1.3
- Tarball SHA-256: 5652b391e0f0e296417b841b02987d3fd33e6c0af342c69542cbb016a71d9d4e
- License:  Apache-2.0 (see LICENSE-vo-amrwbenc.txt, NOTICE-vo-amrwbenc.txt — both are
  bundled into the app as resources to satisfy Apache-2.0 §4(a))

## What was copied

`wrapper.c`, `enc_if.h`, `common/cmnMemory.c`, `common/include/*.h`,
`amrwbenc/src/*.c`, `amrwbenc/inc/*` — i.e. exactly `libvo_amrwbenc_la_SOURCES`
from upstream `Makefile.am`, generic C path only.

## What was deliberately left out

- `amrwbenc/src/asm/ARMV5E`, `amrwbenc/src/asm/ARMV7` — 32-bit ARM assembly,
  unusable on arm64/x86_64. Upstream gates these behind `-DARM -DASM_OPT`,
  which we do **not** define, so the equivalent C is compiled instead.
- `amrwb-enc.c`, `wavreader.c` — upstream's CLI example program.
- autotools machinery, `SampleCode/`, `doc/`.

## Build integration

Compiled directly into the app target by XcodeGen (see `project.yml`):
header search paths point at `amrwbenc/inc` and `common/include`, and
`Sources/SipClient-Bridging-Header.h` exposes `enc_if.h` to Swift.
The `.tab` files are `#include`d by the C sources and are excluded from the
Xcode project so they aren't copied into the app bundle as resources.

Do not edit these files; re-vendor from upstream instead.
