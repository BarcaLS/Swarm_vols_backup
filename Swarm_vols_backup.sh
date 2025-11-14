#!/bin/bash

# Configuration
TMP_BACKUP_DIR="/tmp"
BACKUPS_HOST_ROOT_FOLDER="/opt/backups/stacks"

# Define worker nodes and their SSH ports
declare -A WORKER_NODES
WORKER_NODES=(
    ["server1"]=22
    ["server2"]=40022
)

# Function to find the node running the stack
find_stack_node() {
    local stack_name=$1
    echo "Searching for stack '$stack_name'..."
    STACK_NODE=$(docker stack ps "$stack_name" --format "{{.Node}}" | head -n 1)

    if [ -z "$STACK_NODE" ]; then
        echo "No active nodes found for stack '$stack_name'." >&2
        return 1
    fi
}

# Function to search for stacks (case-insensitive)
search_stacks() {
    local stack_name=$1
    echo "Searching for stacks matching '$stack_name' (case-insensitive)..."
    local stacks_found
    stacks_found=$(docker stack ls --format "{{.Name}}" | grep -i "$stack_name")

    if [ -z "$stacks_found" ]; then
        echo "No stacks found matching '$stack_name'."
    else
        echo "Found the following stacks matching '$stack_name':"
        echo "$stacks_found"
    fi
}

# Function to get SSH credentials
get_ssh_credentials() {
    echo "Enter SSH username for $STACK_NODE (has to be in group docker):"
    read -r SSH_USER
    echo "Enter SSH password for $SSH_USER@$STACK_NODE:"
    read -s SSH_PASSWORD
}

# Function to perform backup on the worker node
backup_stack() {
    local stack_name=$1
    find_stack_node "$stack_name" || exit 1
    local ssh_port=${WORKER_NODES[$STACK_NODE]}

    if [ -z "$ssh_port" ]; then
        echo "No SSH configuration found for node '$STACK_NODE'."
        exit 1
    fi

    get_ssh_credentials

    # Wymuś ręczne wyłączenie stacka
    local confirm_code
    confirm_code=$(shuf -i 100000-999999 -n 1)
    echo
    echo "⚠️  Please stop the stack '$stack_name' manually before continuing."
    echo "Once the stack is stopped, enter the following confirmation code to continue: $confirm_code"

    local user_input
    while true; do
        read -rp "Enter the confirmation code: " user_input
        if [[ "$user_input" == "$confirm_code" ]]; then
            break
        else
            echo "❌ Incorrect code. Please try again."
        fi
    done

    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_dir="$BACKUPS_HOST_ROOT_FOLDER/$stack_name-$timestamp"
    echo "Backup will be stored in: $backup_dir"
    mkdir -p "$backup_dir"

    echo "Connecting to $STACK_NODE via SSH ($SSH_USER@$STACK_NODE:$ssh_port) to perform backup..."

    sshpass -p "$SSH_PASSWORD" ssh -p "$ssh_port" "$SSH_USER@$STACK_NODE" "
        mkdir -p $TMP_BACKUP_DIR/$stack_name && 
        volume_count=$(docker volume ls --format "{{.Name}}" | grep -E "^${stack_name}(_|$)" | wc -l) && 
        count=0 && 
        for volume in $(docker volume ls --format "{{.Name}}" | grep -E "^${stack_name}(_|$)"); do
            count=$((count + 1))
            echo "Packing volume $volume ($count/$volume_count)..."
            docker run --rm -v $volume:/volume -v $TMP_BACKUP_DIR/$stack_name:/backup alpine tar -czf /backup/$volume.tar -C /volume . &&
            echo "Packed $volume"
        done
    "

    echo "Copying backup files from $STACK_NODE to $backup_dir..."
    sshpass -p "$SSH_PASSWORD" scp -P "$ssh_port" "$SSH_USER@$STACK_NODE:$TMP_BACKUP_DIR/$stack_name/*.tar" "$backup_dir/"

    echo "Cleaning up temporary files on $STACK_NODE..."
    sshpass -p "$SSH_PASSWORD" ssh -p "$ssh_port" "$SSH_USER@$STACK_NODE" "rm -rf $TMP_BACKUP_DIR/$stack_name"

    echo "✅ Backup completed successfully! Files created:"
    du -h "$backup_dir"/* | sort -h
}

# Function to restore backup on the worker node
restore_stack() {
    local stack_name=$1

    # List available backup directories for the stack
    echo "Listing available backups for '$stack_name':"
    available_backups=($(ls -d "$BACKUPS_HOST_ROOT_FOLDER/$stack_name-"*/ 2>/dev/null))

    if [ ${#available_backups[@]} -eq 0 ]; then
        echo "No backups found for '$stack_name'."
        return 1
    fi

    # Display available backups
    for i in "${!available_backups[@]}"; do
        backup_timestamp=$(basename "${available_backups[$i]}" | sed 's/^.*-([0-9]{8}-[0-9]{6})$/1/')
        echo "$i) Backup from $backup_timestamp"
    done

    echo "Enter the number of the backup to restore (e.g. 0):"
    read -r backup_choice

    if [[ ! "$backup_choice" =~ ^[0-9]+$ ]] || [ "$backup_choice" -ge "${#available_backups[@]}" ]; then
        echo "Invalid choice."
        return 1
    fi

    selected_backup="${available_backups[$backup_choice]}"
    echo "Selected backup: $selected_backup"

    echo "Select the node to restore the backup to:"
    mapfile -t node_names < <(printf "%sn" "${!WORKER_NODES[@]}")
    for i in "${!node_names[@]}"; do
        echo "$i) ${node_names[$i]}"
    done

    read -r node_choice
    if [[ ! "$node_choice" =~ ^[0-9]+$ ]] || [ "$node_choice" -ge "${#node_names[@]}" ]; then
        echo "Invalid choice."
        return 1
    fi

    STACK_NODE="${node_names[$node_choice]}"
    local ssh_port=${WORKER_NODES[$STACK_NODE]}

    if [ -z "$ssh_port" ]; then
        echo "No SSH configuration found for node '$STACK_NODE'."
        return 1
    fi

    get_ssh_credentials

    echo "Connecting to $STACK_NODE via SSH ($SSH_USER@$STACK_NODE:$ssh_port) to restore backup..."

    # Test SSH connection first
    if ! sshpass -p "$SSH_PASSWORD" ssh -p "$ssh_port" "$SSH_USER@$STACK_NODE" "echo 'SSH connection successful'"; then
        echo "Failed to connect to $STACK_NODE. Please check credentials and try again."
        return 1
    fi

    # Check if user has docker rights
    if ! sshpass -p "$SSH_PASSWORD" ssh -p "$ssh_port" "$SSH_USER@$STACK_NODE" "groups | grep -q docker"; then
        echo "Warning: User $SSH_USER may not have docker group permissions."
        echo "This might cause permission issues during restore."
        read -p "Continue anyway? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Restoration aborted."
            return 1
        fi
    fi

    # Create temporary restore dir on the remote node
    REMOTE_RESTORE_DIR="$TMP_BACKUP_DIR/restore_$stack_name"
    sshpass -p "$SSH_PASSWORD" ssh -p "$ssh_port" "$SSH_USER@$STACK_NODE" "mkdir -p $REMOTE_RESTORE_DIR"

    # Copy backup files to the remote node
    echo "Copying backup files to $STACK_NODE:$REMOTE_RESTORE_DIR..."
    sshpass -p "$SSH_PASSWORD" scp -P "$ssh_port" "$selected_backup"/*.tar "$SSH_USER@$STACK_NODE:$REMOTE_RESTORE_DIR/"

    # Restore backup on the remote worker node
    for tar_file in "$selected_backup"/*.tar; do
        local volume_name
        volume_name=$(basename "$tar_file" .tar)
        echo "Restoring volume '$volume_name' from '$(basename "$tar_file")'..."
        
        # Check if volume exists and remove it if it does
        sshpass -p "$SSH_PASSWORD" ssh -p "$ssh_port" "$SSH_USER@$STACK_NODE" "
            if docker volume inspect $volume_name >/dev/null 2>&1; then
                echo 'Volume $volume_name exists. Removing...'
                docker volume rm $volume_name || { echo 'Failed to remove volume. You may need root privileges.'; exit 1; }
            fi
            
            echo 'Creating volume $volume_name...'
            docker volume create $volume_name || { echo 'Failed to create volume. You may need root privileges.'; exit 1; }
            
            echo 'Extracting backup to volume...'
            docker run --rm -v $volume_name:/volume -v $REMOTE_RESTORE_DIR:/backup alpine sh -c 'tar -xf /backup/$volume_name.tar -C /volume && echo "Restore of $volume_name completed successfully"'
        "
    done

    # Clean up temporary restore files
    echo "Cleaning up restore files on remote node..."
    sshpass -p "$SSH_PASSWORD" ssh -p "$ssh_port" "$SSH_USER@$STACK_NODE" "rm -rf $REMOTE_RESTORE_DIR"

    echo "Restore completed. Please verify volumes were created correctly."
}

# Main execution
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <stack_name> <backup|restore|search>"
    exit 1
fi

STACK_NAME="$1"
ACTION="$2"

case "$ACTION" in
    backup)
        backup_stack "$STACK_NAME"
        ;;
    restore)
        restore_stack "$STACK_NAME"
        ;;
    search)
        search_stacks "$STACK_NAME"
        ;;
    *)
        echo "Invalid action: $ACTION. Use 'backup', 'restore' or 'search'."
        exit 1
        ;;
esac
