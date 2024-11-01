#!/bin/sh

# Enable strict error handling
set -eu

# -----------------------------
# Configuration Variables
# -----------------------------
# Repository URLs and Directories
REPO_URL="https://github.com/opengovern/deploy-opengovernance.git"
REPO_DIR="$HOME/.opengovernance/deploy-terraform"
INFRA_DIR="$REPO_DIR/aws/eks"

# Helm Chart Configuration
HELM_RELEASE="opengovernance"
HELM_CHART="opengovernance/opengovernance"  # Official Helm chart repository
REPO_NAME="opengovernance"
HELM_REPO_URL="https://opengovern.github.io/charts"

# Namespace
NAMESPACE="opengovernance"  # Default namespace

# -----------------------------
# Logging Configuration
# -----------------------------
DEBUG_MODE=true  # Helm operates in debug mode
LOGFILE="$HOME/.opengovernance/install.log"
DEBUG_LOGFILE="$HOME/.opengovernance/helm_debug.log"

# Create the log directories and files if they don't exist
LOGDIR="$(dirname "$LOGFILE")"
DEBUG_LOGDIR="$(dirname "$DEBUG_LOGFILE")"
mkdir -p "$LOGDIR" || { echo "Failed to create log directory at $LOGDIR."; exit 1; }
mkdir -p "$DEBUG_LOGDIR" || { echo "Failed to create debug log directory at $DEBUG_LOGDIR."; exit 1; }
touch "$LOGFILE" "$DEBUG_LOGFILE" || { echo "Failed to create log files."; exit 1; }

# -----------------------------
# Trap for Unexpected Exits
# -----------------------------
trap 'echo_error "Script terminated unexpectedly."; exit 1' INT TERM HUP

# -----------------------------
# Common Functions
# -----------------------------

# Function to display messages directly to the user
echo_prompt() {
    printf "%s\n" "$*" > /dev/tty
}

# Function to display informational messages to console and log with timestamp
echo_info() {
    message="$1"
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    if [ "$DEBUG_MODE" = "true" ]; then
        printf "[DEBUG] %s\n" "$message" > /dev/tty
    fi
    printf "%s [INFO] %s\n" "$timestamp" "$message" >> "$LOGFILE"
}

# Function to display primary messages to console and log with timestamp
echo_primary() {
    message="$1"
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    printf "%s\n" "$message" > /dev/tty
    printf "%s [INFO] %s\n" "$timestamp" "$message" >> "$LOGFILE"
}

# Function to display error messages to console and log with timestamp
echo_error() {
    message="$1"
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    printf "Error: %s\n" "$message" > /dev/tty
    printf "%s [ERROR] %s\n" "$timestamp" "$message" >> "$LOGFILE"
}

# Function to display usage information
usage() {
    echo_primary "Usage: $0 [options]"
    echo_primary ""
    echo_primary "Options:"
    echo_primary "  -d, --domain <domain>    Specify the fully qualified domain for OpenGovernance (e.g., some.example.com)."
    echo_primary "  -t, --type <type>        Specify the installation type."
    echo_primary "                            Types:"
    echo_primary "                              1 - Install with HTTPS (requires a domain name)"
    echo_primary "                              2 - Basic Install (No Ingress, use port-forwarding)"
    echo_primary "  -r, --region <region>    Specify the AWS region to deploy the infrastructure (e.g., us-west-2)."
    echo_primary "  --debug                  Enable debug mode for detailed output."
    echo_primary "  -h, --help               Display this help message."
    exit 1
}

# Function to run helm commands with a timeout of 15 minutes in debug mode
helm_install_with_timeout() {
    helm install "$@" --debug --timeout=15m 2>&1 | tee -a "$DEBUG_LOGFILE" >> "$LOGFILE"
}

# Function to check if a command exists
check_command() {
    cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo_error "Required command '$cmd' is not installed."
        exit 1
    else
        echo_info "Command '$cmd' is installed."
    fi
}

# Function to check if either Terraform or OpenTofu is installed
check_terraform_or_opentofu() {
    if command -v tofu >/dev/null 2>&1; then
        INFRA_BINARY="tofu"
        echo_info "OpenTofu is installed."
    elif command -v terraform >/dev/null 2>&1; then
        INFRA_BINARY="terraform"
        echo_info "Terraform is installed."
    else
        echo_error "Neither OpenTofu nor Terraform is installed. Please install one of them and retry."
        exit 1
    fi
}

# Function to check AWS CLI authentication
check_aws_auth() {
    if ! aws sts get-caller-identity >/dev/null 2>&1; then
        echo_error "AWS CLI is not configured or authenticated. Please run 'aws configure' and ensure you have the necessary permissions."
        exit 1
    fi
    echo_info "AWS CLI is authenticated."
}

# Function to check if kubectl is connected to a cluster
is_kubectl_active() {
    if ! kubectl cluster-info >/dev/null 2>&1; then
        echo_info "kubectl is not connected to any cluster."
        KUBECTL_ACTIVE="false"
        return 1
    else
        echo_info "kubectl is connected to a cluster."
        KUBECTL_ACTIVE="true"
        return 0
    fi
}

# Function to confirm the Kubernetes provider is AWS (EKS)
confirm_provider_is_eks() {
    CURRENT_CONTEXT=$(kubectl config current-context 2>/dev/null || true)
    if [ -n "$CURRENT_CONTEXT" ]; then
        CURRENT_CLUSTER_NAME=$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"$CURRENT_CONTEXT\")].context.cluster}")
        cluster_server=$(kubectl config view -o jsonpath="{.clusters[?(@.name==\"$CURRENT_CLUSTER_NAME\")].cluster.server}")
        case "$cluster_server" in
            *".eks.amazonaws.com"*|*"amazonaws.com"*)
                echo_info "Detected EKS (AWS) cluster."
                CURRENT_PROVIDER="AWS"
                return 0
                ;;
            *)
                echo_info "Detected non-EKS cluster."
                CURRENT_PROVIDER="OTHER"
                return 1
                ;;
        esac
    else
        echo_info "kubectl is not configured to any cluster."
        CURRENT_PROVIDER="NONE"
        return 1
    fi
}

# Function to check if there are at least three ready nodes
check_ready_nodes() {
    ready_nodes=$(kubectl get nodes --no-headers | grep -c ' Ready ')
    if [ "$ready_nodes" -lt 3 ]; then
        echo_error "At least three Kubernetes nodes must be ready. Currently, $ready_nodes node(s) are ready."
        return 1
    else
        echo_info "There are $ready_nodes ready nodes."
        return 0
    fi
}

# Function to determine if the current Kubernetes cluster is suitable for installation
is_cluster_suitable() {
    confirm_provider_is_eks
    if [ "$CURRENT_PROVIDER" = "AWS" ]; then
        if ! check_ready_nodes; then
            echo_error "Cluster does not have the required number of ready nodes."
            CLUSTER_SUITABLE="false"
            return 1
        fi

        if helm list -n "$NAMESPACE" | grep -q "^$HELM_RELEASE\b"; then
            echo_info "OpenGovernance is already installed in namespace '$NAMESPACE'."
            CLUSTER_SUITABLE="false"
            return 1
        fi

        echo_info "Cluster is suitable for OpenGovernance installation."
        CLUSTER_SUITABLE="true"
        return 0
    else
        echo_info "Current Kubernetes cluster is not an EKS cluster."
        CLUSTER_SUITABLE="false"
        return 1
    fi
}

# Function to check prerequisites
check_prerequisites() {
    # List of required commands
    REQUIRED_COMMANDS="git kubectl aws jq helm"

    echo_info "Checking for required tools..."

    # Check if each command is installed
    for cmd in $REQUIRED_COMMANDS; do
        check_command "$cmd"
    done

    # Check for Terraform or OpenTofu
    check_terraform_or_opentofu

    # Check AWS CLI authentication
    check_aws_auth

    # Ensure Helm repository is added and updated
    ensure_helm_repo

    # Check if kubectl is connected to a cluster
    if is_kubectl_active; then
        # Determine if there is a suitable cluster
        if is_cluster_suitable; then
            echo_info "Cluster is suitable for installation."
        else
            echo_info "Cluster is not suitable for installation. Unsetting current kubectl context."
            kubectl config unset current-context || { 
                echo_error "Failed to unset the current kubectl context."
                exit 1
            }
            echo_error "Cluster is not suitable for installation. Exiting."
            exit 1
        fi
    else
        echo_info "kubectl is not connected to any cluster. Proceeding without cluster suitability checks."
    fi

    echo_info "Checking Prerequisites...Completed"
}

# Function to ensure the Helm repository is added and updated in debug mode
ensure_helm_repo() {
    # Check if Helm is installed
    if command -v helm >/dev/null 2>&1; then
        echo_info "Ensuring Helm repository '$REPO_NAME' is added and up to date."

        # Check if the repository already exists
        if helm repo list | awk '{print $1}' | grep -q "^$REPO_NAME$"; then
            echo_info "Helm repository '$REPO_NAME' already exists."
        else
            # Add the repository with debug
            echo_info "Adding Helm repository '$REPO_NAME' in debug mode."
            helm repo add "$REPO_NAME" "$HELM_REPO_URL" --debug 2>&1 | tee -a "$DEBUG_LOGFILE" >> "$LOGFILE" || { echo_error "Failed to add Helm repository '$REPO_NAME'."; exit 1; }
        fi

        # Update the Helm repositories with debug
        echo_info "Updating Helm repositories in debug mode."
        helm repo update --debug 2>&1 | tee -a "$DEBUG_LOGFILE" >> "$LOGFILE" || { echo_error "Failed to update Helm repositories."; exit 1; }
    else
        echo_error "Helm is not installed."
        exit 1
    fi
}

# Function to display cluster metadata to the user
display_cluster_metadata() {
    echo_primary ""
    echo_primary "Cluster Metadata:"
    echo_primary "-----------------"

    # Get AWS Account ID
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
    if [ -n "$ACCOUNT_ID" ]; then
        echo_primary "AWS Account ID: $ACCOUNT_ID"
    else
        echo_primary "AWS Account ID: Unable to retrieve"
    fi

    # Get current context and cluster name
    CURRENT_CONTEXT=$(kubectl config current-context 2>/dev/null)
    if [ -n "$CURRENT_CONTEXT" ]; then
        CURRENT_CLUSTER_NAME=$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"$CURRENT_CONTEXT\")].context.cluster}")
        # Extract the cluster name (last part of the cluster ARN)
        CLUSTER_NAME="${CURRENT_CLUSTER_NAME##*/}"
        echo_primary "Cluster Name: $CLUSTER_NAME"
    else
        echo_primary "Unable to determine current kubectl context."
    fi

    echo_primary "-----------------"
}

# Function to deploy infrastructure
deploy_infrastructure() {
    # Construct the deployment message with REGION if it's set
    if [ -n "$REGION" ]; then
        echo_primary "Deploying infrastructure in region '$REGION'. This step may take 10-15 minutes..."
        export AWS_REGION="$REGION"
    else
        echo_primary "Deploying infrastructure. This step may take 10-15 minutes..."
    fi

    echo_info "Ensuring infrastructure directory exists: $INFRA_DIR"
    mkdir -p "$INFRA_DIR" || { echo_error "Failed to create infrastructure directory at $INFRA_DIR."; exit 1; }

    echo_info "Navigating to infrastructure directory: $INFRA_DIR"
    cd "$INFRA_DIR" || { echo_error "Failed to navigate to $INFRA_DIR"; exit 1; }

    # Set variables for plan and apply
    TF_VAR_REGION_OPTION=""
    
    # Conditionally add the region variable if REGION is set
    if [ -n "$REGION" ]; then
        TF_VAR_REGION_OPTION="-var 'region=$REGION'"
    fi

    # Combine variable options
    TF_VARS_OPTIONS="$TF_VAR_REGION_OPTION"

    # Check for existing infrastructure
    if $INFRA_BINARY state list >> "$LOGFILE" 2>&1; then
        STATE_COUNT=`$INFRA_BINARY state list | wc -l | tr -d ' '`
        if [ "$STATE_COUNT" -gt 0 ]; then
            echo_prompt "Existing infrastructure detected. Do you want to (c)lean up existing infra or (u)se it? [c/u]: "
            read USER_CHOICE
            case "$USER_CHOICE" in
                c|C)
                    echo_info "Destroying existing infrastructure..."
                    # Update destroy command to include variable options
                    eval "$INFRA_BINARY destroy $TF_VARS_OPTIONS -auto-approve" >> "$LOGFILE" 2>&1 || { echo_error "$INFRA_BINARY destroy failed."; exit 1; }
                    ;;
                u|U)
                    echo_info "Using existing infrastructure. Configuring kubectl..."
                    KUBECTL_CMD=`$INFRA_BINARY output -raw configure_kubectl`
                    echo_info "Executing kubectl configuration command."
                    sh -c "$KUBECTL_CMD" >> "$LOGFILE" 2>&1 || { echo_error "$INFRA_BINARY output failed."; exit 1; }
                    return 0  # Skip deployment since we're using existing infra
                    ;;
                *)
                    echo_error "Invalid choice. Exiting."
                    exit 1
                    ;;
            esac
        fi
    fi

    # Proceed to deploy only if cleanup was chosen or infra does not exist
    echo_info "Initializing $INFRA_BINARY..."
    $INFRA_BINARY init >> "$LOGFILE" 2>&1 || { echo_error "$INFRA_BINARY init failed."; exit 1; }

    echo_info "Planning $INFRA_BINARY deployment..."
    # Use eval to properly handle variables with quotes
    eval "$INFRA_BINARY plan $TF_VARS_OPTIONS -out=plan.tfplan" >> "$LOGFILE" 2>&1 || { echo_error "$INFRA_BINARY plan failed."; exit 1; }

    echo_info "Generating JSON representation of the plan..."
    $INFRA_BINARY show -json plan.tfplan > plan.json || { echo_error "$INFRA_BINARY show failed."; exit 1; }

    # Start the apply process in the background
    echo_info "Applying $INFRA_BINARY deployment..."
    eval "$INFRA_BINARY apply $TF_VARS_OPTIONS plan.tfplan" >> "$LOGFILE" 2>&1 &
    APPLY_PID=$!

    # Progress monitoring variables
    CHECK_INTERVAL=10  # in seconds
    total_actions=`jq '.resource_changes | length' plan.json`
    if [ "$total_actions" -eq 0 ]; then
        echo_primary "No resources to add, change, or destroy."
        wait "$APPLY_PID"
    else
        # Extract planned resource addresses
        planned_addresses_file="planned_addresses.txt"
        jq -r '.resource_changes[].address' plan.json > "$planned_addresses_file"

        echo_info "Monitoring progress..."
        while kill -0 "$APPLY_PID" 2>/dev/null; do
            # Check if parent process is still running
            if ! kill -0 "$PPID" 2>/dev/null; then
                echo_error "Parent process $PPID has died. Exiting."
                exit 1
            fi

            # Try to get current state resources
            current_state_resources=`$INFRA_BINARY state list 2>/dev/null || true`

            if [ -n "$current_state_resources" ]; then
                # Save current state resources to a file
                current_state_file="current_state.txt"
                echo "$current_state_resources" > "$current_state_file"

                # Compare current state with planned addresses
                num_completed=`grep -Fxf "$current_state_file" "$planned_addresses_file" | wc -l | tr -d ' '`
                percent_complete=`expr $num_completed \* 100 / $total_actions`

                # Use echo_primary to display progress
                echo_primary "Progress: $num_completed out of $total_actions resources completed ($percent_complete%)"
            else
                echo_primary "No resources applied yet. Retrying in $CHECK_INTERVAL seconds..."
            fi

            sleep "$CHECK_INTERVAL"
        done

        # Final progress check after apply completes
        current_state_resources=`$INFRA_BINARY state list 2>/dev/null || true`

        if [ -n "$current_state_resources" ]; then
            current_state_file="current_state.txt"
            echo "$current_state_resources" > "$current_state_file"

            num_completed=`grep -Fxf "$current_state_file" "$planned_addresses_file" | wc -l | tr -d ' '`
            percent_complete=`expr $num_completed \* 100 / $total_actions`
            echo_primary "Final Progress: $num_completed out of $total_actions resources completed ($percent_complete%)"
        else
            echo_primary "Final Progress: No resources were applied."
        fi

        # Clean up temporary files
        rm -f "$planned_addresses_file"
        if [ -n "${current_state_file:-}" ]; then
            rm -f "$current_state_file"
        fi
    fi

    # Wait for the apply process to finish
    wait "$APPLY_PID" || { echo_error "$INFRA_BINARY apply failed."; exit 1; }

    # Clean up plan files
    rm -f plan.tfplan plan.json

    echo_info "Connecting to the Kubernetes cluster..."
    KUBECTL_CMD=`$INFRA_BINARY output -raw configure_kubectl`

    echo_info "Executing kubectl configuration command."
    sh -c "$KUBECTL_CMD" >> "$LOGFILE" 2>&1 || { echo_error "Failed to configure kubectl."; exit 1; }

    # Verify kubectl configuration
    if ! kubectl cluster-info > /dev/null 2>&1; then
        echo_error "kubectl failed to configure the cluster."
        exit 1
    fi
    echo_info "kubectl configured successfully."
}

# -----------------------------
# Application Installation
# -----------------------------

install_application() {
    echo_primary "Installing OpenGovernance via Helm. This step takes approximately 7-11 minutes."
    echo_info "Installing OpenGovernance via Helm."

    if [ "$INSTALL_TYPE" = "1" ]; then
        # Ensure DOMAIN is set
        if [ -z "${DOMAIN:-}" ]; then
            echo_error "Domain must be provided for installation."
            exit 1
        fi

        # Create a temporary values file
        TEMP_VALUES_FILE="$(mktemp)"
        cat > "$TEMP_VALUES_FILE" <<EOF
global:
  domain: ${DOMAIN}
dex:
  config:
    issuer: ${PROTOCOL}://${DOMAIN}/dex
EOF

        # Run helm install with the values file
        helm_install_with_timeout -n "$NAMESPACE" "$HELM_RELEASE" "$HELM_CHART" --create-namespace -f "$TEMP_VALUES_FILE" || { echo_error "Helm install failed."; exit 1; }
        rm -f "$TEMP_VALUES_FILE"
    else
        # For Basic Install, run helm install without additional values
        helm_install_with_timeout -n "$NAMESPACE" "$HELM_RELEASE" "$HELM_CHART" --create-namespace || { echo_error "Helm install failed."; exit 1; }
    fi

    echo_info "Helm install completed."
}

# -----------------------------
# Ingress Configuration
# -----------------------------

configure_ingress() {
    echo_primary "Configuring Ingress. This step takes approximately 2-3 minutes."

    # Ensure DOMAIN is set
    if [ -z "${DOMAIN:-}" ]; then
        echo_error "DOMAIN must be set to configure Ingress."
        exit 1
    fi

    # Prepare Ingress manifest
    INGRESS_TEMPLATE=$(cat <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  namespace: "${NAMESPACE}"
  name: opengovernance-ingress
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/backend-protocol: HTTP
    kubernetes.io/ingress.class: alb
EOF
    )

    if [ "$USE_HTTPS" = "true" ]; then
        echo_info "Applying Ingress with HTTPS."
        INGRESS_TEMPLATE="$INGRESS_TEMPLATE
    alb.ingress.kubernetes.io/listen-ports: '[{\"HTTP\": 80}, {\"HTTPS\":443}]'
    alb.ingress.kubernetes.io/certificate-arn: \"${CERTIFICATE_ARN}\"
"
    else
        echo_info "Applying Ingress with HTTP only."
        INGRESS_TEMPLATE="$INGRESS_TEMPLATE
    alb.ingress.kubernetes.io/listen-ports: '[{\"HTTP\": 80}]'
"
    fi

    INGRESS_TEMPLATE="$INGRESS_TEMPLATE
spec:
  ingressClassName: alb
  rules:
    - host: \"${DOMAIN}\"
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: nginx-proxy
                port:
                  number: 80
"

    # Apply Ingress
    echo "$INGRESS_TEMPLATE" | kubectl apply -f - >> "$LOGFILE" 2>&1
    echo_info "Ingress applied successfully."
}

# -----------------------------
# Readiness Checks
# -----------------------------

# Function to check OpenGovernance readiness
check_opengovernance_readiness() {
    # Check the readiness of all pods in the specified namespace
    not_ready_pods=$(kubectl get pods -n "$NAMESPACE" --no-headers | awk '{print $3}' | grep -v -E 'Running|Completed' || true)

    if [ -z "$not_ready_pods" ]; then
        APP_HEALTHY="true"
    else
        echo_error "Some OpenGovernance pods are not healthy."
        kubectl get pods -n "$NAMESPACE" >> "$LOGFILE" 2>&1
        APP_HEALTHY="false"
    fi
}

# Function to check pods and migrator jobs
check_pods_and_jobs() {
    attempts=0
    max_attempts=24  # 24 attempts * 30 seconds = 12 minutes
    sleep_time=30

    while [ "$attempts" -lt "$max_attempts" ]; do
        check_opengovernance_readiness
        if [ "${APP_HEALTHY:-false}" = "true" ]; then
            return 0
        fi
        attempts=$((attempts + 1))
        echo_info "Waiting for pods to become ready... ($attempts/$max_attempts)"
        sleep "$sleep_time"
    done

    echo_error "OpenGovernance did not become ready within expected time."
    exit 1
}

# -----------------------------
# ACM Certificate Lookup
# -----------------------------

lookup_acm_certificate() {
    DOMAIN_TO_LOOKUP="$1"
    echo_info "Looking up ACM Certificate ARN for domain '$DOMAIN_TO_LOOKUP'."

    # List certificates with status 'ISSUED'
    CERT_LIST=$(aws acm list-certificates --query 'CertificateSummaryList[?DomainName==`'"$DOMAIN_TO_LOOKUP"'` && Status==`ISSUED`].CertificateArn' --output text 2>/dev/null || true)

    if [ -z "$CERT_LIST" ]; then
        echo_error "No active ACM certificate found for domain '$DOMAIN_TO_LOOKUP'."
        CERTIFICATE_ARN=""
        return 1
    fi

    # If multiple certificates are found, select the first one
    CERTIFICATE_ARN=$(echo "$CERT_LIST" | awk '{print $1}' | head -n 1)

    if [ -z "$CERTIFICATE_ARN" ]; then
        echo_error "Failed to retrieve ACM Certificate ARN for domain '$DOMAIN_TO_LOOKUP'."
        return 1
    fi

    echo_info "Found ACM Certificate ARN: $CERTIFICATE_ARN"
    return 0
}

# -----------------------------
# Port-Forwarding Function
# -----------------------------

basic_install_with_port_forwarding() {
    echo_info "Setting up port-forwarding to access OpenGovernance locally."

    # Start port-forwarding in the background
    kubectl port-forward -n "$NAMESPACE" service/nginx-proxy 8080:80 >> "$LOGFILE" 2>&1 &
    PORT_FORWARD_PID=$!

    # Give port-forwarding some time to establish
    sleep 5

    # Check if port-forwarding is still running
    if kill -0 "$PORT_FORWARD_PID" >/dev/null 2>&1; then
        echo_info "Port-forwarding established successfully."
        echo_prompt "OpenGovernance is accessible at http://localhost:8080"
        echo_prompt "To sign in, use the following default credentials:"
        echo_prompt "  Username: admin@opengovernance.io"
        echo_prompt "  Password: password"
        echo_prompt "You can terminate port-forwarding by killing the background process (PID: $PORT_FORWARD_PID)."
    else
        echo_primary ""
        echo_primary "========================================="
        echo_primary "Port-Forwarding Instructions"
        echo_primary "========================================="
        echo_primary "OpenGovernance is running but not accessible via Ingress."
        echo_primary "You can access it using port-forwarding as follows:"
        echo_primary ""
        echo_primary "kubectl port-forward -n \"$NAMESPACE\" service/nginx-proxy 8080:80"
        echo_primary ""
        echo_primary "Then, access it at http://localhost:8080"
        echo_primary ""
        echo_primary "To sign in, use the following default credentials:"
        echo_primary "  Username: admin@opengovernance.io"
        echo_primary "  Password: password"
        echo_primary ""
    fi
}

# -----------------------------
# AWS Post-Deployment Function
# -----------------------------

# Function to execute AWS-specific post-deployment script
execute_aws_post_deployment() {
    echo_primary "Fetching and executing the AWS post-deployment configuration script."
    curl -sL https://raw.githubusercontent.com/opengovern/deploy-opengovernance/main/aws/scripts/aws.sh | bash
    if [[ $? -eq 0 ]]; then
        echo_primary "AWS post-deployment configuration executed successfully."
    else
        echo_error "Failed to execute AWS post-deployment configuration."
        exit 1
    fi
}

# -----------------------------
# Function to deploy to a specific platform
# -----------------------------

deploy_to_platform() {
    local platform="$1"
    case "$platform" in
        "AWS")
            echo_primary "Deploying OpenGovernance to AWS."
            check_command "aws"  # Ensure AWS CLI is installed
            deploy_infrastructure
            install_application
            execute_aws_post_deployment
            ;;
        "DigitalOcean")
            echo_primary "Deploying OpenGovernance to DigitalOcean."
            # Implement DigitalOcean deployment steps here
            # For example:
            # deploy_to_digitalocean
            echo_error "DigitalOcean deployment not implemented in this script."
            exit 1
            ;;
        # Add cases for other platforms like Azure, GCP as needed
        *)
            echo_error "Unsupported platform: $platform"
            exit 1
            ;;
    esac
}

# -----------------------------
# Read User Input for Deployment Platform
# -----------------------------

choose_deployment() {
    while true; do
        echo_primary "Where would you like to deploy OpenGovernance to?"

        # Initialize options array
        OPTIONS=()
        option_number=1

        # AWS
        echo_primary "$option_number. AWS (EKS)"
        OPTIONS[$option_number]="AWS"
        ((option_number++))

        # DigitalOcean
        echo_primary "$option_number. DigitalOcean"
        OPTIONS[$option_number]="DigitalOcean"
        ((option_number++))

        # Add more platforms as needed

        # Exit
        echo_primary "$option_number. Exit"
        OPTIONS[$option_number]="Exit"
        ((option_number++))

        echo_primary "Press 's' to view cluster and provider details"

        echo_prompt -n "Select an option (1-$((option_number-1))) or press 's' to view details: "

        read -r user_input < /dev/tty

        if [[ "$user_input" =~ ^[sS]$ ]]; then
            display_cluster_metadata
            continue
        fi

        if ! [[ "$user_input" =~ ^[0-9]+$ ]]; then
            echo_error "Invalid input. Please enter a number between 1 and $((option_number-1))."
            continue
        fi

        if (( user_input < 1 || user_input >= option_number )); then
            echo_error "Invalid choice. Please select a number between 1 and $((option_number-1))."
            continue
        fi

        selected_option="${OPTIONS[$user_input]}"

        if [[ "$selected_option" == "Exit" ]]; then
            echo_primary "Exiting."
            exit 0
        else
            # Deploy to the selected platform
            deploy_to_platform "$selected_option"
            break
        fi
    done
}

# -----------------------------
# Main Execution Flow
# -----------------------------

echo_primary "======================================="
echo_primary "Starting OpenGovernance Deployment Script"
echo_primary "======================================="

# Initialize variables
DOMAIN=""
INSTALL_TYPE=""
INSTALL_TYPE_SPECIFIED="false"
SKIP_INFRA="false"
CERTIFICATE_ARN=""                # Will be set during domain confirmation
INFRA_BINARY=""                   # Will be determined later
KUBECTL_ACTIVE="false"            # Will be set in is_kubectl_active
CLUSTER_SUITABLE="false"          # Will be set in is_cluster_suitable
CURRENT_PROVIDER="NONE"           # Will be set in confirm_provider_is_eks
USE_HTTPS="false"                 # Will be set during domain confirmation
PROTOCOL="http"                   # Default protocol
REGION=""                         # New variable for AWS region

# Parse command-line arguments
while [ "$#" -gt 0 ]; do
    case "$1" in
        -d|--domain)
            if [ "$#" -lt 2 ]; then
                echo_error "Option '$1' requires an argument."
                usage
            fi
            DOMAIN="$2"
            shift 2
            ;;
        -t|--type)
            if [ "$#" -lt 2 ]; then
                echo_error "Option '$1' requires an argument."
                usage
            fi
            INSTALL_TYPE="$2"
            INSTALL_TYPE_SPECIFIED="true"
            shift 2
            ;;
        -r|--region)
            if [ "$#" -lt 2 ]; then
                echo_error "Option '$1' requires an argument."
                usage
            fi
            REGION="$2"
            shift 2
            ;;
        --debug)
            DEBUG_MODE="true"
            echo_info "Debug mode enabled."
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo_error "Unknown parameter passed: $1"
            usage
            ;;
    esac
done

# Step 1: Check for required tools and prerequisites
echo_info "Checking for required tools and prerequisites..."
check_prerequisites

# Step 2: Determine Installation Type Based on Parameters
if [ -n "$DOMAIN" ]; then
    # Domain is specified, set installation type to 1
    echo_info "Domain specified: $DOMAIN. Setting installation type to 1."
    INSTALL_TYPE="1"
else
    # Domain is not specified, use install type parameter or prompt
    if [ "$INSTALL_TYPE_SPECIFIED" = "false" ]; then
        # Prompt user for installation type with a 30-second timeout
        echo_primary ""
        echo_primary "======================================="
        echo_primary "Select Installation Type:"
        echo_primary "======================================="
        echo_primary "1) Install with HTTPS (requires a domain name)"
        echo_primary "2) Basic Install (No Ingress, use port-forwarding)"
        echo_primary "Default: 2 (if no input within 30 seconds)"
        echo_prompt "Enter your choice (1/2): "

        # Read user input with a 30-second timeout
        if ! read -t 30 USER_INSTALL_TYPE; then
            USER_INSTALL_TYPE=""
        fi

        if [ -z "$USER_INSTALL_TYPE" ]; then
            echo_primary "No input received within 30 seconds. Proceeding with Basic Install (No Ingress, use port-forwarding)."
            INSTALL_TYPE="2"
        else
            # Validate user input
            case "$USER_INSTALL_TYPE" in
                1|2)
                    INSTALL_TYPE="$USER_INSTALL_TYPE"
                    ;;
                *)
                    echo_error "Invalid installation type selected."
                    usage
                    ;;
            esac
        fi
    else
        # Use install type specified via parameter
        case "$INSTALL_TYPE" in
            1|2)
                ;;
            *)
                echo_error "Invalid installation type specified via parameter."
                usage
                ;;
        esac
    fi
fi

# Step 2.1: If user selected Install with HTTPS, ensure domain is provided
if [ "$INSTALL_TYPE" = "1" ]; then
    if [ -z "$DOMAIN" ]; then
        total_time=0
        DOMAIN_INPUT=""
        while [ "$total_time" -lt 90 ]; do
            remaining_time=$((90 - total_time))
            echo_prompt "Please enter your fully qualified domain name (e.g., some.example.com). You have $remaining_time seconds left: "
            if ! read -t 15 DOMAIN_INPUT; then
                DOMAIN_INPUT=""
            fi

            if [ -z "$DOMAIN_INPUT" ]; then
                total_time=$((total_time + 15))
                echo_info "No domain entered. Please try again."
                if [ "$total_time" -ge 90 ]; then
                    echo_primary "No domain provided after 90 seconds. Proceeding with Basic Install (No Ingress, use port-forwarding)."
                    INSTALL_TYPE="2"
                    break
                fi
            else
                # Confirm the domain
                echo_prompt "You entered domain: $DOMAIN_INPUT. Press Enter to confirm or type a new domain within 15 seconds."
                if ! read -t 15 DOMAIN_CONFIRM; then
                    DOMAIN_CONFIRM=""
                fi

                if [ -z "$DOMAIN_CONFIRM" ]; then
                    # Domain confirmed
                    DOMAIN="$DOMAIN_INPUT"
                    break
                else
                    # User provided a new domain, update DOMAIN_INPUT and loop again
                    DOMAIN_INPUT="$DOMAIN_CONFIRM"
                fi
            fi
        done

        if [ "$INSTALL_TYPE" = "2" ]; then
            echo_info "Proceeding with Basic Install (No Ingress, use port-forwarding)."
        fi
    fi

    # After domain is confirmed, lookup ACM certificate
    if [ -n "$DOMAIN" ]; then
        # Use an if-statement to handle the function's exit status without causing the script to exit
        if lookup_acm_certificate "$DOMAIN"; then
            USE_HTTPS="true"
            PROTOCOL="https"
            echo_info "ACM certificate found. Proceeding with HTTPS."
        else
            USE_HTTPS="false"
            PROTOCOL="http"
            echo_primary "No ACM certificate found for domain '$DOMAIN'. Proceeding with HTTP only."
        fi
    fi
fi

# Step 3: Determine Installation Behavior Based on Cluster Configuration

if [ "$KUBECTL_ACTIVE" = "true" ] && [ "$CLUSTER_SUITABLE" = "true" ]; then
    # Display cluster metadata before prompting
    display_cluster_metadata

    echo_prompt "A suitable EKS cluster is detected. Do you wish to use it and skip infrastructure setup? (y/n): "
    read USE_EXISTING_CLUSTER

    case "$USE_EXISTING_CLUSTER" in
        y|Y)
            SKIP_INFRA="true"
            echo_info "Skipping infrastructure creation. Proceeding with installation using existing cluster."
            ;;
        n|N)
            SKIP_INFRA="false"
            ;;
        *)
            echo_error "Invalid choice. Exiting."
            exit 1
            ;;
    esac
else
    SKIP_INFRA="false"
fi

# Step 4: Clone repository and deploy infrastructure if not skipping
if [ "$SKIP_INFRA" = "false" ]; then
    clone_repository() {
        if [ -d "$REPO_DIR" ]; then
            echo_info "Directory '$REPO_DIR' already exists. Deleting it before cloning..."
            rm -rf "$REPO_DIR" >> "$LOGFILE" 2>&1 || { echo_error "Failed to delete existing directory '$REPO_DIR'."; exit 1; }
        fi
        echo_info "Cloning repository from $REPO_URL to $REPO_DIR..."
        git clone "$REPO_URL" "$REPO_DIR" >> "$LOGFILE" 2>&1 || { echo_error "Failed to clone repository."; exit 1; }
    }

    clone_repository
    deploy_infrastructure
else
    echo_info "Skipping infrastructure deployment as per user request."
fi

# Step 5: Install OpenGovernance via Helm
install_application

# Step 6: Wait for application readiness
check_pods_and_jobs

# Step 7: Configure Ingress or Port-Forwarding based on installation type
if [ "$INSTALL_TYPE" = "1" ]; then
    configure_ingress
elif [ "$INSTALL_TYPE" = "2" ]; then
    basic_install_with_port_forwarding
fi

# Add the new direction messages
if [ "$INSTALL_TYPE" = "1" ]; then
    echo_primary "OpenGovernance has been successfully installed and configured."
    echo_primary ""
    echo_primary "Access your OpenGovernance instance at: ${PROTOCOL}://${DOMAIN}"
    echo_primary ""
    echo_primary "To sign in, use the following default credentials:"
    echo_primary "  Username: admin@opengovernance.io"
    echo_primary "  Password: password"
    echo_primary ""
elif [ "$INSTALL_TYPE" = "2" ]; then
    echo_primary "OpenGovernance has been successfully installed and configured."
    echo_primary ""
    echo_primary "To access OpenGovernance, set up port-forwarding as follows:"
    echo_primary "kubectl port-forward -n \"$NAMESPACE\" service/nginx-proxy 8080:80"
    echo_primary ""
    echo_primary "Then, access it at http://localhost:8080"
    echo_primary ""
    echo_primary "To sign in, use the following default credentials:"
    echo_primary "  Username: admin@opengovernance.io"
    echo_primary "  Password: password"
    echo_primary ""
fi

# Step 8: Choose Deployment Platform
choose_deployment

echo_primary "OpenGovernance deployment script completed successfully."
exit 0