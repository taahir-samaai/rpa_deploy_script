#!/bin/bash
# RPA Production Deployment Script - 5 Workers + 1 Orchestrator (Pod Architecture)
# Single-threaded architecture for maximum predictability

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RPA_HOME="/opt/rpa-system"
RPA_USER="rpauser"
RPA_GROUP="rpauser"
LOG_FILE="/var/log/rpa-deployment.log"
DISCOVERY_DIR=""
ENVIRONMENT_TYPE="production"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Logging functions
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
    log "INFO: $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
    log "SUCCESS: $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
    log "WARNING: $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    log "ERROR: $1"
    exit 1
}

section() {
    echo -e "\n${CYAN}================================================${NC}"
    echo -e "${CYAN} $1 ${NC}"
    echo -e "${CYAN}================================================${NC}"
    log "SECTION: $1"
}

# Usage information
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Deploy RPA system with 5 single-threaded workers + 1 orchestrator in pod architecture.

OPTIONS:
    -d, --discovery-dir DIR    Path to environment discovery directory (required)
    -e, --environment TYPE     Environment type (production, staging, development) [default: production]
    -h, --help                Show this help message

EXAMPLES:
    $0 -d ./environment-discovery-20250904-130738
    $0 -d /path/to/discovery --environment production

POD ARCHITECTURE:
    - 1 Pod containing 6 containers
    - 1 Orchestrator (single-threaded) on port 8620
    - 5 Workers (single-threaded) on ports 8621-8625
    - Shared networking: containers communicate via localhost
    - Total capacity: 5 concurrent automation jobs

EOF
}

# Parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -d|--discovery-dir)
                DISCOVERY_DIR="$2"
                shift 2
                ;;
            -e|--environment)
                ENVIRONMENT_TYPE="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                error "Unknown option: $1. Use -h for help."
                ;;
        esac
    done

    if [[ -z "$DISCOVERY_DIR" ]]; then
        error "Discovery directory is required. Use: $0 -d /path/to/discovery-dir"
    fi

    if [[ ! -d "$DISCOVERY_DIR" ]]; then
        error "Discovery directory does not exist: $DISCOVERY_DIR"
    fi

    DISCOVERY_DIR="$(cd "$DISCOVERY_DIR" && pwd)"
    
    info "Using discovery directory: $DISCOVERY_DIR"
    info "Target environment: $ENVIRONMENT_TYPE"
    info "Architecture: 5 single-threaded workers + 1 orchestrator (pod-based)"
}

# Check prerequisites
check_prerequisites() {
    section "CHECKING PREREQUISITES"
    
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
    fi
    
    if [[ ! -f /etc/redhat-release ]]; then
        error "This script is designed for RHEL/CentOS/Fedora systems"
    fi
    
    local required_dirs=("system" "containers" "config")
    for dir in "${required_dirs[@]}"; do
        if [[ ! -d "$DISCOVERY_DIR/$dir" ]]; then
            error "Invalid discovery directory - missing: $dir"
        fi
    done
    
    success "Prerequisites check passed"
}

# Analyze system resources for 5-worker pod architecture
analyze_system_resources() {
    section "ANALYZING SYSTEM RESOURCES FOR 5-WORKER POD ARCHITECTURE"
    
    CPU_COUNT=$(nproc)
    MEMORY_GB=$(free -g | awk 'NR==2{print $2}')
    AVAILABLE_SPACE=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
    
    info "System specifications:"
    info "  CPU Cores: $CPU_COUNT"
    info "  Memory: ${MEMORY_GB}GB"
    info "  Available Disk: ${AVAILABLE_SPACE}GB"
    
    if [[ $AVAILABLE_SPACE -lt 20 ]]; then
        warning "Low disk space: ${AVAILABLE_SPACE}GB. Recommended: 20GB+"
    fi
    
    if [[ $MEMORY_GB -lt 8 ]]; then
        warning "Low memory: ${MEMORY_GB}GB. Recommended: 8GB+ for 5 workers"
    fi
    
    # 5-worker single-threaded pod configuration
    WORKER_COUNT=5
    MAX_WORKERS=1          # Single-threaded per container
    CONCURRENT_JOBS=1      # One job per worker at a time
    
    # Memory allocation based on system capacity
    case $ENVIRONMENT_TYPE in
        production)
            if [[ $MEMORY_GB -ge 16 ]]; then
                WORKER_MEMORY="2g"
                ORCHESTRATOR_MEMORY="1g"
            elif [[ $MEMORY_GB -ge 8 ]]; then
                WORKER_MEMORY="1g"
                ORCHESTRATOR_MEMORY="512m"
            else
                WORKER_MEMORY="512m"
                ORCHESTRATOR_MEMORY="256m"
            fi
            WORKER_TIMEOUT=600
            JOB_POLL_INTERVAL=10
            ;;
        staging)
            WORKER_COUNT=3
            WORKER_MEMORY="512m"
            ORCHESTRATOR_MEMORY="256m"
            WORKER_TIMEOUT=300
            JOB_POLL_INTERVAL=30
            ;;
        *)
            WORKER_COUNT=2
            WORKER_MEMORY="256m"
            ORCHESTRATOR_MEMORY="256m"
            WORKER_TIMEOUT=180
            JOB_POLL_INTERVAL=60
            ;;
    esac
    
    info "5-Worker Pod Architecture Configuration:"
    info "  Pod Containers: 6 total (1 orchestrator + $WORKER_COUNT workers)"
    info "  Threads per Container: $MAX_WORKERS (single-threaded)"
    info "  Concurrent Jobs per Worker: $CONCURRENT_JOBS"
    info "  Total Job Capacity: $WORKER_COUNT concurrent jobs"
    info "  Worker Memory: $WORKER_MEMORY each"
    info "  Orchestrator Memory: $ORCHESTRATOR_MEMORY"
    info "  Pod Networking: Shared localhost communication"
    info "  External Ports: 8620 (orchestrator), 8621-862$((620+WORKER_COUNT)) (workers)"
    
    success "System analysis completed for 5-worker pod architecture"
}

# Install required packages
install_prerequisites() {
    section "INSTALLING PREREQUISITES"
    
    info "Updating system packages..."
    dnf update -y
    
    info "Installing container and system packages..."
    dnf install -y \
        podman \
        buildah \
        skopeo \
        wget \
        curl \
        unzip \
        git \
        jq \
        tree \
        sqlite \
        gcc \
        python3-devel \
        python3-pip \
        firewalld \
        systemd \
        logrotate \
        htop \
        nano \
        vim
    
    info "Installing podman-compose..."
    pip3 install podman-compose || {
        warning "Failed to install podman-compose, creating wrapper"
        cat > /usr/local/bin/podman-compose << 'COMPOSE_WRAPPER'
#!/bin/bash
export DOCKER_HOST=unix:///run/user/$(id -u)/podman/podman.sock
docker-compose "$@"
COMPOSE_WRAPPER
        chmod +x /usr/local/bin/podman-compose
    }
    
    if ! command -v podman &> /dev/null; then
        error "Podman installation failed"
    fi
    
    success "Prerequisites installed successfully"
}

# Setup user and directories
setup_user_directories() {
    section "SETTING UP USER AND DIRECTORIES"
    
    if ! id -u $RPA_USER &>/dev/null; then
        useradd -r -m -d /home/$RPA_USER -s /bin/bash $RPA_USER
        info "Created RPA user: $RPA_USER"
    else
        info "RPA user already exists: $RPA_USER"
    fi
    
    mkdir -p $RPA_HOME
    chown $RPA_USER:$RPA_GROUP $RPA_HOME
    chmod 755 $RPA_HOME
    
    info "Creating directory structure for 5-worker pod architecture..."
    sudo -u $RPA_USER mkdir -p $RPA_HOME/{
        configs,
        containers/{orchestrator,worker},
        scripts,
        volumes/{data/{db,logs,screenshots,evidence},logs},
        source/{rpa_botfarm,automations},
        backups,
        temp
    }
    
    if ! grep -q "^${RPA_USER}:" /etc/subuid; then
        echo "${RPA_USER}:100000:65536" >> /etc/subuid
    fi
    if ! grep -q "^${RPA_USER}:" /etc/subgid; then
        echo "${RPA_USER}:100000:65536" >> /etc/subgid
    fi
    
    loginctl enable-linger $RPA_USER || warning "Could not enable user lingering"
    
    success "User and directories created for 5-worker pod system"
}

# Deploy source code from discovery
deploy_source_code() {
    section "DEPLOYING SOURCE CODE AND CONFIGURATIONS"
    
    info "Copying discovered source code and configurations..."
    
    # Primary source: Clean production package
    if [[ -d "$DISCOVERY_DIR/production-ready" ]]; then
        info "Using clean production package..."
        cp -r "$DISCOVERY_DIR/production-ready"/* $RPA_HOME/ 2>/dev/null || true
        info "Copied clean production source code"
        
    # Secondary source: Discovery config files from /opt/rpa-system
    elif [[ -d "$DISCOVERY_DIR/config/files/opt/rpa-system" ]]; then
        info "Using discovered configuration files from /opt/rpa-system..."
        cp -r "$DISCOVERY_DIR/config/files/opt/rpa-system"/* $RPA_HOME/ 2>/dev/null || true
        info "Copied source code from discovery config files"
    
    # Fallback: Any config files found
    elif [[ -d "$DISCOVERY_DIR/config/files" ]]; then
        info "Using general configuration files..."
        cp -r "$DISCOVERY_DIR/config/files"/* $RPA_HOME/ 2>/dev/null || true
        info "Copied configuration files from discovery"
    else
        warning "No source code found in discovery package"
    fi
    
    # Verify critical files were copied
    local critical_files=("rpa_botfarm/orchestrator.py" "rpa_botfarm/worker.py" "requirements.txt")
    for file in "${critical_files[@]}"; do
        if [[ -f "$RPA_HOME/$file" ]]; then
            success "Verified: $file"
        else
            warning "Missing: $file"
        fi
    done
    
    success "Source code deployment completed"
}

# Generate 5-worker pod production configurations
generate_production_config() {
    section "GENERATING 5-WORKER POD PRODUCTION CONFIGURATIONS"
    
    info "Generating optimized configurations for $ENVIRONMENT_TYPE environment..."
    info "Creating configuration for $WORKER_COUNT single-threaded workers in pod..."
    
    # Generate worker endpoints for pod networking (localhost with different ports)
    local worker_endpoints=""
    for ((i=1; i<=WORKER_COUNT; i++)); do
        local port=$((8620 + i))
        if [[ $i -eq 1 ]]; then
            worker_endpoints="\"http://localhost:$port/execute\""
        else
            worker_endpoints="$worker_endpoints,\"http://localhost:$port/execute\""
        fi
    done
    
    info "Worker endpoints for pod networking: [$worker_endpoints]"
    
    # Generate orchestrator configuration
    cat > $RPA_HOME/configs/orchestrator.env << EOF
# RPA Orchestrator Configuration - $ENVIRONMENT_TYPE Environment
# 5-Worker Single-threaded Pod Architecture
# Generated on $(date)

# Server Configuration
ORCHESTRATOR_HOST=0.0.0.0
ORCHESTRATOR_PORT=8620
WORKER_ENDPOINTS=[$worker_endpoints]

# Pod Architecture Settings
POD_ARCHITECTURE=true
SHARED_NETWORKING=true
WORKER_COUNT=$WORKER_COUNT

# Single-threaded Performance Settings
MAX_WORKERS=$MAX_WORKERS
WORKER_TIMEOUT=$WORKER_TIMEOUT
JOB_POLL_INTERVAL=$JOB_POLL_INTERVAL
BATCH_SIZE=1
MAX_RETRIES=3
RETRY_DELAY=30
CONCURRENT_JOBS=1

# Storage Configuration
BASE_DATA_DIR=/app/data
DB_PATH=/app/data/db/orchestrator.db
LOG_DIR=/app/logs
EVIDENCE_DIR=/app/data/evidence
SCREENSHOT_DIR=/app/data/screenshots

# Security Configuration
JWT_SECRET=$(openssl rand -hex 32)
ADMIN_USERNAME=admin
ADMIN_PASSWORD=$(openssl rand -base64 16)
AUTH_TOKEN_EXPIRE_HOURS=24

# Environment Settings
ENVIRONMENT=$ENVIRONMENT_TYPE
LOG_LEVEL=INFO
DEBUG=false
HEADLESS=true

# Architecture Settings
ARCHITECTURE=single_threaded_pod
TOTAL_CAPACITY=$WORKER_COUNT

# Health and Monitoring
HEALTH_CHECK_INTERVAL=30
METRICS_ENABLED=true
BACKUP_ENABLED=true
BACKUP_RETENTION_DAYS=30
EOF

    # Generate base worker configuration template
    cat > $RPA_HOME/configs/worker-base.env << EOF
# RPA Worker Base Configuration - $ENVIRONMENT_TYPE Environment
# Single-threaded Worker Template for Pod Architecture
# Generated on $(date)

# Server Configuration
WORKER_HOST=0.0.0.0
# WORKER_PORT will be set per container

# Pod Architecture Settings
POD_ARCHITECTURE=true
SHARED_NETWORKING=true

# Single-threaded Performance Settings
MAX_WORKERS=$MAX_WORKERS
WORKER_TIMEOUT=$WORKER_TIMEOUT
CONCURRENT_JOBS=$CONCURRENT_JOBS
JOB_QUEUE_SIZE=5
THREAD_POOL_SIZE=1

# Browser Configuration
HEADLESS=true
NO_SANDBOX=true
DISABLE_DEV_SHM_USAGE=true
DISABLE_GPU=true
WINDOW_SIZE=1920x1080

# Security Configuration
AUTHORIZED_WORKER_IPS=["172.18.0.0/16","127.0.0.1","10.0.0.0/8","192.168.0.0/16"]
API_TIMEOUT=30

# Storage Configuration
BASE_DATA_DIR=/app/data
LOG_DIR=/app/logs
WORKER_DATA_DIR=/app/worker_data
SCREENSHOT_DIR=/app/data/screenshots
EVIDENCE_DIR=/app/data/evidence

# Environment Settings
ENVIRONMENT=$ENVIRONMENT_TYPE
LOG_LEVEL=INFO
DEBUG=false

# Browser Driver Configuration
CHROMEDRIVER_PATH=/usr/local/bin/chromedriver
CHROME_BINARY_PATH=/usr/bin/chromium-browser

# Evidence and Monitoring
SCREENSHOT_ENABLED=true
EVIDENCE_RETENTION_DAYS=90
PERFORMANCE_MONITORING=true
EOF

    # Generate individual worker config files for pod
    for ((i=1; i<=WORKER_COUNT; i++)); do
        local port=$((8620 + i))
        cp $RPA_HOME/configs/worker-base.env $RPA_HOME/configs/worker${i}.env
        cat >> $RPA_HOME/configs/worker${i}.env << EOF

# Worker-specific Pod Configuration
WORKER_PORT=$port
WORKER_ID=$i
WORKER_NAME=worker$i
POD_WORKER_INDEX=$i
EOF
        info "Created worker${i}.env (port $port)"
    done

    # Save admin password securely
    grep ADMIN_PASSWORD $RPA_HOME/configs/orchestrator.env | cut -d= -f2 > $RPA_HOME/.admin-password
    chmod 600 $RPA_HOME/.admin-password
    chown $RPA_USER:$RPA_GROUP $RPA_HOME/.admin-password
    
    success "5-worker pod configurations generated"
}

# Create container files
create_container_files() {
    section "CREATING CONTAINER FILES FOR POD ARCHITECTURE"
    
    # Create orchestrator Containerfile
    if [[ ! -f "$RPA_HOME/containers/orchestrator/Containerfile" ]]; then
        info "Creating orchestrator Containerfile..."
        cat > $RPA_HOME/containers/orchestrator/Containerfile << 'EOF'
FROM registry.redhat.io/ubi9/python-311:latest

USER root
RUN dnf update -y && \
    dnf install -y sqlite gcc python3-devel curl wget jq procps-ng && \
    dnf clean all

RUN useradd -m -u 1001 rpauser && mkdir -p /app && chown -R rpauser:rpauser /app

USER rpauser
WORKDIR /app

COPY requirements.txt ./
RUN pip install --user --no-cache-dir -r requirements.txt

# Copy core application files for orchestrator
COPY --chown=rpauser:rpauser rpa_botfarm/orchestrator.py ./
COPY --chown=rpauser:rpauser rpa_botfarm/config.py ./
COPY --chown=rpauser:rpauser rpa_botfarm/auth.py ./
COPY --chown=rpauser:rpauser rpa_botfarm/db.py ./
COPY --chown=rpauser:rpauser rpa_botfarm/models.py ./
COPY --chown=rpauser:rpauser rpa_botfarm/errors.py ./
COPY --chown=rpauser:rpauser rpa_botfarm/health_reporter.py ./
COPY --chown=rpauser:rpauser rpa_botfarm/rate_limiter.py ./
COPY --chown=rpauser:rpauser rpa_botfarm/conjur_client.py ./

COPY --chown=rpauser:rpauser . .
RUN mkdir -p data/{db,logs,screenshots,evidence} logs temp

ENV PYTHONPATH=/app
ENV PATH="${PATH}:/home/rpauser/.local/bin"

EXPOSE 8620
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
    CMD curl -f http://localhost:8620/health || exit 1

CMD ["python", "rpa_botfarm/orchestrator.py"]
EOF
    fi

    # Create worker Containerfile with dynamic port support
    if [[ ! -f "$RPA_HOME/containers/worker/Containerfile" ]]; then
        info "Creating worker Containerfile with pod support..."
        cat > $RPA_HOME/containers/worker/Containerfile << 'EOF'
FROM registry.redhat.io/ubi9/python-311:latest

USER root
RUN dnf update -y && \
    dnf install -y chromium sqlite gcc python3-devel curl wget unzip jq procps-ng xvfb && \
    dnf clean all

RUN DRIVER_VERSION=$(curl -s "https://googlechromelabs.github.io/chrome-for-testing/LATEST_RELEASE_STABLE") && \
    wget -O /tmp/chromedriver.zip "https://storage.googleapis.com/chrome-for-testing-public/${DRIVER_VERSION}/linux64/chromedriver-linux64.zip" && \
    unzip /tmp/chromedriver.zip -d /tmp/ && \
    mv /tmp/chromedriver-linux64/chromedriver /usr/local/bin/chromedriver && \
    chmod +x /usr/local/bin/chromedriver && \
    rm -rf /tmp/chromedriver*

RUN useradd -m -u 1001 rpauser && mkdir -p /app && chown -R rpauser:rpauser /app

USER rpauser
WORKDIR /app

COPY requirements.txt ./
RUN pip install --user --no-cache-dir -r requirements.txt

# Copy core application files for worker
COPY --chown=rpauser:rpauser rpa_botfarm/worker.py ./
COPY --chown=rpauser:rpauser rpa_botfarm/config.py ./
COPY --chown=rpauser:rpauser rpa_botfarm/models.py ./
COPY --chown=rpauser:rpauser rpa_botfarm/errors.py ./

# Copy automation modules - this is the key part for your RPA system
COPY --chown=rpauser:rpauser rpa_botfarm/automations/ ./automations/

# Copy drivers if they exist
COPY --chown=rpauser:rpauser rpa_botfarm/drivers/ ./drivers/

COPY --chown=rpauser:rpauser . .
RUN mkdir -p data/{logs,screenshots,evidence} worker_data logs temp

ENV PYTHONPATH=/app
ENV PATH="${PATH}:/home/rpauser/.local/bin"
ENV CHROMEDRIVER_PATH=/usr/local/bin/chromedriver
ENV CHROME_BINARY_PATH=/usr/bin/chromium-browser
ENV HEADLESS=true

# Dynamic port support for pod architecture
EXPOSE 8621
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
    CMD curl -f http://localhost:${WORKER_PORT:-8621}/health || exit 1

# Use dynamic port from environment variable
CMD ["python", "-c", "import os; from rpa_botfarm.worker import app; import uvicorn; uvicorn.run(app, host='0.0.0.0', port=int(os.environ.get('WORKER_PORT', 8621)))"]
EOF
    fi

    # Create requirements.txt if needed
    if [[ ! -f "$RPA_HOME/requirements.txt" ]]; then
        cat > $RPA_HOME/requirements.txt << 'EOF'
fastapi==0.104.1
uvicorn[standard]==0.24.0
pydantic==2.5.0
selenium==4.15.2
requests==2.31.0
httpx==0.25.2
Pillow==10.1.0
python-jose[cryptography]==3.3.0
passlib[bcrypt]==1.7.4
python-multipart==0.0.6
SQLAlchemy==2.0.23
APScheduler==3.10.4
tenacity==8.2.3
python-dotenv==1.0.0
jinja2==3.1.2
aiofiles==23.2.1
psutil==5.9.6
python-dateutil==2.8.2
pytz==2023.3
EOF
    fi
    
    success "Container files created for pod architecture"
}

# Create 5-worker pod management scripts
create_management_scripts() {
    section "CREATING 5-WORKER POD MANAGEMENT SCRIPTS"
    
    # Network creation script
    cat > $RPA_HOME/scripts/create-network.sh << 'EOF'
#!/bin/bash
echo "🔗 Creating RPA container network..."
if podman network exists rpa-network; then
    echo "ℹ️  RPA network already exists"
else
    podman network create --driver bridge --subnet 172.18.0.0/16 --gateway 172.18.0.1 rpa-network
    echo "✅ RPA network created successfully"
fi
EOF

    # Container build script
    cat > $RPA_HOME/scripts/build-containers.sh << 'EOF'
#!/bin/bash
set -e
cd /opt/rpa-system

echo "🔨 Building RPA container images..."

echo "📦 Building orchestrator image..."
podman build --tag rpa-orchestrator:latest --file containers/orchestrator/Containerfile .

echo "📦 Building worker image..."
podman build --tag rpa-worker:latest --file containers/worker/Containerfile .

echo "✅ Container builds completed successfully"
podman images | grep rpa
EOF

    # 5-worker pod system startup script
    cat > $RPA_HOME/scripts/start-system.sh << 'EOF'
#!/bin/bash
set -e
cd /opt/rpa-system

echo "🚀 Starting RPA Pod (5 Workers + 1 Orchestrator)..."

# Set permissions
echo "🔐 Setting permissions..."
chown -R rpauser:rpauser volumes/ || true

# Build containers
echo "🔨 Building containers..."
sudo -u rpauser ./scripts/build-containers.sh

# Stop and remove existing pod if it exists
echo "🧹 Cleaning up existing pod..."
sudo -u rpauser podman pod stop rpa-pod 2>/dev/null || true
sudo -u rpauser podman pod rm rpa-pod 2>/dev/null || true

# Create pod with all port mappings for 5 workers + orchestrator
echo "📦 Creating RPA pod with network configuration..."
sudo -u rpauser podman pod create \
    --name rpa-pod \
    --publish 8620:8620 \
    --publish 8621:8621 \
    --publish 8622:8622 \
    --publish 8623:8623 \
    --publish 8624:8624 \
    --publish 8625:8625 \
    --share net,ipc,uts

if ! sudo -u rpauser podman pod exists rpa-pod; then
    echo "❌ Failed to create RPA pod"
    exit 1
fi

echo "✅ RPA pod created successfully"

# Start orchestrator in pod
echo "🎛️ Starting orchestrator (single-threaded) in pod..."
sudo -u rpauser podman run -d \
    --pod rpa-pod \
    --name rpa-orchestrator \
    --env-file configs/orchestrator.env \
    -v $(pwd)/volumes/data:/app/data:Z \
    -v $(pwd)/volumes/logs:/app/logs:Z \
    --memory=__ORCHESTRATOR_MEMORY__ \
    --cpus=1.0 \
    rpa-orchestrator:latest

# Verify orchestrator started
if ! sudo -u rpauser podman ps | grep -q "rpa-orchestrator"; then
    echo "❌ Failed to start orchestrator"
    exit 1
fi

echo "✅ Orchestrator started successfully"
echo "⏳ Waiting for orchestrator to initialize..."
sleep 15

# Start 5 workers in the same pod, each on their assigned port
echo "👷 Starting 5 workers (single-threaded) in pod..."
for i in {1..5}; do
    port=$((8620 + i))
    echo "  Starting worker $i on internal port $port..."
    
    sudo -u rpauser podman run -d \
        --pod rpa-pod \
        --name rpa-worker$i \
        --env-file configs/worker${i}.env \
        -v $(pwd)/volumes/data:/app/data:Z \
        -v $(pwd)/volumes/logs:/app/logs:Z \
        --memory=__WORKER_MEMORY__ \
        --cpus=1.0 \
        --security-opt seccomp=unconfined \
        --shm-size=1g \
        rpa-worker:latest
    
    # Verify worker started
    if ! sudo -u rpauser podman ps | grep -q "rpa-worker$i"; then
        echo "❌ Failed to start worker $i"
        exit 1
    fi
    
    echo "  ✅ Worker $i started successfully on port $port"
    sleep 3
done

echo "⏳ Waiting for all services to initialize..."
sleep 20

# Health checks for all 6 services
echo "🏥 Checking service health..."
for port in 8620 8621 8622 8623 8624 8625; do
    if curl -f -s --max-time 5 http://localhost:$port/health >/dev/null 2>&1; then
        echo "  ✅ Service on port $port: Healthy"
    else
        echo "  ⚠️  Service on port $port: Not responding (may still be starting)"
    fi
done

# Pod status summary
echo ""
echo "📦 Pod Status:"
sudo -u rpauser podman pod ps
echo ""
echo "📋 Container Status:"
sudo -u rpauser podman ps --pod

echo ""
echo "🎉 RPA Pod startup completed!"
echo "🎛️ Pod Architecture:"
echo "  🏠 Pod Name: rpa-pod"
echo "  🎛️  Orchestrator: rpa-orchestrator (port 8620, single-threaded)"
echo "  👷 Worker 1: rpa-worker1 (port 8621, single-threaded)"
echo "  👷 Worker 2: rpa-worker2 (port 8622, single-threaded)"
echo "  👷 Worker 3: rpa-worker3 (port 8623, single-threaded)"
echo "  👷 Worker 4: rpa-worker4 (port 8624, single-threaded)"
echo "  👷 Worker 5: rpa-worker5 (port 8625, single-threaded)"
echo ""
echo "🌐 Access Points:"
echo "  🎛️  Orchestrator:    http://$(hostname):8620"
echo "  👷 Worker 1:        http://$(hostname):8621"
echo "  👷 Worker 2:        http://$(hostname):8622"
echo "  👷 Worker 3:        http://$(hostname):8623"
echo "  👷 Worker 4:        http://$(hostname):8624"
echo "  👷 Worker 5:        http://$(hostname):8625"
echo ""
echo "🔑 Admin credentials:"
echo "  Username: admin"
echo "  Password: $(cat /opt/rpa-system/.admin-password 2>/dev/null || echo 'Check /opt/rpa-system/.admin-password')"
echo ""
echo "🎯 Total Capacity: 5 concurrent automation jobs"
EOF

    # 5-worker pod system shutdown script
    cat > $RPA_HOME/scripts/stop-system.sh << 'EOF'
#!/bin/bash
echo "🛑 Stopping RPA Pod (1 orchestrator + 5 workers)..."

# Stop the entire pod (stops all containers in it)
sudo -u rpauser podman pod stop rpa-pod 2>/dev/null || true
echo "ℹ️  RPA pod stopped"

# Remove the pod (removes all containers in it)
sudo -u rpauser podman pod rm rpa-pod 2>/dev/null || true
echo "🗑️  RPA pod removed"

echo "✅ RPA System stopped successfully"
EOF

    # 5-worker pod health check script
    cat > $RPA_HOME/scripts/health-check.sh << 'EOF'
#!/bin/bash
echo "🏥 RPA System Health Check (5-Worker Pod Architecture)"
echo "=================================================="
echo "📅 $(date)"
echo ""

# Check pod status
echo "📦 Pod Status:"
if sudo -u rpauser podman pod exists rpa-pod 2>/dev/null; then
    sudo -u rpauser podman pod ps | grep -E "(POD ID|rpa-pod)"
    echo ""
    echo "📋 Container Status in Pod:"
    sudo -u rpauser podman ps -a --pod --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E "(NAMES|rpa-)"
else
    echo "  ❌ RPA pod not found"
fi
echo ""

# Check all 6 service health endpoints
echo "🔍 Service Health Checks:"
services=(
    "8620:Orchestrator"
    "8621:Worker-1"
    "8622:Worker-2"
    "8623:Worker-3"
    "8624:Worker-4"
    "8625:Worker-5"
)

for service in "${services[@]}"; do
    port="${service%%:*}"
    name="${service##*:}"
    
    if curl -f -s --max-time 5 http://localhost:$port/health >/dev/null 2>&1; then
        echo "  ✅ $name (port $port): Healthy"
    else
        echo "  ❌ $name (port $port): Unhealthy or not responding"
    fi
done
echo ""

# Resource usage for all containers in pod
echo "💾 Resource Usage:"
if sudo -u rpauser podman stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}" 2>/dev/null | grep -E "(NAME|rpa-)" | head -7; then
    echo ""
else
    echo "  ⚠️  Unable to retrieve resource stats"
fi

echo "🎯 Pod Architecture Summary:"
echo "  • 1 Pod containing 6 containers"
echo "  • 1 Orchestrator (single-threaded) on port 8620"
echo "  • 5 Workers (single-threaded) on ports 8621-8625"
echo "  • Total capacity: 5 concurrent automation jobs"
echo "  • Communication: Shared pod network (localhost)"
EOF

    # Pod management script
    cat > $RPA_HOME/scripts/manage-pod.sh << 'EOF'
#!/bin/bash
# RPA Pod Management Script

case "$1" in
    "restart-worker")
        if [[ -z "$2" ]]; then
            echo "Usage: $0 restart-worker <worker_number>"
            echo "Example: $0 restart-worker 3"
            exit 1
        fi
        worker_num="$2"
        echo "🔄 Restarting worker $worker_num..."
        sudo -u rpauser podman restart rpa-worker$worker_num
        echo "✅ Worker $worker_num restarted"
        ;;
    "logs")
        if [[ -z "$2" ]]; then
            echo "Usage: $0 logs <service>"
            echo "Services: orchestrator, worker1, worker2, worker3, worker4, worker5"
            exit 1
        fi
        service="$2"
        if [[ "$service" == "orchestrator" ]]; then
            sudo -u rpauser podman logs -f rpa-orchestrator
        else
            sudo -u rpauser podman logs -f rpa-$service
        fi
        ;;
    "exec")
        if [[ -z "$2" ]]; then
            echo "Usage: $0 exec <service>"
            echo "Services: orchestrator, worker1, worker2, worker3, worker4, worker5"
            exit 1
        fi
        service="$2"
        if [[ "$service" == "orchestrator" ]]; then
            sudo -u rpauser podman exec -it rpa-orchestrator /bin/bash
        else
            sudo -u rpauser podman exec -it rpa-$service /bin/bash
        fi
        ;;
    "scale-workers")
        echo "Pod architecture doesn't support dynamic scaling."
        echo "To change worker count, modify deployment script and redeploy."
        ;;
    "pod-logs")
        echo "📋 Pod Logs:"
        sudo -u rpauser podman pod logs rpa-pod
        ;;
    "status")
        echo "📦 Pod Status:"
        sudo -u rpauser podman pod ps
        echo ""
        echo "📋 Container Status:"
        sudo -u rpauser podman ps --pod
        ;;
    *)
        echo "RPA Pod Management Script"
        echo "Usage: $0 <command> [options]"
        echo ""
        echo "Commands:"
        echo "  status              - Show pod and container status"
        echo "  restart-worker <N>  - Restart specific worker (1-5)"
        echo "  logs <service>      - Follow logs for service"
        echo "  exec <service>      - Execute shell in container"
        echo "  pod-logs            - Show all pod logs"
        echo "  scale-workers       - Info about scaling (not supported)"
        echo ""
        echo "Examples:"
        echo "  $0 status"
        echo "  $0 restart-worker 3"
        echo "  $0 logs worker2"
        echo "  $0 exec orchestrator"
        echo "  $0 pod-logs"
        ;;
esac
EOF

    # Make all scripts executable and set ownership
    chmod +x $RPA_HOME/scripts/*.sh
    chown -R $RPA_USER:$RPA_GROUP $RPA_HOME/scripts/
    
    # Fix memory variable substitution with proper escaping
    sed -i "s/__ORCHESTRATOR_MEMORY__/${ORCHESTRATOR_MEMORY}/g" $RPA_HOME/scripts/start-system.sh
    sed -i "s/__WORKER_MEMORY__/${WORKER_MEMORY}/g" $RPA_HOME/scripts/start-system.sh
    
    success "5-worker pod management scripts created and configured"
}

# Configure firewall for 5 workers + orchestrator
configure_firewall() {
    section "CONFIGURING FIREWALL FOR 5-WORKER POD ARCHITECTURE"
    
    systemctl start firewalld
    systemctl enable firewalld
    
    info "Opening ports for orchestrator + 5 workers..."
    firewall-cmd --permanent --add-port=8620/tcp  # Orchestrator
    
    # Open ports for 5 workers
    for ((i=1; i<=5; i++)); do
        port=$((8620 + i))
        firewall-cmd --permanent --add-port=$port/tcp
        info "Opened port $port for worker $i"
    done
    
    # Create custom service definition
    cat > /etc/firewalld/services/rpa-system.xml << 'EOF'
<?xml version="1.0" encoding="utf-8"?>
<service>
  <short>RPA System</short>
  <description>RPA System - 1 Pod with 1 Orchestrator + 5 Worker Services</description>
  <port protocol="tcp" port="8620"/>
  <port protocol="tcp" port="8621"/>
  <port protocol="tcp" port="8622"/>
  <port protocol="tcp" port="8623"/>
  <port protocol="tcp" port="8624"/>
  <port protocol="tcp" port="8625"/>
</service>
EOF

    firewall-cmd --reload
    
    info "Active firewall ports:"
    firewall-cmd --list-ports | tr ' ' '\n' | grep -E '^862[0-5]/tcp$' || warning "RPA ports not found in active rules"
    
    success "Firewall configured for 5-worker pod architecture (ports 8620-8625)"
}

# Configure SELinux
configure_selinux() {
    section "CONFIGURING SELINUX"
    
    if command -v getenforce >/dev/null 2>&1; then
        selinux_status=$(getenforce)
        info "SELinux status: $selinux_status"
        
        if [[ "$selinux_status" != "Disabled" ]]; then
            info "Configuring SELinux for container operations..."
            setsebool -P container_manage_cgroup 1 2>/dev/null || warning "Could not set container_manage_cgroup"
            setsebool -P virt_use_fusefs 1 2>/dev/null || warning "Could not set virt_use_fusefs"
            
            if command -v semanage >/dev/null 2>&1; then
                semanage fcontext -a -t container_file_t "$RPA_HOME/volumes(/.*)?" 2>/dev/null || warning "Could not set SELinux file context"
                restorecon -R $RPA_HOME/volumes/ 2>/dev/null || warning "Could not restore SELinux context"
            fi
            
            success "SELinux configured for containers"
        else
            info "SELinux is disabled, skipping configuration"
        fi
    else
        info "SELinux not available on this system"
    fi
}

# Create systemd service for 5-worker pod system
create_systemd_service() {
    section "CREATING SYSTEMD SERVICE FOR 5-WORKER POD SYSTEM"
    
    cat > /etc/systemd/system/rpa-system.service << EOF
[Unit]
Description=RPA System - 5 Workers + 1 Orchestrator (Pod Architecture)
Documentation=file://$RPA_HOME/DEPLOYMENT_REPORT.md
After=network-online.target
Wants=network-online.target
RequiresMountsFor=$RPA_HOME

[Service]
Type=oneshot
RemainAfterExit=true
User=root
Group=root
WorkingDirectory=$RPA_HOME

# Service commands
ExecStart=$RPA_HOME/scripts/start-system.sh
ExecStop=$RPA_HOME/scripts/stop-system.sh
ExecReload=/bin/bash -c '$RPA_HOME/scripts/stop-system.sh && sleep 10 && $RPA_HOME/scripts/start-system.sh'

# Timeout configuration (longer for pod with 6 containers)
TimeoutStartSec=600
TimeoutStopSec=180
TimeoutAbortSec=30

# Restart configuration
Restart=on-failure
RestartSec=30

# Environment
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=RPA_HOME=$RPA_HOME

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=rpa-system

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable rpa-system.service
    
    info "Systemd service configuration:"
    info "  Service: 5-worker pod RPA system"
    info "  Auto-start: Enabled"
    info "  Management: systemctl {start|stop|status|restart} rpa-system"
    
    success "Systemd service created for 5-worker pod architecture"
}

# Set up log rotation
setup_log_rotation() {
    section "CONFIGURING LOG ROTATION"
    
    cat > /etc/logrotate.d/rpa-system << 'EOF'
/opt/rpa-system/volumes/logs/*.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 644 rpauser rpauser
    copytruncate
    postrotate
        /usr/bin/systemctl reload rpa-system.service > /dev/null 2>&1 || true
    endscript
}

/var/log/rpa-deployment.log {
    weekly
    rotate 12
    compress
    delaycompress
    missingok
    notifempty
    create 644 root root
}
EOF

    success "Log rotation configured"
}

# Set permissions
# Set secure permissions following security best practices
set_permissions() {
    section "SETTING SECURE PERMISSIONS"
    
    info "Applying security-hardened permissions..."
    
    # ================================================================
    # BASIC OWNERSHIP - Set everything to RPA user first
    # ================================================================
    chown -R $RPA_USER:$RPA_GROUP $RPA_HOME
    
    # ================================================================
    # DIRECTORY PERMISSIONS (750 - owner rwx, group rx, no others)
    # ================================================================
    
    # Main directory (750 - no world access)
    chmod 750 $RPA_HOME
    
    # Standard directories (750 - group can read/execute, no world access)
    find $RPA_HOME -type d -exec chmod 750 {} \;
    
    # Data directories (700 - owner only for sensitive data)
    chmod 700 $RPA_HOME/volumes/data
    chmod 700 $RPA_HOME/volumes/data/db
    chmod 700 $RPA_HOME/volumes/data/evidence
    chmod 700 $RPA_HOME/volumes/data/screenshots
    
    # Log directory (755 - needs to be accessible for log rotation)
    chmod 755 $RPA_HOME/volumes/logs
    chmod 755 $RPA_HOME/volumes/data/logs
    
    # Config directory (700 - highly sensitive)
    chmod 700 $RPA_HOME/configs
    
    # Container build contexts (750 - need to be readable for builds)
    chmod 750 $RPA_HOME/containers
    chmod 750 $RPA_HOME/containers/orchestrator
    chmod 750 $RPA_HOME/containers/worker
    
    # ================================================================
    # FILE PERMISSIONS BY TYPE AND SENSITIVITY
    # ================================================================
    
    # Default files (640 - owner rw, group r, no others)
    find $RPA_HOME -type f -exec chmod 640 {} \;
    
    # ================================================================
    # SENSITIVE FILES (600 - owner only)
    # ================================================================
    
    # Credentials and secrets
    chmod 600 $RPA_HOME/.admin-password
    chmod 600 $RPA_HOME/configs/*.env
    chmod 600 $RPA_HOME/configs/worker*.env 2>/dev/null || true
    
    # Database files (600 - contain sensitive job data)
    find $RPA_HOME/volumes/data/db -name "*.db" -type f -exec chmod 600 {} \; 2>/dev/null || true
    
    # Evidence and screenshots (600 - potentially sensitive automation evidence)
    find $RPA_HOME/volumes/data/evidence -type f -exec chmod 600 {} \; 2>/dev/null || true
    find $RPA_HOME/volumes/data/screenshots -type f -exec chmod 600 {} \; 2>/dev/null || true
    
    # SSH keys if they exist
    find $RPA_HOME -name "id_rsa" -o -name "*.key" -o -name "*.pem" -type f -exec chmod 600 {} \; 2>/dev/null || true
    
    # ================================================================
    # EXECUTABLE FILES (750 - owner rwx, group rx, no others)
    # ================================================================
    
    # Shell scripts
    find $RPA_HOME/scripts -name "*.sh" -type f -exec chmod 750 {} \;
    chmod 750 $RPA_HOME/scripts/manage-pod.sh 2>/dev/null || true
    
    # Python executables and main modules
    find $RPA_HOME -name "*.py" -path "*/rpa_botfarm/orchestrator.py" -exec chmod 750 {} \; 2>/dev/null || true
    find $RPA_HOME -name "*.py" -path "*/rpa_botfarm/worker.py" -exec chmod 750 {} \; 2>/dev/null || true
    
    # ================================================================
    # LOG FILES (644 - need to be readable for log rotation/monitoring)
    # ================================================================
    
    find $RPA_HOME/volumes/logs -name "*.log" -type f -exec chmod 644 {} \; 2>/dev/null || true
    chmod 644 /var/log/rpa-deployment.log 2>/dev/null || true
    
    # ================================================================
    # CONTAINER AND BUILD FILES
    # ================================================================
    
    # Container files (640 - readable for builds but not world-readable)
    find $RPA_HOME/containers -name "Containerfile" -o -name "Dockerfile" -type f -exec chmod 640 {} \;
    chmod 640 $RPA_HOME/requirements.txt 2>/dev/null || true
    
    # ================================================================
    # SOURCE CODE FILES (640 - protect intellectual property)
    # ================================================================
    
    # Python source files (640 - readable by group for debugging, not world)
    find $RPA_HOME -name "*.py" -not -path "*/scripts/*" -type f -exec chmod 640 {} \;
    
    # Automation modules (600 - highly sensitive business logic)
    find $RPA_HOME/rpa_botfarm/automations -name "*.py" -type f -exec chmod 600 {} \; 2>/dev/null || true
    
    # ================================================================
    # SPECIAL OWNERSHIP FOR SENSITIVE DIRECTORIES
    # ================================================================
    
    # Ensure configs are owned by RPA user only
    chown -R $RPA_USER:$RPA_GROUP $RPA_HOME/configs/
    
    # Ensure volume data is properly owned
    chown -R $RPA_USER:$RPA_GROUP $RPA_HOME/volumes/
    
    # Ensure scripts are properly owned
    chown -R $RPA_USER:$RPA_GROUP $RPA_HOME/scripts/
    
    # ================================================================
    # SELINUX CONTEXTS (if SELinux is enabled)
    # ================================================================
    
    if command -v restorecon >/dev/null 2>&1 && [[ "$(getenforce 2>/dev/null)" != "Disabled" ]]; then
        info "Setting SELinux contexts for container files..."
        restorecon -R $RPA_HOME/volumes/ 2>/dev/null || warning "Could not restore SELinux contexts"
    fi
    
    # ================================================================
    # VALIDATION AND REPORTING
    # ================================================================
    
    # Verify no world-writable files exist
    local world_writable=$(find $RPA_HOME -type f -perm -002 2>/dev/null | wc -l)
    if [[ $world_writable -gt 0 ]]; then
        warning "Found $world_writable world-writable files - this may be a security risk"
        find $RPA_HOME -type f -perm -002 2>/dev/null | head -5
    fi
    
    # Verify no world-readable sensitive files
    local world_readable_secrets=$(find $RPA_HOME/configs -name "*.env" -perm -004 2>/dev/null | wc -l)
    if [[ $world_readable_secrets -gt 0 ]]; then
        warning "Found world-readable configuration files - fixing..."
        find $RPA_HOME/configs -name "*.env" -perm -004 -exec chmod 600 {} \; 2>/dev/null
    fi
    
    info "Permission summary:"
    info "  🏠 Main directory: 750 (owner+group access only)"
    info "  📁 Standard directories: 750 (no world access)"
    info "  🔒 Sensitive directories: 700 (owner only)"
    info "  📄 Standard files: 640 (owner+group read)"
    info "  🔐 Sensitive files: 600 (owner only)"
    info "  🔧 Executable scripts: 750 (owner+group execute)"
    info "  📊 Log files: 644 (readable for monitoring)"
    
    success "Security-hardened permissions applied"
}

# Additional function for permission auditing
audit_permissions() {
    section "AUDITING PERMISSIONS"
    
    info "Performing security audit of file permissions..."
    
    # Check for common security issues
    local issues_found=0
    
    # Check for world-writable files
    local world_writable=$(find $RPA_HOME -type f -perm -002 2>/dev/null)
    if [[ -n "$world_writable" ]]; then
        warning "World-writable files found:"
        echo "$world_writable"
        ((issues_found++))
    fi
    
    # Check for world-readable config files
    local readable_configs=$(find $RPA_HOME/configs -name "*.env" -perm -004 2>/dev/null)
    if [[ -n "$readable_configs" ]]; then
        warning "World-readable config files found:"
        echo "$readable_configs"
        ((issues_found++))
    fi
    
    # Check for overly permissive directories
    local permissive_dirs=$(find $RPA_HOME -type d -perm -005 2>/dev/null)
    if [[ -n "$permissive_dirs" ]]; then
        warning "World-accessible directories found:"
        echo "$permissive_dirs"
        ((issues_found++))
    fi
    
    # Check for missing admin password protection
    if [[ -f "$RPA_HOME/.admin-password" ]]; then
        local admin_perms=$(stat -c "%a" "$RPA_HOME/.admin-password" 2>/dev/null)
        if [[ "$admin_perms" != "600" ]]; then
            warning "Admin password file has incorrect permissions: $admin_perms (should be 600)"
            ((issues_found++))
        fi
    fi
    
    # Check script permissions
    local script_issues=$(find $RPA_HOME/scripts -name "*.sh" ! -perm 750 2>/dev/null)
    if [[ -n "$script_issues" ]]; then
        warning "Scripts with incorrect permissions found:"
        echo "$script_issues"
        ((issues_found++))
    fi
    
    if [[ $issues_found -eq 0 ]]; then
        success "No permission security issues found"
    else
        warning "Found $issues_found security permission issues"
        info "Run set_permissions() again to fix these issues"
    fi
    
    # Display permission summary for key files
    info "Key file permissions:"
    [[ -f "$RPA_HOME/.admin-password" ]] && info "  Admin password: $(stat -c "%a" "$RPA_HOME/.admin-password" 2>/dev/null || echo "missing")"
    [[ -f "$RPA_HOME/configs/orchestrator.env" ]] && info "  Orchestrator config: $(stat -c "%a" "$RPA_HOME/configs/orchestrator.env" 2>/dev/null || echo "missing")"
    [[ -d "$RPA_HOME/volumes/data" ]] && info "  Data directory: $(stat -c "%a" "$RPA_HOME/volumes/data" 2>/dev/null || echo "missing")"
    [[ -d "$RPA_HOME/scripts" ]] && info "  Scripts directory: $(stat -c "%a" "$RPA_HOME/scripts" 2>/dev/null || echo "missing")"
}

# Validate 5-worker pod deployment
validate_deployment() {
    section "VALIDATING 5-WORKER POD DEPLOYMENT"
    
    info "Performing deployment validation..."
    
    # Check required files
    local required_files=(
        "$RPA_HOME/scripts/start-system.sh"
        "$RPA_HOME/scripts/stop-system.sh"
        "$RPA_HOME/scripts/health-check.sh"
        "$RPA_HOME/scripts/manage-pod.sh"
        "$RPA_HOME/configs/orchestrator.env"
        "$RPA_HOME/configs/worker-base.env"
        "$RPA_HOME/.admin-password"
        "$RPA_HOME/containers/orchestrator/Containerfile"
        "$RPA_HOME/containers/worker/Containerfile"
        "$RPA_HOME/requirements.txt"
    )
    
    for file in "${required_files[@]}"; do
        if [[ ! -f "$file" ]]; then
            error "Required file missing: $file"
        fi
    done
    
    # Check individual worker config files
    for ((i=1; i<=WORKER_COUNT; i++)); do
        local worker_config="$RPA_HOME/configs/worker${i}.env"
        if [[ ! -f "$worker_config" ]]; then
            error "Worker config missing: $worker_config"
        else
            success "Found worker${i}.env"
        fi
    done
    
    # Check automation modules
    local automation_providers=("mfn" "osn" "octotel" "evotel")
    local automation_actions=("validation.py" "cancellation.py")
    
    for provider in "${automation_providers[@]}"; do
        local provider_dir="$RPA_HOME/rpa_botfarm/automations/$provider"
        if [[ -d "$provider_dir" ]]; then
            success "Found automation module: $provider"
            for action in "${automation_actions[@]}"; do
                if [[ -f "$provider_dir/$action" ]]; then
                    success "  ✅ $provider/$action"
                else
                    warning "  ⚠️  $provider/$action (missing)"
                fi
            done
        else
            warning "Missing automation module: $provider"
        fi
    done
    
    # Validate 5-worker configuration
    if grep -q "WORKER_COUNT=$WORKER_COUNT" $RPA_HOME/configs/orchestrator.env; then
        success "5-worker configuration validated"
    else
        warning "Worker count configuration may be incorrect"
    fi
    
    # Check if worker endpoints are properly configured for localhost (pod networking)
    if grep -q "localhost" $RPA_HOME/configs/orchestrator.env; then
        success "Pod networking configuration validated"
    else
        warning "Pod networking configuration may be incorrect"
    fi
    
    # Check firewall ports
    for ((i=0; i<=5; i++)); do
        port=$((8620 + i))
        if firewall-cmd --query-port=$port/tcp >/dev/null 2>&1; then
            success "Firewall port $port open"
        else
            warning "Firewall port $port not open"
        fi
    done
    
    if [[ ! -s "$RPA_HOME/.admin-password" ]]; then
        error "Admin password file is empty or missing"
    fi
    
    success "5-worker pod deployment validation completed"
    audit_permissions
}

# Generate comprehensive deployment report
generate_deployment_report() {
    section "GENERATING 5-WORKER POD DEPLOYMENT REPORT"
    
    local report_file="$RPA_HOME/DEPLOYMENT_REPORT.md"
    local admin_password=$(cat $RPA_HOME/.admin-password 2>/dev/null || echo "ERROR: Could not read password")
    
    cat > "$report_file" << EOF
# RPA 5-Worker Pod Production Deployment Report

## Deployment Information
- **Date:** $(date)
- **Environment:** $ENVIRONMENT_TYPE
- **Architecture:** 5 Single-threaded Workers + 1 Orchestrator (Pod-based)
- **Discovery Source:** $DISCOVERY_DIR
- **Deployment Version:** $(date +%Y%m%d-%H%M%S)
- **Deployed By:** $(whoami)
- **System Hostname:** $(hostname)

## System Specifications
- **Operating System:** $(cat /etc/redhat-release)
- **CPU Cores:** $CPU_COUNT
- **Total Memory:** ${MEMORY_GB}GB
- **Available Disk:** ${AVAILABLE_SPACE}GB

## RPA Pod Configuration
- **Installation Directory:** $RPA_HOME
- **Pod Architecture:** 1 Pod containing 6 containers
- **Worker Containers:** $WORKER_COUNT containers
- **Threads per Container:** 1 (single-threaded)
- **Total Job Capacity:** $WORKER_COUNT concurrent automation jobs
- **Worker Memory:** $WORKER_MEMORY each
- **Orchestrator Memory:** $ORCHESTRATOR_MEMORY
- **Pod Networking:** Shared localhost communication

## Service Endpoints
- **Orchestrator API:** http://$(hostname):8620 (pod networking)
- **Worker 1 API:** http://$(hostname):8621 (pod networking)
- **Worker 2 API:** http://$(hostname):8622 (pod networking)
- **Worker 3 API:** http://$(hostname):8623 (pod networking)
- **Worker 4 API:** http://$(hostname):8624 (pod networking)
- **Worker 5 API:** http://$(hostname):8625 (pod networking)

## Authentication
- **Admin Username:** admin
- **Admin Password:** $admin_password

## Pod Network Configuration
- **Pod Name:** rpa-pod
- **Container Communication:** localhost:PORT within pod
- **External Access:** hostname:PORT
- **Orchestrator Port:** 8620
- **Worker Ports:** 8621-8625
- **Firewall Status:** Configured (ports 8620-8625 open)

## Management Commands

### System Control
\`\`\`bash
# Start 5-worker RPA pod system
systemctl start rpa-system

# Stop 5-worker RPA pod system
systemctl stop rpa-system

# Check system status
systemctl status rpa-system

# View system logs
journalctl -u rpa-system -f
\`\`\`

### Manual Pod Management
\`\`\`bash
# Manual start (starts entire pod with 6 containers)
$RPA_HOME/scripts/start-system.sh

# Manual stop (stops entire pod)
$RPA_HOME/scripts/stop-system.sh

# Health check (checks all 6 services)
$RPA_HOME/scripts/health-check.sh

# Pod management operations
$RPA_HOME/scripts/manage-pod.sh status
$RPA_HOME/scripts/manage-pod.sh restart-worker 3
$RPA_HOME/scripts/manage-pod.sh logs worker2
\`\`\`

### Container Management
\`\`\`bash
# View pod status
sudo -u $RPA_USER podman pod ps

# View all containers in pod
sudo -u $RPA_USER podman ps --pod

# View individual worker logs
sudo -u $RPA_USER podman logs rpa-worker1
sudo -u $RPA_USER podman logs rpa-worker2
sudo -u $RPA_USER podman logs rpa-worker3
sudo -u $RPA_USER podman logs rpa-worker4
sudo -u $RPA_USER podman logs rpa-worker5

# Restart specific worker
sudo -u $RPA_USER podman restart rpa-worker3

# Execute command in container
sudo -u $RPA_USER podman exec -it rpa-orchestrator /bin/bash
\`\`\`

## Pod Architecture Benefits
- **Simplified Management:** Single pod containing all 6 containers
- **Shared Networking:** Containers communicate via localhost within pod
- **Resource Efficiency:** Shared IPC and UTS namespaces
- **Predictable Performance:** Each worker handles exactly 1 job
- **Easy Debugging:** Simple process isolation within shared pod
- **Fault Isolation:** Individual container failures don't affect pod
- **Linear Scaling:** Easy to modify worker count and redeploy

## Deployment Validation
✅ **Prerequisites:** Installed and verified
✅ **5-Worker Pod Architecture:** Configured correctly
✅ **Source Code:** Deployed with all automation modules
✅ **Pod Configurations:** Generated for single-threaded operation
✅ **Container Files:** Created for orchestrator + worker with dynamic ports
✅ **Individual Worker Configs:** Created (worker1.env - worker5.env)
✅ **Firewall:** Configured for ports 8620-8625
✅ **Systemd Service:** Created for pod system
✅ **Permissions:** Set correctly for all components

## Next Steps
1. **Start the pod:** \`systemctl start rpa-system\`
2. **Verify deployment:** \`$RPA_HOME/scripts/health-check.sh\`
3. **Access orchestrator:** http://$(hostname):8620
4. **Submit test jobs:** Use API or web interface
5. **Monitor performance:** Watch resource usage across pod
6. **Test individual workers:** Access each worker endpoint directly

---
**5-Worker Pod RPA System deployed successfully on $(date)**
EOF

    chown $RPA_USER:$RPA_GROUP "$report_file"
    success "5-worker pod deployment report generated: $report_file"
}

# Main deployment function
main() {
    echo -e "${NC}"
    
    info "Starting RPA 5-worker pod production deployment..."
    
    parse_arguments "$@"
    check_prerequisites
    analyze_system_resources
    install_prerequisites
    setup_user_directories
    deploy_source_code
    generate_production_config
    create_container_files
    create_management_scripts
    configure_firewall
    configure_selinux
    create_systemd_service
    setup_log_rotation
    set_permissions
    validate_deployment
    generate_deployment_report
    
    echo -e "\n${GREEN}"
    cat << 'SUCCESS'
    ╔══════════════════════════════════════════════════════════════════╗
    ║              🎉 5-WORKER POD DEPLOYMENT SUCCESSFUL! 🎉           ║
    ╚══════════════════════════════════════════════════════════════════╝
SUCCESS
    echo -e "${NC}"
    
    echo -e "${CYAN}📋 5-Worker Pod Deployment Summary:${NC}"
    echo -e "  🏠 Installation Directory: ${YELLOW}$RPA_HOME${NC}"
    echo -e "  🎯 Architecture: ${YELLOW}5 Workers + 1 Orchestrator (pod-based)${NC}"
    echo -e "  📈 Job Capacity: ${YELLOW}$WORKER_COUNT concurrent automation jobs${NC}"
    echo -e "  🔑 Admin Password: ${YELLOW}$admin_password${NC}"
    echo -e "  💾 Worker Memory: ${YELLOW}$WORKER_MEMORY each${NC}"
    echo -e "  💾 Orchestrator Memory: ${YELLOW}$ORCHESTRATOR_MEMORY${NC}"
    echo -e "  📦 Pod Management: ${YELLOW}Single pod with 6 containers${NC}"
    
    echo -e "\n${CYAN}🚀 Quick Start Commands:${NC}"
    echo -e "  ${BLUE}systemctl start rpa-system${NC}         - Start pod with all 6 containers"
    echo -e "  ${BLUE}$RPA_HOME/scripts/health-check.sh${NC}  - Check all services"
    echo -e "  ${BLUE}$RPA_HOME/scripts/manage-pod.sh status${NC} - Pod management"
    echo -e "  ${BLUE}systemctl status rpa-system${NC}        - Check system status"
    
    echo -e "\n${CYAN}🌐 Access Points (after starting):${NC}"
    echo -e "  🎛️  Orchestrator: ${YELLOW}http://$(hostname):8620${NC} (pod networking)"
    echo -e "  👷 Workers 1-5:  ${YELLOW}http://$(hostname):8621-8625${NC} (pod networking)"
    
    echo -e "\n${CYAN}📚 Documentation:${NC}"
    echo -e "  📄 Deployment report: ${YELLOW}$RPA_HOME/DEPLOYMENT_REPORT.md${NC}"
    echo -e "  📋 Management scripts: ${YELLOW}$RPA_HOME/scripts/${NC}"
    echo -e "  ⚙️  Pod management: ${YELLOW}$RPA_HOME/scripts/manage-pod.sh${NC}"
    
    echo -e "\n${GREEN}✅ Your 5-worker pod RPA system is ready for production!${NC}"
    echo -e "${YELLOW}Next step: systemctl start rpa-system${NC}"
}

# Execute main function
main "$@"
