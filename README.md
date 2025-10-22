# 🐳 Automated Docker Deployment Script (deploy.sh)

This is a robust, single-file Bash script designed to automate the complete setup, deployment, and configuration of a Dockerized application on a remote Linux server (such as an AWS EC2 instance).

It handles everything from source code management to setting up the production web server.

## ✨ Features

- Idempotent Infrastructure Setup: Installs Docker, Docker Compose, and Nginx on the remote server only if they are missing.

- Git Integration: Clones or pulls the latest code from a specified Git repository and branch using a Personal Access Token (PAT).

- Secure File Transfer: Uses a two-step scp process to securely transfer the project directory to the remote deployment path (/opt/app_deploy).

-Container Orchestration: Builds and runs the application using docker-compose up -d --build --remove-orphans.

- Reverse Proxy Configuration: Configures Nginx to listen on Port 80 (HTTP) and reverse-proxy traffic to the container's specified internal port.

- Comprehensive Logging: Logs all actions, success messages, and failures to a timestamped local log file.

- Cleanup Mode: Includes a dedicated --cleanup flag for safely tearing down deployed resources.

## 🛠️ Prerequisites

To run this script successfully, you must have the following available:

- Local (Machine running deploy.sh)

- Bash (POSIX-compliant shell).

- Git for cloning the repository.

- scp (usually included with openssh-client).

- An SSH Private Key (.pem or .rsa) with read permissions (chmod 600).

- A GitHub Personal Access Token (PAT) if your repository is private.

- Remote (Target EC2 Server)

- A Linux distribution (e.g., Ubuntu, Amazon Linux) accessible via SSH.

- The SSH user must have sudo privileges (which is the default for most EC2 users like ubuntu or ec2-user).

-The EC2 Security Group must allow inbound traffic on Port 22 (SSH) and Port 80 (HTTP).


## 🚀 Usage

Make the script executable:

*chmod +x deploy.sh*


Run the script:

*./deploy.sh*


The script will prompt you for all required parameters:


Git Repository URL

PAT (Hidden input)

Branch name

main (Default)

Remote SSH Username

Server IP Address

Local SSH Key Path

Container Internal Port


### Cleanup Mode

To gracefully remove the deployed containers, Nginx configuration, and the project files from the remote server, run the script with the --cleanup flag:

*./deploy.sh --cleanup*


This mode will prompt for the necessary SSH credentials and the Project Name (which is automatically inferred as the repository name, e.g., my-project).