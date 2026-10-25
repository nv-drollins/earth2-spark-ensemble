# Paste-ready: laptop (WSL Ubuntu) -> lab Sparks
#
# Run these INSIDE your WSL Ubuntu window, in order.
# This is the lab configuration. At the venue you change ONLY the three
# HostName lines in ~/.ssh/config -- nothing else, in any file.

# ---------------------------------------------------------------------------
# 1. Push your key to the two Sparks that do not have it yet
#    (.159 already has it). You will be asked for each Spark's password once.
# ---------------------------------------------------------------------------
ssh-copy-id nvidia@192.168.1.188      # spark-ae2c -> e2-spark-2
ssh-copy-id nvidia@192.168.1.124      # spark-862e -> e2-spark-3

# ---------------------------------------------------------------------------
# 2. Create the SSH aliases. THIS is the only file with site-specific detail.
# ---------------------------------------------------------------------------
cat >> ~/.ssh/config <<'EOF'

Host e2-spark-1
    HostName 192.168.1.159
    User nvidia

Host e2-spark-2
    HostName 192.168.1.188
    User nvidia

Host e2-spark-3
    HostName 192.168.1.124
    User nvidia

Host e2-spark-*
    BatchMode yes
    StrictHostKeyChecking accept-new
    ServerAliveInterval 30
    ServerAliveCountMax 4
EOF
chmod 600 ~/.ssh/config

# ---------------------------------------------------------------------------
# 3. Verify all three answer with NO password prompt.
#    Expect: spark-6b64 / spark-ae2c / spark-862e
# ---------------------------------------------------------------------------
for n in e2-spark-1 e2-spark-2 e2-spark-3; do printf "%-11s -> " $n; ssh $n hostname; done

# ---------------------------------------------------------------------------
# 4. Get the latest repo (it changed today: makani pin + new docs)
# ---------------------------------------------------------------------------
cd ~/earth2-spark-ensemble
git pull

# ---------------------------------------------------------------------------
# 5. Create cluster.conf. NODES uses the ALIASES, never addresses, so this
#    file is byte-identical at the lab and at the venue.
# ---------------------------------------------------------------------------
cat > cluster.conf <<'EOF'
NODES="e2-spark-1 e2-spark-2 e2-spark-3"
IMAGE="earth2-spark:1.1"
BUNDLE_DIR="$HOME/e2dist"
CACHE_DIR="$HOME/e2cache"
BASE_IMAGE="nvcr.io/nvidia/physicsnemo/physicsnemo:26.08"
E2S_VERSION="0.18.0"
MAKANI_REF="01c7776f68b72809939ba3c30c3eb0adecfc4922"
TH_REF="v0.9.2"
EOF

# ---------------------------------------------------------------------------
# 6. Confirm the laptop can drive the cluster. All three should be green.
# ---------------------------------------------------------------------------
./scripts/preflight.sh
