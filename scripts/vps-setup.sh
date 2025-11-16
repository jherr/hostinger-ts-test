#!/bin/bash

# Universal VPS Setup Script for TanStack Start / Node.js Apps
# Works on: Ubuntu, Debian, Fedora, RHEL, CentOS Stream, Rocky Linux, AlmaLinux
# Sets up: Node.js 20, build-essentials, PM2, Nginx

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Functions for colored output
print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1"; }
print_info() { echo -e "${YELLOW}➜${NC} $1"; }

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   print_error "This script must be run as root (use sudo)"
   exit 1
fi

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

print_success "Found app: $APP_NAME"

# Detect Linux distribution
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    OS_FAMILY=$ID_LIKE
    VERSION=$VERSION_ID
else
    print_error "Cannot detect OS. /etc/os-release not found"
    exit 1
fi

print_info "Detected OS: $OS (family: $OS_FAMILY)"

# Function to install packages based on distro
install_packages() {
    case "$OS" in
        ubuntu|debian)
            print_info "Using APT package manager"
            apt-get update
            apt-get install -y curl wget git build-essential nginx
            ;;
        
        fedora)
            print_info "Using DNF package manager"
            dnf install -y curl wget git gcc-c++ make nginx
            ;;
        
        rhel|centos|rocky|almalinux)
            print_info "Using YUM/DNF package manager"
            if command -v dnf &> /dev/null; then
                dnf install -y curl wget git gcc-c++ make nginx
            else
                yum install -y curl wget git gcc-c++ make nginx
            fi
            ;;
        
        *)
            # Try to detect based on package manager availability
            if command -v apt-get &> /dev/null; then
                print_info "Using APT package manager (detected)"
                apt-get update
                apt-get install -y curl wget git build-essential nginx
            elif command -v dnf &> /dev/null; then
                print_info "Using DNF package manager (detected)"
                dnf install -y curl wget git gcc-c++ make nginx
            elif command -v yum &> /dev/null; then
                print_info "Using YUM package manager (detected)"
                yum install -y curl wget git gcc-c++ make nginx
            else
                print_error "Unsupported distribution: $OS"
                exit 1
            fi
            ;;
    esac
}

# Install Node.js 24 using NodeSource repository
install_nodejs() {
    print_info "Installing Node.js 24..."
    
    # Remove any existing Node.js installations
    if command -v node &> /dev/null; then
        print_info "Removing existing Node.js installation..."
        case "$OS" in
            ubuntu|debian)
                apt-get remove -y nodejs npm
                ;;
            fedora|rhel|centos|rocky|almalinux)
                if command -v dnf &> /dev/null; then
                    dnf remove -y nodejs npm
                else
                    yum remove -y nodejs npm
                fi
                ;;
        esac
    fi
    
    # Install Node.js based on distro
    case "$OS" in
        ubuntu|debian)
            curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
            apt-get install -y nodejs
            ;;
        
        fedora)
            curl -fsSL https://rpm.nodesource.com/setup_24.x | bash -
            dnf install -y nodejs
            ;;
        
        rhel|centos|rocky|almalinux)
            curl -fsSL https://rpm.nodesource.com/setup_24.x | bash -
            if command -v dnf &> /dev/null; then
                dnf install -y nodejs
            else
                yum install -y nodejs
            fi
            ;;
        
        *)
            print_error "Cannot install Node.js for distribution: $OS"
            exit 1
            ;;
    esac
    
    print_success "Node.js $(node --version) installed"
    print_success "npm $(npm --version) installed"
}

# Install PM2 globally
install_pm2() {
    print_info "Installing PM2..."
    npm install -g pm2
    print_success "PM2 installed"
}

# Configure Nginx
configure_nginx() {
    print_info "Configuring Nginx for $APP_NAME..."
    
    # Nginx config paths vary by distro
    case "$OS" in
        ubuntu|debian)
            NGINX_SITES_AVAILABLE="/etc/nginx/sites-available"
            NGINX_SITES_ENABLED="/etc/nginx/sites-enabled"
            DEFAULT_SITE="default"
            ;;
        
        fedora|rhel|centos|rocky|almalinux)
            NGINX_SITES_AVAILABLE="/etc/nginx/conf.d"
            NGINX_SITES_ENABLED="/etc/nginx/conf.d"
            DEFAULT_SITE="default.conf"
            ;;
    esac
    
    # Create sites directories if they don't exist (for RHEL-based systems)
    if [ "$OS" = "fedora" ] || [[ "$OS" =~ ^(rhel|centos|rocky|almalinux)$ ]]; then
        # RHEL-based systems use conf.d directory
        CONFIG_FILE="$NGINX_SITES_AVAILABLE/$APP_NAME.conf"
    else
        # Debian-based systems use sites-available/enabled
        mkdir -p $NGINX_SITES_AVAILABLE $NGINX_SITES_ENABLED
        CONFIG_FILE="$NGINX_SITES_AVAILABLE/$APP_NAME"
    fi
    
    # Get server IP for reference
    SERVER_IP=$(hostname -I | awk '{print $1}')
    
    # Create Nginx configuration
    cat > "$CONFIG_FILE" << EOL
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    
    # Server name - add your domain here later
    # For now, accepts any domain/IP
    server_name _;
    
    # App: $APP_NAME
    # Server IP: $SERVER_IP
    # To add domain: server_name example.com www.example.com;
    
    location / {
        proxy_pass http://localhost:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    
    # Optional: Increase upload size limit
    client_max_body_size 20M;
}
EOL
    
    # Remove default site and enable new config
    if [ "$OS" = "ubuntu" ] || [ "$OS" = "debian" ]; then
        # Remove default site
        rm -f $NGINX_SITES_ENABLED/$DEFAULT_SITE
        
        # Create symlink for new site
        ln -sf $NGINX_SITES_AVAILABLE/$APP_NAME $NGINX_SITES_ENABLED/$APP_NAME
    else
        # RHEL-based: remove default conf if exists
        rm -f $NGINX_SITES_AVAILABLE/default.conf
        rm -f $NGINX_SITES_AVAILABLE/nginx.conf.default
    fi
    
    # Test Nginx configuration
    nginx -t
    
    # Enable and start Nginx
    systemctl enable nginx
    systemctl restart nginx
    
    print_success "Nginx configured for $APP_NAME"
}

# Setup firewall rules
setup_firewall() {
    print_info "Configuring firewall..."
    
    case "$OS" in
        ubuntu|debian)
            if command -v ufw &> /dev/null; then
                ufw allow 22/tcp
                ufw allow 80/tcp
                ufw allow 443/tcp
                print_success "UFW firewall configured"
            fi
            ;;
        
        fedora|rhel|centos|rocky|almalinux)
            if command -v firewall-cmd &> /dev/null; then
                firewall-cmd --permanent --add-service=http
                firewall-cmd --permanent --add-service=https
                firewall-cmd --permanent --add-service=ssh
                firewall-cmd --reload
                print_success "Firewalld configured"
            fi
            ;;
    esac
}

# Setup PM2 startup script
setup_pm2_startup() {
    print_info "Setting up PM2 startup script..."
    
    # Generate startup script
    pm2 startup systemd -u $(logname) --hp /home/$(logname)
    
    print_success "PM2 startup configured"
}

# Install app dependencies
install_app_dependencies() {
    print_info "Installing app dependencies..."
    
    # Run as the non-root user if we're root
    if [ "$EUID" -eq 0 ] && [ -n "$(logname)" ]; then
        sudo -u $(logname) npm ci --omit=dev || sudo -u $(logname) npm install
    else
        npm ci --omit=dev || npm install
    fi
    
    print_success "App dependencies installed"
}

# Main execution
main() {
    echo "======================================"
    echo "   VPS Setup Script for $APP_NAME"
    echo "======================================"
    echo ""
    
    print_info "Step 1/7: Installing system packages..."
    install_packages
    
    print_info "Step 2/7: Installing Node.js..."
    install_nodejs
    
    print_info "Step 3/7: Installing PM2..."
    install_pm2
    
    print_info "Step 4/7: Configuring Nginx..."
    configure_nginx
    
    print_info "Step 5/7: Setting up firewall..."
    setup_firewall
    
    print_info "Step 6/7: Configuring PM2 startup..."
    setup_pm2_startup
    
    print_info "Step 7/7: Installing app dependencies..."
    install_app_dependencies
    
    echo ""
    echo "======================================"
    print_success "Setup completed successfully!"
    echo "======================================"
    echo ""
    print_info "Next steps:"
    echo "  1. Build your app: npm run build"
    echo "  2. Start with PM2: pm2 start npm --name \"$APP_NAME\" -- start"
    echo "  3. Save PM2 config: pm2 save"
    echo "  4. Your app will be available at: http://$SERVER_IP"
    echo ""
    print_info "To add a domain:"
    echo "  1. Point your domain's A record to: $SERVER_IP"
    echo "  2. Edit: $CONFIG_FILE"
    echo "  3. Change 'server_name _' to 'server_name yourdomain.com'"
    echo "  4. Restart Nginx: systemctl restart nginx"
    echo ""
    print_info "To enable HTTPS with Let's Encrypt:"
    echo "  1. Install certbot:"
    case "$OS" in
        ubuntu|debian)
            echo "     apt install certbot python3-certbot-nginx"
            ;;
        fedora|rhel|centos|rocky|almalinux)
            echo "     dnf install certbot python3-certbot-nginx"
            ;;
    esac
    echo "  2. Run: certbot --nginx -d yourdomain.com"
    echo ""
}

# Run main function
main