#!/bin/bash
# RPA Production Deployment Script - FINAL
# Deploys your discovered RPA system to production VM

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

Deploy your RPA system to production using discovery data.

OPTIONS:
    -d, --discovery-dir DIR    Path to environment discovery directory (required)
    -e, --environment TYPE     Environment type (production, staging, development) [default: production]
    -h, --help                Show this help message

EXAMPLES:
    $0 -d ./environment-discovery-20250904-130738
    $0 -d /path/to/discovery --environment production

REQUIREMENTS:
    - Must run as root
    - Discovery directory must contain valid RPA environment data
    - Production VM should have RHEL/CentOS/Fedora

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

    # Validate required arguments
    if [[ -z "$DISCOVERY_DIR" ]]; then
        error "Discovery directory is required. Use: $0 -d /path/to/discovery-dir"
    fi

    if [[ ! -d "$DISCOVERY_DIR" ]]; then
        error "Discovery directory does not exist: $DISCOVERY_DIR"
    fi

    # Convert to absolute path
    DISCOVERY_DIR="$(cd "$DISCOVERY_DIR" && pwd)"
    
    info "Using discovery directory: $DISCOVERY_DIR"
    info "Target environment: $ENVIRONMENT_TYPE"
}

# Check prerequisites
check_prerequisites() {
    section "CHECKING PREREQUISITES"
    
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
    fi
    
    # Check OS
    if [[ ! -f /etc/redhat-release ]]; then
        error "This script is designed for RHEL/CentOS/Fedora systems"
    fi
    
    # Check discovery directory structure
    local required_dirs=("system" "containers" "config" "source")
    for dir in "${required_dirs[@]}"; do
        if [[ ! -d "$DISCOVERY_DIR/$dir" ]]; then
            error "Invalid discovery directory - missing: $dir"
        fi
    done
    
    success "Prerequisites check passed"
}

# Analyze system resources and optimize configuration
analyze_system_resources() {
    section "ANALYZING SYSTEM RESOURCES"
    
    # Get system specifications
    CPU_COUNT=$(nproc)
    MEMORY_GB=$(free -g | awk 'NR==2{print $2}')
    AVAILABLE_SPACE=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
    
    info "System specifications:"
    info "  CPU Cores: $CPU_COUNT"
    info "  Memory: ${MEMORY_GB}GB"
    info "  Available Disk: ${AVAILABLE_SPACE}GB"
    
    # Resource validation
    if [[ $AVAILABLE_SPACE -lt 20 ]]; then
        warning "Low disk space: ${AVAILABLE_SPACE}GB. Recommended: 20GB+"
    fi
    
    if [[ $MEMORY_GB -lt 4 ]]; then
        warning "Low memory: ${MEMORY_GB}GB. Recommended: 8GB+ for production"
    fi
    
    # Determine resource configuration based on environment and system
    case $ENVIRONMENT_TYPE in
        production)
            if [[ $MEMORY_GB -ge 16 ]]; then
                MAX_WORKERS=$((CPU_COUNT * 3))
                WORKER_MEMORY="4g"
                ORCHESTRATOR_MEMORY="2g"
            elif [[ $MEMORY_GB -ge 8 ]]; then
                MAX_WORKERS=$((CPU_COUNT * 2))
                WORKER_MEMORY="2g"
                ORCHESTRATOR_MEMORY="1g"
            else
                MAX_WORKERS=$CPU_COUNT
                WORKER_MEMORY="1g"
                ORCHESTRATOR_MEMORY="512m"
            fi
            WORKER_TIMEOUT=600
            JOB_POLL_INTERVAL=10
            ;;
        staging)
            MAX_WORKERS=$CPU_COUNT
            WORKER_MEMORY="1g"
            ORCHESTRATOR_MEMORY="512m"
            WORKER_TIMEOUT=300
            JOB_POLL_INTERVAL=30
            ;;
        *)
            MAX_WORKERS=2
            WORKER_MEMORY="512m"
            ORCHESTRATOR_MEMORY="256m"
            WORKER_TIMEOUT=180
            JOB_POLL_INTERVAL=60
            ;;
    esac
    
    info "Resource configuration:"
    info "  Max Workers: $MAX_WORKERS"
    info "  Worker Memory: $WORKER_MEMORY"
    info "  Orchestrator Memory: $ORCHESTRATOR_MEMORY"
    
    success "System analysis completed"
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
    
    # Install container management tools
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
    
    # Verify podman installation
    if ! command -v podman &> /dev/null; then
        error "Podman installation failed"
    fi
    
    success "Prerequisites installed successfully"
}

# Setup user and directories
setup_user_directories() {
    section "SETTING UP USER AND DIRECTORIES"
    
    # Create RPA user if it doesn't exist
    if ! id -u $RPA_USER &>/dev/null; then
        useradd -r -m -d /home/$RPA_USER -s /bin/bash $RPA_USER
        info "Created RPA user: $RPA_USER"
    else
        info "RPA user already exists: $RPA_USER"
    fi
    
    # Create main directory structure
    mkdir -p $RPA_HOME
    chown $RPA_USER:$RPA_GROUP $RPA_HOME
    chmod 755 $RPA_HOME
    
    # Create comprehensive directory structure based on discovery
    info "Creating directory structure..."
    sudo -u $RPA_USER mkdir -p $RPA_HOME/{
        configs,
        containers/{orchestrator,worker},
        scripts,
        volumes/{data/{db,logs,screenshots,evidence},logs},
        source/{rpa_botfarm,automations},
        backups,
        temp
    }
    
    # Set up podman for user
    if ! grep -q "^${RPA_USER}:" /etc/subuid; then
        echo "${RPA_USER}:100000:65536" >> /etc/subuid
    fi
    if ! grep -q "^${RPA_USER}:" /etc/subgid; then
        echo "${RPA_USER}:100000:65536" >> /etc/subgid
    fi
    
    # Enable user lingering for systemd user services
    loginctl enable-linger $RPA_USER || warning "Could not enable user lingering"
    
    success "User and directories created"
}

# Deploy source code and configurations from discovery
deploy_source_code() {
    section "DEPLOYING SOURCE CODE AND CONFIGURATIONS"
    
    info "Copying discovered source code and configurations..."
    
    # Copy all discovered configuration files
    if [[ -d "$DISCOVERY_DIR/config/files" ]]; then
        cp -r "$DISCOVERY_DIR/config/files"/* $RPA_HOME/ 2>/dev/null || true
        info "Copied configuration files from discovery"
    fi
    
    # Copy Python source files with proper structure
    if [[ -f "$DISCOVERY_DIR/source/python_files.txt" ]]; then
        info "Copying Python source files..."
        while IFS= read -r source_file; do
            if [[ -f "$source_file" ]]; then
                # Preserve directory structure under rpa-system
                relative_path="${source_file#*/rpa-system/}"
                if [[ "$relative_path" != "$source_file" ]]; then
                    target_path="$RPA_HOME/$relative_path"
                    target_dir="$(dirname "$target_path")"
                    
                    sudo -u $RPA_USER mkdir -p "$target_dir"
                    cp "$source_file" "$target_path" 2>/dev/null || true
                    chown $RPA_USER:$RPA_GROUP "$target_path" 2>/dev/null || true
                fi
            fi
        done < "$DISCOVERY_DIR/source/python_files.txt"
    fi
    
    # Copy requirements files
    if [[ -f "$DISCOVERY_DIR/source/requirements_files.txt" ]]; then
        while IFS= read -r req_file; do
            if [[ -f "$req_file" ]]; then
                cp "$req_file" "$RPA_HOME/" 2>/dev/null || true
                info "Copied: $(basename "$req_file")"
            fi
        done < "$DISCOVERY_DIR/source/requirements_files.txt"
    fi
    
    # Copy container definition files
    if [[ -f "$DISCOVERY_DIR/source/container_files.txt" ]]; then
        while IFS= read -r container_file; do
            if [[ -f "$container_file" ]]; then
                filename=$(basename "$container_file")
                if [[ "$filename" == *"orchestrator"* || "$container_file" == *"orchestrator"* ]]; then
                    cp "$container_file" "$RPA_HOME/containers/orchestrator/" 2>/dev/null || true
                elif [[ "$filename" == *"worker"* || "$container_file" == *"worker"* ]]; then
                    cp "$container_file" "$RPA_HOME/containers/worker/" 2>/dev/null || true
                else
                    cp "$container_file" "$RPA_HOME/" 2>/dev/null || true
                fi
            fi
        done < "$DISCOVERY_DIR/source/container_files.txt"
    fi
    
    # Copy any shell scripts found
    find "$DISCOVERY_DIR/config/files" -name "*.sh" -type f 2>/dev/null | while read -r script_file; do
        if [[ -f "$script_file" ]]; then
            cp "$script_file" "$RPA_HOME/scripts/" 2>/dev/null || true
            chmod +x "$RPA_HOME/scripts/$(basename "$script_file")" 2>/dev/null || true
        fi
    done
    
    success "Source code deployment completed"
}

# Generate production environment configurations
generate_production_config() {
    section "GENERATING PRODUCTION CONFIGURATIONS"
    
    info "Generating optimized configurations for $ENVIRONMENT_TYPE environment..."
    
    # Generate orchestrator configuration
    cat > $RPA_HOME/configs/orchestrator.env << EOF
# RPA Orchestrator Configuration - $ENVIRONMENT_TYPE Environment
# Generated on $(date)

# Server Configuration
ORCHESTRATOR_HOST=0.0.0.0
ORCHESTRATOR_PORT=8620
WORKER_ENDPOINTS=["http://worker1:8621/execute","http://worker2:8621/execute"]

# Performance Settings
MAX_WORKERS=$MAX_WORKERS
WORKER_TIMEOUT=$WORKER_TIMEOUT
JOB_POLL_INTERVAL=$JOB_POLL_INTERVAL
BATCH_SIZE=5
MAX_RETRIES=3
RETRY_DELAY=30

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

# Health and Monitoring
HEALTH_CHECK_INTERVAL=30
METRICS_ENABLED=true
BACKUP_ENABLED=true
BACKUP_RETENTION_DAYS=30

# External Reporting (if applicable)
HEALTH_REPORT_ENABLED=true
HEALTH_REPORT_ENDPOINT=http://your-external-endpoint/health
EOF

    # Generate worker configuration
    cat > $RPA_HOME/configs/worker.env << EOF
# RPA Worker Configuration - $ENVIRONMENT_TYPE Environment
# Generated on $(date)

# Server Configuration
WORKER_HOST=0.0.0.0
WORKER_PORT=8621

# Performance Settings
MAX_WORKERS=$MAX_WORKERS
WORKER_TIMEOUT=$WORKER_TIMEOUT
CONCURRENT_JOBS=2
JOB_QUEUE_SIZE=10

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

    # Save admin password securely
    grep ADMIN_PASSWORD $RPA_HOME/configs/orchestrator.env | cut -d= -f2 > $RPA_HOME/.admin-password
    chmod 600 $RPA_HOME/.admin-password
    chown $RPA_USER:$RPA_GROUP $RPA_HOME/.admin-password
    
    # Create database initialization script
    cat > $RPA_HOME/scripts/init-database.sh << 'DB_INIT_EOF'
#!/bin/bash
# Initialize RPA database schema

DB_PATH="/opt/rpa-system/volumes/data/db/orchestrator.db"
mkdir -p "$(dirname "$DB_PATH")"

sqlite3 "$DB_PATH" << 'SQL'
-- Jobs table
CREATE TABLE IF NOT EXISTS jobs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    external_job_id TEXT UNIQUE,
    provider TEXT NOT NULL,
    action TEXT NOT NULL,
    parameters TEXT,
    status TEXT DEFAULT 'queued',
    result TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    started_at TIMESTAMP,
    updated_at TIMESTAMP,
    retry_count INTEGER DEFAULT 0,
    max_retries INTEGER DEFAULT 2,
    assigned_worker TEXT
);

-- Job status tracking
CREATE TABLE IF NOT EXISTS job_status (
    job_id TEXT PRIMARY KEY,
    status TEXT NOT NULL,
    result TEXT,
    start_time TEXT,
    end_time TEXT
);

-- System metrics
CREATE TABLE IF NOT EXISTS system_metrics (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    metric_name TEXT NOT NULL,
    metric_value TEXT NOT NULL,
    worker_id TEXT
);

-- Indexes for performance
CREATE INDEX IF NOT EXISTS idx_jobs_status ON jobs(status);
CREATE INDEX IF NOT EXISTS idx_jobs_external_id ON jobs(external_job_id);
CREATE INDEX IF NOT EXISTS idx_jobs_created_at ON jobs(created_at);
CREATE INDEX IF NOT EXISTS idx_metrics_timestamp ON system_metrics(timestamp);

SQL

echo "Database initialized successfully"
DB_INIT_EOF

    chmod +x $RPA_HOME/scripts/init-database.sh
    
    success "Production configurations generated"
}

# Create optimized container files
create_container_files() {
    section "CREATING CONTAINER FILES"
    
    # Create orchestrator Containerfile
    info "Creating orchestrator Containerfile..."
    cat > $RPA_HOME/containers/orchestrator/Containerfile << 'ORCHESTRATOR_CONTAINERFILE'
FROM registry.redhat.io/ubi9/python-311:latest

# Set up as root for package installation
USER root

# Install system dependencies
RUN dnf update -y && \
    dnf install -y \
        sqlite \
        gcc \
        python3-devel \
        curl \
        wget \
        jq \
        procps-ng \
        && dnf clean all

# Create application user and directory
RUN useradd -m -u 1001 rpauser && \
    mkdir -p /app && \
    chown -R rpauser:rpauser /app

# Switch to application user
USER rpauser
WORKDIR /app

# Copy requirements and install Python dependencies
COPY requirements.txt ./
RUN pip install --user --no-cache-dir -r requirements.txt

# Copy application code
COPY --chown=rpauser:rpauser . .

# Create necessary directories
RUN mkdir -p data/{db,logs,screenshots,evidence} logs temp

# Set environment variables
ENV PYTHONPATH=/app
ENV PATH="${PATH}:/home/rpauser/.local/bin"

# Expose port
EXPOSE 8620

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
    CMD curl -f http://localhost:8620/health || exit 1

# Run the orchestrator
CMD ["python", "orchestrator.py"]
ORCHESTRATOR_CONTAINERFILE

    # Create worker Containerfile
    info "Creating worker Containerfile..."
    cat > $RPA_HOME/containers/worker/Containerfile << 'WORKER_CONTAINERFILE'
FROM registry.redhat.io/ubi9/python-311:latest

# Set up as root for package installation
USER root

# Install system dependencies including Chrome and ChromeDriver
RUN dnf update -y && \
    dnf install -y \
        chromium \
        sqlite \
        gcc \
        python3-devel \
        curl \
        wget \
        unzip \
        jq \
        procps-ng \
        xvfb \
        && dnf clean all

# Install ChromeDriver
RUN CHROME_VERSION=$(chromium-browser --version | cut -d' ' -f2 | cut -d'.' -f1-3) && \
    DRIVER_VERSION=$(curl -s "https://googlechromelabs.github.io/chrome-for-testing/LATEST_RELEASE_STABLE") && \
    wget -O /tmp/chromedriver.zip "https://storage.googleapis.com/chrome-for-testing-public/${DRIVER_VERSION}/linux64/chromedriver-linux64.zip" && \
    unzip /tmp/chromedriver.zip -d /tmp/ && \
    mv /tmp/chromedriver-linux64/chromedriver /usr/local/bin/chromedriver && \
    chmod +x /usr/local/bin/chromedriver && \
    rm -rf /tmp/chromedriver*

# Create application user and directory
RUN useradd -m -u 1001 rpauser && \
    mkdir -p /app && \
    chown -R rpauser:rpauser /app

# Switch to application user
USER rpauser
WORKDIR /app

# Copy requirements and install Python dependencies
COPY requirements.txt ./
RUN pip install --user --no-cache-dir -r requirements.txt

# Copy application code
COPY --chown=rpauser:rpauser . .

# Create necessary directories
RUN mkdir -p data/{logs,screenshots,evidence} worker_data logs temp

# Set environment variables
ENV PYTHONPATH=/app
ENV PATH="${PATH}:/home/rpauser/.local/bin"
ENV CHROMEDRIVER_PATH=/usr/local/bin/chromedriver
ENV CHROME_BINARY_PATH=/usr/bin/chromium-browser
ENV HEADLESS=true
ENV NO_SANDBOX=true
ENV DISABLE_DEV_SHM_USAGE=true

# Expose port
EXPOSE 8621

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
    CMD curl -f http://localhost:8621/health || exit 1

# Run the worker
CMD ["python", "worker.py"]
WORKER_CONTAINERFILE

    # Create requirements.txt if it doesn't exist
    if [[ ! -f "$RPA_HOME/requirements.txt" ]]; then
        info "Creating requirements.txt..."
        cat > $RPA_HOME/requirements.txt << 'REQUIREMENTS_EOF'
# Core API Framework
fastapi==0.104.1
uvicorn[standard]==0.24.0
pydantic==2.5.0

# Web Automation
selenium==4.15.2
requests==2.31.0
httpx==0.25.2

# Image Processing
Pillow==10.1.0

# Authentication & Security
python-jose[cryptography]==3.3.0
passlib[bcrypt]==1.7.4
python-multipart==0.0.6

# Database
SQLAlchemy==2.0.23

# Task Scheduling & Execution
APScheduler==3.10.4
tenacity==8.2.3

# Utilities
python-dotenv==1.0.0
jinja2==3.1.2
aiofiles==23.2.1
psutil==5.9.6

# Development & Debugging
python-dateutil==2.8.2
pytz==2023.3
REQUIREMENTS_EOF
    fi
    
    success "Container files created"
}

# Create comprehensive management scripts
create_management_scripts() {
    section "CREATING MANAGEMENT SCRIPTS"
    
    # Network creation script
    cat > $RPA_HOME/scripts/create-network.sh << 'NETWORK_SCRIPT'
#!/bin/bash
echo "🔗 Creating RPA container network..."

# Create custom bridge network for RPA containers
if podman network exists rpa-network; then
    echo "ℹ️  RPA network already exists"
else
    podman network create \
        --driver bridge \
        --subnet 172.18.0.0/16 \
        --gateway 172.18.0.1 \
        --dns 8.8.8.8 \
        rpa-network
    echo "✅ RPA network created successfully"
fi

# List networks
echo "📋 Current networks:"
podman network ls
NETWORK_SCRIPT

    # Container build script
    cat > $RPA_HOME/scripts/build-containers.sh << 'BUILD_SCRIPT'
#!/bin/bash
set -e
cd /opt/rpa-system

echo "🔨 Building RPA container images..."

# Build orchestrator image
echo "📦 Building orchestrator image..."
podman build \
    --tag rpa-orchestrator:latest \
    --tag rpa-orchestrator:$(date +%Y%m%d) \
    --file containers/orchestrator/Containerfile \
    .

echo "📦 Building worker image..."
podman build \
    --tag rpa-worker:latest \
    --tag rpa-worker:$(date +%Y%m%d) \
    --file containers/worker/Containerfile \
    .

echo "✅ Container builds completed successfully"

# Show built images
echo "📋 Built images:"
podman images | grep rpa
BUILD_SCRIPT

    # System startup script
    cat > $RPA_HOME/scripts/start-system.sh << 'START_SCRIPT'
#!/bin/bash
set -e
cd /opt/rpa-system

echo "🚀 Starting RPA System..."

# Initialize database
echo "💾 Initializing database..."
sudo -u rpauser ./scripts/init-database.sh

# Create network
echo "🔗 Setting up network..."
sudo -u rpauser ./scripts/create-network.sh

# Set proper permissions
echo "🔐 Setting permissions..."
chown -R rpauser:rpauser volumes/ || true

# Build containers if needed
echo "🔨 Building containers..."
sudo -u rpauser ./scripts/build-containers.sh

# Start orchestrator
echo "📊 Starting orchestrator..."
sudo -u rpauser podman run -d \
    --name rpa-orchestrator \
    --hostname orchestrator \
    --network rpa-network \
    -p 8620:8620 \
    --env-file configs/orchestrator.env \
    -v $(pwd)/volumes/data:/app/data:Z \
    -v $(pwd)/volumes/logs:/app/logs:Z \
    --restart unless-stopped \
    --memory=$ORCHESTRATOR_MEMORY \
    --cpus=1.0 \
    --health-interval=30s \
    --health-timeout=10s \
    --health-retries=3 \
    rpa-orchestrator:latest

echo "⏳ Waiting for orchestrator to start..."
sleep 15

# Start worker 1
echo "👷 Starting worker 1..."
sudo -u rpauser podman run -d \
    --name rpa-worker1 \
    --hostname worker1 \
    --network rpa-network \
    -p 8621:8621 \
    --env-file configs/worker.env \
    -v $(pwd)/volumes/data:/app/data:Z \
    -v $(pwd)/volumes/logs:/app/logs:Z \
    --restart unless-stopped \
    --memory=$WORKER_MEMORY \
    --cpus=1.0 \
    --security-opt seccomp=unconfined \
    --shm-size=2g \
    --health-interval=30s \
    --health-timeout=10s \
    --health-retries=3 \
    rpa-worker:latest

echo "⏳ Waiting for worker 1 to start..."
sleep 10

# Start worker 2
echo "👷 Starting worker 2..."
sudo -u rpauser podman run -d \
    --name rpa-worker2 \
    --hostname worker2 \
    --network rpa-network \
    -p 8622:8621 \
    --env-file configs/worker.env \
    -v $(pwd)/volumes/data:/app/data:Z \
    -v $(pwd)/volumes/logs:/app/logs:Z \
    --restart unless-stopped \
    --memory=$WORKER_MEMORY \
    --cpus=1.0 \
    --security-opt seccomp=unconfined \
    --shm-size=2g \
    --health-interval=30s \
    --health-timeout=10s \
    --health-retries=3 \
    rpa-worker:latest

echo "⏳ Waiting for all services to initialize..."
sleep 20

# Perform health checks
echo "🏥 Checking service health..."
for port in 8620 8621 8622; do
    if curl -f -s http://localhost:$port/health >/dev/null 2>&1; then
        echo "  ✅ Service on port $port: Healthy"
    else
        echo "  ⚠️  Service on port $port: Not responding (may still be starting)"
    fi
done

echo ""
echo "🎉 RPA System startup completed!"
echo "📊 Access Points:"
echo "  🎛️  Orchestrator:    http://$(hostname):8620"
echo "  👷 Worker 1:        http://$(hostname):8621"
echo "  👷 Worker 2:        http://$(hostname):8622"
echo ""
echo "🔑 Admin credentials:"
echo "  Username: admin"
echo "  Password: $(cat /opt/rpa-system/.admin-password 2>/dev/null || echo 'Check /opt/rpa-system/.admin-password')"
START_SCRIPT

    # System shutdown script
    cat > $RPA_HOME/scripts/stop-system.sh << 'STOP_SCRIPT'
#!/bin/bash
echo "🛑 Stopping RPA System..."

# Stop containers gracefully
containers=(rpa-orchestrator rpa-worker1 rpa-worker2)

for container in "${containers[@]}"; do
    if sudo -u rpauser podman container exists "$container" 2>/dev/null; then
        echo "⏹️  Stopping $container..."
        sudo -u rpauser podman stop "$container" --time 30 2>/dev/null || true
        sudo -u rpauser podman rm "$container" 2>/dev/null || true
        echo "✅ $container stopped and removed"
    fi
done

echo "✅ RPA System stopped successfully"
STOP_SCRIPT

    # Comprehensive health check script
    cat > $RPA_HOME/scripts/health-check.sh << 'HEALTH_SCRIPT'
#!/bin/bash
echo "🏥 RPA System Health Check"
echo "=========================="
echo "📅 $(date)"
echo ""

# Check container status
echo "📦 Container Status:"
if sudo -u rpauser podman ps -a | grep -q rpa-; then
    sudo -u rpauser podman ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E "(NAMES|rpa-)"
else
    echo "  ❌ No RPA containers found"
fi
echo ""

# Check service health endpoints
echo "🔍 Service Health Checks:"
services=(
    "8620:Orchestrator"
    "8621:Worker-1"
    "8622:Worker-2"
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

# Check resource usage
echo "💾 Resource Usage:"
if sudo -u rpauser podman stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}" 2>/dev/null | grep -E "(NAME|rpa-)" | head -4; then
    echo ""
else
    echo "  ⚠️  Unable to retrieve resource stats"
    echo ""
fi

# Check disk usage
echo "💽 Disk Usage:"
df -h /opt/rpa-system | tail -n +2 | while read -r line; do
    echo "  📁 $line"
done
echo ""

# Check recent logs for errors
echo "⚠️  Recent Errors (last 10):"
error_count=0
for log_file in /opt/rpa-system/volumes/logs/*.log; do
    if [[ -f "$log_file" ]]; then
        recent_errors=$(tail -n 100 "$log_file" 2>/dev/null | grep -i error | tail -n 5)
        if [[ -n "$recent_errors" ]]; then
            echo "  📄 $(basename "$log_file"):"
            echo "$recent_errors" | sed 's/^/    /'
            error_count=$((error_count + 1))
        fi
    fi
done

if [[ $error_count -eq 0 ]]; then
    echo "  ✅ No recent errors found in log files"
fi
echo ""

# System uptime and load
echo "⚡ System Performance:"
echo "  🕐 Uptime: $(uptime -p)"
echo "  📈 Load Average: $(uptime | awk -F'load average:' '{print $2}')"
echo "  🧠 Memory: $(free -h | awk 'NR==2{printf "%.1f%% used of %s\n", $3/$2*100, $2}')"
echo ""

# Network connectivity
echo "🌐 Network Status:"
if ping -c 1 8.8.8.8 >/dev/null 2>&1; then
    echo "  ✅ Internet connectivity: OK"
else
    echo "  ❌ Internet connectivity: Failed"
fi

if sudo -u rpauser podman network exists rpa-network 2>/dev/null; then
    echo "  ✅ RPA container network: OK"
else
    echo "  ❌ RPA container network: Missing"
fi

echo ""
echo "🏥 Health check completed at $(date)"
HEALTH_SCRIPT

    # Backup script
    cat > $RPA_HOME/scripts/backup-system.sh << 'BACKUP_SCRIPT'
#!/bin/bash
BACKUP_DIR="/opt/rpa-system/backups"
BACKUP_NAME="rpa-backup-$(date +%Y%m%d-%H%M%S)"
BACKUP_PATH="$BACKUP_DIR/$BACKUP_NAME.tar.gz"

echo "📦 Creating RPA system backup..."
echo "📅 $(date)"

# Create backup directory
mkdir -p "$BACKUP_DIR"

# Stop system for consistent backup
echo "⏸️  Stopping system for backup..."
/opt/rpa-system/scripts/stop-system.sh

# Create comprehensive backup
echo "📁 Creating backup archive..."
tar -czf "$BACKUP_PATH" \
    --exclude='backups' \
    --exclude='volumes/logs/*.log' \
    --exclude='temp' \
    --exclude='*.tmp' \
    -C /opt/rpa-system \
    .

# Restart system
echo "▶️  Restarting system..."
/opt/rpa-system/scripts/start-system.sh

# Backup information
backup_size=$(du -h "$BACKUP_PATH" | cut -f1)
echo "✅ Backup created successfully"
echo "📄 File: $BACKUP_PATH"
echo "📊 Size: $backup_size"

# Cleanup old backups (keep last 7 days)
echo "🧹 Cleaning up old backups (keeping 7 most recent)..."
find "$BACKUP_DIR" -name "rpa-backup-*.tar.gz" -type f | sort | head -n -7 | xargs rm -f 2>/dev/null || true

# List current backups
echo "📋 Current backups:"
ls -lah "$BACKUP_DIR"/rpa-backup-*.tar.gz 2>/dev/null | tail -n 5 || echo "  No backups found"

echo "📦 Backup process completed at $(date)"
BACKUP_SCRIPT

    # Make all scripts executable
    chmod +x $RPA_HOME/scripts/*.sh
    chown -R $RPA_USER:$RPA_GROUP $RPA_HOME/scripts/
    
    # Substitute memory variables in start script
    sed -i "s/\$ORCHESTRATOR_MEMORY/$ORCHESTRATOR_MEMORY/g" $RPA_HOME/scripts/start-system.sh
    sed -i "s/\$WORKER_MEMORY/$WORKER_MEMORY/g" $RPA_HOME/scripts/start-system.sh
    
    success "Management scripts created and configured"
}

# Configure firewall for RPA services
configure_firewall() {
    section "CONFIGURING FIREWALL"
    
    # Enable and start firewalld
    systemctl start firewalld
    systemctl enable firewalld
    
    # Open RPA service ports
    info "Opening RPA service ports..."
    firewall-cmd --permanent --add-port=8620/tcp  # Orchestrator
    firewall-cmd --permanent --add-port=8621/tcp  # Worker 1
    firewall-cmd --permanent --add-port=8622/tcp  # Worker 2
    
    # Add custom service definition (optional)
    cat > /etc/firewalld/services/rpa-system.xml << 'FIREWALL_SERVICE'
<?xml version="1.0" encoding="utf-8"?>
<service>
  <short>RPA System</short>
  <description>RPA System - Orchestrator and Worker Services</description>
  <port protocol="tcp" port="8620"/>
  <port protocol="tcp" port="8621"/>
  <port protocol="tcp" port="8622"/>
</service>
FIREWALL_SERVICE

    # Reload firewall rules
    firewall-cmd --reload
    
    # Show active rules
    info "Active firewall rules:"
    firewall-cmd --list-ports | tr ' ' '\n' | grep -E '^862[0-2]/tcp$' || warning "RPA ports not found in active rules"
    
    success "Firewall configured successfully"
}

# Configure SELinux for containers
configure_selinux() {
    section "CONFIGURING SELINUX"
    
    # Check if SELinux is available and enforcing
    if command -v getenforce >/dev/null 2>&1; then
        selinux_status=$(getenforce)
        info "SELinux status: $selinux_status"
        
        if [[ "$selinux_status" != "Disabled" ]]; then
            info "Configuring SELinux for container operations..."
            
            # Set SELinux booleans for containers
            setsebool -P container_manage_cgroup 1 2>/dev/null || warning "Could not set container_manage_cgroup"
            setsebool -P virt_use_fusefs 1 2>/dev/null || warning "Could not set virt_use_fusefs"
            
            # Set proper contexts for data volumes
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

# Create systemd service for automatic startup
create_systemd_service() {
    section "CREATING SYSTEMD SERVICE"
    
    cat > /etc/systemd/system/rpa-system.service << EOF
[Unit]
Description=RPA System Container Stack
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

# Timeout configuration
TimeoutStartSec=300
TimeoutStopSec=120
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

    # Reload systemd and enable service
    systemctl daemon-reload
    systemctl enable rpa-system.service
    
    info "Systemd service configuration:"
    info "  Service file: /etc/systemd/system/rpa-system.service"
    info "  Auto-start: Enabled"
    info "  Commands:"
    info "    Start:   systemctl start rpa-system"
    info "    Stop:    systemctl stop rpa-system"
    info "    Status:  systemctl status rpa-system"
    info "    Logs:    journalctl -u rpa-system -f"
    
    success "Systemd service created and enabled"
}

# Set up log rotation
setup_log_rotation() {
    section "CONFIGURING LOG ROTATION"
    
    cat > /etc/logrotate.d/rpa-system << 'LOGROTATE_CONFIG'
# RPA System log rotation configuration
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
        # Signal containers to reopen log files if needed
        /usr/bin/systemctl reload rpa-system.service > /dev/null 2>&1 || true
    endscript
}

# Deployment and system logs
/var/log/rpa-deployment.log {
    weekly
    rotate 12
    compress
    delaycompress
    missingok
    notifempty
    create 644 root root
}
LOGROTATE_CONFIG

    # Test log rotation configuration
    logrotate -d /etc/logrotate.d/rpa-system >/dev/null 2>&1 || warning "Log rotation configuration may have issues"
    
    success "Log rotation configured (daily rotation, 30-day retention)"
}

# Set comprehensive permissions and ownership
set_permissions() {
    section "SETTING PERMISSIONS AND OWNERSHIP"
    
    # Set directory ownership
    chown -R $RPA_USER:$RPA_GROUP $RPA_HOME
    
    # Set directory permissions
    chmod 755 $RPA_HOME
    find $RPA_HOME -type d -exec chmod 755 {} \;
    
    # Set file permissions
    find $RPA_HOME -type f -exec chmod 644 {} \;
    
    # Make scripts executable
    chmod -R 755 $RPA_HOME/scripts/
    
    # Secure sensitive files
    chmod 600 $RPA_HOME/.admin-password
    chmod 600 $RPA_HOME/configs/*.env
    
    # Set proper ownership for sensitive files
    chown $RPA_USER:$RPA_GROUP $RPA_HOME/.admin-password
    chown -R $RPA_USER:$RPA_GROUP $RPA_HOME/configs/
    
    # Ensure volume directories have correct ownership
    chown -R $RPA_USER:$RPA_GROUP $RPA_HOME/volumes/
    chmod -R 755 $RPA_HOME/volumes/
    
    success "Permissions and ownership configured"
}

# Validate deployment integrity
validate_deployment() {
    section "VALIDATING DEPLOYMENT"
    
    info "Performing deployment validation..."
    
    # Check required files
    local required_files=(
        "$RPA_HOME/scripts/start-system.sh"
        "$RPA_HOME/scripts/stop-system.sh"
        "$RPA_HOME/scripts/health-check.sh"
        "$RPA_HOME/configs/orchestrator.env"
        "$RPA_HOME/configs/worker.env"
        "$RPA_HOME/.admin-password"
        "$RPA_HOME/containers/orchestrator/Containerfile"
        "$RPA_HOME/containers/worker/Containerfile"
    )
    
    for file in "${required_files[@]}"; do
        if [[ ! -f "$file" ]]; then
            error "Required file missing: $file"
        fi
    done
    
    # Check required directories
    local required_dirs=(
        "$RPA_HOME/scripts"
        "$RPA_HOME/configs"
        "$RPA_HOME/containers/orchestrator"
        "$RPA_HOME/containers/worker"
        "$RPA_HOME/volumes/data"
        "$RPA_HOME/volumes/logs"
    )
    
    for dir in "${required_dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            error "Required directory missing: $dir"
        fi
    done
    
    # Test podman functionality
    if ! sudo -u $RPA_USER podman version >/dev/null 2>&1; then
        error "Podman not accessible for RPA user"
    fi
    
    # Check systemd service
    if ! systemctl is-enabled rpa-system.service >/dev/null 2>&1; then
        error "RPA systemd service not properly enabled"
    fi
    
    # Validate configuration files
    if ! grep -q "ORCHESTRATOR_PORT=8620" $RPA_HOME/configs/orchestrator.env; then
        warning "Orchestrator configuration may be incomplete"
    fi
    
    if ! grep -q "WORKER_PORT=8621" $RPA_HOME/configs/worker.env; then
        warning "Worker configuration may be incomplete"
    fi
    
    # Check admin password
    if [[ ! -s "$RPA_HOME/.admin-password" ]]; then
        error "Admin password file is empty or missing"
    fi
    
    success "Deployment validation completed successfully"
}

# Generate comprehensive deployment report
generate_deployment_report() {
    section "GENERATING DEPLOYMENT REPORT"
    
    local report_file="$RPA_HOME/DEPLOYMENT_REPORT.md"
    local admin_password=$(cat $RPA_HOME/.admin-password 2>/dev/null || echo "ERROR: Could not read password")
    
    cat > "$report_file" << EOF
# RPA Production Deployment Report

## Deployment Information
- **Date:** $(date)
- **Environment:** $ENVIRONMENT_TYPE
- **Discovery Source:** $DISCOVERY_DIR
- **Deployment Version:** $(date +%Y%m%d-%H%M%S)
- **Deployed By:** $(whoami)
- **System Hostname:** $(hostname)

## System Specifications
- **Operating System:** $(cat /etc/redhat-release)
- **Kernel Version:** $(uname -r)
- **CPU Cores:** $CPU_COUNT
- **Total Memory:** ${MEMORY_GB}GB
- **Available Disk:** ${AVAILABLE_SPACE}GB
- **Architecture:** $(uname -m)

## RPA System Configuration
- **Installation Directory:** $RPA_HOME
- **RPA User Account:** $RPA_USER
- **Max Concurrent Workers:** $MAX_WORKERS
- **Worker Memory Limit:** $WORKER_MEMORY
- **Orchestrator Memory Limit:** $ORCHESTRATOR_MEMORY
- **Worker Timeout:** ${WORKER_TIMEOUT}s
- **Job Poll Interval:** ${JOB_POLL_INTERVAL}s

## Service Endpoints
- **Orchestrator API:** http://$(hostname):8620
- **Worker 1 API:** http://$(hostname):8621
- **Worker 2 API:** http://$(hostname):8622

## Authentication
- **Admin Username:** admin
- **Admin Password:** $admin_password
- **JWT Token Expiry:** 24 hours

## Container Images
- **Orchestrator:** rpa-orchestrator:latest
- **Worker:** rpa-worker:latest
- **Base Image:** registry.redhat.io/ubi9/python-311:latest

## Network Configuration
- **Container Network:** rpa-network (172.18.0.0/16)
- **Orchestrator Port:** 8620
- **Worker Ports:** 8621, 8622
- **Firewall Status:** Configured (ports 8620-8622 open)

## Storage Configuration
- **Data Directory:** $RPA_HOME/volumes/data
- **Log Directory:** $RPA_HOME/volumes/logs
- **Database Path:** $RPA_HOME/volumes/data/db/orchestrator.db
- **Evidence Storage:** $RPA_HOME/volumes/data/evidence
- **Screenshot Storage:** $RPA_HOME/volumes/data/screenshots

## Security Configuration
- **SELinux:** $(getenforce 2>/dev/null || echo "Not available")
- **Firewall:** Active (firewalld)
- **User Isolation:** Container user (rpauser:1001)
- **File Permissions:** Restrictive (644/755)
- **Network Isolation:** Container bridge network

## Management Commands

### System Control
\`\`\`bash
# Start the RPA system
systemctl start rpa-system

# Stop the RPA system
systemctl stop rpa-system

# Restart the RPA system
systemctl restart rpa-system

# Check system status
systemctl status rpa-system

# View system logs
journalctl -u rpa-system -f
\`\`\`

### Manual Management
\`\`\`bash
# Manual start (if systemd not available)
$RPA_HOME/scripts/start-system.sh

# Manual stop
$RPA_HOME/scripts/stop-system.sh

# Health check
$RPA_HOME/scripts/health-check.sh

# Create backup
$RPA_HOME/scripts/backup-system.sh

# Build containers
$RPA_HOME/scripts/build-containers.sh
\`\`\`

### Container Management
\`\`\`bash
# View running containers
sudo -u $RPA_USER podman ps

# View container logs
sudo -u $RPA_USER podman logs rpa-orchestrator
sudo -u $RPA_USER podman logs rpa-worker1
sudo -u $RPA_USER podman logs rpa-worker2

# Container resource usage
sudo -u $RPA_USER podman stats

# Restart specific container
sudo -u $RPA_USER podman restart rpa-orchestrator
\`\`\`

## Monitoring and Maintenance

### Health Monitoring
- **Health Check Script:** $RPA_HOME/scripts/health-check.sh
- **Health Check Interval:** 30 seconds
- **Service Endpoints:** /health on each service port
- **Log Rotation:** Daily (30-day retention)

### Backup Strategy
- **Automatic Backups:** Not configured (manual only)
- **Backup Location:** $RPA_HOME/backups/
- **Backup Retention:** 7 days
- **Backup Script:** $RPA_HOME/scripts/backup-system.sh

### Log Locations
- **Application Logs:** $RPA_HOME/volumes/logs/
- **System Logs:** /var/log/rpa-deployment.log
- **Container Logs:** \`sudo -u $RPA_USER podman logs CONTAINER_NAME\`
- **Service Logs:** \`journalctl -u rpa-system\`

## Troubleshooting Guide

### Common Issues

#### System Won't Start
1. Check systemd status: \`systemctl status rpa-system\`
2. Check container status: \`sudo -u $RPA_USER podman ps -a\`
3. Review logs: \`journalctl -u rpa-system -n 50\`
4. Verify network: \`sudo -u $RPA_USER podman network ls\`

#### Containers Won't Build
1. Check disk space: \`df -h\`
2. Verify source code: \`ls -la $RPA_HOME/\`
3. Check build logs: \`sudo -u $RPA_USER podman build --no-cache ...\`
4. Verify requirements.txt: \`cat $RPA_HOME/requirements.txt\`

#### Network Connectivity Issues
1. Check firewall: \`firewall-cmd --list-ports\`
2. Verify ports: \`ss -tuln | grep 862\`
3. Test endpoints: \`curl http://localhost:8620/health\`
4. Check container network: \`sudo -u $RPA_USER podman network inspect rpa-network\`

#### Performance Issues
1. Monitor resources: \`$RPA_HOME/scripts/health-check.sh\`
2. Check container stats: \`sudo -u $RPA_USER podman stats\`
3. Review logs: \`tail -f $RPA_HOME/volumes/logs/*.log\`
4. Adjust resource limits in start script

### Support Contacts
- **System Administrator:** $(whoami)@$(hostname)
- **Deployment Date:** $(date)
- **Configuration Files:** $RPA_HOME/configs/
- **Management Scripts:** $RPA_HOME/scripts/

## Post-Deployment Tasks

### Immediate Tasks (Next 24 hours)
- [ ] Start the RPA system: \`systemctl start rpa-system\`
- [ ] Verify all services are healthy: \`$RPA_HOME/scripts/health-check.sh\`
- [ ] Test orchestrator web interface at http://$(hostname):8620
- [ ] Submit a test automation job
- [ ] Verify workers are processing jobs correctly
- [ ] Check all log files for errors
- [ ] Test backup creation: \`$RPA_HOME/scripts/backup-system.sh\`

### Weekly Tasks
- [ ] Run comprehensive health check
- [ ] Review system resource utilization
- [ ] Check log files for errors or warnings
- [ ] Verify backup creation and retention
- [ ] Test service restart procedures

### Monthly Tasks
- [ ] Update container base images and rebuild
- [ ] Review and rotate admin passwords
- [ ] Update system packages: \`dnf update -y\`
- [ ] Test disaster recovery procedures
- [ ] Review and optimize resource allocation

## Configuration Files Reference

### Environment Configuration
- **Orchestrator Config:** $RPA_HOME/configs/orchestrator.env
- **Worker Config:** $RPA_HOME/configs/worker.env
- **Admin Password:** $RPA_HOME/.admin-password

### Container Definitions
- **Orchestrator Image:** $RPA_HOME/containers/orchestrator/Containerfile
- **Worker Image:** $RPA_HOME/containers/worker/Containerfile
- **Requirements:** $RPA_HOME/requirements.txt

### Management Scripts
- **System Start:** $RPA_HOME/scripts/start-system.sh
- **System Stop:** $RPA_HOME/scripts/stop-system.sh
- **Health Check:** $RPA_HOME/scripts/health-check.sh
- **Backup System:** $RPA_HOME/scripts/backup-system.sh
- **Build Containers:** $RPA_HOME/scripts/build-containers.sh

## Deployment Validation

✅ **Prerequisites:** Installed and verified
✅ **User Account:** Created ($RPA_USER)
✅ **Directories:** Created with proper permissions
✅ **Source Code:** Deployed from discovery data
✅ **Configurations:** Generated for $ENVIRONMENT_TYPE environment
✅ **Container Files:** Created (Orchestrator, Worker)
✅ **Management Scripts:** Created and executable
✅ **Firewall:** Configured (ports 8620-8622)
✅ **SELinux:** Configured for containers
✅ **Systemd Service:** Created and enabled
✅ **Log Rotation:** Configured (daily, 30-day retention)
✅ **Permissions:** Set correctly
✅ **Validation:** All checks passed

## Next Steps

1. **Start the system:** \`systemctl start rpa-system\`
2. **Verify deployment:** \`$RPA_HOME/scripts/health-check.sh\`
3. **Access web interface:** http://$(hostname):8620
4. **Submit test job:** Use the orchestrator API
5. **Monitor system:** Check logs and performance
6. **Set up monitoring:** Configure external monitoring tools
7. **Schedule backups:** Add cron job for regular backups
8. **Document procedures:** Create operational runbooks

---

**Deployment completed successfully on $(date)**

For technical support, refer to the troubleshooting section above or check the management scripts in $RPA_HOME/scripts/
EOF

    # Set proper ownership
    chown $RPA_USER:$RPA_GROUP "$report_file"
    chmod 644 "$report_file"
    
    success "Comprehensive deployment report generated: $report_file"
}

# Main deployment orchestration function
main() {
    # Display banner
    echo -e "${CYAN}"
    cat << 'BANNER'
    ____  ____   _       ____  ____   ___  ____  
   |  _ \|  _ \ / \     |  _ \|  _ \ / _ \|  _ \ 
   | |_) | |_) / _ \    | |_) | |_) | | | | | | |
   |  _ <|  __/ ___ \   |  __/|  _ <| |_| | |_| |
   |_| \_\_| /_/   \_\  |_|   |_| \_\\___/|____/ 
                                                 
       Production Deployment System
BANNER
    echo -e "${NC}"
    
    info "Starting RPA production deployment process..."
    
    # Execute deployment phases
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
    
    # Success summary
    echo -e "\n${GREEN}"
    cat << 'SUCCESS_BANNER'
    ╔══════════════════════════════════════════════════════════════════╗
    ║                    🎉 DEPLOYMENT SUCCESSFUL! 🎉                  ║
    ╚══════════════════════════════════════════════════════════════════╝
SUCCESS_BANNER
    echo -e "${NC}"
    
    echo -e "${CYAN}📋 Deployment Summary:${NC}"
    echo -e "  🏠 Installation Directory: ${YELLOW}$RPA_HOME${NC}"
    echo -e "  👤 RPA User Account: ${YELLOW}$RPA_USER${NC}"
    echo -e "  🔑 Admin Password: ${YELLOW}$(cat $RPA_HOME/.admin-password 2>/dev/null || echo 'Check deployment report')${NC}"
    echo -e "  🌍 Environment Type: ${YELLOW}$ENVIRONMENT_TYPE${NC}"
    echo -e "  🖥️  System Resources: ${YELLOW}${CPU_COUNT} CPUs, ${MEMORY_GB}GB RAM${NC}"
    
    echo -e "\n${CYAN}🚀 Quick Start Commands:${NC}"
    echo -e "  ${BLUE}systemctl start rpa-system${NC}         - Start the RPA system"
    echo -e "  ${BLUE}$RPA_HOME/scripts/health-check.sh${NC}  - Check system health"
    echo -e "  ${BLUE}systemctl status rpa-system${NC}        - Check service status"
    
    echo -e "\n${CYAN}🌐 Access Points (after starting):${NC}"
    echo -e "  🎛️  Orchestrator: ${YELLOW}http://$(hostname):8620${NC}"
    echo -e "  👷 Worker 1:     ${YELLOW}http://$(hostname):8621${NC}"
    echo -e "  👷 Worker 2:     ${YELLOW}http://$(hostname):8622${NC}"
    
    echo -e "\n${CYAN}📚 Documentation:${NC}"
    echo -e "  📄 Full deployment report: ${YELLOW}$RPA_HOME/DEPLOYMENT_REPORT.md${NC}"
    echo -e "  📋 Management scripts: ${YELLOW}$RPA_HOME/scripts/${NC}"
    echo -e "  ⚙️  Configuration files: ${YELLOW}$RPA_HOME/configs/${NC}"
    
    echo -e "\n${GREEN}✅ Your RPA system is ready for production use!${NC}"
    echo -e "${YELLOW}Next step: systemctl start rpa-system${NC}"
}

# Execute main function with all arguments
main "$@"