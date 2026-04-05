#!/bin/bash
# ============================================================
# GRIMSEC VPS Setup — Complete security lab configuration
# Moves all services to non-standard ports, installs scan tools,
# sets up automated DAST scanning with cron
#
# Run: bash grimsec-vps-setup.sh
# ============================================================

set -euo pipefail

echo "╔═══════════════════════════════════════════════╗"
echo "║   GRIMSEC VPS Lab Setup v2.0                  ║"
echo "║   Secure ports + scan tools + automation      ║"
echo "╚═══════════════════════════════════════════════╝"

VPS_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
echo "VPS IP: ${VPS_IP}"
echo ""

# ── Step 1: Install scan tools ──────────────────────
echo "[1/6] Installing scan tools..."

# Go
if ! command -v go &>/dev/null; then
  echo "  → Installing Go..."
  curl -sL https://go.dev/dl/go1.22.5.linux-amd64.tar.gz | tar -C /usr/local -xzf -
  export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin
  echo 'export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin' >> ~/.bashrc
else
  export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin
fi

# Nuclei
if ! command -v nuclei &>/dev/null; then
  echo "  → Installing Nuclei..."
  go install -v github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest 2>&1 | tail -1
fi
nuclei -update-templates -silent 2>/dev/null || true

# httpx
if ! command -v httpx &>/dev/null; then
  echo "  → Installing httpx..."
  go install -v github.com/projectdiscovery/httpx/cmd/httpx@latest 2>&1 | tail -1
fi

echo "  ✓ Scan tools ready"

# ── Step 2: Configure SigNoz on port 7777 ──────────
echo ""
echo "[2/6] Moving SigNoz to port 7777..."

cd /opt/signoz/deploy/docker 2>/dev/null || {
  echo "  SigNoz not found at /opt/signoz — skipping"
}

if [ -f docker-compose.yaml ]; then
  docker compose down 2>/dev/null || true
  
  # Backup
  cp docker-compose.yaml docker-compose.yaml.bak 2>/dev/null || true
  
  # Change port mapping from 8080:8080 to 7777:8080
  sed -i 's/"8080:8080"/"7777:8080"/g' docker-compose.yaml
  sed -i "s/'8080:8080'/'7777:8080'/g" docker-compose.yaml
  
  docker compose up -d 2>&1 | tail -3
  echo "  ✓ SigNoz moved to port 7777"
fi

# ── Step 3: Configure Windmill on port 9443 ─────────
echo ""
echo "[3/6] Moving Windmill to port 9443..."

cd /opt/windmill 2>/dev/null || {
  echo "  Windmill not found at /opt/windmill — skipping"
}

if [ -f docker-compose.yml ]; then
  docker compose down 2>/dev/null || true
  
  # Remove broken Caddyfile if it's a directory
  [ -d Caddyfile ] && rm -rf Caddyfile
  
  # Create proper Caddyfile
  cat > Caddyfile << 'CADDYEOF'
:9443 {
    reverse_proxy windmill_server:8000

    encode gzip

    header {
        X-Content-Type-Options "nosniff"
        X-Frame-Options "DENY"
        X-XSS-Protection "1; mode=block"
        Referrer-Policy "strict-origin-when-cross-origin"
        Permissions-Policy "accelerometer=(), camera=(), geolocation=(), gyroscope=(), magnetometer=(), microphone=(), payment=(), usb=()"
        -Server
    }
}
CADDYEOF

  # Backup
  cp docker-compose.yml docker-compose.yml.bak 2>/dev/null || true
  
  # Change Caddy port from 80 to 9443
  sed -i 's/"80:80"/"9443:9443"/g' docker-compose.yml
  sed -i 's/"443:443"/"9444:9444"/g' docker-compose.yml
  
  # Make sure .env exists
  if [ ! -f .env ] || ! grep -q WM_IMAGE .env; then
    echo 'WM_IMAGE=ghcr.io/windmill-labs/windmill:main' >> .env
    echo 'DATABASE_URL=postgres://postgres:changeme@db/windmill?sslmode=disable' >> .env
  fi
  
  docker compose up -d 2>&1 | tail -3
  echo "  ✓ Windmill moved to port 9443"
fi

# ── Step 4: Wait for services ───────────────────────
echo ""
echo "[4/6] Waiting 45s for services to start..."
sleep 45

echo "  Service status:"
for svc in "SigNoz:7777" "Windmill:9443"; do
  NAME="${svc%%:*}"
  PORT="${svc##*:}"
  CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://localhost:${PORT} 2>/dev/null || echo "000")
  if [ "$CODE" = "200" ] || [ "$CODE" = "302" ]; then
    echo "  ✓ ${NAME} → http://${VPS_IP}:${PORT} (${CODE})"
  else
    echo "  ⚠ ${NAME} → port ${PORT} returned ${CODE}"
  fi
done

# ── Step 5: Create GRIMSEC scan script ──────────────
echo ""
echo "[5/6] Creating automated scan script..."

mkdir -p /opt/grimsec/scans /opt/grimsec/results

cat > /opt/grimsec/run-dast.sh << 'SCANEOF'
#!/bin/bash
# GRIMSEC Automated DAST Scanner
# Runs Nuclei + header audits against all lab targets

export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin
DATE=$(date -u +"%Y%m%d-%H%M")
RESULTS="/opt/grimsec/results/${DATE}"
mkdir -p "$RESULTS"

echo "[$(date -u)] GRIMSEC DAST scan starting..."

# Define targets
declare -A TARGETS
TARGETS[signoz]=7777
TARGETS[windmill]=9443

for APP in "${!TARGETS[@]}"; do
  PORT=${TARGETS[$APP]}
  URL="http://localhost:${PORT}"
  
  # Check if target is up
  CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$URL" 2>/dev/null)
  if [ "$CODE" = "000" ]; then
    echo "  ⚠ ${APP} (port ${PORT}) not reachable — skipping"
    continue
  fi
  
  echo "  → Scanning ${APP} on port ${PORT}..."
  
  # Nuclei scan
  nuclei -u "$URL" \
    -severity critical,high,medium,low,info \
    -jsonl \
    -o "${RESULTS}/${APP}-nuclei.jsonl" \
    -silent -timeout 10 -rate-limit 50 2>/dev/null || true
  
  NUCLEI_COUNT=$(wc -l < "${RESULTS}/${APP}-nuclei.jsonl" 2>/dev/null || echo "0")
  
  # Header audit
  {
    echo "=== ${APP} DAST Report ==="
    echo "Target: ${URL}"
    echo "Scan: ${DATE}"
    echo ""
    echo "--- Response Headers ---"
    curl -sI --max-time 5 "$URL"
    echo ""
    echo "--- Security Headers ---"
    for h in content-security-policy x-frame-options x-content-type-options strict-transport-security referrer-policy permissions-policy; do
      val=$(curl -sI --max-time 5 "$URL" | grep -i "^${h}:" | head -1)
      [ -n "$val" ] && echo "✓ $val" || echo "✗ ${h}: MISSING"
    done
    echo ""
    echo "--- HTTP Methods ---"
    for m in OPTIONS PUT DELETE TRACE; do
      c=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 -X "$m" "$URL" 2>/dev/null)
      echo "$m: $c"
    done
    echo ""
    echo "--- API Probes ---"
    for ep in /api/v1/version /api/v1/health /api/v1/config; do
      resp=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" "${URL}${ep}" 2>/dev/null)
      echo "${ep} → ${resp}"
    done
  } > "${RESULTS}/${APP}-headers.txt"
  
  echo "    Nuclei: ${NUCLEI_COUNT} findings | Headers: saved"
done

# Generate summary
{
  echo "# GRIMSEC DAST Scan — ${DATE}"
  echo ""
  echo "| App | Nuclei Findings | Port |"
  echo "|-----|----------------|------|"
  for APP in "${!TARGETS[@]}"; do
    PORT=${TARGETS[$APP]}
    COUNT=$(wc -l < "${RESULTS}/${APP}-nuclei.jsonl" 2>/dev/null || echo "0")
    echo "| ${APP} | ${COUNT} | ${PORT} |"
  done
  echo ""
  echo "Results: ${RESULTS}/"
} > "${RESULTS}/summary.md"

echo "[$(date -u)] Scan complete. Results: ${RESULTS}/"
cat "${RESULTS}/summary.md"
SCANEOF

chmod +x /opt/grimsec/run-dast.sh

echo "  ✓ Scan script: /opt/grimsec/run-dast.sh"

# ── Step 6: Set up weekly cron ──────────────────────
echo ""
echo "[6/6] Setting up weekly cron (Monday 6AM UTC)..."

# Add cron job (idempotent — removes old one first)
crontab -l 2>/dev/null | grep -v "grimsec" | crontab -
(crontab -l 2>/dev/null; echo "0 6 * * 1 /opt/grimsec/run-dast.sh >> /var/log/grimsec-dast.log 2>&1") | crontab -

echo "  ✓ Cron: Every Monday at 6AM UTC"
echo "    Log: /var/log/grimsec-dast.log"

# ── Summary ─────────────────────────────────────────
echo ""
echo "╔═══════════════════════════════════════════════╗"
echo "║   Setup Complete                              ║"
echo "╠═══════════════════════════════════════════════╣"
echo "║                                               ║"
echo "║   SigNoz:   http://${VPS_IP}:7777          ║"
echo "║   Windmill: http://${VPS_IP}:9443          ║"
echo "║                                               ║"
echo "║   Manual scan: /opt/grimsec/run-dast.sh       ║"
echo "║   Auto scan:   Mondays 6AM UTC               ║"
echo "║   Results:     /opt/grimsec/results/          ║"
echo "║                                               ║"
echo "╚═══════════════════════════════════════════════╝"
echo ""
echo "Run a scan now?  /opt/grimsec/run-dast.sh"
echo "Check results:   ls /opt/grimsec/results/"
echo ""
echo "To tear down apps:"
echo "  cd /opt/signoz/deploy/docker && docker compose down"
echo "  cd /opt/windmill && docker compose down"
