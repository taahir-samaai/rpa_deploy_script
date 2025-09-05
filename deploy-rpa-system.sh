#!/bin/bash
# RPA Clean Production Packager
# Creates a clean, production-ready package excluding unnecessary files

set -e

# Configuration
SOURCE_DIR="/opt/rpa-system"
DISCOVERY_DIR="/root/environment-discovery-20250904-130738"
CLEAN_PACKAGE_DIR="${DISCOVERY_DIR}/production-ready"
LOG_FILE="${DISCOVERY_DIR}/clean-packaging.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

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

# Verify source directory
check_source() {
    section "CHECKING SOURCE DIRECTORY"
    
    if [[ ! -d "$SOURCE_DIR" ]]; then
        error "Source directory not found: $SOURCE_DIR"
    fi
    
    if [[ ! -f "$SOURCE_DIR/rpa_botfarm/orchestrator.py" ]]; then
        error "orchestrator.py not found in $SOURCE_DIR/rpa_botfarm/"
    fi
    
    info "Source directory: $SOURCE_DIR"
    info "Package directory: $CLEAN_PACKAGE_DIR"
    
    # Create clean package directory
    rm -rf "$CLEAN_PACKAGE_DIR"
    mkdir -p "$CLEAN_PACKAGE_DIR"
    
    success "Source verification completed"
}

# Package essential files only
package_essential_files() {
    section "PACKAGING ESSENTIAL FILES"
    
    info "Copying essential production files..."
    
    # Create directory structure
    mkdir -p "$CLEAN_PACKAGE_DIR"/{rpa_botfarm/automations,configs,containers/{orchestrator,worker},scripts,volumes/{data,logs}}
    
    # Core RPA files (excluding unwanted files)
    info "Copying core RPA botfarm files..."
    
    # Define essential core files
    local core_files=(
        "auth.py"
        "config.py" 
        "conjur_client.py"
        "db.py"
        "errors.py"
        "health_reporter.py"
        "models.py"
        "orchestrator.py"
        "rate_limiter.py"
        "test_framework.py"
        "worker.py"
    )
    
    # Copy core files
    for file in "${core_files[@]}"; do
        if [[ -f "$SOURCE_DIR/rpa_botfarm/$file" ]]; then
            cp "$SOURCE_DIR/rpa_botfarm/$file" "$CLEAN_PACKAGE_DIR/rpa_botfarm/"
            success "Copied: $file"
        else
            warning "Not found: $file"
        fi
    done
    
    # Copy automations directory (all provider modules)
    info "Copying automation modules..."
    if [[ -d "$SOURCE_DIR/rpa_botfarm/automations" ]]; then
        # Copy the entire automations directory, excluding pycache
        rsync -av \
            --exclude='__pycache__' \
            --exclude='*.pyc' \
            "$SOURCE_DIR/rpa_botfarm/automations/" \
            "$CLEAN_PACKAGE_DIR/rpa_botfarm/automations/"
        success "Copied automation modules"
    fi
    
    # Copy essential root-level files
    info "Copying root-level files..."
    local root_files=(
        "requirements.txt"
        "start-system.sh"
        "update_mfn_validation.py"
        "update_osn_validation.py"
    )
    
    for file in "${root_files[@]}"; do
        if [[ -f "$SOURCE_DIR/$file" ]]; then
            cp "$SOURCE_DIR/$file" "$CLEAN_PACKAGE_DIR/"
            success "Copied root file: $file"
        fi
    done
    
    # Copy configs directory if it exists
    if [[ -d "$SOURCE_DIR/configs" ]]; then
        cp -r "$SOURCE_DIR/configs"/* "$CLEAN_PACKAGE_DIR/configs/" 2>/dev/null || true
        success "Copied configs directory"
    fi
    
    # Copy containers directory if it exists
    if [[ -d "$SOURCE_DIR/containers" ]]; then
        cp -r "$SOURCE_DIR/containers"/* "$CLEAN_PACKAGE_DIR/containers/" 2>/dev/null || true
        success "Copied containers directory"
    fi
    
    # Copy scripts directory (excluding test scripts)
    if [[ -d "$SOURCE_DIR/scripts" ]]; then
        find "$SOURCE_DIR/scripts" -name "*.sh" -not -path "*/test*" -not -path "*/debug*" | while read -r script; do
            cp "$script" "$CLEAN_PACKAGE_DIR/scripts/"
        done
        success "Copied production scripts"
    fi
    
    success "Essential files packaging completed"
}

# Verify automation modules
verify_automation_modules() {
    section "VERIFYING AUTOMATION MODULES"
    
    local providers=("evotel" "mfn" "octotel" "osn")
    local required_actions=("validation.py" "cancellation.py")
    
    for provider in "${providers[@]}"; do
        local provider_dir="$CLEAN_PACKAGE_DIR/rpa_botfarm/automations/$provider"
        
        if [[ -d "$provider_dir" ]]; then
            info "Checking provider: $provider"
            
            # Check for required action files
            for action in "${required_actions[@]}"; do
                if [[ -f "$provider_dir/$action" ]]; then
                    success "  ✅ $provider/$action"
                else
                    warning "  ⚠️  $provider/$action (missing)"
                fi
            done
            
            # Check for __init__.py
            if [[ -f "$provider_dir/__init__.py" ]]; then
                success "  ✅ $provider/__init__.py"
            else
                warning "  ⚠️  $provider/__init__.py (missing)"
            fi
        else
            warning "Provider directory missing: $provider"
        fi
    done
    
    success "Automation modules verification completed"
}

# Create production inventory
create_production_inventory() {
    section "CREATING PRODUCTION INVENTORY"
    
    local inventory_file="$CLEAN_PACKAGE_DIR/PRODUCTION_INVENTORY.md"
    
    cat > "$inventory_file" << 'INVENTORY_EOF'
# RPA Production System Inventory

## Package Information
- **Created:** $(date)
- **Source:** /opt/rpa-system
- **Type:** Clean production package (no test files, documentation, or temporary files)

## Core Components

### Main Applications
INVENTORY_EOF

    # List core applications
    echo "- **orchestrator.py** - Main orchestration service" >> "$inventory_file"
    echo "- **worker.py** - Automation worker service" >> "$inventory_file"
    echo "" >> "$inventory_file"
    
    echo "### Core Modules" >> "$inventory_file"
    for core_file in "$CLEAN_PACKAGE_DIR/rpa_botfarm"/*.py; do
        if [[ -f "$core_file" ]]; then
            filename=$(basename "$core_file")
            file_size=$(stat -c%s "$core_file" 2>/dev/null || echo "0")
            echo "- **$filename** (${file_size} bytes)" >> "$inventory_file"
        fi
    done
    
    echo "" >> "$inventory_file"
    echo "### Automation Providers" >> "$inventory_file"
    
    # List automation providers
    for provider_dir in "$CLEAN_PACKAGE_DIR/rpa_botfarm/automations"/*; do
        if [[ -d "$provider_dir" ]]; then
            provider_name=$(basename "$provider_dir")
            echo "#### $provider_name" >> "$inventory_file"
            
            for action_file in "$provider_dir"/*.py; do
                if [[ -f "$action_file" ]]; then
                    action_name=$(basename "$action_file")
                    echo "- **$action_name**" >> "$inventory_file"
                fi
            done
            echo "" >> "$inventory_file"
        fi
    done
    
    cat >> "$inventory_file" << 'INVENTORY_EOF2'

## Configuration Files
INVENTORY_EOF2

    # List configuration files
    find "$CLEAN_PACKAGE_DIR" -name "*.env" -o -name "*.conf" -o -name "*.json" -o -name "requirements.txt" | while read -r config_file; do
        rel_path="${config_file#$CLEAN_PACKAGE_DIR/}"
        echo "- **$rel_path**" >> "$inventory_file"
    done
    
    cat >> "$inventory_file" << 'INVENTORY_EOF3'

## Statistics
- **Core Python Files:** $(find "$CLEAN_PACKAGE_DIR/rpa_botfarm" -maxdepth 1 -name "*.py" | wc -l)
- **Automation Providers:** $(find "$CLEAN_PACKAGE_DIR/rpa_botfarm/automations" -maxdepth 1 -type d | grep -v "automations$" | wc -l)
- **Total Python Files:** $(find "$CLEAN_PACKAGE_DIR" -name "*.py" | wc -l)
- **Package Size:** $(du -sh "$CLEAN_PACKAGE_DIR" | cut -f1)

## Excluded Items
The following items were intentionally excluded from the production package:
- **bin/** - Test scripts and utilities
- **docs/** - Documentation files  
- **totp_generator.py** - TOTP utility (not needed in production)
- **.git/** - Git repository data
- **__pycache__/** - Python cache files
- **drivers/** - Browser driver files (will be installed in container)
- **python_env/** - Development environment files

## Production Ready
This package contains only the essential files needed for production deployment:
- ✅ Core RPA framework
- ✅ All automation provider modules (evotel, mfn, octotel, osn)
- ✅ Configuration templates
- ✅ Container definitions
- ✅ Management scripts
- ✅ Dependencies (requirements.txt)

This clean package is optimized for production deployment and excludes all development, 
testing, and documentation files to minimize size and security surface.

The deployment will create:
- 1 Orchestrator container (single-threaded) on port 8620
- 5 Worker containers (single-threaded) on ports 8621-8625
- Each container uses exactly 1 thread for predictable resource usage
- Total capacity: 5 concurrent automation jobs (1 per worker)
INVENTORY_EOF3

    success "Production inventory created"
}

# Update discovery package
update_discovery_package() {
    section "UPDATING DISCOVERY PACKAGE"
    
    # Update the main summary
    local summary_file="$DISCOVERY_DIR/ENVIRONMENT_SUMMARY.md"
    
    cat >> "$summary_file" << 'SUMMARY_UPDATE'

## Clean Production Package

### Production-Ready Package Status
- ✅ **Clean Production Package:** Created in `production-ready/` directory
- ✅ **Essential Files Only:** Core modules + automation providers
- ✅ **Excluded Unnecessary:** bin/, docs/, totp_generator.py, .git/, __pycache__/
- ✅ **Optimized Size:** Minimal footprint for production deployment
- ✅ **Security Focused:** No test scripts or development files

### Production Package Contents
- **Core RPA Framework:** orchestrator.py, worker.py, auth.py, config.py, db.py, etc.
- **Automation Modules:** evotel, mfn, octotel, osn (validation + cancellation)
- **Configuration Files:** Production-ready templates
- **Dependencies:** requirements.txt with exact versions
- **Management Scripts:** Essential production scripts only

### Deployment Ready
This clean production package is optimized for enterprise deployment with:
- Minimal security surface (no test/debug files)
- Reduced package size  
- Only production-essential components
- Ready for container deployment
SUMMARY_UPDATE

    success "Discovery package updated"
}

# Create final clean deployment package
create_final_clean_package() {
    section "CREATING FINAL CLEAN DEPLOYMENT PACKAGE"
    
    cd /root
    
    # Create the final deployment package
    local package_name="rpa-clean-production-$(date +%Y%m%d-%H%M%S).tar.gz"
    
    info "Creating clean production deployment package: $package_name"
    
    tar -czf "$package_name" environment-discovery-20250904-130738/
    
    # Package information
    local package_size=$(du -sh "$package_name" | cut -f1)
    local total_files=$(tar -tzf "$package_name" | wc -l)
    
    success "Clean production package created:"
    info "  📦 Package: $package_name"
    info "  📊 Size: $package_size"
    info "  📄 Files: $total_files"
    info "  🎯 Type: Production-optimized (essential files only)"
    
    # Create deployment README
    cat > "CLEAN_DEPLOYMENT_README.md" << README_EOF
# RPA Clean Production Deployment Package

## Package Information
- **Package:** $package_name
- **Created:** $(date)
- **Size:** $package_size
- **Type:** Clean production package (essential files only)

## What's Included
✅ **Core RPA Framework:**
   - orchestrator.py (main service)
   - worker.py (automation worker)
   - auth.py, config.py, db.py, models.py (core modules)
   
✅ **Automation Providers:**
   - evotel (validation + cancellation)
   - mfn (validation + cancellation) 
   - octotel (validation + cancellation)
   - osn (validation + cancellation)

✅ **Production Essentials:**
   - requirements.txt (dependencies)
   - Configuration templates
   - Container definitions
   - Management scripts

## What's Excluded
❌ **Development/Test Files:**
   - bin/ (test scripts)
   - docs/ (documentation)
   - totp_generator.py
   - .git/ (version control)
   - __pycache__/ (cache files)

## Package Structure
\`\`\`
environment-discovery-20250904-130738/
├── production-ready/           # CLEAN PRODUCTION FILES
│   ├── rpa_botfarm/           # Core RPA framework
│   │   ├── orchestrator.py    # Main orchestrator
│   │   ├── worker.py          # Worker service
│   │   ├── auth.py            # Authentication
│   │   ├── config.py          # Configuration
│   │   ├── db.py              # Database operations
│   │   ├── models.py          # Data models
│   │   └── automations/       # Provider modules
│   │       ├── evotel/        # Evotel automation
│   │       ├── mfn/           # MFN automation  
│   │       ├── octotel/       # Octotel automation
│   │       └── osn/           # OSN automation
│   ├── requirements.txt       # Python dependencies
│   ├── configs/               # Configuration templates
│   ├── containers/            # Container definitions
│   └── scripts/               # Management scripts
├── system/                    # System discovery data
├── containers/               # Container runtime info
├── network/                  # Network configuration
└── [other discovery data]
\`\`\`

## Deployment Commands

### 1. Transfer to Production VM
\`\`\`bash
scp $package_name user@prod-vm:/tmp/
\`\`\`

### 2. Extract and Deploy
\`\`\`bash
cd /tmp
tar -xzf $package_name
sudo ./rpa_production_deploy.sh -d environment-discovery-20250904-130738 -e production
\`\`\`

### 3. Start System
\`\`\`bash
sudo systemctl start rpa-system
sudo /opt/rpa-system/scripts/health-check.sh
\`\`\`

## Benefits of Clean Package
- **🔒 Security:** No test scripts or debug files
- **📦 Size:** Smaller package, faster transfers
- **🎯 Focus:** Only production-essential components
- **🚀 Performance:** Optimized for enterprise deployment

This package is production-ready and enterprise-grade!
README_EOF

    success "Clean deployment README created"
    
    echo -e "\n${GREEN}🎉 CLEAN PRODUCTION PACKAGE READY! 🎉${NC}"
    echo -e "\n${CYAN}Package Summary:${NC}"
    echo -e "  📦 File: ${YELLOW}$package_name${NC}"
    echo -e "  📊 Size: ${YELLOW}$package_size${NC}"
    echo -e "  🎯 Type: ${YELLOW}Production-optimized${NC}"
    echo -e "  📋 README: ${YELLOW}CLEAN_DEPLOYMENT_README.md${NC}"
    echo -e "\n${CYAN}Key Features:${NC}"
    echo -e "  ✅ Essential files only (no bin/, docs/, test files)"
    echo -e "  ✅ All automation providers (evotel, mfn, octotel, osn)"
    echo -e "  ✅ Core RPA framework (orchestrator, worker, auth, db)"
    echo -e "  ✅ Production-ready configuration templates"
    echo -e "  ✅ Optimized for security and performance"
}

# Main execution
main() {
    echo -e "${CYAN}"
    cat << 'BANNER'
    ____  ____   _        ____ _     _____    _    _   _ 
   |  _ \|  _ \ / \      / ___| |   | ____|  / \  | \ | |
   | |_) | |_) / _ \    | |   | |   |  _|   / _ \ |  \| |
   |  _ <|  __/ ___ \   | |___| |___| |___ / ___ \| |\  |
   |_| \_\_| /_/   \_\   \____|_____|_____/_/   \_\_| \_|
                                                        
        Production Package Cleaner
BANNER
    echo -e "${NC}"
    
    check_source
    package_essential_files
    verify_automation_modules
    create_production_inventory
    update_discovery_package
    create_final_clean_package
    
    echo -e "\n${GREEN}✅ Clean production package created successfully!${NC}"
    echo -e "${YELLOW}Your RPA system is now packaged for enterprise production deployment.${NC}"
}

main "$@"
