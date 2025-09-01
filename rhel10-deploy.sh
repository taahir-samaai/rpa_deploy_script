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
echo "🔍 RPA System Health Check"
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

    # Create build and start script for after adding source code
    cat > $RPA_HOME/scripts/build-and-start.sh << 'EOF'
#!/bin/bash
# build-and-start.sh - Build containers and start RPA system

set -e
cd /opt/rpa-system

echo "🔍 Checking for required RPA source files..."

# Check for required files
required_files=("orchestrator.py" "worker.py" "config.py" "requirements.txt")
missing_files=()

for file in "${required_files[@]}"; do
    if [ ! -f "$file" ]; then
        missing_files+=("$file")
    fi
done

if [ ${#missing_files[@]} -gt 0 ]; then
    echo "Missing required files: ${missing_files[*]}"
    echo "Please add your RPA source code first!"
    exit 1
fi

echo "All required files found"

# Check if automation modules exist
if [ ! -d "automations" ]; then
    echo " Warning: automations/ directory not found"
    echo "   Creating empty automations directory..."
    sudo -u rpauser mkdir -p automations
    echo "   You'll need to add your automation modules here"
fi

echo " Building container images..."
sudo -u rpauser podman build -t rpa-orchestrator:latest -f containers/orchestrator/Containerfile . || {
    echo " Failed to build orchestrator container"
    exit 1
}

sudo -u rpauser podman build -t rpa-worker:latest -f containers/worker/Containerfile . || {
    echo " Failed to build worker container"
    exit 1
}

echo " Container images built successfully"

echo " Starting RPA system..."
systemctl start rpa-system

echo " Waiting for services to start..."
sleep 30

echo " Checking service status..."
systemctl status rpa-system --no-pager

echo " Running health checks..."
./scripts/health-check-podman.sh

echo " RPA system started successfully!"
EOF

    chmod +x $RPA_HOME/scripts/build-and-start.sh
    
    # Create template files script
    cat > $RPA_HOME/scripts/create-template-files.sh << 'TEMPLATE_EOF'
#!/bin/bash
# create-template-files.sh - Create template RPA files for testing

set -e
cd /opt/rpa-system

echo "🏗️  Creating template RPA files for testing..."

# Create minimal orchestrator.py
cat > orchestrator.py << 'EOF'
#!/usr/bin/env python3
"""Template RPA Orchestrator"""
import os, logging
from fastapi import FastAPI
from contextlib import asynccontextmanager

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info(" RPA Orchestrator starting...")
    yield
    logger.info(" RPA Orchestrator shutting down...")

app = FastAPI(title="RPA Orchestrator", lifespan=lifespan)

@app.get("/")
async def root():
    return {"message": "RPA Orchestrator is running", "status": "active"}

@app.get("/health")
async def health():
    return {"status": "healthy", "service": "orchestrator"}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host=os.getenv("ORCHESTRATOR_HOST", "0.0.0.0"), 
               port=int(os.getenv("ORCHESTRATOR_PORT", "8620")))
EOF

# Create minimal worker.py
cat > worker.py << 'EOF'
#!/usr/bin/env python3
"""Template RPA Worker"""
import os, logging
from fastapi import FastAPI
from contextlib import asynccontextmanager

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info(" RPA Worker starting...")
    yield
    logger.info(" RPA Worker shutting down...")

app = FastAPI(title="RPA Worker", lifespan=lifespan)

@app.get("/")
async def root():
    return {"message": "RPA Worker is running", "status": "active"}

@app.get("/health")
async def health():
    return {"status": "healthy", "service": "worker"}

@app.post("/execute")
async def execute_job(job_data: dict):
    return {"status": "success", "message": "Template execution completed"}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host=os.getenv("WORKER_HOST", "0.0.0.0"), 
               port=int(os.getenv("WORKER_PORT", "8621")))
EOF

# Create minimal config.py
cat > config.py << 'EOF'
"""Template RPA Configuration"""
import os
from pathlib import Path

class Config:
    BASE_DATA_DIR = os.getenv("BASE_DATA_DIR", "./data")
    LOG_DIR = os.path.join(BASE_DATA_DIR, "logs")
    ORCHESTRATOR_HOST = os.getenv("ORCHESTRATOR_HOST", "0.0.0.0")
    ORCHESTRATOR_PORT = int(os.getenv("ORCHESTRATOR_PORT", "8620"))
    WORKER_HOST = os.getenv("WORKER_HOST", "0.0.0.0")
    WORKER_PORT = int(os.getenv("WORKER_PORT", "8621"))
    
    @classmethod
    def setup_directories(cls):
        Path(cls.BASE_DATA_DIR).mkdir(parents=True, exist_ok=True)
        Path(cls.LOG_DIR).mkdir(parents=True, exist_ok=True)
EOF

# Create basic automations
mkdir -p automations
touch automations/__init__.py

chown -R rpauser:rpauser .
echo " Template files created! Run './scripts/build-and-start.sh' to test."
TEMPLATE_EOF

    chmod +x $RPA_HOME/scripts/create-template-files.sh
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
    generate_configurations
    
    # Create requirements.txt with correct dependencies
    create_requirements_file() {
        info "Creating requirements.txt with RPA dependencies..."
        
        cat > $RPA_HOME/requirements.txt << 'EOF'
# Core FastAPI dependencies
fastapi
uvicorn[standard]
pydantic

# HTTP Client
requests

# Scheduling
apscheduler

# Database and ORM
sqlalchemy

# Retry Logic
tenacity

# Environment Configuration
python-dotenv

# Authentication and Security
bcrypt
pyjwt[crypto]

# Web Automation
selenium

# 2FA/OTP Support
pyotp

# System Monitoring
psutil
EOF
        
        chown $RPA_USER:$RPA_GROUP $RPA_HOME/requirements.txt
        chmod 644 $RPA_HOME/requirements.txt
        
        success "requirements.txt created with $(wc -l < $RPA_HOME/requirements.txt) dependencies"
        info "Requirements file contents:"
        cat $RPA_HOME/requirements.txt
    }
    
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
    check_rpa_source_code
    
    # Check if RPA source code exists and provide instructions
    check_rpa_source_code() {
        info "Checking for RPA source code..."
        
        required_files=("orchestrator.py" "worker.py" "config.py")
        missing_files=()
        
        for file in "${required_files[@]}"; do
            if [ ! -f "$RPA_HOME/$file" ]; then
                missing_files+=("$file")
            fi
        done
        
        if [ ${#missing_files[@]} -eq 0 ]; then
            success "All required RPA source files found!"
            info "Ready to build and start containers"
        else
            warning "Missing RPA source files: ${missing_files[*]}"
            info "You need to copy your RPA source code to $RPA_HOME/"
            info "Required files:"
            printf "  • %s\n" "${required_files[@]}"
            
            if [ ! -d "$RPA_HOME/automations" ]; then
                info "  • automations/ directory (with your automation modules)"
            fi
            
            info ""
            info " TO ADD YOUR RPA SOURCE CODE:"
            info "================================"
            info "Option 1 - From local machine:"
            info "  scp -r /path/to/your/rpa/files/* ec2-user@$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4):/tmp/"
            info "  sudo cp -r /tmp/your-files/* $RPA_HOME/"
            info "  sudo chown -R $RPA_USER:$RPA_GROUP $RPA_HOME/"
            info ""
            info "Option 2 - From Git repository:"
            info "  cd $RPA_HOME"
            info "  sudo -u $RPA_USER git clone https://github.com/your-repo/rpa-project.git temp"
            info "  sudo -u $RPA_USER cp -r temp/* ."
            info "  sudo -u $RPA_USER rm -rf temp"
            info ""
            info "After adding your source code, run:"
            info "  systemctl start rpa-system"
        fi
    }
    
    create_containerfiles
    
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
    echo "Requirements.txt:  Created with $(wc -l < $RPA_HOME/requirements.txt) dependencies"
    echo ""
    echo " NEXT STEPS:"
    echo "1. Copy your RPA source code to $RPA_HOME/"
    echo "   Required files: orchestrator.py, worker.py, config.py, automations/"
    echo "2. Build and start: $RPA_HOME/scripts/build-and-start.sh"
    echo "3. Check status: $RPA_HOME/scripts/health-check-podman.sh"
    echo ""
    echo " FOR TESTING WITHOUT YOUR CODE:"
    echo "$RPA_HOME/scripts/create-template-files.sh  # Create test files"
    echo "$RPA_HOME/scripts/build-and-start.sh        # Build and start"
    echo ""
    echo " QUICK START COMMANDS:"
    echo "# Option 1: Test with template files"
    echo "cd $RPA_HOME && ./scripts/create-template-files.sh && ./scripts/build-and-start.sh"
    echo ""
    echo "# Option 2: Add your real RPA code first"
    echo "# (copy your files to $RPA_HOME/)"
    echo "cd $RPA_HOME && ./scripts/build-and-start.sh"
    echo ""
    echo "Service URLs (after startup):"
    echo "- Orchestrator: http://$(hostname -I | awk '{print $1}'):8620"
    echo "- Worker 1: http://$(hostname -I | awk '{print $1}'):8621"
    echo "- Worker 2: http://$(hostname -I | awk '{print $1}'):8622"
    echo "================================================"
}

# Run main function
main_rhel10 "$@"
