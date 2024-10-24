#!/bin/bash

set -e

# -----------------------------
# Logging Configuration
# -----------------------------
LOGFILE="$HOME/opengovernance_install.log"

# Ensure the log directory exists
mkdir -p "$(dirname "$LOGFILE")"

# Redirect all output to the log file and the console
exec > >(tee -i "$LOGFILE") 2>&1

# -----------------------------
# Function Definitions
# -----------------------------

# Function to display informational messages
function echo_info() {
  printf "\n\033[1;34m%s\033[0m\n\n" "$1"
}

# Function to display error messages
function echo_error() {
  printf "\n\033[0;31m%s\033[0m\n\n" "$1"
}

# Function to display usage information
function usage() {
  echo "Usage: $0 [-d DOMAIN] [-e EMAIL] [--dry-run]"
  echo ""
  echo "Options:"
  echo "  -d, --domain    Specify the domain for OpenGovernance."
  echo "  -e, --email     Specify the email for Let's Encrypt certificate generation."
  echo "  --dry-run       Perform a trial run with no changes made."
  echo "  -h, --help      Display this help message."
  exit 1
}

# Function to validate email format
function validate_email() {
  local email_regex="^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"
  if [[ ! "$EMAIL" =~ $email_regex ]]; then
    echo_error "Invalid email format: $EMAIL"
    exit 1
  fi
}

# Function to validate domain format
function validate_domain() {
  local domain_regex="^(([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)\.)+([A-Za-z]{2,})$"
  if [[ ! "$DOMAIN" =~ $domain_regex ]]; then
    echo_error "Invalid domain format: $DOMAIN"
    exit 1
  fi
}

# Function to parse command-line arguments
function parse_args() {
  DRY_RUN=false
  while [[ "$#" -gt 0 ]]; do
    case $1 in
      -d|--domain)
        DOMAIN="$2"
        shift 2
        ;;
      -e|--email)
        EMAIL="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=true
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

  # Validate DOMAIN and EMAIL if they are set
  if [ -n "$DOMAIN" ]; then
    validate_domain
  fi

  if [ -n "$EMAIL" ]; then
    validate_email
  fi
}

# Function to check prerequisites
function check_prerequisites() {
  echo_info "Checking Prerequisites"

  # Check if kubectl is connected to a cluster
  if ! kubectl cluster-info > /dev/null 2>&1; then
    echo_error "Error: kubectl is not connected to a cluster."
    echo "Please configure kubectl to connect to a Kubernetes cluster and try again."
    exit 1
  fi

  # Check if Helm is installed
  if ! command -v helm &> /dev/null; then
    echo_error "Error: Helm is not installed."
    echo "Please install Helm and try again."
    exit 1
  fi

  # Check if there are at least three ready nodes
  READY_NODES=$(kubectl get nodes --no-headers | grep -c 'Ready')
  if [ "$READY_NODES" -lt 3 ]; then
    echo_error "Error: At least three Kubernetes nodes must be ready. Currently, $READY_NODES node(s) are ready."
    exit 1
  else
    echo_info "There are $READY_NODES ready nodes."
  fi
}

# Function to check if OpenGovernance is installed
function check_opengovernance_installation() {
  # Check if the Helm repo is added
  local helm_repo=$(helm repo list | grep -o "opengovernance")
  if [ -z "$helm_repo" ]; then
    echo_error "Error: OpenGovernance Helm repo is not added."
    return 1
  fi

  # Check if the OpenGovernance release is installed and in a deployed state
  local helm_release=$(helm list -n opengovernance | grep opengovernance | awk '{print $8}')
  if [ "$helm_release" == "deployed" ]; then
    echo_info "OpenGovernance is successfully installed and running."
    return 0
  else
    echo_error "Error: OpenGovernance is not installed or not in a 'deployed' state."
    return 1
  fi
}

# Function to check OpenGovernance configuration
function check_opengovernance_config() {
  # Initialize variables
  local custom_host_name=false
  local dex_configuration_ok=false
  local ssl_configured=false

  # Retrieve the app hostname by looking up the environment variables
  ENV_VARS=$(kubectl get deployment metadata-service -n opengovernance \
    -o jsonpath='{.spec.template.spec.containers[0].env[*]}')

  # Extract the primary domain from the environment variables
  DOMAIN=$(echo "$ENV_VARS" | grep -o '"name":"METADATA_PRIMARY_DOMAIN_URL","value":"[^"]*"' | awk -F'"' '{print $8}')

  # Determine if it's a custom hostname or not
  if [[ $DOMAIN == "og.app.domain" ]]; then
    custom_host_name=false
  elif [[ $DOMAIN =~ ^([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}$ ]]; then
    custom_host_name=true
  fi

  # Retrieve redirect URIs
  redirect_uris=$(echo "$ENV_VARS" | grep -o '"name":"METADATA_DEX_PUBLIC_CLIENT_REDIRECT_URIS","value":"[^"]*"' | awk -F'"' '{print $8}')

  # Check if the primary domain is present in the redirect URIs
  if echo "$redirect_uris" | grep -q "$DOMAIN"; then
    dex_configuration_ok=true
  fi

  # Enhanced SSL configuration check
  if [[ $custom_host_name == true ]] && \
     echo "$redirect_uris" | grep -q "https://$DOMAIN"; then
     
    if kubectl get ingress opengovernance-ingress -n opengovernance &> /dev/null; then
      # Use kubectl describe to get Ingress details
      INGRESS_DETAILS=$(kubectl describe ingress opengovernance-ingress -n opengovernance)

      # Check for TLS configuration in the Ingress specifically for the DOMAIN
      if echo "$INGRESS_DETAILS" | grep -q "tls:" && echo "$INGRESS_DETAILS" | grep -q "host: $DOMAIN"; then
        
        # Check if the Ingress Controller has an assigned external IP
        INGRESS_EXTERNAL_IP=$(kubectl get svc ingress-nginx-controller -n opengovernance -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
        if [ -n "$INGRESS_EXTERNAL_IP" ]; then
          ssl_configured=true
        fi
      fi
    fi
  fi

  # Output results
  echo "Custom Hostname: $custom_host_name"
  echo "App Configured Hostname: $DOMAIN"
  echo "Dex Configuration OK: $dex_configuration_ok"
  echo "SSL/TLS configured in Ingress: $ssl_configured"

  # Export variables for use in other functions
  export custom_host_name
  export ssl_configured
}

# Function to check OpenGovernance readiness
function check_opengovernance_readiness() {
  # Check the status of all pods in the 'opengovernance' namespace
  local not_ready_pods=$(kubectl get pods -n opengovernance --no-headers | awk '{print $3}' | grep -v -E 'Running|Succeeded|Completed' | wc -l)
  
  if [ "$not_ready_pods" -eq 0 ]; then
    echo_info "All Pods are running and/or healthy."
    return 0
  else
    echo_error "Some Pods are not running or healthy."
    kubectl get pods -n opengovernance
    return 1
  fi

  # Check the status of 'migrator-job' pods
  local migrator_pods=$(kubectl get pods -n opengovernance -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep '^migrator-job')
  
  if [ -n "$migrator_pods" ]; then
    for pod in $migrator_pods; do
      local status=$(kubectl get pod "$pod" -n opengovernance -o jsonpath='{.status.phase}')
      if [ "$status" != "Succeeded" ] && [ "$status" != "Completed" ]; then
        echo_error "Pod '$pod' is in '$status' state. It needs to be in 'Completed' state."
        return 1
      fi
    done
  fi
  
  return 0
}

# Function to configure email and domain
function configure_email_and_domain() {
  echo_info "Configuring DOMAIN and EMAIL"

  # Capture DOMAIN if not set via arguments
  if [ -z "$DOMAIN" ]; then
    while true; do
      echo ""
      echo "Enter your domain for OpenGovernance (required for custom hostname)."
      read -p "Domain (or press Enter to skip): " DOMAIN < /dev/tty
      if [ -z "$DOMAIN" ]; then
        echo_info "No domain entered. Skipping domain configuration."
        break
      fi
      echo "You entered: $DOMAIN"
      read -p "Is this correct? (Y/n): " yn < /dev/tty
      case $yn in
          "" | [Yy]* ) 
              validate_domain
              break
              ;;
          [Nn]* ) 
              echo "Let's try again."
              DOMAIN=""
              ;;
          * ) 
              echo "Please answer y or n.";;
      esac
    done
  fi

  # Proceed to capture EMAIL if DOMAIN is set and user chooses SSL
  if [ -n "$DOMAIN" ]; then
    echo ""
    echo "Do you want to set up SSL/TLS with Let's Encrypt?"
    select yn in "Yes" "No"; do
      case $yn in
          Yes ) 
              ENABLE_HTTPS=true
              if [ -z "$EMAIL" ]; then
                while true; do
                  echo "Enter your email for HTTPS certificate generation via Let's Encrypt."
                  read -p "Email: " EMAIL < /dev/tty
                  if [ -z "$EMAIL" ]; then
                    echo_error "Email is required for SSL/TLS setup."
                  else
                    echo "You entered: $EMAIL"
                    read -p "Is this correct? (Y/n): " yn < /dev/tty
                    case $yn in
                        "" | [Yy]* ) 
                            validate_email
                            break
                            ;;
                        [Nn]* ) 
                            echo "Let's try again."
                            EMAIL=""
                            ;;
                        * ) 
                            echo "Please answer y or n.";;
                    esac
                  fi
                done
              fi
              break
              ;;
          No ) 
              ENABLE_HTTPS=false
              break
              ;;
          * ) echo "Please select 1 or 2.";;
      esac
    done
  else
    EMAIL=""
    ENABLE_HTTPS=false
  fi
}

# Function to install OpenGovernance
function install_opengovernance() {
  echo_info "Installing OpenGovernance"

  # Add the OpenGovernance Helm repository and update
  if ! helm repo list | grep -qw opengovernance; then
    helm repo add opengovernance https://opengovern.github.io/charts
    echo_info "Added OpenGovernance Helm repository."
  else
    echo_info "OpenGovernance Helm repository already exists. Skipping add."
  fi
  helm repo update

  # Install OpenGovernance
  echo_info "Note: The Helm installation can take 5-7 minutes to complete. Please be patient."

  if [ "$DRY_RUN" = true ]; then
    helm install -n opengovernance opengovernance \
      opengovernance/opengovernance --create-namespace --timeout=10m \
      --dry-run \
      -f - <<EOF
global:
  domain: ${DOMAIN}
dex:
  config:
    issuer: ${ENABLE_HTTPS:+https://${DOMAIN}/dex}${ENABLE_HTTPS:-http://${DOMAIN}/dex}
EOF
  else
    helm install -n opengovernance opengovernance \
      opengovernance/opengovernance --create-namespace --timeout=10m \
      -f - <<EOF
global:
  domain: ${DOMAIN}
dex:
  config:
    issuer: ${ENABLE_HTTPS:+https://${DOMAIN}/dex}${ENABLE_HTTPS:-http://${DOMAIN}/dex}
EOF
  fi

  echo_info "OpenGovernance application installation completed."
}

# Function to run installation logic
function run_installation_logic() {
  # Check if app is installed
  if ! check_opengovernance_installation; then
    # App is not installed, proceed to install
    echo_info "OpenGovernance is not installed."
    configure_email_and_domain
    install_opengovernance
  fi

  # Check if OpenGovernance is ready
  if ! check_opengovernance_readiness; then
    echo_error "OpenGovernance is not ready."
    exit 1
  fi

  # Check OpenGovernance configuration
  check_opengovernance_config

  # Determine if app is considered complete
  if [ "$custom_host_name" == "true" ] && [ "$ssl_configured" == "true" ]; then
    echo_info "OpenGovernance is fully configured with custom hostname and SSL/TLS."
  else
    # Ask the user what they want to do
    echo ""
    echo "OpenGovernance is installed but not fully configured."
    echo "Please select an option to proceed:"
    PS3="Enter the number corresponding to your choice: "
    options=("Set up Custom Hostname" "Set up Custom Hostname + SSL" "Exit")
    select opt in "${options[@]}"; do
      case $REPLY in
        1)
          ENABLE_HTTPS=false
          configure_email_and_domain
          update_opengovernance_configuration
          break
          ;;
        2)
          ENABLE_HTTPS=true
          configure_email_and_domain
          update_opengovernance_configuration
          break
          ;;
        3)
          echo_info "Exiting the script."
          exit 0
          ;;
        *)
          echo "Invalid option. Please enter 1, 2, or 3."
          ;;
      esac
    done
  fi
}

# Function to update OpenGovernance configuration
function update_opengovernance_configuration() {
  echo_info "Updating OpenGovernance configuration with custom hostname and SSL settings."

  # Proceed to set up Ingress Controller and related resources
  setup_ingress_controller

  if [ "$ENABLE_HTTPS" = true ]; then
    setup_cert_manager_and_issuer
  fi

  deploy_ingress_resources

  # Perform Helm upgrade with new configuration
  perform_helm_upgrade

  # Restart relevant pods
  restart_pods

  # Re-check OpenGovernance configuration
  check_opengovernance_config

  # Check if SSL/TLS is configured
  if [ "$ssl_configured" == "true" ]; then
    echo_info "OpenGovernance is now configured with custom hostname and SSL/TLS."
  else
    echo_error "Failed to configure SSL/TLS."
    exit 1
  fi
}

# Function to install NGINX Ingress Controller and get External IP
function setup_ingress_controller() {
  echo_info "Installing NGINX Ingress Controller and Retrieving External IP"

  # Install NGINX Ingress Controller if not already installed
  if helm list -n opengovernance | grep -qw ingress-nginx; then
    echo_info "NGINX Ingress Controller is already installed. Skipping installation."
  else
    if ! helm repo list | grep -qw ingress-nginx; then
      helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
      echo_info "Added ingress-nginx Helm repository."
    else
      echo_info "Ingress-nginx Helm repository already exists. Skipping add."
    fi

    helm repo update

    echo_info "Installing NGINX Ingress Controller in 'opengovernance' namespace."
    if [ "$DRY_RUN" = true ]; then
      helm install ingress-nginx ingress-nginx/ingress-nginx \
        --namespace opengovernance \
        --create-namespace \
        --set controller.replicaCount=2 \
        --set controller.resources.requests.cpu=100m \
        --set controller.resources.requests.memory=90Mi \
        --dry-run
    else
      helm install ingress-nginx ingress-nginx/ingress-nginx \
        --namespace opengovernance \
        --create-namespace \
        --set controller.replicaCount=2 \
        --set controller.resources.requests.cpu=100m \
        --set controller.resources.requests.memory=90Mi
    fi
  fi

  echo_info "Waiting for Ingress Controller to obtain an external IP (2-6 minutes)..."
  START_TIME=$(date +%s)
  TIMEOUT=360  # 6 minutes

  while true; do
    INGRESS_EXTERNAL_IP=$(kubectl get svc ingress-nginx-controller -n opengovernance -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    if [ -n "$INGRESS_EXTERNAL_IP" ]; then
      echo "Ingress Controller External IP: $INGRESS_EXTERNAL_IP"
      break
    fi
    CURRENT_TIME=$(date +%s)
    ELAPSED_TIME=$((CURRENT_TIME - START_TIME))
    if [ $ELAPSED_TIME -ge $TIMEOUT ]; then
      echo_error "Error: Ingress Controller External IP not assigned within timeout period."
      exit 1
    fi
    echo "Waiting for EXTERNAL-IP assignment..."
    sleep 15
  done

  # Export the external IP for later use
  export INGRESS_EXTERNAL_IP
}

# Function to set up cert-manager and Let's Encrypt Issuer
function setup_cert_manager_and_issuer() {
  echo_info "Setting up cert-manager and Let's Encrypt Issuer"

  # Check if cert-manager is installed in any namespace
  if helm list --all-namespaces | grep -qw cert-manager; then
    echo_info "cert-manager is already installed in the cluster. Skipping installation."
  else
    # Add Jetstack Helm repository if not already added
    if ! helm repo list | grep -qw jetstack; then
      helm repo add jetstack https://charts.jetstack.io
      echo_info "Added Jetstack Helm repository."
    else
      echo_info "Jetstack Helm repository already exists. Skipping add."
    fi

    helm repo update

    # Install cert-manager in the 'cert-manager' namespace
    echo_info "Installing cert-manager in the 'cert-manager' namespace."
    if [ "$DRY_RUN" = true ]; then
      helm install cert-manager jetstack/cert-manager \
        --namespace cert-manager \
        --create-namespace \
        --set installCRDs=true \
        --set prometheus.enabled=false \
        --dry-run
    else
      helm install cert-manager jetstack/cert-manager \
        --namespace cert-manager \
        --create-namespace \
        --set installCRDs=true \
        --set prometheus.enabled=false
    fi

    echo_info "Waiting for cert-manager pods to be ready..."
    if ! kubectl wait --for=condition=ready pod --all --namespace cert-manager --timeout=120s; then
      echo_error "cert-manager pods did not become ready in time."
      exit 1
    fi
  fi

  # Check if the Let's Encrypt Issuer already exists in 'opengovernance' namespace
  if kubectl get issuer letsencrypt-nginx -n opengovernance > /dev/null 2>&1; then
    echo_info "Issuer 'letsencrypt-nginx' already exists in 'opengovernance' namespace. Skipping creation."
  else
    # Create the Let's Encrypt Issuer in the 'opengovernance' namespace
    echo_info "Creating Let's Encrypt Issuer in 'opengovernance' namespace."
    if [ "$DRY_RUN" = true ]; then
      kubectl apply -f - <<EOF --dry-run=client
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: letsencrypt-nginx
  namespace: opengovernance
spec:
  acme:
    email: ${EMAIL}
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-nginx-private-key
    solvers:
      - http01:
          ingress:
            class: nginx
EOF
    else
      kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: letsencrypt-nginx
  namespace: opengovernance
spec:
  acme:
    email: ${EMAIL}
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-nginx-private-key
    solvers:
      - http01:
          ingress:
            class: nginx
EOF
    fi

    echo_info "Waiting for Issuer to be ready (up to 6 minutes)..."
    if ! kubectl wait --namespace opengovernance \
      --for=condition=Ready issuer/letsencrypt-nginx \
      --timeout=360s; then
      echo_error "Issuer 'letsencrypt-nginx' did not become ready in time."
      exit 1
    fi
  fi
}

# Function to deploy Ingress Resources
function deploy_ingress_resources() {
  echo_info "Deploying Ingress Resources"

  # Define desired Ingress configuration based on the installation case
  if [ "$ENABLE_HTTPS" = true ]; then
    # Custom Domain with HTTPS
    DESIRED_INGRESS=$(cat <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: opengovernance-ingress
  namespace: opengovernance
  annotations:
    cert-manager.io/issuer: letsencrypt-nginx
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  tls:
    - hosts:
        - ${DOMAIN}
      secretName: letsencrypt-nginx
  ingressClassName: nginx
  rules:
    - host: ${DOMAIN}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: nginx-proxy
                port:
                  number: 80
EOF
)
  elif [ -n "$DOMAIN" ]; then
    # Custom Domain without HTTPS
    DESIRED_INGRESS=$(cat <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: opengovernance-ingress
  namespace: opengovernance
spec:
  ingressClassName: nginx
  rules:
    - host: ${DOMAIN}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: nginx-proxy
                port:
                  number: 80
EOF
)
  else
    # No Custom Domain, use external IP, no host field
    DESIRED_INGRESS=$(cat <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: opengovernance-ingress
  namespace: opengovernance
spec:
  ingressClassName: nginx
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: nginx-proxy
                port:
                  number: 80
EOF
)
  fi

  # Apply the Ingress configuration
  echo_info "Applying Ingress configuration."
  if [ "$DRY_RUN" = true ]; then
    echo "$DESIRED_INGRESS" | kubectl apply -f - --dry-run=client
  else
    echo "$DESIRED_INGRESS" | kubectl apply -f -
  fi
  echo_info "Ingress 'opengovernance-ingress' has been applied."
}

# Function to perform Helm upgrade
function perform_helm_upgrade() {
  echo_info "Performing Helm Upgrade with new configuration"

  if [ -z "$DOMAIN" ]; then
    echo_error "Error: DOMAIN is not set."
    exit 1
  fi

  echo_info "Upgrading OpenGovernance Helm release with domain: $DOMAIN"

  if [ "$DRY_RUN" = true ]; then
    helm upgrade -n opengovernance opengovernance opengovernance/opengovernance --timeout=10m --dry-run -f - <<EOF
global:
  domain: "${DOMAIN}"
  debugMode: true
dex:
  config:
    issuer: "${ENABLE_HTTPS:+https://${DOMAIN}/dex}${ENABLE_HTTPS:-http://${DOMAIN}/dex}"
EOF
  else
    helm upgrade -n opengovernance opengovernance opengovernance/opengovernance --timeout=10m -f - <<EOF
global:
  domain: "${DOMAIN}"
  debugMode: true
dex:
  config:
    issuer: "${ENABLE_HTTPS:+https://${DOMAIN}/dex}${ENABLE_HTTPS:-http://${DOMAIN}/dex}"
EOF
  fi

  echo_info "Helm upgrade completed successfully."
}

# Function to restart relevant pods
function restart_pods() {
  echo_info "Restarting Relevant Pods"

  if kubectl get pods -n opengovernance -l app=nginx-proxy | grep -qw nginx-proxy; then
    kubectl delete pods -l app=nginx-proxy -n opengovernance
    echo_info "nginx-proxy pods have been restarted."
  else
    echo_info "No nginx-proxy pods found to restart."
  fi

  if kubectl get pods -n opengovernance -l app.kubernetes.io/name=dex | grep -qw dex; then
    kubectl delete pods -l app.kubernetes.io/name=dex -n opengovernance
    echo_info "dex pods have been restarted."
  else
    echo_info "No dex pods found to restart."
  fi
}

# -----------------------------
# Main Execution Flow
# -----------------------------

parse_args "$@"
check_prerequisites
run_installation_logic
