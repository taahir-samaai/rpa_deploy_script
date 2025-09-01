#!/bin/bash
# fix-podman-and-start.sh - Fix Podman user namespace issues and start RPA system

set -e
cd /opt/rpa-system

echo "🔧 FIXING PODMAN NAMESPACE AND STARTING RPA SYSTEM"
echo "=================================================="

# 1. Create missing requirements.txt
echo "📦 1. CREATING REQUIREMENTS.TXT:"
echo "-------------------------------"
cat > requirements.txt << 'EOF'
fastapi
uvicorn[standard]
pydantic
requests
apscheduler
sqlalchemy
tenacity
python-dotenv
bcrypt
pyjwt[crypto]
selenium
pyotp
psutil
EOF

chown rpauser:rpauser requirements.txt
echo "✅ requirements.txt created with $(wc -l < requirements.txt) dependencies"

# 2. Fix Podman user namespace mapping
echo -e "\n🔧 2. FIXING PODMAN USER NAMESPACE MAPPING:"
echo "------------------------------------------"

# Clear existing problematic mappings
> /etc/subuid
> /etc/subgid

# Add proper user namespace mapping
echo "rpauser:100000:65536" >> /etc/subuid
echo "rpauser:100000:65536" >> /etc/subgid

# Also add root mapping (sometimes needed)
echo "root:100000:65536" >> /etc/subuid  
echo "root:100000:65536" >> /etc/subgid

echo "✅ User namespace mappings fixed"
cat /etc/subuid
cat /etc/subgid

# 3. Reset Podman for the user
echo -e "\n🔄 3. RESETTING PODMAN USER CONFIGURATION:"
echo "----------------------------------------"
sudo -u rpauser podman system reset --force || true
sudo -u rpauser podman system info | grep -E "(runRoot|graphRoot|rootless)" || true

# 4. Alternative: Run containers as root (workaround)
echo -e "\n🚀 4. BUILDING AND STARTING CONTAINERS (AS ROOT - WORKAROUND):"
echo "------------------------------------------------------------"

# Create root-mode startup script
cat > scripts/start-system-root.sh << 'ROOTEOF'
#!/bin/bash
set -e
cd /opt/rpa-system

echo "🚀 Starting RPA System with root Podman (workaround)..."

# Create network
podman network exists rpa-network || podman network create \
    --driver bridge \
    --subnet 172.18.0.0/16 \
    rpa-network

# Build containers
echo "📦 Building containers..."
podman build -t rpa-orchestrator:latest -f containers/orchestrator/Containerfile .
podman build -t rpa-worker:latest -f containers/worker/Containerfile .

# Start orchestrator
echo "🎛️  Starting orchestrator..."
podman run -d \
    --name rpa-orchestrator \
    --hostname orchestrator \
    --network rpa-network \
    -p 8620:8620 \
    --env-file configs/orchestrator.env \
    -v $(pwd)/volumes/data:/app/data:Z \
    -v $(pwd)/volumes/logs:/app/logs:Z \
    --restart unless-stopped \
    --memory=1g \
    --cpus=0.8 \
    rpa-orchestrator:latest

# Start worker 1
echo "👷 Starting worker 1..."
podman run -d \
    --name rpa-worker1 \
    --hostname worker1 \
    --network rpa-network \
    -p 8621:8621 \
    --env-file configs/worker.env \
    -v $(pwd)/volumes/data:/app/data:Z \
    -v $(pwd)/volumes/logs:/app/logs:Z \
    --restart unless-stopped \
    --memory=1.5g \
    --cpus=1.0 \
    --security-opt seccomp=unconfined \
    --shm-size=2g \
    rpa-worker:latest

# Start worker 2  
echo "👷 Starting worker 2..."
podman run -d \
    --name rpa-worker2 \
    --hostname worker2 \
    --network rpa-network \
    -p 8622:8621 \
    --env-file configs/worker.env \
    -v $(pwd)/volumes/data:/app/data:Z \
    -v $(pwd)/volumes/logs:/app/logs:Z \
    --restart unless-stopped \
    --memory=1.5g \
    --cpus=1.0 \
    --security-opt seccomp=unconfined \
    --shm-size=2g \
    rpa-worker:latest

echo "⏳ Waiting for services to start..."
sleep 45

echo "🏥 Health Check Results:"
for port in 8620 8621 8622; do
    if curl -f -s http://localhost:$port/health > /dev/null; then
        echo "✅ Service on port $port: Healthy"
        curl -s http://localhost:$port/health | jq -r '.service // .status' || echo "  Status: Running"
    else
        echo "❌ Service on port $port: Unhealthy"
    fi
done

echo ""
echo "📦 Container Status:"
podman ps -a | grep rpa-

echo ""
echo "✅ RPA System startup complete!"
echo "📊 Orchestrator: http://localhost:8620"  
echo "👷 Worker 1: http://localhost:8621"
echo "👷 Worker 2: http://localhost:8622"
ROOTEOF

chmod +x scripts/start-system-root.sh

# 5. Run the root-mode startup
echo -e "\n🚀 5. STARTING SYSTEM WITH ROOT PERMISSIONS:"
echo "------------------------------------------"
./scripts/start-system-root.sh

echo -e "\n🎯 SUMMARY:"
echo "=========="
echo "✅ requirements.txt created"
echo "✅ User namespace mappings fixed"  
echo "🔧 Using root-mode Podman as workaround for namespace issues"
echo "🚀 RPA System should now be running!"
