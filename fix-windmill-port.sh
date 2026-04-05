#!/bin/bash
# ============================================================
# Fix Windmill: Move to port 9443 and configure properly
# Run: curl -sL <url> | bash
# ============================================================

set -euo pipefail

echo "╔═══════════════════════════════════════════════╗"
echo "║   Windmill Port Fix — Moving to port 9443     ║"
echo "╚═══════════════════════════════════════════════╝"

cd /opt/windmill

# Stop Windmill
echo "[1/4] Stopping Windmill..."
docker compose down 2>/dev/null || true

# Remove the broken Caddyfile directory if it exists
rm -rf Caddyfile 2>/dev/null || true

# Create a proper Caddyfile that listens on 9443
echo "[2/4] Creating Caddyfile for port 9443..."
cat > Caddyfile << 'EOF'
:9443 {
    reverse_proxy windmill_server:8000

    encode gzip

    # Security headers
    header {
        X-Content-Type-Options "nosniff"
        X-Frame-Options "DENY"
        Referrer-Policy "strict-origin-when-cross-origin"
        Permissions-Policy "accelerometer=(), camera=(), geolocation=(), gyroscope=(), magnetometer=(), microphone=(), payment=(), usb=()"
        -Server
    }
}
EOF

# Update docker-compose to expose port 9443 instead of 80/443
echo "[3/4] Updating docker-compose port mapping..."

# Backup original
cp docker-compose.yml docker-compose.yml.bak

# Replace Caddy port mappings
# The original maps 80:80 and 443:443 — change to 9443:9443
python3 -c "
import re
with open('docker-compose.yml', 'r') as f:
    content = f.read()

# Replace port mappings in the caddy service section
# Match patterns like '80:80' or '443:443' and replace with 9443:9443
content = re.sub(r'\"80:80\"', '\"9443:9443\"', content)
content = re.sub(r'\"443:443\"', '\"9444:9444\"', content)

with open('docker-compose.yml', 'w') as f:
    f.write(content)
print('  Port mappings updated')
"

# Start Windmill
echo "[4/4] Starting Windmill on port 9443..."
docker compose up -d 2>&1 | tail -5

echo ""
echo "Waiting 30s for startup..."
sleep 30

# Verify
if curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://localhost:9443 2>/dev/null | grep -q "200\|302"; then
  echo "✓ Windmill running on port 9443"
  echo ""
  echo "Access at: http://$(curl -s ifconfig.me 2>/dev/null || echo 'YOUR_IP'):9443"
else
  echo "⚠ Windmill may still be starting. Check with:"
  echo "  docker ps | grep windmill"
  echo "  curl -I http://localhost:9443"
fi

echo ""
echo "Done! Windmill is now on port 9443."
