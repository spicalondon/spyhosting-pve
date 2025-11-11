#!/usr/bin/env bash
set -euo pipefail

DEFAULT_IMG_DIR="/var/lib/vz/template/qemu"
DEFAULT_STORAGE="local"
DEFAULT_BRIDGE="vmbr0"
DEFAULT_MEMORY=2048

log() { echo "[$(date +%H:%M:%S)] $*"; }

ensure_dir() {
  local d="$1"
  if [[ ! -d "$d" ]]; then
    log "Creating directory $d"
    mkdir -p "$d"
  fi
}

download_if_missing() {
  local url="$1"
  local path="$2"

  if [[ -f "$path" ]]; then
    log "Image already exists: $path (skip download)"
    return
  fi

  log "Downloading $url -> $path"
  wget -O "$path" "$url"
}

# ⬇️ YENİ: cloud image içine root/ssh ayarlarını pişir
customize_cloud_image() {
  local img_path="$1"

  # virt-customize yoksa atla (istersen burada exit de diyebilirsin)
  if ! command -v virt-customize >/dev/null 2>&1; then
    log "virt-customize not found, skipping image customization for $img_path"
    return
  fi

  log "Patching cloud-init settings inside $img_path (enable root & ssh password)"

  virt-customize -a "$img_path" \
    --run-command 'mkdir -p /etc/cloud' \
    --edit '/etc/cloud/cloud.cfg:s/^disable_root:.*$/disable_root: false/;' \
    --edit '/etc/cloud/cloud.cfg:s/^ssh_pwauth:.*$/ssh_pwauth: true/;' \
    --append-line '/etc/cloud/cloud.cfg:ssh_pwauth: true' \
    --append-line '/etc/cloud/cloud.cfg:disable_root: false' \
    --run-command 'chown root:root /etc/cloud/cloud.cfg'

  # istersen default root şifresini de image içine yaz:
  # virt-customize -a "$img_path" --root-password password:12345678
}

create_or_update_vm() {
  local vmid="$1"
  local name="$2"
  local mem="$3"
  local bridge="$4"

  if qm status "$vmid" >/dev/null 2>&1; then
    log "VMID $vmid already exists, will only update config."
  else
    log "Creating base VM $vmid ($name)"
    qm create "$vmid" --name "$name" --memory "$mem" --net0 "virtio,bridge=$bridge"
  fi
}

import_disk_if_needed() {
  local vmid="$1"
  local img_path="$2"
  local storage="$3"

  local target="/var/lib/vz/images/$vmid/vm-$vmid-disk-0.raw"
  if [[ -f "$target" ]]; then
    log "Disk already imported for VM $vmid: $target (skip import)"
  else
    log "Importing disk $img_path -> VM $vmid on storage $storage"
    qm importdisk "$vmid" "$img_path" "$storage"
  fi

  log "Attaching disk as scsi0 on VM $vmid"
  qm set "$vmid" --scsihw virtio-scsi-pci --scsi0 "$storage:$vmid/vm-$vmid-disk-0.raw"
}

attach_cloudinit_and_boot() {
  local vmid="$1"
  local storage="$2"

  log "Attaching cloud-init drive on VM $vmid"
  qm set "$vmid" --ide2 "$storage:cloudinit"

  log "Setting boot order to scsi0 on VM $vmid"
  qm set "$vmid" --boot order=scsi0

  log "Enabling qemu-guest-agent on VM $vmid"
  qm set "$vmid" --agent enabled=1
}

make_template() {
  local vmid="$1"

  log "Converting VM $vmid to template (idempotent)"
  qm template "$vmid" || true

  log "============== VM $vmid config =============="
  qm config "$vmid"
  log "============================================="
}

TEMPLATES=(
  "9000|ubuntu-24-cloud|https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img|noble-server-cloudimg-amd64.img|local|vmbr0|2048"
  "9001|debian-12-cloud|https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2|debian-12-genericcloud-amd64.qcow2|local|vmbr0|2048"
  "9002|ubuntu-22-cloud|https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img|jammy-server-cloudimg-amd64.img|local|vmbr0|2048"
)

log "==> Cloud templates provisioning started on host: $(hostname)"
ensure_dir "$DEFAULT_IMG_DIR"

for entry in "${TEMPLATES[@]}"; do
  IFS="|" read -r VMID VMNAME IMG_URL IMG_FILE STORAGE BRIDGE MEMORY_MB <<<"$entry"
  IMG_PATH="${DEFAULT_IMG_DIR}/${IMG_FILE}"

  log "--- processing template: $VMID ($VMNAME) ---"

  download_if_missing "$IMG_URL" "$IMG_PATH"

  # ⬇️ indirildikten sonra patchle
  customize_cloud_image "$IMG_PATH"

  create_or_update_vm "$VMID" "$VMNAME" "$MEMORY_MB" "$BRIDGE"
  import_disk_if_needed "$VMID" "$IMG_PATH" "$STORAGE"
  attach_cloudinit_and_boot "$VMID" "$STORAGE"
  make_template "$VMID"

  log "--- done: $VMID ($VMNAME) ---"
  echo
done

log "✅ All templates processed."
