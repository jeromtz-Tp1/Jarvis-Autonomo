#!/usr/bin/env bash
# Regenera windows/BUNDLE_MANIFEST.sha256 (ejecutar tras cambiar cualquier archivo del paquete).
cd "$(dirname "$0")/.." && find windows/wsl patches deploy/phase2-72h mock scripts/voice_test.py -type f | LC_ALL=C sort | xargs sha256sum > windows/BUNDLE_MANIFEST.sha256 && wc -l windows/BUNDLE_MANIFEST.sha256
