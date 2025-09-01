#!/bin/bash
# deploy-rpa-system.sh
# Complete deployment script for RPA system on RHEL with Podman

set -euo pipefail

# Configuration
RPA_HOME="/opt/rpa-system"
RPA_USER="rpauser"
RPA_GROUP="rpauser"
LOG_FILE="/var/log/rpa-deployment.log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
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
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        exit 1
    fi
}

# Detect system specifications
detect_system() {
    info "Detecting system specifications..."
    
    # Get CPU and memory info
    CPU_COUNT=$(nproc)
    MEMORY_GB=$(free -g | awk 'NR==2{print $2}')
    DISK_AVAILABLE=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
    
    info "System specs: ${CPU_COUNT} CPU cores, ${MEMORY_GB}GB RAM, ${DISK_AVAILABLE}GB available disk"
    
    # Check if this is a t3.medium or similar
    if [[ $CPU_COUNT -eq 2 ]] && [[ $MEMORY_GB -eq 3 || $MEMORY_GB -eq 4 ]]; then
        info "Detected t3.medium-like instance, applying optimizations"
        OPTIMIZE_FOR_T3_MEDIUM=true
    else
        OPTIMIZE_FOR_T3_MEDIUM=false
    fi
}

# Install prerequisites
install_prerequisites() {
    info "Installing prerequisites..."
    
    # Update system
    dnf update -y
    
    # Install required packages
    dnf install -y \
        podman \
        podman-compose \
        git \
        curl \
        jq \
        wget \
        unzip \
        firewalld \
        python3 \
        python3-pip \
        sqlite \
        chrony
    
    # Enable and start required services
    systemctl enable --now firewalld
    systemctl enable --now chronyd
    
    success "Prerequisites installed successfully"
}

# Create RPA user and directories
setup_user_and_directories() {
    info "Setting up RPA user and directories..."
    
    # Create RPA user if it doesn't exist
    if ! id -u $RPA_USER &>/dev/null; then
        useradd -r -m -d /home/$RPA_USER -s /bin/bash $RPA_USER
        info "Created RPA user: $RPA_USER"
    fi
    
    # Create application directory
    mkdir -p $RPA_HOME
    chown $RPA_USER:$RPA_GROUP $RPA_HOME
    chmod 755 $RPA_HOME
    
    # Create directory structure
    sudo -u $RPA_USER mkdir -p $RPA_HOME/{containers/{orchestrator,worker},configs,volumes/{data/{db,logs,screenshots,evidence},logs},scripts}
    
    # Set up subuid and subgid for rootless containers
    echo "${RPA_USER}:100000:65536" >> /etc/subuid
    echo "${RPA_USER}:100000:65536" >> /etc/subgid
    
    # Enable lingering for user services
    loginctl enable-linger $RPA_USER
    
    success "User and directories set up successfully"
}

# Configure firewall
configure_firewall() {
    info "Configuring firewall..."
    
    # Open required ports
    firewall-cmd --permanent --add-port=8620/tcp  # Orchestrator
    firewall-cmd --permanent --add-port=8621/tcp  # Worker 1
    firewall-cmd --permanent --add-port=8622/tcp  # Worker 2
    firewall-cmd --permanent --add-port=8623/tcp  # Additional workers
    
    # Add rich rules for better security
    firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="127.0.0.1" port protocol="tcp" port="8620-8625" accept'
    
    firewall-cmd --reload
    
    success "Firewall configured successfully"
}

# Configure SELinux
configure_selinux() {
    info "Configuring SELinux..."
    
    # Set SELinux booleans for containers
    setsebool -P container_manage_cgroup 1
    setsebool -P virt_use_fusefs 1
    
    # Set file contexts for RPA directories
    semanage fcontext -a -t container_file_t "$RPA_HOME/volumes(/.*)?" 2>/dev/null || true
    restorecon -R $RPA_HOME/volumes/
    
    success "SELinux configured for containers"
}

# Generate optimized configurations
generate_configurations() {
    info "Generating optimized configurations..."
    
    # Calculate optimal worker settings based on system specs
    if [[ $OPTIMIZE_FOR_T3_MEDIUM == true ]]; then
        MAX_WORKERS=4
        BATCH_SIZE=2
        WORKER_TIMEOUT=900
        JOB_POLL_INTERVAL=30
    else
        MAX_WORKERS=$((CPU_COUNT * 2))
        BATCH_SIZE=3
        WORKER_TIMEOUT=600
        JOB_POLL_INTERVAL=15
    fi
    
    # Generate orchestrator environment file
    cat > $RPA_HOME/configs/orchestrator.env << EOF
# Orchestrator Configuration
ORCHESTRATOR_HOST=0.0.0.0
ORCHESTRATOR_PORT=8620

# Worker Management
WORKER_ENDPOINTS=["http://worker1:8621/execute","http://worker2:8621/execute"]
MAX_WORKERS=$MAX_WORKERS
WORKER_TIMEOUT=$WORKER_TIMEOUT

# Job Processing
JOB_POLL_INTERVAL=$JOB_POLL_INTERVAL
BATCH_SIZE=$BATCH_SIZE
METRICS_INTERVAL=300

# Database
BASE_DATA_DIR=/app/data
DB_PATH=/app/data/db/orchestrator.db
DB_CONNECTION_POOL_SIZE=20
DB_MAX_OVERFLOW=30

# Security
JWT_SECRET=$(openssl rand -hex 32)
ADMIN_USERNAME=admin
ADMIN_PASSWORD=$(openssl rand -base64 12)

# Logging
LOG_LEVEL=INFO
STRUCTURED_LOGGING=true
LOG_JSON_FORMAT=true

# Health Monitoring
HEALTH_REPORT_ENABLED=true
HEALTH_REPORT_INTERVAL=300
EOF

    # Generate worker environment file
    cat > $RPA_HOME/configs/worker.env << EOF
# Worker Configuration
WORKER_HOST=0.0.0.0
WORKER_PORT=8621

# Threading
MAX_WORKERS=$MAX_WORKERS
WORKER_TIMEOUT=$WORKER_TIMEOUT
WORKER_THREAD_POOL_SIZE=$MAX_WORKERS

# Browser Settings
HEADLESS=true
NO_SANDBOX=true
DISABLE_DEV_SHM_USAGE=true
START_MAXIMIZED=false
CHROMEDRIVER_PATH=/usr/local/bin/chromedriver

# Security
AUTHORIZED_WORKER_IPS=["172.18.0.0/16","127.0.0.1"]

# Data
BASE_DATA_DIR=/app/data
SCREENSHOT_DIR=/app/data/screenshots
EVIDENCE_DIR=/app/data/evidence

# Performance
PYTHON_GC_THRESHOLD=700,10,10
SQLITE_TIMEOUT=30
SELENIUM_PAGE_LOAD_TIMEOUT=45

# Logging
LOG_LEVEL=INFO
STRUCTURED_LOGGING=true
LOG_JSON_FORMAT=true
EOF
    
    # Store admin credentials securely
    echo "$(grep ADMIN_PASSWORD $RPA_HOME/configs/orchestrator.env | cut -d= -f2)" > $RPA_HOME/.admin-password
    chmod 600 $RPA_HOME/.admin-password
    chown $RPA_USER:$RPA_GROUP $RPA_HOME/.admin-password
    
    success "Configuration files generated"
    info "Admin password saved to $RPA_HOME/.admin-password"
}

# Create Containerfiles
create_containerfiles() {
    info "Creating Containerfiles..."
    
    # Orchestrator Containerfile
    cat > $RPA_HOME/containers/orchestrator/Containerfile << 'EOF'
FROM registry.redhat.io/ubi9/python-311:latest

USER root

# Install system dependencies
RUN dnf update -y && \
    dnf install -y \
        sqlite \
        sqlite-devel \
        gcc \
        python3-devel && \
    dnf clean all

# Create app user
RUN useradd -m -u 1001 rpauser && \
    mkdir -p /app /app/data /app/logs && \
    chown -R rpauser:rpauser /app

USER rpauser
WORKDIR /app

# Install Python dependencies
COPY requirements.txt ./
RUN pip install --user --no-cache-dir -r requirements.txt

# Copy application code
COPY --chown=rpauser:rpauser . .

# Create directories
RUN mkdir -p data/db data/logs data/screenshots data/evidence

EXPOSE 8620

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD curl -f http://localhost:8620/health || exit 1

CMD ["python", "orchestrator.py"]
EOF

    # Worker Containerfile
    cat > $RPA_HOME/containers/worker/Containerfile << 'EOF'
FROM registry.redhat.io/ubi9/python-311:latest

USER root

# Install Chrome and system dependencies
RUN dnf update -y && \
    dnf install -y \
        chromium \
        chromium-headless \
        sqlite \
        sqlite-devel \
        gcc \
        python3-devel \
        xvfb \
        curl \
        wget \
        unzip && \
    dnf clean all

# Install ChromeDriver
RUN CHROME_DRIVER_VERSION=$(curl -sS https://chromedriver.storage.googleapis.com/LATEST_RELEASE) && \
    wget -O /tmp/chromedriver.zip "https://chromedriver.storage.googleapis.com/${CHROME_DRIVER_VERSION}/chromedriver_linux64.zip" && \
    unzip /tmp/chromedriver.zip -d /tmp/ && \
    mv /tmp/chromedriver /usr/local/bin/chromedriver && \
    chmod +x /usr/local/bin/chromedriver && \
    rm -f /tmp/chromedriver.zip

# Create app user
RUN useradd -m -u 1001 rpauser && \
    mkdir -p /app /app/data /app/logs && \
    chown -R rpauser:rpauser /app

USER rpauser
WORKDIR /app

# Install Python dependencies
COPY requirements.txt ./
RUN pip install --user --no-cache-dir -r requirements.txt

# Copy application code
COPY --chown=rpauser:rpauser . .

# Create directories
RUN mkdir -p data/logs data/screenshots data/evidence worker_data

# Set environment variables
ENV CHROMEDRIVER_PATH=/usr/local/bin/chromedriver
ENV HEADLESS=true
ENV NO_SANDBOX=true
ENV DISABLE_DEV_SHM_USAGE=true

EXPOSE 8621

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD curl -f http://localhost:8621/health || exit 1

CMD ["python", "worker.py"]
EOF

    success "Containerfiles created"
}

# Create podman-compose configuration
create_podman_compose() {
    info "Creating podman-compose configuration..."
    
    cat > $RPA_HOME/podman-compose.yml << EOF
version: '3.8'

services:
  orchestrator:
    build:
      context: .
      dockerfile: containers/orchestrator/Containerfile
    container_name: rpa-orchestrator
    hostname: orchestrator
    ports:
      - "8620:8620"
    env_file:
      - configs/orchestrator.env
    volumes:
      - ./volumes/data:/app/data:Z
      - ./volumes/logs:/app/logs:Z
    networks:
      - rpa-network
    restart: unless-stopped
    depends_on:
      - worker1
      - worker2
    resources:
      limits:
        memory: 1G
        cpus: '0.8'
      reservations:
        memory: 512M
        cpus: '0.4'

  worker1:
    build:
      context: .
      dockerfile: containers/worker/Containerfile
    container_name: rpa-worker1
    hostname: worker1
    ports:
      - "8621:8621"
    env_file:
      - configs/worker.env
    volumes:
      - ./volumes/data:/app/data:Z
      - ./volumes/logs:/app/logs:Z
    networks:
      - rpa-network
    restart: unless-stopped
    security_opt:
      - seccomp:unconfined
    shm_size: 2gb
    resources:
      limits:
        memory: 1.5G
        cpus: '1.0'
      reservations:
        memory: 512M
        cpus: '0.5'

  worker2:
    build:
      context: .
      dockerfile: containers/worker/Containerfile
    container_name: rpa-worker2
    hostname: worker2
    ports:
      - "8622:8621"
    env_file:
      - configs/worker.env
    volumes:
      - ./volumes/data:/app/data:Z
      - ./volumes/logs:/app/logs:Z
    networks:
      - rpa-network
    restart: unless-stopped
    security_opt:
      - seccomp:unconfined
    shm_size: 2gb
    resources:
      limits:
        memory: 1.5G
        cpus: '1.0'
      reservations:
        memory: 512M
        cpus: '0.5'

networks:
  rpa-network:
    driver: bridge
    ipam:
      config:
        - subnet: 172.18.0.0/16

volumes:
  rpa-data:
  rpa-logs:
EOF

    success "Podman-compose configuration created"
}

# Create management scripts
create_management_scripts() {
    info "Creating management scripts..."
    
    # System start script
    cat > $RPA_HOME/scripts/start-system.sh << 'EOF'
#!/bin/bash
set -e

cd /opt/rpa-system

echo "🚀 Starting RPA System..."

# Set proper permissions
sudo chown -R rpauser:rpauser volumes/

# Build and start containers
echo "📦 Building containers..."
sudo -u rpauser podman-compose build --parallel

echo "🔧 Starting services..."
sudo -u rpauser podman-compose up -d

# Wait for services
echo "⏳ Waiting for services to start..."
sleep 30

# Health checks
for port in 8620 8621 8622; do
    if curl -f -s http://localhost:$port/health > /dev/null; then
        echo "✅ Service on port $port: Healthy"
    else
        echo "❌ Service on port $port: Unhealthy"
    fi
done

echo "✅ RPA System startup complete!"
echo "📊 Orchestrator: http://localhost:8620"
echo "👷 Worker 1: http://localhost:8621"
echo "👷 Worker 2: http://localhost:8622"

sudo -u rpauser podman-compose ps
EOF

    # System stop script
    cat > $RPA_HOME/scripts/stop-system.sh << 'EOF'
#!/bin/bash
cd /opt/rpa-system

echo "🛑 Stopping RPA System..."
sudo -u rpauser podman-compose down
echo "✅ RPA System stopped"
EOF

    # Health check script
    cat > $RPA_HOME/scripts/health-check.sh << 'EOF'
#!/bin/bash
cd /opt/rpa-system

echo "🔍 RPA System Health Check"
echo "=========================="

# Check services
for port in 8620 8621 8622; do
    if curl -f -s http://localhost:$port/health > /dev/null; then
        echo "✅ Service (port $port): Healthy"
    else
        echo "❌ Service (port $port): Unhealthy"
    fi
done

# Container status
echo -e "\n📦 Container Status:"
sudo -u rpauser podman-compose ps

# Resource usage
echo -e "\n💾 Resource Usage:"
sudo -u rpauser podman stats --no-stream
EOF

    # Backup script
    cat > $RPA_HOME/scripts/backup.sh << 'EOF'
#!/bin/bash
BACKUP_DIR="/backup/rpa-$(date +%Y%m%d-%H%M%S)"
mkdir -p $BACKUP_DIR

echo "💾 Creating backup in $BACKUP_DIR..."

# Backup database and data
cp -r /opt/rpa-system/volumes/data $BACKUP_DIR/
tar -czf $BACKUP_DIR/logs.tar.gz /opt/rpa-system/volumes/logs/
cp -r /opt/rpa-system/configs $BACKUP_DIR/

echo "✅ Backup completed: $BACKUP_DIR"
EOF

    # Make scripts executable
    chmod +x $RPA_HOME/scripts/*.sh
    chown -R $RPA_USER:$RPA_GROUP $RPA_HOME/scripts/
    
    success "Management scripts created"
}

# Create systemd service
create_systemd_service() {
    info "Creating systemd service..."
    
    cat > /etc/systemd/system/rpa-system.service << EOF
[Unit]
Description=RPA System Container Stack
After=network.target
Wants=network.target

[Service]
Type=oneshot
RemainAfterExit=true
ExecStart=$RPA_HOME/scripts/start-system.sh
ExecStop=$RPA_HOME/scripts/stop-system.sh
ExecReload=/bin/bash -c 'cd $RPA_HOME && sudo -u $RPA_USER podman-compose restart'
TimeoutStartSec=300
TimeoutStopSec=60
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable rpa-system.service
    
    success "Systemd service created and enabled"
}

# Set up monitoring
setup_monitoring() {
    info "Setting up basic monitoring..."
    
    # Create monitoring script
    cat > $RPA_HOME/scripts/monitor.sh << 'EOF'
#!/bin/bash
# Simple monitoring script

LOG_FILE="/var/log/rpa-monitoring.log"

while true; do
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Check services
    orchestrator_status="DOWN"
    worker1_status="DOWN"
    worker2_status="DOWN"
    
    if curl -f -s http://localhost:8620/health > /dev/null 2>&1; then
        orchestrator_status="UP"
    fi
    
    if curl -f -s http://localhost:8621/health > /dev/null 2>&1; then
        worker1_status="UP"
    fi
    
    if curl -f -s http://localhost:8622/health > /dev/null 2>&1; then
        worker2_status="UP"
    fi
    
    # Log status
    echo "$timestamp - Orchestrator: $orchestrator_status, Worker1: $worker1_status, Worker2: $worker2_status" >> $LOG_FILE
    
    # Sleep for 5 minutes
    sleep 300
done
EOF

    chmod +x $RPA_HOME/scripts/monitor.sh
    
    # Create monitoring service
    cat > /etc/systemd/system/rpa-monitor.service << EOF
[Unit]
Description=RPA System Monitor
After=rpa-system.service
Wants=rpa-system.service

[Service]
Type=simple
ExecStart=$RPA_HOME/scripts/monitor.sh
Restart=always
RestartSec=30
User=$RPA_USER

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable rpa-monitor.service
    
    success "Monitoring setup complete"
}

# Final setup and testing
final_setup() {
    info "Performing final setup..."
    
    # Set proper ownership
    chown -R $RPA_USER:$RPA_GROUP $RPA_HOME
    
    # Create log rotation configuration
    cat > /etc/logrotate.d/rpa-system << EOF
$RPA_HOME/volumes/logs/*.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    create 644 $RPA_USER $RPA_GROUP
    postrotate
        systemctl reload rpa-system || true
    endscript
}
EOF
    
    # Final permissions check
    chmod -R 755 $RPA_HOME
    chmod -R 644 $RPA_HOME/configs/*
    chmod 600 $RPA_HOME/.admin-password
    
    success "Final setup complete"
}

# Main deployment function
main() {
    info "Starting RPA System deployment on RHEL..."
    
    check_root
    detect_system
    install_prerequisites
    setup_user_and_directories
    configure_firewall
    configure_selinux
    generate_configurations
    create_containerfiles
    create_podman_compose
    create_management_scripts
    create_systemd_service
    setup_monitoring
    final_setup
    
    success "RPA System deployment completed successfully!"
    echo ""
    echo "================================================"
    echo "DEPLOYMENT SUMMARY"
    echo "================================================"
    echo "Installation Directory: $RPA_HOME"
    echo "RPA User: $RPA_USER"
    echo "Admin Password: $(cat $RPA_HOME/.admin-password)"
    echo ""
    echo "Next Steps:"
    echo "1. Copy your RPA source code to $RPA_HOME/"
    echo "2. Review configurations in $RPA_HOME/configs/"
    echo "3. Start the system: systemctl start rpa-system"
    echo "4. Check status: $RPA_HOME/scripts/health-check.sh"
    echo ""
    echo "Service URLs:"
    echo "- Orchestrator: http://$(hostname -I | awk '{print $1}'):8620"
    echo "- Worker 1: http://$(hostname -I | awk '{print $1}'):8621"
    echo "- Worker 2: http://$(hostname -I | awk '{print $1}'):8622"
    echo "================================================"
}

# Run main function
main "$@"
