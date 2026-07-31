#!/usr/bin/env bash
set -e

echo "==================================================="
echo "     Welcome to Cympho Installation Script!        "
echo "==================================================="

# Helper function to run commands as root whether we have sudo or are root
run_as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif command -v sudo &> /dev/null; then
        sudo "$@"
    else
        echo "Error: Need root privileges and sudo is not installed."
        exit 1
    fi
}

# 1. Ask for installation type
echo "Are you installing this for Local Development or Production VPS?"
select INST_TYPE in "Local" "Production"; do
    case $INST_TYPE in
        Local ) IS_PROD=0; break;;
        Production ) IS_PROD=1; break;;
    esac
done

DOMAIN=""
if [ "$IS_PROD" -eq 1 ]; then
    read -p "Enter your Domain or Subdomain (e.g., cympho.example.com): " DOMAIN

    if [[ ! "$DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
        echo "Error: Enter a bare hostname such as cympho.example.com (no scheme or path)."
        exit 1
    fi
fi

echo ""
echo "--- Onboarding Details ---"
read -p "Admin Email: " ADMIN_EMAIL
read -p "Admin Name: " ADMIN_NAME
read -s -p "Admin Password (min 8 chars): " ADMIN_PASSWORD
echo ""
read -p "Company Name: " COMPANY_NAME
read -p "Company Issue Prefix (e.g., CYM): " ISSUE_PREFIX

if [ -z "$ISSUE_PREFIX" ]; then
  ISSUE_PREFIX="CYM"
fi

ISSUE_PREFIX=$(printf '%s' "$ISSUE_PREFIX" | tr '[:lower:]' '[:upper:]')
if [[ ! "$ISSUE_PREFIX" =~ ^[A-Z][A-Z0-9]{1,9}$ ]]; then
    echo "Error: Issue prefix must be 2-10 uppercase letters or numbers and start with a letter."
    exit 1
fi

# 2. Detect OS and Machine architecture
OS="$(uname -s)"
ARCH="$(uname -m)"
case "${OS}" in
    Linux*)     MACHINE=Linux;;
    Darwin*)    MACHINE=Mac;;
    *)          MACHINE="UNKNOWN:${OS}"
esac

echo -e "\nDetected OS: $MACHINE ($ARCH)"

# 3. Check Repo
if [ ! -f "mix.exs" ]; then
    echo "Warning: mix.exs not found. You must run this script from inside the Cympho project directory."
    read -p "Enter GitHub repo URL to clone, or press Ctrl+C to abort: " REPO_URL
    if [ ! -z "$REPO_URL" ]; then
        git clone "$REPO_URL" cympho_app
        cd cympho_app
    else
        exit 1
    fi
fi

# 4. Check and install base tools on empty VPS
if [ "$MACHINE" == "Mac" ]; then
    if ! command -v brew &> /dev/null; then
        echo "Homebrew not found. Please install it first: https://brew.sh/"
        exit 1
    fi
    echo "Installing dependencies for Mac via Homebrew..."
    brew install postgresql@14 asdf node || true
    brew services start postgresql@14 || true
    if [ "$IS_PROD" -eq 1 ]; then
        brew install caddy || true
    fi

elif [ "$MACHINE" == "Linux" ]; then
    echo "Installing core dependencies for Ubuntu/Linux..."
    
    # Update and install basic tools
    run_as_root apt-get update -y
    run_as_root apt-get install -y curl git unzip wget software-properties-common apt-transport-https build-essential libssl-dev automake autoconf libncurses5-dev
    
    # Install Node.js (needed for assets)
    if ! command -v node &> /dev/null; then
        echo "Installing Node.js..."
        curl -fsSL https://deb.nodesource.com/setup_20.x | run_as_root bash -
        run_as_root apt-get install -y nodejs
    fi

    # Install PostgreSQL
    if ! command -v psql &> /dev/null; then
        echo "Installing PostgreSQL..."
        run_as_root apt-get install -y postgresql postgresql-contrib
        run_as_root systemctl start postgresql
        run_as_root systemctl enable postgresql
    fi

    # Configure UFW firewall if present
    if command -v ufw &> /dev/null && [ "$IS_PROD" -eq 1 ]; then
        echo "Configuring firewall for web traffic..."
        run_as_root ufw allow 80/tcp
        run_as_root ufw allow 443/tcp
    fi
    
    # Asdf installation if missing
    if [ ! -d "$HOME/.asdf" ]; then
        echo "Installing asdf..."
        git clone https://github.com/asdf-vm/asdf.git ~/.asdf --branch v0.14.0
        echo -e '\n. $HOME/.asdf/asdf.sh' >> ~/.bashrc
        echo -e '\n. $HOME/.asdf/completions/asdf.bash' >> ~/.bashrc
    fi

    # Install Caddy for reverse proxy and SSL if Production
    if [ "$IS_PROD" -eq 1 ]; then
        if ! command -v caddy &> /dev/null; then
            echo "Installing Caddy..."
            run_as_root apt-get install -y debian-keyring debian-archive-keyring apt-transport-https
            curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | run_as_root gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg --yes
            curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | run_as_root tee /etc/apt/sources.list.d/caddy-stable.list
            run_as_root apt-get update -y
            run_as_root apt-get install -y caddy
        fi
    fi
fi

# Ensure asdf is available in the current shell
if [ -f "$HOME/.asdf/asdf.sh" ]; then
    source "$HOME/.asdf/asdf.sh"
fi

# 5. Install Erlang and Elixir based on .tool-versions
if command -v asdf &> /dev/null; then
    echo "Installing Erlang and Elixir plugins via asdf..."
    asdf plugin add erlang || true
    asdf plugin add elixir || true
    echo "Running asdf install to install required versions..."
    asdf install
else
    echo "WARNING: asdf not found. Please ensure Elixir and Erlang are installed manually."
fi

# 6. Database and Secrets setup
ENV_FILE=".env"
export MIX_ENV="dev"

# Generate DB Password for Production
DB_PASS="postgres"
if [ "$IS_PROD" -eq 1 ]; then
    export MIX_ENV="prod"
    # Generate random DB password for security
    DB_PASS=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 20)
    
    if [ "$MACHINE" == "Linux" ]; then
        echo "Configuring PostgreSQL user for production..."
        # Create a database user with the generated password
        run_as_root -u postgres psql -c "CREATE USER cympho_user WITH PASSWORD '$DB_PASS' CREATEDB;" || true
        run_as_root -u postgres psql -c "ALTER USER cympho_user WITH PASSWORD '$DB_PASS';" || true
    fi

    echo "Generating production secrets..."
    mix local.hex --force
    mix local.rebar --force
    mix deps.get

    # Generate secrets if they don't exist
    if [ ! -f "$ENV_FILE" ]; then
        SECRET_KEY_BASE=$(mix phx.gen.secret)
        CYMPHO_ENCRYPTION_KEY=$(mix phx.gen.secret 32)
        CYMPHO_USER_JWT_SECRET=$(mix phx.gen.secret)
        CYMPHO_AGENT_JWT_SECRET=$(mix phx.gen.secret)
        LIVE_VIEW_SALT=$(mix phx.gen.secret 16)
        
        cat <<EOF > "$ENV_FILE"
MIX_ENV=prod
PORT=4000
APP_HOST=$DOMAIN
SECRET_KEY_BASE=$SECRET_KEY_BASE
LIVE_VIEW_SALT=$LIVE_VIEW_SALT
CYMPHO_ENCRYPTION_KEY=$CYMPHO_ENCRYPTION_KEY
CYMPHO_USER_JWT_SECRET=$CYMPHO_USER_JWT_SECRET
CYMPHO_AGENT_JWT_SECRET=$CYMPHO_AGENT_JWT_SECRET
DATABASE_URL=ecto://cympho_user:$DB_PASS@localhost/cympho_prod
EOF
    fi
    chmod 600 "$ENV_FILE"
    set -a
    source "$ENV_FILE"
    set +a
else
    mix local.hex --force
    mix local.rebar --force
    mix deps.get
fi

# 7. Setup Project Dependencies and Database
echo "Setting up Mix dependencies and database for $MIX_ENV environment..."
mix setup

# 8. Seed the Admin User and Company
echo "Seeding the admin user and company..."
export CYMPHO_INSTALL_ADMIN_EMAIL="$ADMIN_EMAIL"
export CYMPHO_INSTALL_ADMIN_NAME="$ADMIN_NAME"
export CYMPHO_INSTALL_ADMIN_PASSWORD="$ADMIN_PASSWORD"
export CYMPHO_INSTALL_COMPANY_NAME="$COMPANY_NAME"
export CYMPHO_INSTALL_ISSUE_PREFIX="$ISSUE_PREFIX"

cat <<'EOF' > seed_admin.exs
alias Cympho.Repo
alias Cympho.Companies
alias Cympho.Users.User

admin_email = System.fetch_env!("CYMPHO_INSTALL_ADMIN_EMAIL")
admin_name = System.fetch_env!("CYMPHO_INSTALL_ADMIN_NAME")
admin_password = System.fetch_env!("CYMPHO_INSTALL_ADMIN_PASSWORD")
company_name = System.fetch_env!("CYMPHO_INSTALL_COMPANY_NAME")
issue_prefix = System.fetch_env!("CYMPHO_INSTALL_ISSUE_PREFIX")

# Check if the company already exists or create a new autonomous one
company = case Repo.get_by(Companies.Company, name: company_name) do
  nil ->
    {:ok, %{company: company}} = Companies.create_autonomous_company(%{
      name: company_name,
      goal_title: "Initial Company Goal",
      issue_prefix: issue_prefix,
      engineer_count: 1,
      adapter: :claude_code
    })
    company
  c -> c
end

user_attrs = %{
  email: admin_email,
  name: admin_name,
  password: admin_password,
  company_id: company.id
}

# Create or Update the admin user
case Repo.get_by(User, email: admin_email) do
  nil ->
    %User{}
    |> User.registration_changeset(user_attrs)
    |> Repo.insert()
    |> case do
      {:ok, _user} -> 
        IO.puts("Admin user created successfully!")
      {:error, changeset} -> 
        IO.puts("Failed to create admin user:")
        IO.inspect(changeset.errors)
    end
  _user ->
    IO.puts("Admin user with this email already exists.")
end
EOF

mix run seed_admin.exs
rm seed_admin.exs
unset CYMPHO_INSTALL_ADMIN_EMAIL CYMPHO_INSTALL_ADMIN_NAME CYMPHO_INSTALL_ADMIN_PASSWORD
unset CYMPHO_INSTALL_COMPANY_NAME CYMPHO_INSTALL_ISSUE_PREFIX

# If production, optionally build assets and release
if [ "$IS_PROD" -eq 1 ]; then
    echo "Building assets for production..."
    mix assets.deploy || echo "Warning: assets.deploy failed, you may need to run it manually."
fi

# 9. Setup Production Services (Systemd + Caddy)
if [ "$IS_PROD" -eq 1 ] && [ "$MACHINE" == "Linux" ]; then
    echo "Setting up Caddy reverse proxy for $DOMAIN..."
    CADDYFILE="/etc/caddy/Caddyfile"
    run_as_root tee $CADDYFILE > /dev/null <<EOF
$DOMAIN {
    reverse_proxy localhost:4000
}
EOF
    run_as_root systemctl restart caddy
    run_as_root systemctl enable caddy
    
    echo "Setting up Systemd service for Cympho..."
    SERVICE_FILE="/etc/systemd/system/cympho.service"
    APP_DIR=$(pwd)
    USER=$(whoami)
    ASDF_DIR="$HOME/.asdf"
    
    run_as_root tee $SERVICE_FILE > /dev/null <<EOF
[Unit]
Description=Cympho Phoenix Application
After=network.target postgresql.service caddy.service

[Service]
Type=simple
User=$USER
WorkingDirectory=$APP_DIR
Environment="PATH=$ASDF_DIR/shims:$ASDF_DIR/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=/bin/bash -lc 'set -a; source "$APP_DIR/.env"; source "$ASDF_DIR/asdf.sh"; set +a; exec mix phx.server'
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

    run_as_root systemctl daemon-reload
    run_as_root systemctl enable cympho
    run_as_root systemctl restart cympho

    echo "==================================================="
    echo "  Production Installation Complete!                "
    echo "  Your app should now be running at: https://$DOMAIN"
    echo "  Systemd service 'cympho' is running the server.  "
    echo "==================================================="
else
    echo "==================================================="
    echo "  Local Installation Complete!                     "
    echo "  Start the server with: mix phx.server            "
    echo "==================================================="
fi
