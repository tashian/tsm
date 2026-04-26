#!/usr/bin/env bash
# Publishes the @tashian/tsm npm packages.
# Order matters: platform package first, wrapper second, so the wrapper's
# optionalDependencies resolve at install time.
#
# Required env (provided by the GitHub Actions workflow):
#   - id-token: write  (OIDC for npm Trusted Publishing + sigstore provenance)
#
# Locally, run only after `npm login` and only for testing — real releases
# happen from CI so provenance attestations are valid.

set -euo pipefail

VERSION="${1:?usage: publish-npm.sh <version-without-v>}"
export VERSION

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLATFORM_DIR="${ROOT}/npm/darwin-arm64"
WRAPPER_DIR="${ROOT}/npm/wrapper"

if [[ ! -x "${ROOT}/dist/bin/tsm" || ! -x "${ROOT}/dist/bin/tsmd" ]]; then
    echo "error: dist/bin/{tsm,tsmd} missing or not executable. Run \`just build\` first." >&2
    exit 1
fi

# Stage binaries + LICENSE into the platform package
rm -rf "${PLATFORM_DIR}/bin"
mkdir -p "${PLATFORM_DIR}/bin"
cp "${ROOT}/dist/bin/tsm" "${ROOT}/dist/bin/tsmd" "${PLATFORM_DIR}/bin/"
chmod +x "${PLATFORM_DIR}/bin/tsm" "${PLATFORM_DIR}/bin/tsmd"
cp "${ROOT}/LICENSE" "${PLATFORM_DIR}/LICENSE"
cp "${ROOT}/LICENSE" "${WRAPPER_DIR}/LICENSE"

# Bump versions in both package.json files. The wrapper's optionalDependencies
# pin to the same version as the platform package.
node - "${PLATFORM_DIR}/package.json" "${WRAPPER_DIR}/package.json" <<'NODE'
const fs = require("node:fs");
for (const p of process.argv.slice(1)) {
    const pkg = JSON.parse(fs.readFileSync(p, "utf8"));
    pkg.version = process.env.VERSION;
    if (pkg.optionalDependencies) {
        for (const k of Object.keys(pkg.optionalDependencies)) {
            if (k.startsWith("@tashian/tsm-")) {
                pkg.optionalDependencies[k] = process.env.VERSION;
            }
        }
    }
    fs.writeFileSync(p, JSON.stringify(pkg, null, 2) + "\n");
}
NODE

# Publish platform package first.
( cd "${PLATFORM_DIR}" && npm publish --provenance --access public )
# Then the wrapper, whose optionalDependencies now resolve.
( cd "${WRAPPER_DIR}"  && npm publish --provenance --access public )

echo "✓ published @tashian/tsm-darwin-arm64@${VERSION}"
echo "✓ published @tashian/tsm@${VERSION}"
