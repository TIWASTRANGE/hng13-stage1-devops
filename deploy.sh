#!/bin/bash

# ==============================================================================
# AWS EC2 Docker Deployment Script (deploy.sh)
# Objective: Automates the setup and deployment of a Dockerized application
# on a remote Linux server (e.g., AWS EC2) using SSH and scp.
# ==============================================================================

# --- Configuration & Global Variables ---
LOG_FILE="deploy_$(date +%Y%m%d_%H%M%S).log"
REMOTE_PATH="/opt/app_deploy"
APP_NAME="" # Will be set to the folder name of the cloned repo

# Terminal Colors for Logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- Core Helper Functions ---

# Log messages with timestamps and color-coding
log_action() {
    local type="$1"
    local message="$2"
    local color=""

    case "$type" in
        INFO) color="$BLUE";;
        SUCCESS) color="$GREEN";;
        WARN) color="$YELLOW";;
        ERROR) color="$RED";;
        *) color="$NC";;
    esac

    echo -e "$(date +%H:%M:%S) ${color}[$type]${NC} $message" | tee -a "$LOG_FILE"
}

# Exit script and log error
die() {
    log_action ERROR "FATAL ERROR: $1"
    log_action INFO "Deployment failed. Check '$LOG_FILE' for details."
    exit 1
}

# --- Cleanup and Idempotency Functions ---

# Function to safely clean up the local repository clone on exit/failure
cleanup_local_repo() {
    log_action INFO "Starting local cleanup operations..."
    if [ -n "$LOCAL_PROJECT_PATH" ] && [ -d "$LOCAL_PROJECT_PATH" ]; then
        log_action INFO "Removing temporary local project directory: $LOCAL_PROJECT_PATH"
        rm -rf "$LOCAL_PROJECT_PATH"
    fi
    log_action INFO "Local cleanup complete."
}

# Trap unexpected exits (non-zero exit status) and keyboard interrupts (Ctrl+C)
trap 'die "An unexpected error occurred in stage $?."' ERR
trap 'die "Script interrupted by user (Ctrl+C)." ; cleanup_local_repo' INT
set -o pipefail # Fail pipe chains if any part fails

# --- Parameter Collection and Validation ---

collect_parameters() {
    log_action INFO "Starting parameter collection..."
    
    # 1. Git Repository URL
    while true; do
        read -r -p "Enter Git Repository URL (e.g., https://github.com/user/repo.git): " GIT_REPO_URL
        if [[ "$GIT_REPO_URL" =~ ^(http|https)://.*\.git$ ]]; then
            # Extract app name from URL (e.g., repo.git -> repo)
            APP_NAME=$(basename "$GIT_REPO_URL" .git)
            LOCAL_PROJECT_PATH="$APP_NAME"
            break
        else
            log_action WARN "Invalid Git URL format. Must start with http(s) and end with .git."
        fi
    done

    # 2. Personal Access Token (PAT)
    log_action INFO "The Personal Access Token (PAT) will not be visible when typed."
    read -r -s -p "Enter Git Personal Access Token (PAT): " PAT
    echo # Newline after silent read
    if [ -z "$PAT" ]; then
        log_action WARN "PAT is empty. Deployment may fail if the repository is private."
    fi

    # 3. Branch Name
    read -r -p "Enter Git branch name (default: main): " GIT_BRANCH
    GIT_BRANCH=${GIT_BRANCH:-main}

    # 4. Remote Server SSH Details
    read -r -p "Enter Remote SSH Username (e.g., ec2-user): " REMOTE_USER
    read -r -p "Enter Server IP Address: " REMOTE_IP
    
    while true; do
        read -r -p "Enter Local SSH Key Path (e.g., ~/.ssh/id_rsa): " SSH_KEY_PATH
        if [ -f "$SSH_KEY_PATH" ]; then
            # Set minimum required permissions for SSH key
            chmod 600 "$SSH_KEY_PATH"
            break
        else
            log_action WARN "SSH Key not found at '$SSH_KEY_PATH'. Please provide a valid path."
        fi
    done

    # 5. Application Port
    while true; do
        read -r -p "Enter Container Internal Port (e.g., 3000, 8080): " APP_PORT
        if [[ "$APP_PORT" =~ ^[0-9]+$ ]] && [ "$APP_PORT" -gt 0 ] && [ "$APP_PORT" -lt 65536 ]; then
            break
        else
            log_action WARN "Invalid port number. Must be between 1 and 65535."
        fi
    done
    
    # Check for local scp utility
    if ! command -v scp &> /dev/null; then
        die "SCP utility is required for file transfer but was not found locally. Please install it (e.g., 'sudo apt install openssh-client')."
    fi
    
    log_action SUCCESS "All parameters collected."
}

# --- Local Git Operations ---

clone_or_pull_repo() {
    log_action INFO "Starting Git operations for branch '$GIT_BRANCH'..."
    
    # Use PAT for cloning private repos
    AUTH_GIT_REPO_URL=$(echo "$GIT_REPO_URL" | sed "s|://|://$PAT@|")

    if [ -d "$LOCAL_PROJECT_PATH" ]; then
        log_action INFO "Local directory exists. Updating changes..."
        
        if cd "$LOCAL_PROJECT_PATH"; then
            git fetch --all --tags --force > /dev/null 2>&1
            if git checkout "$GIT_BRANCH" && git pull origin "$GIT_BRANCH" --ff-only; then
                log_action SUCCESS "Successfully pulled latest changes on branch '$GIT_BRANCH'."
            else
                die "Failed to checkout or pull branch '$GIT_BRANCH'."
            fi
        else
            die "Failed to change directory into '$LOCAL_PROJECT_PATH'."
        fi
    else
        log_action INFO "Cloning repository into '$LOCAL_PROJECT_PATH'..."
        if git clone --branch "$GIT_BRANCH" "$AUTH_GIT_REPO_URL" "$LOCAL_PROJECT_PATH"; then
            log_action SUCCESS "Successfully cloned repository on branch '$GIT_BRANCH'."
            if ! cd "$LOCAL_PROJECT_PATH"; then
                die "Failed to change directory into '$LOCAL_PROJECT_PATH' after cloning."
            fi
        else
            die "Failed to clone repository. Check URL, PAT, and branch name."
        fi
    fi

    # Check for required Docker files
    if [ -f "docker-compose.yml" ]; then
        log_action SUCCESS "Found required file: docker-compose.yml."
    elif [ -f "Dockerfile" ]; then
        log_action WARN "Found Dockerfile, but not docker-compose.yml. Deploying with simple docker run."
        log_action WARN "This script is optimized for docker-compose.yml, deployment might fail."
    else
        die "No Dockerfile or docker-compose.yml found in the repository root."
    fi
    
    # Return to the original directory before file transfer
    cd - > /dev/null || die "Could not return to original directory."
}

# --- Remote Environment Setup & Deployment ---

# Function to execute commands on the remote server
remote_ssh_exec() {
    local command="$1"
    log_action INFO "Executing remote command on $REMOTE_IP: $command"
    
    ssh -T -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "$REMOTE_USER@$REMOTE_IP" "
        set -e
        $command
    " 2>&1 | tee -a "$LOG_FILE" || die "Remote command execution failed: $command"
}

prepare_remote_environment() {
    log_action INFO "Checking SSH connectivity to $REMOTE_IP..."
    ssh -i "$SSH_KEY_PATH" -o BatchMode=yes -o ConnectTimeout=5 "$REMOTE_USER@$REMOTE_IP" 'echo "Connection successful"' || die "SSH connection test failed. Check key, IP, and user."

    log_action INFO "Starting remote environment preparation (installing Docker, Docker Compose, Nginx, openssh-client, rsync)..."
    
    local setup_commands="
        # 1. Update and Install Dependencies (Idempotent)
        sudo apt update -y; sudo apt install -y ca-certificates curl gnupg lsb-release nginx docker-compose openssh-client rsync || (
            # Fallback for systems that use yum (e.g., CentOS/RHEL/Amazon Linux)
            sudo yum update -y
            sudo yum install -y docker docker-compose nginx openssh-client rsync
        )

        # 2. Configure Docker
        if ! command -v docker > /dev/null; then
            echo 'Docker not found after installation attempts.'
            exit 1
        fi
        
        # Add current user to docker group (if not already)
        sudo usermod -aG docker \$USER
        
        # Enable and start services (Idempotent)
        sudo systemctl enable docker || true
        sudo systemctl start docker || true
        sudo systemctl enable nginx || true
        sudo systemctl start nginx || true

        # 3. Confirm installation versions (for logging)
        echo 'Docker Version: \$(sudo docker --version)'
        echo 'Docker Compose Version: \$(sudo docker-compose --version || echo 'Not found')'
        echo 'Nginx Version: \$(nginx -v 2>&1)'

        # 4. Create remote project directory
        sudo mkdir -p $REMOTE_PATH
    "
    remote_ssh_exec "$setup_commands"
    log_action SUCCESS "Remote environment prepared. Docker, Docker Compose, Nginx, rsync, and openssh-client are installed."
}

transfer_and_deploy_application() {
    log_action INFO "Starting remote cleanup and file transfer via SCP..."
    
    # Define temp path in user's home directory for reliable file transfer
    local REMOTE_TEMP_PATH="/home/$REMOTE_USER/deploy_temp"
    
    log_action INFO "Ensuring remote temporary directory $REMOTE_TEMP_PATH exists and is clean."
    ssh -T -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "$REMOTE_USER@$REMOTE_IP" "mkdir -p $REMOTE_TEMP_PATH && rm -rf $REMOTE_TEMP_PATH/*" || die "Failed to prepare remote temporary directory."

    # 1. Transfer files to the user's home directory (safe intermediate location)
    log_action INFO "Step 1/2: Transferring project files to temporary home directory on $REMOTE_IP."
    if scp -r -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "$LOCAL_PROJECT_PATH" "$REMOTE_USER@$REMOTE_IP:$REMOTE_TEMP_PATH"; then
        log_action SUCCESS "Project files successfully transferred to $REMOTE_TEMP_PATH."
    else
        die "SCP failed during file transfer to temporary location. Check local permissions or network."
    fi

    # 2. Remote Deployment Commands
    log_action INFO "Step 2/2: Starting remote deployment and file migration..."
    
    local deploy_commands="
        # Define source and destination paths
        LOCAL_SRC_PATH=\"$REMOTE_TEMP_PATH/$APP_NAME\"
        FINAL_DEST_PATH=\"$REMOTE_PATH/$APP_NAME\"
        
        # 2.1. Clean up and replace the final destination path
        echo 'Pre-deployment cleanup: Removing existing project directory in $REMOTE_PATH...'
        sudo rm -rf \$FINAL_DEST_PATH
        
        # 2.2. Move the temporary files to the final destination using sudo
        echo 'Migrating files from home directory to \$FINAL_DEST_PATH...'
        sudo mv \$LOCAL_SRC_PATH \$FINAL_DEST_PATH

        # 2.3. Clean up the temporary directory in the user's home
        rm -rf $REMOTE_TEMP_PATH || true
        
        # 2.4. Navigate to the deployment directory
        cd \$FINAL_DEST_PATH
        
        # Ensure cleanup before redeploying (Idempotency)
        echo 'Stopping and removing old containers...'
        if sudo docker-compose down > /dev/null 2>&1; then 
            echo 'Old containers gracefully stopped and removed.'
        else
            echo 'No old containers found to stop/remove, proceeding with build.'
        fi

        # Build and run containers in detached mode
        echo 'Building and starting new containers...'
        sudo docker-compose up -d --build --remove-orphans

        # Wait for container to start
        echo 'Waiting for container to initialize...'
        sleep 5

        # Validate container health
        CONTAINER_ID=\$(sudo docker ps -qf \"name=$APP_NAME\" | head -n1)
        if [ -n \"\$CONTAINER_ID\" ] && sudo docker ps | grep \"\$CONTAINER_ID\" | grep -q 'Up'; then
            echo 'Container health check passed: container is Up.'
            echo 'Container ID: '\$CONTAINER_ID
            sudo docker logs --tail 10 \"\$CONTAINER_ID\" || true
        else
            echo 'Container health check failed. Deployment failed.'
            sudo docker ps -a
            exit 1
        fi
    "
    remote_ssh_exec "$deploy_commands"
    log_action SUCCESS "Dockerized application successfully built and deployed."
}

configure_nginx_proxy() {
    log_action INFO "Configuring Nginx reverse proxy (Port 80 -> Container Port $APP_PORT)..."
    
    # FIXED: Use here-doc with single quotes to prevent shell variable expansion
    local nginx_commands="
        NGINX_CONF_PATH='/etc/nginx/sites-available/$APP_NAME.conf'
        NGINX_LINK_PATH='/etc/nginx/sites-enabled/$APP_NAME.conf'
        
        # Write config file to the remote server using here-doc
        sudo tee \$NGINX_CONF_PATH > /dev/null << 'EOF'
server {
    listen 80;
    listen [::]:80;
    server_name _;

    location / {
        # Reverse proxy to the container
        proxy_pass http://localhost:$APP_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        
        # Optional: Security headers for production
        add_header X-Frame-Options \"DENY\";
        add_header X-Content-Type-Options \"nosniff\";
        add_header X-XSS-Protection \"1; mode=block\";
    }
}
EOF
        
        # Create symbolic link to enable the site (Idempotency)
        if [ ! -L \$NGINX_LINK_PATH ]; then
            sudo ln -s \$NGINX_CONF_PATH \$NGINX_LINK_PATH
        fi
        
        # Remove default config to prevent conflicts
        if [ -L /etc/nginx/sites-enabled/default ]; then
            sudo rm /etc/nginx/sites-enabled/default || true
        fi
        
        # Test configuration syntax and reload Nginx
        sudo nginx -t && sudo systemctl reload nginx
    "
    remote_ssh_exec "$nginx_commands"
    log_action SUCCESS "Nginx reverse proxy configured and reloaded."
}

validate_full_deployment() {
    log_action INFO "Final deployment validation..."
    
    # 1. Remote container and application check with retry logic
    local remote_validation="
        # Check if container is running
        CONTAINER_ID=\$(sudo docker ps -qf \"name=$APP_NAME\" | head -n1)
        if [ -z \"\$CONTAINER_ID\" ]; then
            echo 'Container is not running.'
            exit 1
        fi
        echo 'Container ID: '\$CONTAINER_ID
        
        # Wait for application to be fully ready
        echo 'Waiting for application to be fully ready...'
        sleep 10
        
        # Test with retry logic (max 10 attempts, 3 seconds each)
        MAX_ATTEMPTS=10
        ATTEMPT=0
        
        while [ \$ATTEMPT -lt \$MAX_ATTEMPTS ]; do
            HTTP_CODE=\$(curl -s -o /dev/null -w '%{http_code}' http://localhost:$APP_PORT 2>&1)
            
            if [ \"\$HTTP_CODE\" = \"200\" ] || [ \"\$HTTP_CODE\" = \"301\" ] || [ \"\$HTTP_CODE\" = \"302\" ]; then
                echo \"Internal application check passed (HTTP \$HTTP_CODE)\"
                break
            fi
            
            ATTEMPT=\$((ATTEMPT + 1))
            if [ \$ATTEMPT -lt \$MAX_ATTEMPTS ]; then
                echo \"Attempt \$ATTEMPT/\$MAX_ATTEMPTS: Status \$HTTP_CODE, retrying...\"
                sleep 3
            else
                echo \"Application failed to respond correctly after \$MAX_ATTEMPTS attempts (Status: \$HTTP_CODE)\"
                sudo docker logs --tail 30 \$CONTAINER_ID
                exit 1
            fi
        done
        
        # Test Nginx proxy
        HTTP_CODE=\$(curl -s -o /dev/null -w '%{http_code}' http://localhost 2>&1)
        if [ \"\$HTTP_CODE\" = \"200\" ] || [ \"\$HTTP_CODE\" = \"301\" ] || [ \"\$HTTP_CODE\" = \"302\" ]; then
            echo \"Internal Nginx proxy check passed (HTTP \$HTTP_CODE)\"
        else
            echo \"Nginx proxy check failed (HTTP \$HTTP_CODE)\"
            exit 1
        fi
    "
    remote_ssh_exec "$remote_validation"

    # 2. External accessibility check (from local machine)
    log_action INFO "Testing external accessibility (curl http://$REMOTE_IP)..."
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://$REMOTE_IP" 2>&1)
    
    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "301" ] || [ "$HTTP_CODE" = "302" ]; then
        log_action SUCCESS "External accessibility test successful! Application is live at http://$REMOTE_IP (HTTP $HTTP_CODE)."
    else
        log_action ERROR "External accessibility test failed (HTTP $HTTP_CODE). Check firewall/security groups (Port 80)."
    fi
}

# --- Main Execution Flow ---

main() {
    log_action INFO "Starting robust Docker deployment script..."
    
    # If a cleanup flag is passed, only run the cleanup command
    if [ "$1" == "--cleanup" ]; then
        log_action WARN "Running CLEANUP MODE. All deployment resources will be removed."
        
        # We still need parameters for remote user/IP/key
        read -r -p "Enter Remote SSH Username: " REMOTE_USER
        read -r -p "Enter Server IP Address: " REMOTE_IP
        read -r -p "Enter Local SSH Key Path: " SSH_KEY_PATH
        
        # We need the APP_NAME to know what to clean up
        read -r -p "Enter the Project Name to clean up (folder name, e.g., 'my-app'): " APP_NAME

        local cleanup_remote_commands="
            echo 'Running remote cleanup for app: $APP_NAME'
            
            # Stop and remove containers
            cd $REMOTE_PATH/$APP_NAME || echo 'Project directory not found, skipping docker cleanup.'
            sudo docker-compose down || true 
            
            # Remove project directory
            sudo rm -rf $REMOTE_PATH/$APP_NAME || true
            
            # Remove Nginx configuration
            NGINX_CONF_PATH='/etc/nginx/sites-available/$APP_NAME.conf'
            NGINX_LINK_PATH='/etc/nginx/sites-enabled/$APP_NAME.conf'
            sudo rm -f \$NGINX_CONF_PATH \$NGINX_LINK_PATH || true
            
            # Test and reload Nginx
            sudo nginx -t && sudo systemctl reload nginx || true
            echo 'Remote cleanup complete.'
        "
        remote_ssh_exec "$cleanup_remote_commands"
        log_action SUCCESS "CLEANUP MODE finished."
        exit 0
    fi
    
    # Normal Deployment Flow
    
    collect_parameters
    clone_or_pull_repo
    
    # Now that we have the LOCAL_PROJECT_PATH, ensure cleanup runs on exit
    trap 'cleanup_local_repo' EXIT

    prepare_remote_environment
    transfer_and_deploy_application
    configure_nginx_proxy
    validate_full_deployment
    
    log_action SUCCESS "--- DEPLOYMENT COMPLETE ---"
    log_action INFO "Application is now running on http://$REMOTE_IP"
}

# Execute main function
main "$@"