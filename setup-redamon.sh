#!/bin/bash
# ============================================================
# GRIMSEC — RedAmon Adversary Simulation Setup
# Stops Windmill to free RAM, installs RedAmon
# Run: bash setup-redamon.sh
# ============================================================

set -euo pipefail

echo "╔═══════════════════════════════════════════════╗"
echo "║   GRIMSEC — RedAmon Setup                     ║"
echo "║   Adversary Simulation Framework              ║"
echo "╚═══════════════════════════════════════════════╝"

# ── Step 1: Free up resources ────────────────────
echo ""
echo "[1/5] Freeing RAM — stopping Windmill..."
cd /opt/windmill 2>/dev/null && docker compose down 2>/dev/null || true
echo "  ✓ Windmill stopped"

echo ""
echo "  Current memory:"
free -h | grep Mem

# ── Step 2: Clone RedAmon ────────────────────────
echo ""
echo "[2/5] Cloning RedAmon..."
cd /opt
if [ -d redamon ]; then
  echo "  RedAmon already exists, pulling latest..."
  cd redamon && git pull 2>/dev/null || true
else
  git clone https://github.com/samugit83/redamon.git
  cd redamon
fi
echo "  ✓ RedAmon cloned"

# ── Step 3: Create env file ──────────────────────
echo ""
echo "[3/5] Configuring environment..."

if [ ! -f .env ]; then
  cp .env.example .env 2>/dev/null || true
fi

# Check if OpenAI key is set
if ! grep -q "OPENAI_API_KEY=sk-" .env 2>/dev/null; then
  echo ""
  echo "  ⚠ IMPORTANT: RedAmon needs an LLM API key."
  echo "  Edit /opt/redamon/.env and add ONE of these:"
  echo ""
  echo "    OPENAI_API_KEY=sk-your-key-here"
  echo "    ANTHROPIC_API_KEY=sk-ant-your-key-here"
  echo ""
  echo "  You can also use Ollama for free local inference"
  echo "  (but it needs more RAM — not recommended with 8GB)"
  echo ""
  echo "  After adding your key, run:"
  echo "    cd /opt/redamon && ./redamon.sh install"
  echo ""
  echo "  The install takes 10-15 minutes for first run."
fi

echo "  ✓ Environment configured"

# ── Step 4: Open firewall port ───────────────────
echo ""
echo "[4/5] RedAmon runs on port 3000 (webapp) and 8090 (agent API)..."
echo "  These ports are blocked by your firewall (good for security)"
echo "  Access RedAmon via SSH tunnel instead:"
echo ""
echo "  ssh -L 3000:localhost:3000 -L 8090:localhost:8090 root@72.62.76.53"
echo ""
echo "  Then open http://localhost:3000 in your browser"

# ── Step 5: Install RedAmon ──────────────────────
echo ""
echo "[5/5] Starting RedAmon install (without GVM to save RAM)..."
echo "  This will take 10-15 minutes on first run..."
echo ""

cd /opt/redamon
chmod +x redamon.sh

# Check if .env has an API key before installing
if grep -qE "OPENAI_API_KEY=sk-|ANTHROPIC_API_KEY=sk-ant-" .env 2>/dev/null; then
  ./redamon.sh install
  
  echo ""
  echo "╔═══════════════════════════════════════════════╗"
  echo "║   RedAmon Installed                           ║"
  echo "║                                               ║"
  echo "║   Web UI: http://localhost:3000               ║"
  echo "║   (use SSH tunnel to access)                  ║"
  echo "║                                               ║"
  echo "║   SSH tunnel command:                         ║"
  echo "║   ssh -L 3000:localhost:3000 root@72.62.76.53 ║"
  echo "╚═══════════════════════════════════════════════╝"
else
  echo "  ⏸ Skipping install — no API key configured yet."
  echo ""
  echo "  To complete setup:"
  echo "  1. Edit /opt/redamon/.env and add your API key"
  echo "  2. Run: cd /opt/redamon && ./redamon.sh install"
  echo ""
  echo "  After install, access via SSH tunnel:"
  echo "  ssh -L 3000:localhost:3000 root@72.62.76.53"
  echo "  Then open http://localhost:3000"
fi
