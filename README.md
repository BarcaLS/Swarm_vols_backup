# Docker Swarm Volume Backup & Restore Script

This repository contains a Bash script that automates **backup** and **restore** of Docker Swarm stack volumes across multiple worker nodes.  
It supports:

- automatic detection of which node the stack is running on  
- SSH access per-node with customizable ports  
- volume packaging via temporary Alpine containers  
- safe restore with volume recreation  
- manual confirmation to prevent accidental backups while stack is running  
- searching stacks by name  

The script is designed for admins managing multi-node Docker Swarm clusters with persistent volumes stored locally on workers.

---

## Features

### ✔️ Backup
- Automatically detects the node running the stack
- Connects via SSH (username + password)
- Creates `.tar` archives of each volume matching `stackname_*`
- Packages volumes via Alpine `tar`
- Stores results under:

```
/opt/backups/stacks/<stack>-YYYYMMDD-HHMMSS/
```

### ✔️ Restore
- Interactive selection of available backups
- Restore to any worker node defined in the config
- Safely removes existing volumes before restoring
- Extracts data back into Docker volumes via Alpine

### ✔️ Search
- Case-insensitive search for stacks:

```
./script.sh <name> search
```

---

## Requirements

- Docker installed on all worker nodes
- SSH access with a user belonging to the `docker` group
- `sshpass` installed locally
- Bash 4+
- Access to Docker Swarm manager (for `docker stack ls` / `docker stack ps`)

---

## Installation

Clone the repository:

```bash
git clone https://github.com/your/repo.git
cd repo
chmod +x backup.sh
```

---

## Configuration

At the top of the script:

```bash
TMP_BACKUP_DIR="/tmp"
BACKUPS_HOST_ROOT_FOLDER="/opt/backups/stacks"

declare -A WORKER_NODES=(
    ["server1"]=22
    ["server2"]=40022
)
```

Define:

- worker node hostnames (must match Docker node names)
- SSH ports per node
- backup destination root folder

---

## Usage

### Backup a stack:

```bash
./backup.sh <stack_name> backup
```

Workflow:
1. Script detects the Swarm node where the stack runs  
2. Asks for SSH credentials  
3. Requires user to manually stop the stack (with a 6-digit confirmation code)  
4. Creates tar archives for each volume  
5. Copies them to backup directory  

---

### Restore a stack:

```bash
./backup.sh <stack_name> restore
```

Workflow:
1. Script shows available backups  
2. User selects backup  
3. User selects target node  
4. Script uploads `.tar` files  
5. Recreates Docker volumes  
6. Restores data into each volume  

---

### Search stacks:

```bash
./backup.sh <substring> search
```

Example:

```bash
./backup.sh wiki search
```

---

## Example Backup Output

```
Backup will be stored in: /opt/backups/stacks/wiki-20251114-130501
Connecting to server1...
Packing volume wiki_db (1/2)...
Packing volume wiki_data (2/2)...
Copying files...
Backup completed successfully!
```

---

## Safety Features

- Requires stack to be stopped before backup  
- Confirmation code prevents accidental backups  
- Warns if SSH user is not in `docker` group  
- Removes and recreates volumes during restore to avoid data corruption  

---

## Notes

- Script uses `docker volume ls` and matches volumes starting with `<stackname>` or `<stackname>_`.
- Backup is node-local: volumes exist on the worker node where the service was running.
- Compatible with local volumes, NFS volumes, and bind mounts as long as data is inside the Docker volume.

---

## License

MIT License  
Feel free to modify and extend.
