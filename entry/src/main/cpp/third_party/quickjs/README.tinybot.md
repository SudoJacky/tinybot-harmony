# Vendored QuickJS

Unmodified core files from QuickJS 2026-06-04 (Fabrice Bellard and Charlie Gordon), MIT license; see LICENSE.

Source: https://bellard.org/quickjs/quickjs-2026-06-04.tar.xz

Archive SHA-256: `b376e839b322978313d929fd20663b11ba58b75df5a46c126dd19ea2fa70ad2a`

Only the engine and its C dependencies are included. The CLI, quickjs-libc, native module loading, std and os are deliberately excluded. Build flags follow upstream (`_GNU_SOURCE`, `CONFIG_VERSION`, `-fwrapv`). Updating these files requires rerunning the native sandbox adversarial tests and the HarmonyOS build.
