#!/bin/bash
# Walle consumer project setup — runs inside the devcontainer at postCreate time.
set -euo pipefail

echo "[INFO] Enabling corepack"
corepack enable || echo "[WARN] corepack enable failed, continuing"
