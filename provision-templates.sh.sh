#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Proxmox cloud template provisioner
#  - gerekli paketleri kurar (wget, libguestfs-tools)
#  - cloud image indirir
#  - image'i patch'ler (root + ssh_pwauth)
#  - VM oluşturup template'e çevirir
#  - cluster'da 9000 doluysa 10000, o da doluysa 11000 ...
# ============================================================

DEFAULT_IMG_DIR="/var/lib/vz/template/qemu"
DEFAULT_STORAGE="local"
DEFAULT_BRIDGE="vmbr0"
DEFAULT_MEMORY=2048

log() { echo "[$(date +%H:%M:%S)] $*"; }

# root kontrolü
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "bu script root olarak çalışmalı (sudo ./provision-templates.sh)"
  exit 1
fi

# ------------------------------------------------------------
# APT helper
# ------------------------------------------------------------
APT_UPDATED=0
apt_update_once() {
  if [[ $APT_UPDATED -eq 0 ]]; then
    log "Running apt-get update (first and only time)..."
    apt-get update || true
    APT_UPDATED=1
  fi
}

ensure_package() {
  local pkg="$1"
  if dpkg -s "$pkg" >/dev/null 2>&1; then
    return
  fi

  if [[ "${SKIP_INSTALL:-0}" == "1" ]]; then
    log "SKIP_INSTALL=1, ama paket yok: $pkg"
    return
  fi

  apt_update_once
  log "Installing missing package: $pkg"
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg"
}

# ------------------------------------------------------------
# klasör
# ------------------------------------------------------------
ensure_dir() {
  local d="$1"
  if [[ ! -d "$d" ]]; then
    log "Creating directory $d"
    mkdir -p "$d"
  fi
}

# ------------------------------------------------------------
# indir
# ------------------------------------------------------------
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

# ------------------------------------------------------------
# image'i içerden patchle
# ------------------------------------------------------------
customize_cloud_image() {
  local img_path="$1"

  if ! command -v virt-customize >/dev/null 2>&1; then
    log "virt-customize not found, trying to install libguestfs-tools..."
    ensure_package "libguestfs-tools"
  fi

  if ! command -v virt-customize >/dev/null 2>&1; then
    log "virt-customize still not found, skipping image customization for $img_path"
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
}

# ------------------------------------------------------------
# cluster'da bu VMID var mı? (tüm node'ları görerek)
# ------------------------------------------------------------
has_vmid_cluster() {
  local id="$1"
  # pvesh JSON döndürüyor, basit grep yeter
  if pvesh get /cluster/resources --type vm --output-format json 2>/dev/null | grep -q "\"vmid\": ${id}"; then
    return 0
  fi
  return 1
}

# ------------------------------------------------------------
# vm oluştur / güncelle (bu node'da)
# ------------------------------------------------------------
create_or_update_vm() {
  local vmid="$1"
  local name="$2"
  local mem="$3"
  local bridge="$4"

  if qm status "$vmid" >/dev/null 2>&1; then
    log "VMID $vmid already exists on this node, will only update config."
  else
    log "Creating base VM $vmid ($name)"
    qm create "$vmid" --name "$name" --memory "$mem" --net0 "virtio,bridge=$bridge"
  fi
}

# ------------------------------------------------------------
# disk import
# ------------------------------------------------------------
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

# ------------------------------------------------------------
# cloud-init tak
# ------------------------------------------------------------
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

# ------------------------------------------------------------
# template'e çevir
# ------------------------------------------------------------
make_template() {
  local vmid="$1"

  log "Converting VM $vmid to template (idempotent)"
  qm template "$vmid" || true

  log "============== VM $vmid config =============="
  qm config "$vmid"
  log "============================================="
}

# ------------------------------------------------------------
# 9000/10000/... seç
# ------------------------------------------------------------
pick_vmid_base() {
  # elle verildiyse kullan
  if [[ -n "${VMID_BASE:-}" ]]; then
    echo "$VMID_BASE"
    return
  fi

  local candidates=(9000 10000 11000 12000 13000 14000)

  for base in "${candidates[@]}"; do
    local used=0
    for off in 0 1 2; do
      local id=$((base + off))
      if has_vmid_cluster "$id"; then
        used=1
        break
      fi
    done
    if [[ $used -eq 0 ]]; then
      echo "$base"
      return
    fi
  done

  echo "none"
}

# ------------------------------------------------------------
# TEMPLATE LİSTESİ
# ------------------------------------------------------------
TEMPLATES=(
  "ubuntu-24-cloud|https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img|noble-server-cloudimg-amd64.img|local|vmbr0|2048"
  "debian-12-cloud|https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2|debian-12-genericcloud-amd64.qcow2|local|vmbr0|2048"
  "ubuntu-22-cloud|https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img|jammy-server-cloudimg-amd64.img|local|vmbr0|2048"
)

# ------------------------------------------------------------
# ana akış
# ------------------------------------------------------------
log "==> Cloud templates provisioning started on host: $(hostname)"

ensure_package "wget"
ensure_dir "$DEFAULT_IMG_DIR"

VMID_BASE=$(pick_vmid_base)
if [[ "$VMID_BASE" == "none" ]]; then
  log "UYARI: 9000/10000/11000 ... hepsi cluster'da dolu görünüyor. Çıkıyorum."
  exit 1
fi
log "Using VMID base: $VMID_BASE"

idx=0
for entry in "${TEMPLATES[@]}"; do
  IFS="|" read -r VMNAME IMG_URL IMG_FILE STORAGE BRIDGE MEMORY_MB <<<"$entry"
  VMID=$((VMID_BASE + idx))
  idx=$((idx + 1))

  IMG_PATH="${DEFAULT_IMG_DIR}/${IMG_FILE}"

  log "--- processing template: $VMID ($VMNAME) ---"

  download_if_missing "$IMG_URL" "$IMG_PATH"
  customize_cloud_image "$IMG_PATH"

  # create
  create_or_update_vm "$VMID" "$VMNAME" "$MEMORY_MB" "$BRIDGE"

  import_disk_if_needed "$VMID" "$IMG_PATH" "$STORAGE"
  attach_cloudinit_and_boot "$VMID" "$STORAGE"
  make_template "$VMID"

  log "--- done: $VMID ($VMNAME) ---"
  echo
done

log "✅ All templates processed."
