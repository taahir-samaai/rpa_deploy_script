#!/bin/bash
# rhel10-rpa-deployment.sh
# RHEL 10 compatible RPA deployment script

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

# Install prerequisites for RHEL 10
install_prerequisites_rhel10() {
    info "Installing prerequisites for RHEL 10..."
    
    # Update system (already done, skip)
    info "System already updated"
    
    # Install available packages
    dnf install -y \
        wget \
        unzip \
        firewalld \
        python3-pip \
        sqlite \
        gcc \
        python3-devel \
        git \
        curl \
        jq || {
            warning "Some packages may have failed to install, continuing..."
        }
    
    # Install podman-compose via pip
    info "Installing podman-compose via pip..."
    pip3 install podman-compose
    
    # Create symlink for system-wide access
    if [ -f /usr/local/bin/podman-compose ]; then
        ln -sf /usr/local/bin/podman-compose /usr/bin/podman-compose
    elif [ -f /root/.local/bin/podman-compose ]; then
        ln -sf /root/.local/bin/podman-compose /usr/bin/podman-compose
    fi
    
    # Verify podman-compose installation
    if command -v podman-compose &> /dev/null; then
        success "podman-compose installed successfully"
    else
        error "Failed to install podman-compose"
        info "Trying alternative installation method..."
        
        # Alternative: Install docker-compose and use it with podman
        pip3 install docker-compose
        
        # Create wrapper script
        cat > /usr/local/bin/podman-compose << 'EOF'
#!/bin/bash
# Wrapper script to use docker-compose with podman
export DOCKER_HOST=unix:///run/user/$(id -u)/podman/podman.sock
docker-compose "$@"
EOF
        chmod +x /usr/local/bin/podman-compose
        ln -sf /usr/local/bin/podman-compose /usr/bin/podman-compose
    fi
    
    success "Prerequisites installed successfully"
}

# Rest of the functions remain the same, but let's create a simplified version
# that works without podman-compose if needed

# Create native podman scripts instead of relying on podman-compose
create_native_podman_scripts() {
    info "Creating native Podman management scripts..."
    
    # Create network creation script
    cat > $RPA_HOME/scripts/create-network.sh << 'EOF'
#!/bin/bash
podman network exists rpa-network || podman network create \
    --driver bridge \
    --subnet 172.18.0.0/16 \
    rpa-network
EOF

    # Create build script
    cat > $RPA_HOME/scripts/build-containers.sh << 'EOF'
#!/bin/bash
cd /opt/rpa-system

echo "Building orchestrator..."
podman build -t rpa-orchestrator:latest -f containers/orchestrator/Containerfile .

echo "Building worker..."
podman build -t rpa-worker:latest -f containers/worker/Containerfile .

echo "Container builds complete"
EOF

    # Create start script using native podman
    cat > $RPA_HOME/scripts/start-system-podman.sh << 'EOF'
#!/bin/bash
set -e

cd /opt/rpa-system

echo "🚀 Starting RPA System with native Podman..."

# Create network
./scripts/create-network.sh

# Set proper permissions
chown -R rpauser:rpauser volumes/

# Build containers
sudo -u rpauser ./scripts/build-containers.sh

# Start orchestrator
echo "Starting orchestrator..."
sudo -u rpauser podman run -d \
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
echo "Starting worker 1..."
sudo -u rpauser podman run -d \
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
echo "Starting worker 2..."
sudo -u rpauser podman run -d \
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
sleep 30

# Health checks
for port in 8620 8621 8622; do
    if curl -f -s http://localhost:$port/health > /dev/null; then
        echo "Service on port $port: Healthy"
    else
        echo "Service on port $port: Unhealthy"
    fi
done

echo "RPA System startup complete!"
echo "Orchestrator: http://localhost:8620"
echo "Worker 1: http://localhost:8621"
echo "Worker 2: http://localhost:8622"

sudo -u rpauser podman ps
EOF

    # Create stop script
    cat > $RPA_HOME/scripts/stop-system-podman.sh << 'EOF'
#!/bin/bash
echo "Stopping RPA System..."

sudo -u rpauser podman stop rpa-orchestrator rpa-worker1 rpa-worker2 2>/dev/null || true
sudo -u rpauser podman rm rpa-orchestrator rpa-worker1 rpa-worker2 2>/dev/null || true

echo "RPA System stopped"
EOF

    # Create health check script
    cat > $RPA_HOME/scripts/health-check-podman.sh << 'EOF'
#!/bin/bash
echo "RPA System Health Check"
echo "=========================="

# Check services
for port in 8620 8621 8622; do
    if curl -f -s http://localhost:$port/health > /dev/null; then
        echo "Service (port $port): Healthy"
    else
        echo "Service (port $port): Unhealthy"
    fi
done

# Container status
echo -e "\nContainer Status:"
sudo -u rpauser podman ps -a | grep rpa-

# Resource usage
echo -e "\nResource Usage:"
sudo -u rpauser podman stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}" | head -4
EOF

    # Make all scripts executable
    chmod +x $RPA_HOME/scripts/*.sh
    chown -R $RPA_USER:$RPA_GROUP $RPA_HOME/scripts/
    
    success "Native Podman scripts created"
}

# Update systemd service to use native podman scripts
create_systemd_service_native() {
    info "Creating systemd service for native Podman..."
    
    cat > /etc/systemd/system/rpa-system.service << EOF
[Unit]
Description=RPA System Container Stack (Native Podman)
After=network.target
Wants=network.target

[Service]
Type=oneshot
RemainAfterExit=true
ExecStart=$RPA_HOME/scripts/start-system-podman.sh
ExecStop=$RPA_HOME/scripts/stop-system-podman.sh
ExecReload=/bin/bash -c 'cd $RPA_HOME && $RPA_HOME/scripts/stop-system-podman.sh && sleep 5 && $RPA_HOME/scripts/start-system-podman.sh'
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

# Check if we can use podman-compose or fall back to native podman
choose_deployment_method() {
    if command -v podman-compose &> /dev/null; then
        info "Using podman-compose for container management"
        USE_PODMAN_COMPOSE=true
    else
        warning "podman-compose not available, using native Podman commands"
        USE_PODMAN_COMPOSE=false
    fi
}

# Main function for RHEL 10 deployment
main_rhel10() {
    info "Starting RPA System deployment on RHEL 10..."
    
    # Reuse existing system detection
    CPU_COUNT=$(nproc)
    MEMORY_GB=$(free -g | awk 'NR==2{print $2}')
    DISK_AVAILABLE=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
    
    info "System specs: ${CPU_COUNT} CPU cores, ${MEMORY_GB}GB RAM, ${DISK_AVAILABLE}GB available disk"
    
    if [[ $CPU_COUNT -eq 2 ]] && [[ $MEMORY_GB -eq 3 || $MEMORY_GB -eq 4 ]]; then
        info "Detected t3.medium-like instance, applying optimizations"
        OPTIMIZE_FOR_T3_MEDIUM=true
    else
        OPTIMIZE_FOR_T3_MEDIUM=false
    fi
    
    install_prerequisites_rhel10
    choose_deployment_method
    
    # Continue with existing functions but choose the right method
    info "Continuing with RPA system setup..."
    
    # Create user and directories (reuse existing function)
    setup_user_and_directories() {
        info "Setting up RPA user and directories..."
        
        if ! id -u $RPA_USER &>/dev/null; then
            useradd -r -m -d /home/$RPA_USER -s /bin/bash $RPA_USER
            info "Created RPA user: $RPA_USER"
        fi
        
        mkdir -p $RPA_HOME
        chown $RPA_USER:$RPA_GROUP $RPA_HOME
        chmod 755 $RPA_HOME
        
        sudo -u $RPA_USER mkdir -p $RPA_HOME/{containers/{orchestrator,worker},configs,volumes/{data/{db,logs,screenshots,evidence},logs},scripts}
        
        echo "${RPA_USER}:100000:65536" >> /etc/subuid
        echo "${RPA_USER}:100000:65536" >> /etc/subgid
        
        loginctl enable-linger $RPA_USER
        
        success "User and directories set up successfully"
    }
    
    setup_user_and_directories
    
    # Configure firewall and SELinux (reuse existing functions)
    configure_firewall() {
        info "Configuring firewall..."
        
        firewall-cmd --permanent --add-port=8620/tcp  # Orchestrator
        firewall-cmd --permanent --add-port=8621/tcp  # Worker 1
        firewall-cmd --permanent --add-port=8622/tcp  # Worker 2
        firewall-cmd --reload
        
        success "Firewall configured successfully"
    }
    
    configure_selinux() {
        info "Configuring SELinux..."
        
        setsebool -P container_manage_cgroup 1 || true
        setsebool -P virt_use_fusefs 1 || true
        
        success "SELinux configured for containers"
    }
    
    configure_firewall
    configure_selinux
    
    # Generate configurations with RHEL 10 optimizations
    generate_configurations() {
        info "Generating optimized configurations..."
        
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
        
        # Orchestrator config
        cat > $RPA_HOME/configs/orchestrator.env << EOF
ORCHESTRATOR_HOST=0.0.0.0
ORCHESTRATOR_PORT=8620
WORKER_ENDPOINTS=["http://worker1:8621/execute","http://worker2:8621/execute"]
MAX_WORKERS=$MAX_WORKERS
WORKER_TIMEOUT=$WORKER_TIMEOUT
JOB_POLL_INTERVAL=$JOB_POLL_INTERVAL
BATCH_SIZE=$BATCH_SIZE
BASE_DATA_DIR=/app/data
JWT_SECRET=$(openssl rand -hex 32)
ADMIN_USERNAME=admin
ADMIN_PASSWORD=$(openssl rand -base64 12)
LOG_LEVEL=INFO
EOF

        # Worker config
        cat > $RPA_HOME/configs/worker.env << EOF
WORKER_HOST=0.0.0.0
WORKER_PORT=8621
MAX_WORKERS=$MAX_WORKERS
WORKER_TIMEOUT=$WORKER_TIMEOUT
HEADLESS=true
NO_SANDBOX=true
DISABLE_DEV_SHM_USAGE=true
AUTHORIZED_WORKER_IPS=["172.18.0.0/16","127.0.0.1"]
BASE_DATA_DIR=/app/data
LOG_LEVEL=INFO
EOF

        echo "$(grep ADMIN_PASSWORD $RPA_HOME/configs/orchestrator.env | cut -d= -f2)" > $RPA_HOME/.admin-password
        chmod 600 $RPA_HOME/.admin-password
        chown $RPA_USER:$RPA_GROUP $RPA_HOME/.admin-password
        
        success "Configuration files generated"
    }
    
    generate_configurations
    
    # Create containerfiles (reuse existing function but simplified)
    create_containerfiles() {
        info "Creating Containerfiles..."
        
        # Orchestrator Containerfile (simplified)
        cat > $RPA_HOME/containers/orchestrator/Containerfile << 'EOF'
FROM registry.redhat.io/ubi9/python-311:latest

USER root
RUN dnf update -y && dnf install -y sqlite gcc python3-devel && dnf clean all
RUN useradd -m -u 1001 rpauser && mkdir -p /app && chown -R rpauser:rpauser /app

USER rpauser
WORKDIR /app

COPY requirements.txt ./
RUN pip install --user --no-cache-dir -r requirements.txt

COPY --chown=rpauser:rpauser . .
RUN mkdir -p data/db data/logs data/screenshots data/evidence

EXPOSE 8620
HEALTHCHECK --interval=30s --timeout=10s --retries=3 CMD curl -f http://localhost:8620/health || exit 1
CMD ["python", "orchestrator.py"]
EOF

        # Worker Containerfile (simplified)
        cat > $RPA_HOME/containers/worker/Containerfile << 'EOF'
FROM registry.redhat.io/ubi9/python-311:latest

USER root
RUN dnf update -y && \
    dnf install -y chromium sqlite gcc python3-devel curl wget unzip && \
    dnf clean all

# Install ChromeDriver
RUN CHROME_DRIVER_VERSION=$(curl -sS https://chromedriver.storage.googleapis.com/LATEST_RELEASE 2>/dev/null || echo "119.0.6045.105") && \
    wget -O /tmp/chromedriver.zip "https://chromedriver.storage.googleapis.com/${CHROME_DRIVER_VERSION}/chromedriver_linux64.zip" && \
    unzip /tmp/chromedriver.zip -d /tmp/ && \
    mv /tmp/chromedriver /usr/local/bin/chromedriver && \
    chmod +x /usr/local/bin/chromedriver && \
    rm -f /tmp/chromedriver.zip

RUN useradd -m -u 1001 rpauser && mkdir -p /app && chown -R rpauser:rpauser /app

USER rpauser
WORKDIR /app

COPY requirements.txt ./
RUN pip install --user --no-cache-dir -r requirements.txt

COPY --chown=rpauser:rpauser . .
RUN mkdir -p data/logs data/screenshots data/evidence worker_data

ENV CHROMEDRIVER_PATH=/usr/local/bin/chromedriver
ENV HEADLESS=true

EXPOSE 8621
HEALTHCHECK --interval=30s --timeout=10s --retries=3 CMD curl -f http://localhost:8621/health || exit 1
CMD ["python", "worker.py"]
EOF
        
        success "Containerfiles created"
    }
    
    create_containerfiles
    create_native_podman_scripts
    create_systemd_service_native
    
    # Final setup
    chown -R $RPA_USER:$RPA_GROUP $RPA_HOME
    chmod -R 755 $RPA_HOME
    chmod 600 $RPA_HOME/.admin-password
    
    success "RPA System deployment completed successfully!"
    echo ""
    echo "================================================"
    echo "RHEL 10 DEPLOYMENT SUMMARY"
    echo "================================================"
    echo "Installation Directory: $RPA_HOME"
    echo "Admin Password: $(cat $RPA_HOME/.admin-password)"
    echo ""
    echo "Next Steps:"
    echo "1. Copy your RPA source code to $RPA_HOME/"
    echo "2. Start the system: systemctl start rpa-system"
    echo "3. Check status: $RPA_HOME/scripts/health-check-podman.sh"
    echo "================================================"
}

# Run main function
main_rhel10 "$@"
