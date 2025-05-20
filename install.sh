#!/bin/bash

# Installs the enclave setup and runs it as a service.

user=grail
service_name=grail-pro
image_name=grail-enclave
vsock_proxy_port=8000
aws_region=eu-west-2

if [ "$EUID" -ne 0 ]; then
    echo Please run as root
    exit 1
fi

if [ "$#" != 0 ]; then
    echo "Usage: $0"
    exit 1
fi

if getent passwd "$user" > /dev/null 2>&1; then
    echo "User $user already exists"
    exit 1
fi
if getent group "$user" > /dev/null 2>&1; then
    echo "Group $user already exists"
    exit 1
fi

set -e

echo Installing dependencies...
dnf install aws-nitro-enclaves-cli aws-nitro-enclaves-cli-devel docker git python3.12 -y

echo Starting nitro enclaves allocator service...
systemctl enable --now nitro-enclaves-allocator

echo "Creating enclave user $user..."
useradd --create-home --user-group --shell "$(type -p bash)" -G ne "$user"

echo Building docker image...
systemctl start docker.service
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(git -C "$script_dir" rev-parse --show-toplevel)"
docker build "$repo_dir" -t "$image_name"

echo Building enclave image...
enclave_home_dir="/home/$user"
image_file="$enclave_home_dir/$image_name.eif"
nitro-cli build-enclave --docker-uri "$image_name:latest" --output-file "$image_file"
chmod 444 "$image_file"

echo Building Python virtual environment for the parent server...
parent_package_name=parent-manager
server_dir="$enclave_home_dir/$parent_package_name"
venv_dir="$server_dir/venv"
rsync -a --chown=$user:$user --info=progress2 "$repo_dir/$parent_package_name/" "$server_dir/"
su -c "python3.12 -m venv '$venv_dir'" "$user"
su -c ". '$venv_dir/bin/activate' && pip install '$server_dir'" "$user"

echo "Creating and enabling $service_name service..."

run_script_file="$enclave_home_dir/run.sh"
cat > "$run_script_file" <<EOF
#!/bin/bash
vsock-proxy $vsock_proxy_port kms.$aws_region.amazonaws.com 443 &
nitro-cli run-enclave --cpu-count 2 --memory 512 --enclave-cid 16 --eif-path $image_file  # --debug-mode
. "$venv_dir/bin/activate"
allfather
EOF
chown "$user:$user" "$run_script_file"
chmod 700 "$run_script_file"

cat > "/etc/systemd/system/$service_name.service" <<EOF
[Unit]
Description=Grail Pro Enclave
After=network.target
Requires=network.target

[Service]
Type=simple
User=$user
WorkingDirectory=$enclave_home_dir
PIDFile="/tmp/$service_name.pid"
ExecStart="$run_script_file" &
ExecStop=/bin/sh -c 'start-stop-daemon --quiet --stop --chuid "$user" --pidfile="/tmp/$service_name.pid"'

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "$service_name"

echo "Enclave service $service_name installed and started."
