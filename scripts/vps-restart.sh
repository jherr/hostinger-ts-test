#!/bin/bash

# VPS Restart/Deploy Script for Node.js Apps
# Pulls latest changes, rebuilds, and restarts with PM2
# Works with any Node.js app that has a package.json

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Functions for colored output
print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1"; }
print_info() { echo -e "${YELLOW}➜${NC} $1"; }
print_step() { echo -e "${BLUE}[$1]${NC} $2"; }

# Check for package.json in current directory
if [ ! -f "package.json" ]; then
    print_error "No package.json found in current directory"
    print_info "Please run this script from your Node.js project root"
    exit 1
fi

# Extract app name from package.json
APP_NAME=$(grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' package.json | sed 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')

if [ -z "$APP_NAME" ]; then
    print_error "Could not extract app name from package.json"
    exit 1
fi

# Function to check if PM2 is installed
check_pm2() {
    if ! command -v pm2 &> /dev/null; then
        print_error "PM2 is not installed"
        print_info "Install it with: npm install -g pm2"
        exit 1
    fi
}

# Function to check if git repo exists
check_git() {
    if [ ! -d ".git" ]; then
        print_error "This is not a git repository"
        print_info "Initialize git or clone your repository first"
        exit 1
    fi
}

# Function to stash any local changes
stash_changes() {
    if ! git diff --quiet || ! git diff --cached --quiet; then
        print_info "Stashing local changes..."
        git stash push -m "Auto-stash before deployment $(date +%Y%m%d_%H%M%S)"
        print_success "Local changes stashed"
        return 0
    fi
    return 1
}

# Function to pull latest changes
pull_latest() {
    print_step "1/5" "Pulling latest changes from origin/main..."
    
    # Fetch latest changes
    git fetch origin
    
    # Check if main branch exists, fallback to master if not
    if git show-ref --verify --quiet refs/remotes/origin/main; then
        BRANCH="main"
    elif git show-ref --verify --quiet refs/remotes/origin/master; then
        BRANCH="master"
        print_info "No 'main' branch found, using 'master'"
    else
        print_error "Neither 'main' nor 'master' branch found on origin"
        exit 1
    fi
    
    # Pull the changes
    git pull origin $BRANCH
    print_success "Pulled latest changes from origin/$BRANCH"
}

# Function to install dependencies
install_dependencies() {
    print_step "2/5" "Installing dependencies..."
    
    # Check if package-lock.json exists for faster ci install
    if [ -f "package-lock.json" ]; then
        npm ci --production=false
    else
        npm install
    fi
    
    print_success "Dependencies installed"
}

# Function to build the app
build_app() {
    print_step "3/5" "Building application..."
    
    # Check if build script exists in package.json
    if grep -q '"build"' package.json; then
        npm run build
        print_success "Build completed"
    else
        print_info "No build script found, skipping build step"
    fi
}

# Function to restart with PM2
restart_pm2() {
    print_step "4/5" "Restarting application with PM2..."
    
    # Check if app is already running in PM2
    if pm2 list | grep -q "$APP_NAME"; then
        # App exists, restart it
        pm2 restart "$APP_NAME"
        print_success "Application restarted: $APP_NAME"
    else
        # App doesn't exist, start it
        print_info "Application not found in PM2, starting new instance..."
        
        # Check for start script
        if grep -q '"start"' package.json; then
            pm2 start npm --name "$APP_NAME" -- start
            print_success "Application started: $APP_NAME"
        else
            print_error "No 'start' script found in package.json"
            print_info "Add a start script to your package.json"
            exit 1
        fi
    fi
    
    # Save PM2 configuration
    pm2 save
}

# Function to show status
show_status() {
    print_step "5/5" "Deployment complete!"
    echo ""
    
    # Show PM2 status for this app
    pm2 show "$APP_NAME" | grep -E "status|uptime|restarts|CPU|memory" || true
    
    echo ""
    print_info "Useful commands:"
    echo "  • View logs:    pm2 logs $APP_NAME"
    echo "  • Monitor:      pm2 monit"
    echo "  • Stop app:     pm2 stop $APP_NAME"
    echo "  • Start app:    pm2 start $APP_NAME"
    echo "  • App info:     pm2 show $APP_NAME"
}

# Function to handle errors
on_error() {
    print_error "Deployment failed!"
    
    # Check if we stashed changes
    if [ "$STASHED" = true ]; then
        print_info "Restoring stashed changes..."
        git stash pop
    fi
    
    # Show PM2 logs for debugging
    print_info "Recent PM2 logs:"
    pm2 logs "$APP_NAME" --lines 20 --nostream || true
    
    exit 1
}

# Set up error handling
trap on_error ERR
STASHED=false

# Main execution
main() {
    echo "======================================"
    echo "   Deploying: $APP_NAME"
    echo "======================================"
    echo ""
    
    # Pre-flight checks
    check_git
    check_pm2
    
    # Store if we stashed changes
    if stash_changes; then
        STASHED=true
    fi
    
    # Deployment steps
    pull_latest
    install_dependencies
    build_app
    restart_pm2
    show_status
    
    # Restore stashed changes if any
    if [ "$STASHED" = true ]; then
        print_info "Restoring stashed changes..."
        git stash pop
        print_success "Stashed changes restored"
    fi
    
    echo ""
    print_success "Deployment successful! 🚀"
}

# Support for command line arguments
case "${1:-}" in
    --help|-h)
        echo "Usage: $0 [options]"
        echo ""
        echo "Options:"
        echo "  --help, -h     Show this help message"
        echo "  --logs, -l     Show logs after deployment"
        echo "  --force, -f    Force restart even if app isn't running"
        echo ""
        echo "This script will:"
        echo "  1. Pull latest changes from git"
        echo "  2. Install/update dependencies"
        echo "  3. Build the application"
        echo "  4. Restart with PM2"
        echo ""
        exit 0
        ;;
    --logs|-l)
        main
        echo ""
        print_info "Streaming logs (Ctrl+C to exit)..."
        pm2 logs "$APP_NAME"
        ;;
    --force|-f)
        # Force restart by deleting PM2 process first
        pm2 delete "$APP_NAME" 2>/dev/null || true
        main
        ;;
    *)
        main
        ;;
esac