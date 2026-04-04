#!/bin/bash
# ============================================================
# GRIMSEC DAST Runner — Automated scan + push to GitHub
# Run on your Hostinger VPS: bash grimsec-dast-runner.sh
# ============================================================

set -euo pipefail

echo "╔═══════════════════════════════════════════════╗"
echo "║   GRIMSEC DAST Runner v1.0                    ║"
echo "║   Automated Nuclei scanning + GitHub push     ║"
echo "╚═══════════════════════════════════════════════╝"

# ── Config ──────────────────────────────────────────
RESULTS_DIR="/opt/grimsec-dast"
GITHUB_REPO="camgrimsec/grimsec"
BRANCH="dast-results"

mkdir -p "$RESULTS_DIR"

# ── Step 1: Install tools ───────────────────────────
echo ""
echo "[1/6] Installing tools..."

# Go (if needed)
if ! command -v go &>/dev/null; then
  echo "  → Installing Go..."
  curl -sL https://go.dev/dl/go1.22.5.linux-amd64.tar.gz | tar -C /usr/local -xzf -
  export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin
  echo 'export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin' >> ~/.bashrc
fi

# Nuclei
if ! command -v nuclei &>/dev/null; then
  echo "  → Installing Nuclei..."
  go install -v github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest 2>&1 | tail -1
fi
export PATH=$PATH:$HOME/go/bin

echo "  → Updating Nuclei templates..."
nuclei -update-templates -silent 2>/dev/null || true

# Git config
git config --global user.email "grimsec-bot@sectheops.com"
git config --global user.name "GRIMSEC DAST Runner"

echo "  ✓ Tools ready"

# ── Step 2: Stand up Windmill ───────────────────────
echo ""
echo "[2/6] Starting Windmill..."

mkdir -p /opt/windmill && cd /opt/windmill
if [ ! -f docker-compose.yml ]; then
  curl -sL https://raw.githubusercontent.com/windmill-labs/windmill/main/docker-compose.yml -o docker-compose.yml
  curl -sL https://raw.githubusercontent.com/windmill-labs/windmill/main/.env -o .env
fi
# Ensure .env exists with WM_IMAGE
if [ ! -f .env ] || ! grep -q WM_IMAGE .env; then
  echo 'WM_IMAGE=ghcr.io/windmill-labs/windmill:main' >> .env
  echo 'DATABASE_URL=postgres://postgres:changeme@db/windmill?sslmode=disable' >> .env
fi
docker compose up -d 2>&1 | tail -5
echo "  Waiting 30s for startup..."
sleep 30

# Check if running
if curl -s -o /dev/null -w "%{http_code}" http://localhost:8000 | grep -q "200\|302\|301"; then
  echo "  ✓ Windmill running on :8000"
else
  echo "  ⚠ Windmill may not be fully ready, scanning anyway..."
fi

# ── Step 3: Stand up SigNoz ─────────────────────────
echo ""
echo "[3/6] Starting SigNoz..."

cd /opt
if [ ! -d signoz ]; then
  git clone --depth=1 -b main https://github.com/SigNoz/signoz.git
fi
cd signoz/deploy/docker
docker compose up -d 2>&1 | tail -5
echo "  Waiting 45s for startup..."
sleep 45

if curl -s -o /dev/null -w "%{http_code}" http://localhost:3301 | grep -q "200\|302\|301"; then
  echo "  ✓ SigNoz running on :3301"
else
  echo "  ⚠ SigNoz may not be fully ready, scanning anyway..."
fi

# ── Step 4: Run DAST scans ──────────────────────────
echo ""
echo "[4/6] Running Nuclei scans..."

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
DATE_SHORT=$(date -u +"%Y%m%d")

# Windmill scan
echo "  → Scanning Windmill (port 8000)..."
nuclei -u http://localhost:8000 \
  -severity critical,high,medium,low \
  -jsonl \
  -o "$RESULTS_DIR/windmill-nuclei-${DATE_SHORT}.jsonl" \
  -silent 2>/dev/null || true

WINDMILL_COUNT=$(wc -l < "$RESULTS_DIR/windmill-nuclei-${DATE_SHORT}.jsonl" 2>/dev/null || echo "0")
echo "  ✓ Windmill: ${WINDMILL_COUNT} findings"

# SigNoz scan
echo "  → Scanning SigNoz (port 3301)..."
nuclei -u http://localhost:3301 \
  -severity critical,high,medium,low \
  -jsonl \
  -o "$RESULTS_DIR/signoz-nuclei-${DATE_SHORT}.jsonl" \
  -silent 2>/dev/null || true

SIGNOZ_COUNT=$(wc -l < "$RESULTS_DIR/signoz-nuclei-${DATE_SHORT}.jsonl" 2>/dev/null || echo "0")
echo "  ✓ SigNoz: ${SIGNOZ_COUNT} findings"

# Header audits
echo "  → Running header audits..."
for app in "windmill:8000" "signoz:3301"; do
  NAME="${app%%:*}"
  PORT="${app##*:}"
  {
    echo "=== ${NAME} (port ${PORT}) ==="
    echo "Timestamp: ${TIMESTAMP}"
    echo ""
    echo "--- Response Headers ---"
    curl -sI "http://localhost:${PORT}" 2>/dev/null
    echo ""
    echo "--- Security Headers Check ---"
    echo "Content-Security-Policy: $(curl -sI http://localhost:${PORT} 2>/dev/null | grep -i 'content-security-policy' || echo 'MISSING')"
    echo "X-Frame-Options: $(curl -sI http://localhost:${PORT} 2>/dev/null | grep -i 'x-frame-options' || echo 'MISSING')"
    echo "X-Content-Type-Options: $(curl -sI http://localhost:${PORT} 2>/dev/null | grep -i 'x-content-type-options' || echo 'MISSING')"
    echo "Strict-Transport-Security: $(curl -sI http://localhost:${PORT} 2>/dev/null | grep -i 'strict-transport' || echo 'MISSING')"
    echo "X-Powered-By: $(curl -sI http://localhost:${PORT} 2>/dev/null | grep -i 'x-powered-by' || echo 'not disclosed')"
    echo ""
    echo "--- CORS Check ---"
    curl -sI -H "Origin: https://evil.com" "http://localhost:${PORT}" 2>/dev/null | grep -i 'access-control' || echo "No CORS headers"
    echo ""
    echo "--- HTTP Methods ---"
    for method in OPTIONS PUT DELETE TRACE; do
      CODE=$(curl -s -o /dev/null -w "%{http_code}" -X ${method} "http://localhost:${PORT}" 2>/dev/null)
      echo "${method}: ${CODE}"
    done
    echo ""
  } > "$RESULTS_DIR/${NAME}-headers-${DATE_SHORT}.txt"
done
echo "  ✓ Header audits complete"

# ── Step 5: Generate summary ────────────────────────
echo ""
echo "[5/6] Generating scan summary..."

cat > "$RESULTS_DIR/scan-summary-${DATE_SHORT}.md" << EOF
# GRIMSEC DAST Scan Results — ${TIMESTAMP}

## Scan Environment
- **Runner:** GRIMSEC DAST Runner v1.0
- **VPS:** $(hostname)
- **Nuclei version:** $(nuclei -version 2>&1 | head -1)
- **Scan date:** ${TIMESTAMP}

## Windmill
- **Target:** http://localhost:8000
- **Nuclei findings:** ${WINDMILL_COUNT}
- **Header audit:** windmill-headers-${DATE_SHORT}.txt
- **Raw results:** windmill-nuclei-${DATE_SHORT}.jsonl

## SigNoz
- **Target:** http://localhost:3301
- **Nuclei findings:** ${SIGNOZ_COUNT}
- **Header audit:** signoz-headers-${DATE_SHORT}.txt
- **Raw results:** signoz-nuclei-${DATE_SHORT}.jsonl

## Files
\`\`\`
$(ls -la $RESULTS_DIR/*${DATE_SHORT}*)
\`\`\`
EOF

echo "  ✓ Summary generated"

# ── Step 6: Push to GitHub ──────────────────────────
echo ""
echo "[6/6] Pushing results to GitHub..."

cd /opt
if [ ! -d grimsec-repo ]; then
  git clone "https://github.com/${GITHUB_REPO}.git" grimsec-repo 2>/dev/null || {
    echo "  ⚠ Could not clone repo. Make sure git credentials are configured."
    echo "  Run: gh auth login  OR  set up a GitHub PAT"
    echo ""
    echo "  Results saved locally at: ${RESULTS_DIR}/"
    echo "  You can manually push or paste the results."
    exit 0
  }
fi

cd grimsec-repo
git pull origin main 2>/dev/null || true

# Create dast-results directory in repo
mkdir -p dast-results/
cp "$RESULTS_DIR"/*"${DATE_SHORT}"* dast-results/

git add dast-results/
git commit -m "feat(dast): automated DAST scan results — ${DATE_SHORT}

Windmill: ${WINDMILL_COUNT} Nuclei findings
SigNoz: ${SIGNOZ_COUNT} Nuclei findings
Runner: GRIMSEC DAST Runner v1.0" 2>/dev/null || echo "  No changes to commit"

git push origin main 2>/dev/null || {
  echo "  ⚠ Push failed. You may need to configure git credentials:"
  echo "     gh auth login"
  echo "     OR: git remote set-url origin https://<PAT>@github.com/${GITHUB_REPO}.git"
}

# ── Step 7: Cleanup (optional) ──────────────────────
echo ""
echo "╔═══════════════════════════════════════════════╗"
echo "║   DAST Scan Complete                          ║"
echo "║                                               ║"
echo "║   Windmill: ${WINDMILL_COUNT} findings                      ║"
echo "║   SigNoz:   ${SIGNOZ_COUNT} findings                      ║"
echo "║                                               ║"
echo "║   Results: ${RESULTS_DIR}/     ║"
echo "║   Pushed to: github.com/${GITHUB_REPO}        ║"
echo "╚═══════════════════════════════════════════════╝"
echo ""
echo "To tear down the apps and free resources:"
echo "  cd /opt/windmill && docker compose down"
echo "  cd /opt/signoz/deploy && docker compose down"
echo "  docker system prune -f"
