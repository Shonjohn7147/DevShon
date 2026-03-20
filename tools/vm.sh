#!/bin/bash
set -euo pipefail

# =============================
# Enhanced Multi-VM Manager
# =============================

# Function to display header
display_header() {
    clear
    cat << "EOF"
========================================================================
|               _____                 _                                |
|              |  __ \               | |                               |
|              | |  | | _____   _____| |__   ___  _ __                 |
|              | |  | |/ _ \ \ / / __| '_ \ / _ \| '_ \                |
|              | |__| |  __/\ V /\__ \ | | | (_) | | | |               |
|              |_____/ \___| \_/ |___/_| |_|\___/|_| |_|               |
|                                                                      |
|                           POWERED BY SHON                            |
========================================================================
EOF
    echo
}

# Function to display colored output
print_status() {
    local type=$1
    local message=$2 
    
    case $type in
        "INFO") echo -e "\033[1;34m[INFO]\033[0m $message" ;;
        "WARN") echo -e "\033[1;33m[WARN]\033[0m $message" ;;
        "ERROR") echo -e "\033[1;31m[ERROR]\033[0m $message" ;;
        "SUCCESS") echo -e "\033[1;32m[SUCCESS]\033[0m $message" ;;
        "INPUT") echo -e "\033[1;36m[INPUT]\033[0m $message" ;;
        *) echo "[$type] $message" ;;
    esac
}

# Function to download a file with retries and multiple fallback mirrors
download_with_retry() {
    local target_file=$1
    shift
    local mirrors=("$@")
    local max_retries=2
    
    # Check if target already exists in current VM directory
    if [[ -f "$target_file" ]]; then
        print_status "SUCCESS" "File $(basename "$target_file") already exists. Using cached version."
        return 0
    fi

    # Check for a "global" cache in common locations
    local global_caches=("/root/vms/$(basename "$target_file")" "$HOME/vms/$(basename "$target_file")")
    for cache in "${global_caches[@]}"; do
        if [[ -f "$cache" ]]; then
            # Avoid copying to itself
            if [[ -f "$target_file" ]] && [[ "$target_file" -ef "$cache" ]]; then continue; fi
            
            print_status "INFO" "Found $(basename "$target_file") in cache ($cache). Copying..."
            cp "$cache" "$target_file"
            return 0
        fi
    done

    # Try each mirror
    for url in "${mirrors[@]}"; do
        [[ -z "$url" ]] && continue
        
        print_status "INFO" "Validating mirror: $(echo "$url" | cut -d/ -f3)..."
        if ! wget -q -4 --spider --tries=1 --timeout=5 "$url"; then
            print_status "WARN" "Mirror reachable but returned 404 or timed out. Skipping..."
            continue
        fi

        for ((i=1; i<=max_retries; i++)); do
            print_status "INFO" "Downloading $(basename "$target_file") (Attempt $i/$max_retries)..."
            if wget -U "Mozilla/5.0" -4 --progress=bar:force "$url" -O "$target_file.tmp"; then
                mv "$target_file.tmp" "$target_file"
                print_status "SUCCESS" "Download successful."
                return 0
            fi
            print_status "WARN" "Attempt $i failed."
            sleep 1
        done
    done

    # All mirrors failed - Manual Fallback
    print_status "ERROR" "All download mirrors failed for $(basename "$target_file")."
    echo "------------------------------------------------------------------------"
    print_status "INPUT" "Please provide a local path to the $(basename "$target_file") file,"
    read -p "$(print_status "INPUT" "or press Enter to cancel installation: ")" local_path
    echo "------------------------------------------------------------------------"
    
    if [[ -n "$local_path" ]] && [[ -f "$local_path" ]]; then
        print_status "INFO" "Using provided local file: $local_path"
        cp "$local_path" "$target_file"
        return 0
    fi

    return 1
}

# Function to validate input
validate_input() {
    local type=$1
    local value=$2
    
    case $type in
        "number")
            if ! [[ "$value" =~ ^[0-9]+$ ]]; then
                print_status "ERROR" "Must be a number"
                return 1
            fi
            ;;
        "size")
            if ! [[ "$value" =~ ^[0-9]+[GgMm]$ ]]; then
                print_status "ERROR" "Must be a size with unit (e.g., 100G, 512M)"
                return 1
            fi
            ;;
        "port")
            if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt 23 ] || [ "$value" -gt 65535 ]; then
                print_status "ERROR" "Must be a valid port number (23-65535)"
                return 1
            fi
            ;;
        "name")
            if ! [[ "$value" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                print_status "ERROR" "VM name can only contain letters, numbers, hyphens, and underscores"
                return 1
            fi
            ;;
        "username")
            if ! [[ "$value" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]]; then
                print_status "ERROR" "Username must start with a letter or underscore, and contain only letters, numbers, hyphens, and underscores"
                return 1
            fi
            ;;
    esac
    return 0
}

# Function to check dependencies
check_dependencies() {
    local deps=("qemu-system-x86_64" "wget" "cloud-localds" "qemu-img" "genisoimage")
    local missing_deps=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing_deps+=("$dep")
        fi
    done
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        print_status "ERROR" "Missing dependencies: ${missing_deps[*]}"
        print_status "INFO" "On Ubuntu/Debian, try: sudo apt install qemu-system cloud-image-utils wget"
        exit 1
    fi
}

# Function to cleanup temporary files
cleanup() {
    if [ -f "user-data" ]; then rm -f "user-data"; fi
    if [ -f "meta-data" ]; then rm -f "meta-data"; fi
    if [ -f "autounattend.xml" ]; then rm -f "autounattend.xml"; fi
}

# VirtIO Drivers for Windows (Multiple Mirrors for stability)
VIRTIO_MIRRORS=(
    "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
    "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.262-1/virtio-win.iso"
    "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.248-1/virtio-win.iso"
)

# Function to get all VM configurations
get_vm_list() {
    find "$VM_DIR" -name "*.conf" -exec basename {} .conf \; 2>/dev/null | sort
}

# Function to load VM configuration
load_vm_config() {
    local vm_name=$1
    local config_file="$VM_DIR/$vm_name.conf"
    
    if [[ -f "$config_file" ]]; then
        # Clear previous variables to avoid "unbound variable" errors or stale data
        unset DISK_SIZE MEMORY CPUS SSH_PORT GUI_MODE PORT_FORWARDS IMG_FILE SEED_FILE INSTALL_ISO CREATED
        unset VNC_ENABLED VNC_PORT UNATTEND_ISO VIRTIO_ISO
        
        # Load the configuration
        source "$config_file"
        
        # Set defaults to avoid "unbound variable" crashes
        SSH_PORT="${SSH_PORT:-2222}"
        VNC_ENABLED="${VNC_ENABLED:-false}"
        VNC_PORT="${VNC_PORT:-5901}"
        GUI_MODE="${GUI_MODE:-false}"
        MEMORY="${MEMORY:-2048}"
        CPUS="${CPUS:-2}"
        DISK_SIZE="${DISK_SIZE:-20G}"
        USERNAME="${USERNAME:-admin}"
        PASSWORD="${PASSWORD:-password}"
        OS_TYPE="${OS_TYPE:-ubuntu}"
        UNATTEND_ISO="${UNATTEND_ISO:-}"
        VIRTIO_ISO="${VIRTIO_ISO:-}"
        IMG_FILE="${IMG_FILE:-$VM_DIR/$vm_name.qcow2}"
        SEED_FILE="${SEED_FILE:-$VM_DIR/$vm_name-seed.img}"
        INSTALL_ISO="${INSTALL_ISO:-}"
        return 0
    else
        print_status "ERROR" "Configuration for VM '$vm_name' not found"
        return 1
    fi
}

# Function to generate autounattend.xml for Windows
generate_windows_unattend() {
    cat > autounattend.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="windowsPE">
        <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WCM/2004/xml" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <DiskConfiguration>
                <Disk wcm:action="add">
                    <CreatePartitions>
                        <CreatePartition wcm:action="add">
                            <Order>1</Order>
                            <Type>Primary</Type>
                            <Extend>true</Extend>
                        </CreatePartition>
                    </CreatePartitions>
                    <ModifyPartitions>
                        <ModifyPartition wcm:action="add">
                            <Active>true</Active>
                            <Format>NTFS</Format>
                            <Label>Windows</Label>
                            <Order>1</Order>
                            <PartitionID>1</PartitionID>
                        </ModifyPartition>
                    </ModifyPartitions>
                    <DiskID>0</DiskID>
                    <WillShowUI>OnError</WillShowUI>
                </Disk>
            </DiskConfiguration>
            <UserData>
                <AcceptEula>true</AcceptEula>
                <FullName>$USERNAME</FullName>
                <Organization>Home</Organization>
            </UserData>
            <ImageInstall>
                <OSImage>
                    <InstallTo>
                        <DiskID>0</DiskID>
                        <PartitionID>1</PartitionID>
                    </InstallTo>
                </OSImage>
            </ImageInstall>
            <RunSynchronous>
                <!-- Bypass Windows 11 Requirements -->
                <RunSynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <Path>reg add "HKLM\SYSTEM\Setup\LabConfig" /v "BypassTPMCheck" /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>2</Order>
                    <Path>reg add "HKLM\SYSTEM\Setup\LabConfig" /v "BypassSecureBootCheck" /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>3</Order>
                    <Path>reg add "HKLM\SYSTEM\Setup\LabConfig" /v "BypassRAMCheck" /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
            </RunSynchronous>
        </component>
        <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WCM/2004/xml" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <SetupUILanguage>
                <UILanguage>en-US</UILanguage>
            </SetupUILanguage>
            <InputLocale>en-US</InputLocale>
            <SystemLocale>en-US</SystemLocale>
            <UILanguage>en-US</UILanguage>
            <UserLocale>en-US</UserLocale>
        </component>
    </settings>
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WCM/2004/xml" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <AutoLogon>
                <Password>
                    <Value>$PASSWORD</Value>
                    <PlainText>true</PlainText>
                </Password>
                <Enabled>true</Enabled>
                <Username>$USERNAME</Username>
            </AutoLogon>
            <UserAccounts>
                <LocalAccounts>
                    <LocalAccount wcm:action="add">
                        <Password>
                            <Value>$PASSWORD</Value>
                            <PlainText>true</PlainText>
                        </Password>
                        <Description>Local Administrator</Description>
                        <DisplayName>$USERNAME</DisplayName>
                        <Group>Administrators</Group>
                        <Name>$USERNAME</Name>
                    </LocalAccount>
                </LocalAccounts>
            </UserAccounts>
            <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <HideLocalAccountScreen>true</HideLocalAccountScreen>
                <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <NetworkLocation>Work</NetworkLocation>
                <ProtectYourPC>3</ProtectYourPC>
            </OOBE>
            <TimeZone>UTC</TimeZone>
        </component>
    </settings>
</unattend>
EOF
}

# Function to save VM configuration
save_vm_config() {
    local config_file="$VM_DIR/$VM_NAME.conf"
    
    cat > "$config_file" <<EOF
VM_NAME="$VM_NAME"
OS_TYPE="$OS_TYPE"
CODENAME="$CODENAME"
IMG_URL="$IMG_URL"
HOSTNAME="$HOSTNAME"
USERNAME="$USERNAME"
PASSWORD="$PASSWORD"
DISK_SIZE="$DISK_SIZE"
MEMORY="$MEMORY"
CPUS="$CPUS"
SSH_PORT="$SSH_PORT"
GUI_MODE="$GUI_MODE"
VNC_ENABLED="$VNC_ENABLED"
VNC_PORT="$VNC_PORT"
PORT_FORWARDS="$PORT_FORWARDS"
IMG_FILE="$IMG_FILE"
SEED_FILE="$SEED_FILE"
INSTALL_ISO="$INSTALL_ISO"
UNATTEND_ISO="$UNATTEND_ISO"
VIRTIO_ISO="$VIRTIO_ISO"
CREATED="$CREATED"
EOF
    
    print_status "SUCCESS" "Configuration saved to $config_file"
}

# Function to create new VM
create_new_vm() {
    print_status "INFO" "Creating a new VM"
    
    # Initialize all config variables to avoid "unbound variable" errors
    local VM_NAME="" HOSTNAME="" USERNAME="" PASSWORD="" DISK_SIZE="" MEMORY="" CPUS=""
    local SSH_PORT="" GUI_MODE=false VNC_ENABLED=false VNC_PORT="5901"
    local PORT_FORWARDS="" OS_TYPE="" CODENAME="" IMG_URL=""
    local IMG_FILE="" SEED_FILE="" INSTALL_ISO="" UNATTEND_ISO="" VIRTIO_ISO=""
    local CREATED=""
    
    # OS Selection
    print_status "INFO" "Select an OS to set up:"
    local os_options=()
    local i=1
    for os in "${!OS_OPTIONS[@]}"; do
        echo "  $i) $os"
        os_options[$i]="$os"
        ((i++))
    done
    
    while true; do
        read -p "$(print_status "INPUT" "Enter your choice (1-${#OS_OPTIONS[@]}): ")" choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#OS_OPTIONS[@]} ]; then
            local os="${os_options[$choice]}"
            IFS='|' read -r OS_TYPE CODENAME IMG_URL DEFAULT_HOSTNAME DEFAULT_USERNAME DEFAULT_PASSWORD <<< "${OS_OPTIONS[$os]}"
            break
        else
            print_status "ERROR" "Invalid selection. Try again."
        fi
    done

    # Custom Inputs with validation
    while true; do
        read -p "$(print_status "INPUT" "Enter VM name (default: $DEFAULT_HOSTNAME): ")" VM_NAME
        VM_NAME="${VM_NAME:-$DEFAULT_HOSTNAME}"
        if validate_input "name" "$VM_NAME"; then
            # Check if VM name already exists
            if [[ -f "$VM_DIR/$VM_NAME.conf" ]]; then
                print_status "ERROR" "VM with name '$VM_NAME' already exists"
            else
                break
            fi
        fi
    done

    while true; do
        read -p "$(print_status "INPUT" "Enter hostname (default: $VM_NAME): ")" HOSTNAME
        HOSTNAME="${HOSTNAME:-$VM_NAME}"
        if validate_input "name" "$HOSTNAME"; then
            break
        fi
    done

    while true; do
        read -p "$(print_status "INPUT" "Enter username (default: $DEFAULT_USERNAME): ")" USERNAME
        USERNAME="${USERNAME:-$DEFAULT_USERNAME}"
        if validate_input "username" "$USERNAME"; then
            break
        fi
    done

    while true; do
        read -s -p "$(print_status "INPUT" "Enter password (default: $DEFAULT_PASSWORD): ")" PASSWORD
        PASSWORD="${PASSWORD:-$DEFAULT_PASSWORD}"
        echo
        if [ -n "$PASSWORD" ]; then
            break
        else
            print_status "ERROR" "Password cannot be empty"
        fi
    done

    while true; do
        read -p "$(print_status "INPUT" "Disk size (default: 20G): ")" DISK_SIZE
        DISK_SIZE="${DISK_SIZE:-20G}"
        if validate_input "size" "$DISK_SIZE"; then
            break
        fi
    done

    while true; do
        read -p "$(print_status "INPUT" "Memory in MB (default: 2048): ")" MEMORY
        MEMORY="${MEMORY:-2048}"
        if validate_input "number" "$MEMORY"; then
            break
        fi
    done

    while true; do
        read -p "$(print_status "INPUT" "Number of CPUs (default: 2): ")" CPUS
        CPUS="${CPUS:-2}"
        if validate_input "number" "$CPUS"; then
            break
        fi
    done

    while true; do
        read -p "$(print_status "INPUT" "SSH Port (default: 2222): ")" SSH_PORT
        SSH_PORT="${SSH_PORT:-2222}"
        if validate_input "port" "$SSH_PORT"; then
            # Check if port is already in use
            if ss -tln 2>/dev/null | grep -q ":$SSH_PORT "; then
                print_status "ERROR" "Port $SSH_PORT is already in use"
            else
                break
            fi
        fi
    done

    if [[ "$OS_TYPE" == "windows" ]]; then
        print_status "INFO" "Windows requires GUI mode for installation. Forcing GUI mode enabled."
        GUI_MODE=true
    else
        while true; do
            read -p "$(print_status "INPUT" "Enable GUI mode? (y/n, default: n): ")" gui_input
            GUI_MODE=false
            gui_input="${gui_input:-n}"
            if [[ "$gui_input" =~ ^[Yy]$ ]]; then 
                GUI_MODE=true
                break
            elif [[ "$gui_input" =~ ^[Nn]$ ]]; then
                break
            else
                print_status "ERROR" "Please answer y or n"
            fi
        done
    fi

    # Remote Access Options
    while true; do
        read -p "$(print_status "INPUT" "Enable VNC access? (y/n, default: n): ")" vnc_input
        VNC_ENABLED=false
        vnc_input="${vnc_input:-n}"
        if [[ "$vnc_input" =~ ^[Yy]$ ]]; then 
            VNC_ENABLED=true
            read -p "$(print_status "INPUT" "VNC Port (default: 5901): ")" VNC_PORT
            VNC_PORT="${VNC_PORT:-5901}"
            break
        elif [[ "$vnc_input" =~ ^[Nn]$ ]]; then
            break
        else
            print_status "ERROR" "Please answer y or n"
        fi
    done

    # Additional network options
    read -p "$(print_status "INPUT" "Additional port forwards (e.g., 8080:80, press Enter for none): ")" PORT_FORWARDS

    IMG_FILE="$VM_DIR/$VM_NAME.img"
    SEED_FILE="$VM_DIR/$VM_NAME-seed.iso"
    if [[ "$OS_TYPE" == "windows" ]]; then
        INSTALL_ISO="$VM_DIR/${OS_TYPE}_${CODENAME}.iso"
        UNATTEND_ISO="$VM_DIR/$VM_NAME-unattend.iso"
        VIRTIO_ISO="$VM_DIR/virtio-win.iso"
    else
        INSTALL_ISO=""
        UNATTEND_ISO=""
        VIRTIO_ISO=""
    fi
    CREATED="$(date)"

    # Download and setup VM image
    setup_vm_image
    
    # Save configuration
    save_vm_config
}

setup_vm_image() {
    print_status "INFO" "Downloading and preparing image..."
    
    # Create VM directory if it doesn't exist
    mkdir -p "$VM_DIR"
    
    if [[ "$OS_TYPE" == "windows" ]]; then
        # Download Windows ISO
        if [[ ! -f "$INSTALL_ISO" ]]; then
            download_with_retry "$INSTALL_ISO" "$IMG_URL" || exit 1
        fi
        
        # Download VirtIO ISO
        if [[ ! -f "$VIRTIO_ISO" ]]; then
            download_with_retry "$VIRTIO_ISO" "${VIRTIO_MIRRORS[@]}" || exit 1
        fi

        # Generate Unattend ISO
        print_status "INFO" "Generating unattended installation media..."
        generate_windows_unattend
        if genisoimage -o "$UNATTEND_ISO" -J -R -V "UNATTEND" autounattend.xml; then
            print_status "SUCCESS" "Unattended ISO created: $UNATTEND_ISO"
            rm -f autounattend.xml
        else
            print_status "ERROR" "Failed to create unattended ISO"
            exit 1
        fi
        
        if [[ ! -f "$IMG_FILE" ]]; then
            print_status "INFO" "Creating new blank disk image for Windows..."
            qemu-img create -f qcow2 "$IMG_FILE" "$DISK_SIZE"
        fi
        
        print_status "SUCCESS" "VM '$VM_NAME' created successfully."
        return 0
    fi
    
    # Check if image already exists
    if [[ -f "$IMG_FILE" ]]; then
        print_status "INFO" "Image file already exists. Skipping download."
    else
        download_with_retry "$IMG_FILE" "$IMG_URL" || exit 1
    fi
    
    # Resize the disk image if needed
    if ! qemu-img resize "$IMG_FILE" "$DISK_SIZE" 2>/dev/null; then
        print_status "WARN" "Failed to resize disk image. Creating new image with specified size..."
        # Create a new image with the specified size
        rm -f "$IMG_FILE"
        qemu-img create -f qcow2 -F qcow2 -b "$IMG_FILE" "$IMG_FILE.tmp" "$DISK_SIZE" 2>/dev/null || \
        qemu-img create -f qcow2 "$IMG_FILE" "$DISK_SIZE"
        if [ -f "$IMG_FILE.tmp" ]; then
            mv "$IMG_FILE.tmp" "$IMG_FILE"
        fi
    fi

    # cloud-init configuration
    cat > user-data <<EOF
#cloud-config
hostname: $HOSTNAME
ssh_pwauth: true
disable_root: false
users:
  - name: $USERNAME
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    password: $(openssl passwd -6 "$PASSWORD" | tr -d '\n')
chpasswd:
  list: |
    root:$PASSWORD
    $USERNAME:$PASSWORD
  expire: false
EOF

    cat > meta-data <<EOF
instance-id: iid-$VM_NAME
local-hostname: $HOSTNAME
EOF

    if ! cloud-localds "$SEED_FILE" user-data meta-data; then
        print_status "ERROR" "Failed to create cloud-init seed image"
        exit 1
    fi
    
    print_status "SUCCESS" "VM '$VM_NAME' created successfully."
}

# Function to start a VM
start_vm() {
    local vm_name=$1
    
    if load_vm_config "$vm_name"; then
        print_status "INFO" "Starting VM: $vm_name"
        print_status "INFO" "SSH: ssh -p $SSH_PORT $USERNAME@localhost"
        print_status "INFO" "Password: $PASSWORD"
        
        # Check if image file exists
        if [[ ! -f "$IMG_FILE" ]]; then
            print_status "ERROR" "VM image file not found: $IMG_FILE"
            return 1
        fi
        
        # Check if seed file exists (skip for windows)
        if [[ "$OS_TYPE" != "windows" ]] && [[ ! -f "$SEED_FILE" ]]; then
            print_status "WARN" "Seed file not found, recreating..."
            setup_vm_image
        fi
        
        # Base QEMU command
        local qemu_cmd=(qemu-system-x86_64 -m "$MEMORY" -smp "$CPUS" -audiodev none,id=n1)

        # Check for KVM availability
        local kvm_enabled=false
        if [ -w /dev/kvm ] && grep -qE "vmx|svm" /proc/cpuinfo; then
            print_status "INFO" "KVM acceleration enabled."
            qemu_cmd+=(-enable-kvm -cpu host)
            kvm_enabled=true
        else
            print_status "WARN" "KVM not accessible. Falling back to software emulation (TCG)."
            print_status "WARN" "Note: TCG mode is VERY SLOW. Booting may take several minutes."
            qemu_cmd+=(-cpu max)
        fi

        if [[ "$OS_TYPE" == "windows" ]]; then
            qemu_cmd+=(
                -drive "file=$IMG_FILE,format=qcow2,if=ide"
                -drive "file=$INSTALL_ISO,media=cdrom,readonly=on"
                -boot d
                -device e1000,netdev=n0
                -netdev "user,id=n0,hostfwd=tcp::$SSH_PORT-:22"
            )
            
            # Add unattended and driver ISOs if they exist
            if [[ -f "$UNATTEND_ISO" ]]; then
                qemu_cmd+=(-drive "file=$UNATTEND_ISO,media=cdrom,readonly=on")
            fi
            if [[ -f "$VIRTIO_ISO" ]]; then
                qemu_cmd+=(-drive "file=$VIRTIO_ISO,media=cdrom,readonly=on")
            fi
        else
            qemu_cmd+=(
                -drive "file=$IMG_FILE,format=qcow2,if=virtio"
                -drive "file=$SEED_FILE,format=raw,if=virtio"
                -boot order=c
                -device e1000,netdev=n0
                -netdev "user,id=n0,hostfwd=tcp::$SSH_PORT-:22"
            )
        fi

        # Add port forwards if specified
        if [[ -n "$PORT_FORWARDS" ]]; then
            IFS=',' read -ra forwards <<< "$PORT_FORWARDS"
            for forward in "${forwards[@]}"; do
                IFS=':' read -r host_port guest_port <<< "$forward"
                qemu_cmd+=(-device "e1000,netdev=n${#qemu_cmd[@]}")
                qemu_cmd+=(-netdev "user,id=n${#qemu_cmd[@]},hostfwd=tcp::$host_port-:$guest_port")
            done
        fi

        # Add GUI, VNC, or console mode
        # Only auto-enable VNC if GUI_MODE is true AND VNC was NOT explicitly disabled (it's false by default)
        # However, the user said "avoid vnc", so we should be careful here.
        if [[ "$GUI_MODE" == true ]] && [[ -z "${DISPLAY:-}" ]] && [[ "$VNC_ENABLED" == "auto" ]]; then
            print_status "WARN" "No display detected. Enabling VNC as requested by GUI_MODE..."
            VNC_ENABLED=true
        fi

        if [[ "$VNC_ENABLED" == true ]]; then
            local vnc_display=$((VNC_PORT - 5900))
            qemu_cmd+=(-vnc ":$vnc_display" -display none -serial mon:stdio)
            print_status "SUCCESS" "VNC enabled on port $VNC_PORT (: $vnc_display)"
            print_status "INFO" "Connection: Use a VNC viewer (like RealVNC or TightVNC) to connect to 'localhost:$VNC_PORT'"
            if [[ "$kvm_enabled" == false ]]; then
                print_status "INFO" "Since you are in TCG mode, the screen may take 1-2 minutes to appear."
            fi
            print_status "INFO" "Terminal Console: Serial output will be shown below (if supported by OS)."
        elif [[ "$GUI_MODE" == true ]] && [[ -n "${DISPLAY:-}" ]]; then
            qemu_cmd+=(-vga virtio -display gtk -serial mon:stdio)
            print_status "INFO" "Opening GUI window... (Serial output also visible in terminal)"
        else
            qemu_cmd+=(-nographic -serial mon:stdio)
            print_status "INFO" "Starting in terminal mode (nographic)."
            if [[ "$GUI_MODE" == true ]]; then
                print_status "WARN" "GUI mode requested but no display found. Running headless."
            fi
        fi

        # Add performance enhancements
        qemu_cmd+=(
            -device virtio-balloon-pci
            -object rng-random,filename=/dev/urandom,id=rng0
            -device virtio-rng-pci,rng=rng0
        )

        print_status "INFO" "Starting QEMU..."
        "${qemu_cmd[@]}"
        
        print_status "INFO" "VM $vm_name has been shut down"
    fi
}

# Function to delete a VM
delete_vm() {
    local vm_name=$1
    
    print_status "WARN" "This will permanently delete VM '$vm_name' and all its data!"
    read -p "$(print_status "INPUT" "Are you sure? (y/N): ")" -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if load_vm_config "$vm_name"; then
            rm -f "$IMG_FILE" "$SEED_FILE" "$VM_DIR/$vm_name.conf"
            [[ -n "$UNATTEND_ISO" ]] && rm -f "$UNATTEND_ISO"
            print_status "SUCCESS" "VM '$vm_name' has been deleted"
        fi
    else
        print_status "INFO" "Deletion cancelled"
    fi
}

# Function to show VM info
show_vm_info() {
    local vm_name=$1
    
    if load_vm_config "$vm_name"; then
        echo
        print_status "INFO" "VM Information: $vm_name"
        echo "=========================================="
        echo "OS: $OS_TYPE"
        echo "Hostname: $HOSTNAME"
        echo "Username: $USERNAME"
        echo "Password: $PASSWORD"
        echo "SSH Port: $SSH_PORT"
        echo "Memory: $MEMORY MB"
        echo "CPUs: $CPUS"
        echo "Disk: $DISK_SIZE"
        echo "GUI Mode: $GUI_MODE"
        echo "VNC Enabled: $VNC_ENABLED (Port: $VNC_PORT)"
        echo "Port Forwards: ${PORT_FORWARDS:-None}"
        echo "Created: $CREATED"
        echo "Image File: $IMG_FILE"
        echo "Seed File: $SEED_FILE"
        echo "Install ISO: ${INSTALL_ISO:-None}"
        [[ -n "$UNATTEND_ISO" ]] && echo "Unattend ISO: $UNATTEND_ISO"
        [[ -n "$VIRTIO_ISO" ]] && echo "VirtIO ISO: $VIRTIO_ISO"
        echo "=========================================="
        echo
        read -p "$(print_status "INPUT" "Press Enter to continue...")"
    fi
}

# Function to check if VM is running
is_vm_running() {
    local vm_name=$1
    if pgrep -f "qemu-system-x86_64.*$vm_name" >/dev/null; then
        return 0
    else
        return 1
    fi
}

# Function to stop a running VM
stop_vm() {
    local vm_name=$1
    
    if load_vm_config "$vm_name"; then
        if is_vm_running "$vm_name"; then
            print_status "INFO" "Stopping VM: $vm_name"
            pkill -f "qemu-system-x86_64.*$IMG_FILE"
            sleep 2
            if is_vm_running "$vm_name"; then
                print_status "WARN" "VM did not stop gracefully, forcing termination..."
                pkill -9 -f "qemu-system-x86_64.*$IMG_FILE"
            fi
            print_status "SUCCESS" "VM $vm_name stopped"
        else
            print_status "INFO" "VM $vm_name is not running"
        fi
    fi
}

# Function to edit VM configuration
edit_vm_config() {
    local vm_name=$1
    
    if load_vm_config "$vm_name"; then
        print_status "INFO" "Editing VM: $vm_name"
        
        while true; do
            echo "What would you like to edit?"
            echo "  1) Hostname"
            echo "  2) Username"
            echo "  3) Password"
            echo "  4) SSH Port"
            echo "  5) GUI Mode"
            echo "  6) VNC Access"
            echo "  7) Port Forwards"
            echo "  8) Memory (RAM)"
            echo "  9) CPU Count"
            echo " 10) Disk Size"
            echo "  0) Back to main menu"
            
            read -p "$(print_status "INPUT" "Enter your choice: ")" edit_choice
            
            case $edit_choice in
                1)
                    while true; do
                        read -p "$(print_status "INPUT" "Enter new hostname (current: $HOSTNAME): ")" new_hostname
                        new_hostname="${new_hostname:-$HOSTNAME}"
                        if validate_input "name" "$new_hostname"; then
                            HOSTNAME="$new_hostname"
                            break
                        fi
                    done
                    ;;
                2)
                    while true; do
                        read -p "$(print_status "INPUT" "Enter new username (current: $USERNAME): ")" new_username
                        new_username="${new_username:-$USERNAME}"
                        if validate_input "username" "$new_username"; then
                            USERNAME="$new_username"
                            break
                        fi
                    done
                    ;;
                3)
                    while true; do
                        read -s -p "$(print_status "INPUT" "Enter new password (current: ****): ")" new_password
                        new_password="${new_password:-$PASSWORD}"
                        echo
                        if [ -n "$new_password" ]; then
                            PASSWORD="$new_password"
                            break
                        else
                            print_status "ERROR" "Password cannot be empty"
                        fi
                    done
                    ;;
                4)
                    while true; do
                        read -p "$(print_status "INPUT" "Enter new SSH port (current: $SSH_PORT): ")" new_ssh_port
                        new_ssh_port="${new_ssh_port:-$SSH_PORT}"
                        if validate_input "port" "$new_ssh_port"; then
                            # Check if port is already in use
                            if [ "$new_ssh_port" != "$SSH_PORT" ] && ss -tln 2>/dev/null | grep -q ":$new_ssh_port "; then
                                print_status "ERROR" "Port $new_ssh_port is already in use"
                            else
                                SSH_PORT="$new_ssh_port"
                                break
                            fi
                        fi
                    done
                    ;;
                5)
                    if [[ "$OS_TYPE" == "windows" ]]; then
                        print_status "ERROR" "GUI mode cannot be disabled for Windows VMs."
                    else
                        while true; do
                            read -p "$(print_status "INPUT" "Enable GUI mode? (y/n, current: $GUI_MODE): ")" gui_input
                            gui_input="${gui_input:-}"
                            if [[ "$gui_input" =~ ^[Yy]$ ]]; then 
                                GUI_MODE=true
                                break
                            elif [[ "$gui_input" =~ ^[Nn]$ ]]; then
                                GUI_MODE=false
                                break
                            elif [ -z "$gui_input" ]; then
                                # Keep current value if user just pressed Enter
                                break
                            else
                                print_status "ERROR" "Please answer y or n"
                            fi
                        done
                    fi
                    ;;
                6)
                    while true; do
                        read -p "$(print_status "INPUT" "Enable VNC? (y/n, current: $VNC_ENABLED): ")" vnc_input
                        if [[ "$vnc_input" =~ ^[Yy]$ ]]; then 
                            VNC_ENABLED=true
                            read -p "$(print_status "INPUT" "Enter VNC port (current: $VNC_PORT): ")" VNC_PORT
                            VNC_PORT="${VNC_PORT:-5901}"
                            break
                        elif [[ "$vnc_input" =~ ^[Nn]$ ]]; then
                            VNC_ENABLED=false
                            break
                        elif [ -z "$vnc_input" ]; then
                            break
                        else
                            print_status "ERROR" "Please answer y or n"
                        fi
                    done
                    ;;
                7)
                    read -p "$(print_status "INPUT" "Additional port forwards (current: ${PORT_FORWARDS:-None}): ")" new_port_forwards
                    PORT_FORWARDS="${new_port_forwards:-$PORT_FORWARDS}"
                    ;;
                8)
                    while true; do
                        read -p "$(print_status "INPUT" "Enter new memory in MB (current: $MEMORY): ")" new_memory
                        new_memory="${new_memory:-$MEMORY}"
                        if validate_input "number" "$new_memory"; then
                            MEMORY="$new_memory"
                            break
                        fi
                    done
                    ;;
                9)
                    while true; do
                        read -p "$(print_status "INPUT" "Enter new CPU count (current: $CPUS): ")" new_cpus
                        new_cpus="${new_cpus:-$CPUS}"
                        if validate_input "number" "$new_cpus"; then
                            CPUS="$new_cpus"
                            break
                        fi
                    done
                    ;;
                10)
                    while true; do
                        read -p "$(print_status "INPUT" "Enter new disk size (current: $DISK_SIZE): ")" new_disk_size
                        new_disk_size="${new_disk_size:-$DISK_SIZE}"
                        if validate_input "size" "$new_disk_size"; then
                            DISK_SIZE="$new_disk_size"
                            break
                        fi
                    done
                    ;;
                0)
                    return 0
                    ;;
                *)
                    print_status "ERROR" "Invalid selection"
                    continue
                    ;;
            esac
            
            # Recreate seed image with new configuration if user/password/hostname changed
            if [[ "$edit_choice" -eq 1 || "$edit_choice" -eq 2 || "$edit_choice" -eq 3 ]]; then
                print_status "INFO" "Updating cloud-init configuration..."
                setup_vm_image
            fi
            
            # Save configuration
            save_vm_config
            
            read -p "$(print_status "INPUT" "Continue editing? (y/N): ")" continue_editing
            if [[ ! "$continue_editing" =~ ^[Yy]$ ]]; then
                break
            fi
        done
    fi
}

# Function to resize VM disk
resize_vm_disk() {
    local vm_name=$1
    
    if load_vm_config "$vm_name"; then
        print_status "INFO" "Current disk size: $DISK_SIZE"
        
        while true; do
            read -p "$(print_status "INPUT" "Enter new disk size (e.g., 50G): ")" new_disk_size
            if validate_input "size" "$new_disk_size"; then
                if [[ "$new_disk_size" == "$DISK_SIZE" ]]; then
                    print_status "INFO" "New disk size is the same as current size. No changes made."
                    return 0
                fi
                
                # Check if new size is smaller than current (not recommended)
                local current_size_num=${DISK_SIZE%[GgMm]}
                local new_size_num=${new_disk_size%[GgMm]}
                local current_unit=${DISK_SIZE: -1}
                local new_unit=${new_disk_size: -1}
                
                # Convert both to MB for comparison
                if [[ "$current_unit" =~ [Gg] ]]; then
                    current_size_num=$((current_size_num * 1024))
                fi
                if [[ "$new_unit" =~ [Gg] ]]; then
                    new_size_num=$((new_size_num * 1024))
                fi
                
                if [[ $new_size_num -lt $current_size_num ]]; then
                    print_status "WARN" "Shrinking disk size is not recommended and may cause data loss!"
                    read -p "$(print_status "INPUT" "Are you sure you want to continue? (y/N): ")" confirm_shrink
                    if [[ ! "$confirm_shrink" =~ ^[Yy]$ ]]; then
                        print_status "INFO" "Disk resize cancelled."
                        return 0
                    fi
                fi
                
                # Resize the disk
                print_status "INFO" "Resizing disk to $new_disk_size..."
                if qemu-img resize "$IMG_FILE" "$new_disk_size"; then
                    DISK_SIZE="$new_disk_size"
                    save_vm_config
                    print_status "SUCCESS" "Disk resized successfully to $new_disk_size"
                else
                    print_status "ERROR" "Failed to resize disk"
                    return 1
                fi
                break
            fi
        done
    fi
}

# Function to show VM performance metrics
show_vm_performance() {
    local vm_name=$1
    
    if load_vm_config "$vm_name"; then
        if is_vm_running "$vm_name"; then
            print_status "INFO" "Performance metrics for VM: $vm_name"
            echo "=========================================="
            
            # Get QEMU process ID
            local qemu_pid=$(pgrep -f "qemu-system-x86_64.*$IMG_FILE")
            if [[ -n "$qemu_pid" ]]; then
                # Show process stats
                echo "QEMU Process Stats:"
                ps -p "$qemu_pid" -o pid,%cpu,%mem,sz,rss,vsz,cmd --no-headers
                echo
                
                # Show memory usage
                echo "Memory Usage:"
                free -h
                echo
                
                # Show disk usage
                echo "Disk Usage:"
                df -h "$IMG_FILE" 2>/dev/null || du -h "$IMG_FILE"
            else
                print_status "ERROR" "Could not find QEMU process for VM $vm_name"
            fi
        else
            print_status "INFO" "VM $vm_name is not running"
            echo "Configuration:"
            echo "  Memory: $MEMORY MB"
            echo "  CPUs: $CPUS"
            echo "  Disk: $DISK_SIZE"
        fi
        echo "=========================================="
        read -p "$(print_status "INPUT" "Press Enter to continue...")"
    fi
}

# Function for system checkup
system_checkup() {
    echo "=========================================="
    print_status "INFO" "System Checkup"
    echo "=========================================="
    
    # Check IPs
    local ipv4_local=$(hostname -I | awk '{print $1}')
    local ipv4_public=$(curl -s4 ifconfig.me || echo "Not available")
    local ipv6_local=$(hostname -I | awk '{print $2}')
    local ipv6_public=$(curl -s6 ifconfig.me || echo "Not available")
    
    echo "Local IPv4:  $ipv4_local"
    echo "Public IPv4: $ipv4_public"
    echo "Local IPv6:  $ipv6_local"
    echo "Public IPv6: $ipv6_public"
    echo
    
    # Check KVM
    if [ -w /dev/kvm ]; then
        print_status "SUCCESS" "KVM acceleration is AVAILABLE and ACCESSIBLE."
    elif [ -e /dev/kvm ]; then
        print_status "WARN" "KVM exists but is NOT ACCESSIBLE (Permission denied). Try: sudo usermod -aG kvm \$USER"
    else
        print_status "ERROR" "KVM is NOT AVAILABLE on this system."
    fi
    echo
    
    # Check Dependencies
    local deps=("qemu-system-x86_64" "wget" "cloud-localds" "qemu-img")
    for dep in "${deps[@]}"; do
        if command -v "$dep" &> /dev/null; then
            print_status "SUCCESS" "Dependency '$dep' found"
        else
            print_status "WARN" "Dependency '$dep' MISSING"
        fi
    done
    
    echo "=========================================="
    read -p "$(print_status "INPUT" "Press Enter to continue...")"
}

# Function for system checkup
system_checkup() {
    display_header
    print_status "INFO" "Running System Checkup..."
    echo "------------------------------------------------------------------------"
    
    # 1. KVM Check
    if [ -w /dev/kvm ] && grep -qE "vmx|svm" /proc/cpuinfo; then
        print_status "SUCCESS" "KVM Acceleration: AVAILABLE"
    else
        print_status "WARN" "KVM Acceleration: NOT AVAILABLE (Performance will be slow)"
        echo "   Tip: Check BIOS virtualization settings and 'lsmod | grep kvm'"
    fi
    
    # 2. Dependencies Check
    local deps=("qemu-system-x86_64" "wget" "cloud-localds" "qemu-img" "genisoimage" "git" "curl")
    local missing=0
    for dep in "${deps[@]}"; do
        if command -v "$dep" &> /dev/null; then
            printf "  %-20s | \033[1;32mINSTALLED\033[0m\n" "$dep"
        else
            printf "  %-20s | \033[1;31mNOT FOUND\033[0m\n" "$dep"
            missing=$((missing + 1))
        fi
    done
    
    # 3. Disk Space Check
    local free_space=$(df -h "$VM_DIR" | tail -1 | awk '{print $4}')
    print_status "INFO" "Free Space in $VM_DIR: $free_space"
    
    # 4. Networking Check
    if ip addr show scope global | grep -q "inet "; then
        print_status "SUCCESS" "Network: ONLINE"
    else
        print_status "ERROR" "Network: OFFLINE"
    fi
    
    echo "------------------------------------------------------------------------"
    if [ $missing -gt 0 ]; then
        print_status "WARN" "Found $missing missing dependencies. Some features may not work."
    else
        print_status "SUCCESS" "System is ready to go!"
    fi
}

# Function to install Tailscale
install_tailscale() {
    if command -v tailscale >/dev/null 2>&1; then
        print_status "INFO" "Tailscale is already installed."
        read -p "$(print_status "INPUT" "Do you want to run the installer anyway? (y/n): ")" reinstall
        if [[ ! "$reinstall" =~ ^[Yy]$ ]]; then
            return 0
        fi
    fi

    print_status "INFO" "Installing Tailscale..."
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL https://tailscale.com/install.sh | sh
    elif command -v wget >/dev/null 2>&1; then
        sh -c "$(wget -qO- https://tailscale.com/install.sh)"
    else
        print_status "ERROR" "Neither curl nor wget found. Please install one to proceed."
        return 1
    fi
    
    if command -v tailscale >/dev/null 2>&1; then
        print_status "SUCCESS" "Tailscale installed successfully!"
        print_status "INFO" "You can now run 'tailscale up' to connect to your Tailnet."
    else
        print_status "ERROR" "Tailscale installation failed or requires manual intervention."
    fi
}

# Function for system dashboard
system_dashboard() {
    clear
    while true; do
        display_header
        echo "========================================================================"
        echo "                         SYSTEM DASHBOARD                               "
        echo "========================================================================"
        
        # CPU Usage
        local cpu_usage=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1"%"}')
        echo -e "CPU Usage:    \033[1;32m$cpu_usage\033[0m"
        
        # Memory Usage
        local mem_info=$(free -m | grep Mem)
        local total_mem=$(echo $mem_info | awk '{print $2}')
        local used_mem=$(echo $mem_info | awk '{print $3}')
        local mem_pct=$((used_mem * 100 / total_mem))
        echo -e "Memory Usage: \033[1;34m$used_mem / $total_mem MB ($mem_pct%)\033[0m"
        
        # Disk Usage (VM Directory)
        local disk_info=$(df -h "$VM_DIR" | tail -1)
        local disk_used=$(echo $disk_info | awk '{print $3}')
        local disk_total=$(echo $disk_info | awk '{print $2}')
        local disk_pct=$(echo $disk_info | awk '{print $5}')
        echo -e "Disk Usage:   \033[1;33m$disk_used / $disk_total ($disk_pct) in $VM_DIR\033[0m"
        
        echo "------------------------------------------------------------------------"
        echo "Running VMs:"
        local running_found=false
        local vms=($(get_vm_list))
        for vm in "${vms[@]}"; do
            local pid=$(pgrep -f "qemu-system-x86_64.*$vm" || echo "")
            if [[ -n "$pid" ]]; then
                local vm_stats=$(ps -p "$pid" -o %cpu,%mem --no-headers)
                printf "  %-20s | PID: %-6s | CPU: %-5s | MEM: %-5s\n" "$vm" "$pid" $(echo $vm_stats | awk '{print $1"%"}') $(echo $vm_stats | awk '{print $2"%"}')
                running_found=true
            fi
        done
        [[ "$running_found" == false ]] && echo "  No VMs currently running."
        
        echo "========================================================================"
        echo "  [R] Refresh  [B] Back to Main Menu"
        read -n 1 -s -t 5 input
        case ${input^^} in
            B) return ;;
            R) continue ;;
        esac
    done
}

# Main menu function
main_menu() {
    while true; do
        display_header
        
        local vms=($(get_vm_list))
        local vm_count=${#vms[@]}
        
        if [ $vm_count -gt 0 ]; then
            print_status "INFO" "Found $vm_count existing VM(s):"
            for i in "${!vms[@]}"; do
                local status="Stopped"
                if is_vm_running "${vms[$i]}"; then
                    status="Running"
                fi
                printf "  %2d) %s (%s)\n" $((i+1)) "${vms[$i]}" "$status"
            done
            echo
        fi
        
        echo "Main Menu:"
        echo "  1) Create a new VM"
        local opt_dashboard=2
        local opt_checkup=3
        local opt_tailscale=4
        if [ $vm_count -gt 0 ]; then
            echo "  2) Start a VM"
            echo "  3) Stop a VM"
            echo "  4) Show VM info"
            echo "  5) Edit VM configuration"
            echo "  6) Delete a VM"
            echo "  7) Resize VM disk"
            echo "  8) Show VM performance"
            opt_dashboard=9
            opt_checkup=10
            opt_tailscale=11
        fi
        echo "  $opt_dashboard) System Dashboard"
        echo "  $opt_checkup) System Checkup"
        echo "  $opt_tailscale) Install Tailscale"
        echo "  0) Exit"
        echo
        
        read -p "$(print_status "INPUT" "Enter your choice: ")" choice
        
        case $choice in
            1)
                create_new_vm
                ;;
            0)
                print_status "INFO" "Goodbye!"
                exit 0
                ;;
            $opt_dashboard)
                system_dashboard
                ;;
            $opt_checkup)
                system_checkup
                ;;
            $opt_tailscale)
                install_tailscale
                ;;
            2)
                if [ $vm_count -gt 0 ]; then
                    read -p "$(print_status "INPUT" "Enter VM number to start: ")" vm_num
                    if [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le $vm_count ]; then
                        start_vm "${vms[$((vm_num-1))]}"
                    else
                        print_status "ERROR" "Invalid selection"
                    fi
                fi
                ;;
            3)
                if [ $vm_count -gt 0 ]; then
                    read -p "$(print_status "INPUT" "Enter VM number to stop: ")" vm_num
                    if [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le $vm_count ]; then
                        stop_vm "${vms[$((vm_num-1))]}"
                    else
                        print_status "ERROR" "Invalid selection"
                    fi
                fi
                ;;
            4)
                if [ $vm_count -gt 0 ]; then
                    read -p "$(print_status "INPUT" "Enter VM number to show info: ")" vm_num
                    if [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le $vm_count ]; then
                        show_vm_info "${vms[$((vm_num-1))]}"
                    else
                        print_status "ERROR" "Invalid selection"
                    fi
                fi
                ;;
            5)
                if [ $vm_count -gt 0 ]; then
                    read -p "$(print_status "INPUT" "Enter VM number to edit: ")" vm_num
                    if [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le $vm_count ]; then
                        edit_vm_config "${vms[$((vm_num-1))]}"
                    else
                        print_status "ERROR" "Invalid selection"
                    fi
                fi
                ;;
            6)
                if [ $vm_count -gt 0 ]; then
                    read -p "$(print_status "INPUT" "Enter VM number to delete: ")" vm_num
                    if [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le $vm_count ]; then
                        delete_vm "${vms[$((vm_num-1))]}"
                    else
                        print_status "ERROR" "Invalid selection"
                    fi
                fi
                ;;
            7)
                if [ $vm_count -gt 0 ]; then
                    read -p "$(print_status "INPUT" "Enter VM number to resize disk: ")" vm_num
                    if [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le $vm_count ]; then
                        resize_vm_disk "${vms[$((vm_num-1))]}"
                    else
                        print_status "ERROR" "Invalid selection"
                    fi
                fi
                ;;
            8)
                if [ $vm_count -gt 0 ]; then
                    read -p "$(print_status "INPUT" "Enter VM number to show performance: ")" vm_num
                    if [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le $vm_count ]; then
                        show_vm_performance "${vms[$((vm_num-1))]}"
                    else
                        print_status "ERROR" "Invalid selection"
                    fi
                fi
                ;;
            *)
                print_status "ERROR" "Invalid option"
                ;;
        esac
        
        read -p "$(print_status "INPUT" "Press Enter to continue...")"
    done
}

# Set trap to cleanup on exit
trap cleanup EXIT

# Check dependencies
check_dependencies

# Initialize paths
VM_DIR="${VM_DIR:-$HOME/vms}"
mkdir -p "$VM_DIR"

# Supported OS list
declare -A OS_OPTIONS=(
    ["Ubuntu 22.04"]="ubuntu|jammy|https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img|ubuntu22|ubuntu|ubuntu"
    ["Ubuntu 24.04"]="ubuntu|noble|https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img|ubuntu24|ubuntu|ubuntu"
    ["Debian 11"]="debian|bullseye|https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-generic-amd64.qcow2|debian11|debian|debian"
    ["Debian 12"]="debian|bookworm|https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2|debian12|debian|debian"
    ["Fedora 40"]="fedora|40|https://download.fedoraproject.org/pub/fedora/linux/releases/40/Cloud/x86_64/images/Fedora-Cloud-Base-40-1.14.x86_64.qcow2|fedora40|fedora|fedora"
    ["CentOS Stream 9"]="centos|stream9|https://cloud.centos.org/centos/9-stream/x86_64/images/CentOS-Stream-GenericCloud-9-latest.x86_64.qcow2|centos9|centos|centos"
    ["AlmaLinux 9"]="almalinux|9|https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2|almalinux9|alma|alma"
    ["Rocky Linux 9"]="rockylinux|9|https://download.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud.latest.x86_64.qcow2|rocky9|rocky|rocky"
    ["Windows Server 2022"]="windows|2022|https://software-static.download.prss.microsoft.com/sg/download/888969d5-f34g-4e03-ac9d-1f9786c66749/SERVER_EVAL_x64FRE_en-us.iso|win2022|Administrator|password"
    ["Windows 11"]="windows|11|https://www.microsoft.com/software-download/windows11|win11|Administrator|password"
)

# Start the main menu
main_menu

