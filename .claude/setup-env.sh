#!/usr/bin/env bash
# Prepares a fresh Claude Code cloud container for REA work (idempotent).
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS=/opt/rea-tools
GHIDRA_DIR="$TOOLS/ghidra_12.1.4_PUBLIC"
JADX_JAR="$TOOLS/jadx-headless-mcp-0.7.1-all.jar"
mkdir -p "$TOOLS"

# Node 24.18.0 + npm 11.16.0 (pinned by .nvmrc / packageManager)
if [ "$(/usr/local/bin/node -v 2>/dev/null)" != "v24.18.0" ]; then
  curl -fsSL https://nodejs.org/dist/v24.18.0/node-v24.18.0-linux-x64.tar.xz | tar -xJ -C /usr/local --strip-components=1
fi
export PATH=/usr/local/bin:$PATH
[ "$(npm -v)" = "11.16.0" ] || npm i -g npm@11.16.0 >/dev/null

# Ghidra 12.1.4 (sha256 pinned in .github/workflows/ghidra-bridge-sources.yml)
if [ ! -x "$GHIDRA_DIR/support/analyzeHeadless" ]; then
  curl -fsSL -o /tmp/ghidra.zip https://github.com/NationalSecurityAgency/ghidra/releases/download/Ghidra_12.1.4_build/ghidra_12.1.4_PUBLIC_20260921.zip
  echo "ddac49f903da9d5bac833e5cc79395098b9c33cfd3279be5f31bd00387d2d4db  /tmp/ghidra.zip" | sha256sum -c -
  unzip -q /tmp/ghidra.zip -d "$TOOLS" && rm /tmp/ghidra.zip
fi

# jadx-headless-mcp 0.7.1 (sha256 from docs/android-analysis.md)
if [ ! -f "$JADX_JAR" ]; then
  curl -fsSL -o "$JADX_JAR" https://github.com/1013503897/jadx-headless-mcp/releases/download/v0.7.1/jadx-headless-mcp-0.7.1-all.jar
  echo "6e5eacf500b64292bfb73c49797c1958f6ee44646e43e868039ae7feb573ff75  $JADX_JAR" | sha256sum -c -
fi

# Hopper's .deb names pre-t64 Qt6 packages; Ubuntu 24.04 renamed them. Shim the old names.
if ! dpkg -s libqt6network6 >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq && apt-get install -y -qq equivs libqt6gui6t64 libqt6xml6t64 libqt6printsupport6t64 libqt6network6t64 >/dev/null
  shim=$(mktemp -d)
  for p in libqt6gui6 libqt6xml6 libqt6printsupport6 libqt6network6; do
    printf 'Package: %s\nVersion: 6.4.2+dfsg-21.1build5+shim1\nDepends: %st64\nDescription: t64 rename shim\n' "$p" "$p" > "$shim/$p.ctl"
    (cd "$shim" && equivs-build "$p.ctl" >/dev/null)
  done
  dpkg -i "$shim"/*.deb >/dev/null
fi

cd "$REPO"
git submodule update --init --recursive -q
[ -d node_modules ] || npm ci --no-audit --no-fund
npm run build:cached >/dev/null

# Hopper install + Claude Code MCP registration + REA skill (additive, backs up config)
GHIDRA_INSTALL_DIR="$GHIDRA_DIR" REA_JADX_MCP_JAR="$JADX_JAR" \
  node scripts/rea.mjs setup --client claude_code --install-hopper --yes >/dev/null

if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  {
    echo "export PATH=/usr/local/bin:\$PATH"
    echo "export GHIDRA_INSTALL_DIR=$GHIDRA_DIR"
    echo "export REA_JADX_MCP_JAR=$JADX_JAR"
    echo "export HOPPER_LAUNCHER_PATH=/opt/hopper/bin/Hopper"
    echo "export REA_ANALYSIS_PROVIDER=ghidra"
  } >> "$CLAUDE_ENV_FILE"
fi
