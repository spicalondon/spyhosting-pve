#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Proxmox cloud template provisioner
#  - gerekli paketleri kurar (wget, libguestfs-tools)
#  - cloud image indirir
#  - image'i patch'ler (root + ssh_pwauth)
#  - VM oluşturup template'e çevirir
#  - cluster'da 100 doluysa otomatik 200, sonra 300...
#
# Kullanım:
#   ./provision-templates.sh                           # tüm template'leri sırayla kur
#   ./provision-templates.sh --templates 0,2           # sadece 0 ve 2 numaralı template'leri kur
#   ./provision-templates.sh --templates debian-12,ubuntu-24  # isme göre seçim
#   ./provision-templates.sh --order 2,0,1             # sırayı değiştirerek kur
# ============================================================

# ------------------------------------------------------------
# TEMPLATE LİSTESİ
# ------------------------------------------------------------
TEMPLATES=(
  "ubuntu-24-cloud|https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img|noble-server-cloudimg-amd64.img|local-lvm|vmbr0|2048"
  "ubuntu-22-cloud|https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img|jammy-server-cloudimg-amd64.img|local-lvm|vmbr0|2048"
  "ubuntu-20-cloud|https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64.img|focal-server-cloudimg-amd64.img|local-lvm|vmbr0|2048"
  "debian-12-cloud|https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2|debian-12-genericcloud-amd64.qcow2|local-lvm|vmbr0|2048"
)

MIN_TEMPLATE_VMID=100
MAX_TEMPLATE_VMID=99999

DEFAULT_IMG_DIR="/var/lib/vz/template/qemu"
DEFAULT_STORAGE="local-lvm"
DEFAULT_BRIDGE="vmbr0"
DEFAULT_MEMORY=2048

# kurulum sırası/seçimi için parametreler
TEMPLATE_SELECTION=""
TEMPLATE_ORDER=""

log() { echo "[$(date +%H:%M:%S)] $*"; }

# ------------------------------------------------------------
# parametre parse
# ------------------------------------------------------------
parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --templates)
        TEMPLATE_SELECTION="$2"
        shift 2
        ;;
      --order)
        TEMPLATE_ORDER="$2"
        shift 2
        ;;
      --help|-h)
        echo "Kullanım: $0 [OPTIONS]"
        echo ""
        echo "Seçenekler:"
        echo "  --templates <list>   Kurulacak template'leri belirt (indeks veya isim, virgülle ayrılmış)"
        echo "                       Örnek: --templates 0,2  veya  --templates debian-12,ubuntu-24"
        echo "  --order <list>       Template kurulum sırasını belirt (indeksler, virgülle ayrılmış)"
        echo "                       Örnek: --order 2,0,1"
        echo "  --help               Bu yardım mesajını göster"
        echo ""
        echo "Mevcut template'ler:"
        echo "  [0] ubuntu-24-cloud"
        echo "  [1] debian-12-cloud"
        echo "  [2] ubuntu-22-cloud"
        exit 0
        ;;
      *)
        echo "Bilinmeyen parametre: $1"
        echo "Yardım için: $0 --help"
        exit 1
        ;;
    esac
  done
}

# root kontrolü
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "bu script root olarak çalışmalı (sudo ./script.sh)"
  exit 1
fi

# parametreleri parse et
parse_arguments "$@"

# ------------------------------------------------------------
# apt helper
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
# vm oluştur / güncelle
# (cluster'da bu id başka node'a aitse create etmiyoruz)
# ------------------------------------------------------------
create_or_update_vm() {
  local vmid="$1"
  local name="$2"
  local mem="$3"
  local bridge="$4"

  local conf="/etc/pve/qemu-server/${vmid}.conf"
  local this_node
  this_node=$(hostname)

  if [[ -f "$conf" ]]; then
    # conf içinden node satırını çek
    local owner_node
    owner_node=$(awk '/^node:/{print $2}' "$conf" || true)

    if [[ -n "$owner_node" && "$owner_node" != "$this_node" ]]; then
      log "VMID $vmid cluster'da var ama node '$owner_node' üzerinde, bu node'da create etmiyorum."
      return 1
    fi
    
    log "VMID $vmid already exists on this node, will only update config."
    return 0
  fi

  log "Creating base VM $vmid ($name)"
  if ! qm create "$vmid" --name "$name" --memory "$mem" --net0 "virtio,bridge=$bridge" 2>&1; then
    log "ERROR: qm create failed for VMID $vmid (VM might exist without config file)"
    return 2
  fi
  return 0
}

# ------------------------------------------------------------
# diski import et
# ------------------------------------------------------------
import_disk_if_needed() {
  local vmid="$1"
  local img_path="$2"
  local storage="$3"

  # Storage tipine göre disk yolunu belirle
  local disk_exists=false
  if [[ "$storage" == "local-lvm" ]]; then
    # LVM için logical volume kontrolü
    if lvs "pve/vm-$vmid-disk-0" >/dev/null 2>&1; then
      disk_exists=true
    fi
  else
    # Dosya tabanlı storage için
    local target="/var/lib/vz/images/$vmid/vm-$vmid-disk-0.raw"
    if [[ -f "$target" ]]; then
      disk_exists=true
    fi
  fi

  if $disk_exists; then
    log "Disk already imported for VM $vmid (skip import)"
  else
    log "Importing disk $img_path -> VM $vmid on storage $storage"
    qm importdisk "$vmid" "$img_path" "$storage"
  fi

  log "Attaching disk as scsi0 on VM $vmid"
  qm set "$vmid" --scsihw virtio-scsi-pci --scsi0 "$storage:vm-$vmid-disk-0"
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
# template var mı kontrol et
# ------------------------------------------------------------
is_template_exists() {
  local vmid="$1"
  local conf="/etc/pve/qemu-server/${vmid}.conf"

  # config dosyası var mı?
  if [[ ! -f "$conf" ]]; then
    return 1  # yok
  fi

  # template mi kontrol et
  if grep -q "^template:" "$conf" 2>/dev/null; then
    return 0  # template var
  fi

  return 1  # config var ama template değil
}

# ------------------------------------------------------------
# cluster-wide VMID seçimi - cluster'daki tüm node'larda boş base ara
#  - base'leri 100, 200, 300, ... şeklinde dener
#  - tüm template'ler için contiguous blok bulur
#  - hiçbir VMID MAX_TEMPLATE_VMID (99999) üstüne çıkmaz
# ------------------------------------------------------------
pick_vmid_base() {
  # Elle VMID_BASE environment variable ile geldiyse onu kullan
  if [[ -n "${VMID_BASE:-}" ]]; then
    echo "$VMID_BASE"
    return
  fi

  local template_count=${#ACTIVE_TEMPLATES[@]}  # kaç template kurulacak?
  local min_vmid="${MIN_TEMPLATE_VMID}"
  local max_vmid="${MAX_TEMPLATE_VMID}"

  # Bütün template'leri aynı blokta tutmak için:
  # base + (template_count - 1) <= max_vmid olmalı
  local max_base=$((max_vmid - template_count + 1))
  if (( max_base < min_vmid )); then
    echo "DEBUG: No possible base in ${min_vmid}-${max_vmid} for ${template_count} templates" >&2
    echo "none"
    return
  fi

  # max_base'i en yakın 100'lüğe AŞAĞI yuvarla (100, 200, ... gibi gidiyoruz)
  max_base=$(( (max_base / 100) * 100 ))

  echo "DEBUG: pick_vmid_base: min_vmid=${min_vmid}, max_vmid=${max_vmid}, template_count=${template_count}, max_base=${max_base}" >&2

  local base
  for base in $(seq "${min_vmid}" 100 "${max_base}"); do
    local blacklist_file="/tmp/.vmid_base_${base}_occupied"

    echo "DEBUG: Checking base $base, blacklist file: $blacklist_file" >&2

    # Daha önce başarısız olup blacklist edilen base'leri atla
    if [[ -f "$blacklist_file" ]]; then
      echo "DEBUG: Base $base is blacklisted, skipping" >&2
      continue
    fi

    local all_free=1

    # base, base+1, ... base+(template_count-1) id'leri boş mu?
    for off in $(seq 0 $((template_count - 1))); do
      local id=$((base + off))

      # Güvenlik: id max_vmid'i geçmesin
      if (( id > max_vmid )); then
        echo "DEBUG: ID $id > max_vmid $max_vmid, base $base is invalid" >&2
        all_free=0
        break
      fi

      if [[ -f "/etc/pve/qemu-server/${id}.conf" ]]; then
        echo "DEBUG: VMID $id has config file, base $base not available" >&2
        all_free=0
        break
      fi
    done

    if [[ $all_free -eq 1 ]]; then
      echo "DEBUG: Base $base selected!" >&2
      echo "$base"
      return
    fi
  done

  echo "DEBUG: No free base found in ${min_vmid}-${max_base}" >&2
  echo "none"
}

# ------------------------------------------------------------
# template seçim/sıralama fonksiyonu
# ------------------------------------------------------------
build_template_list() {
  local -a result=()

  # --order parametresi varsa, sadece o sırayı kullan
  if [[ -n "$TEMPLATE_ORDER" ]]; then
    log "Template kurulum sırası: $TEMPLATE_ORDER"
    IFS=',' read -ra INDICES <<<"$TEMPLATE_ORDER"
    for idx in "${INDICES[@]}"; do
      idx=$(echo "$idx" | xargs)  # trim whitespace
      if [[ "$idx" =~ ^[0-9]+$ ]] && [[ $idx -lt ${#TEMPLATES[@]} ]]; then
        result+=("${TEMPLATES[$idx]}")
      else
        log "UYARI: geçersiz indeks '$idx', atlıyorum"
      fi
    done
    # her elemanı ayrı satırda yazdır
    printf '%s\n' "${result[@]}"
    return
  fi

  # --templates parametresi varsa, seçili template'leri al
  if [[ -n "$TEMPLATE_SELECTION" ]]; then
    log "Seçili template'ler: $TEMPLATE_SELECTION"
    IFS=',' read -ra SELECTION <<<"$TEMPLATE_SELECTION"

    for sel in "${SELECTION[@]}"; do
      sel=$(echo "$sel" | xargs)  # trim whitespace

      # sayısal indeks mi?
      if [[ "$sel" =~ ^[0-9]+$ ]]; then
        if [[ $sel -lt ${#TEMPLATES[@]} ]]; then
          result+=("${TEMPLATES[$sel]}")
        else
          log "UYARI: geçersiz indeks '$sel', atlıyorum"
        fi
      else
        # isim ile arama
        local found=0
        for tmpl in "${TEMPLATES[@]}"; do
          IFS="|" read -r VMNAME _ <<<"$tmpl"
          if [[ "$VMNAME" == "$sel" ]]; then
            result+=("$tmpl")
            found=1
            break
          fi
        done
        if [[ $found -eq 0 ]]; then
          log "UYARI: '$sel' isimli template bulunamadı, atlıyorum"
        fi
      fi
    done

    # her elemanı ayrı satırda yazdır
    printf '%s\n' "${result[@]}"
    return
  fi

  # parametre yoksa tüm template'leri döndür (her biri ayrı satırda)
  printf '%s\n' "${TEMPLATES[@]}"
}

# Aktif template listesini oluştur
readarray -t ACTIVE_TEMPLATES < <(build_template_list)

if [[ ${#ACTIVE_TEMPLATES[@]} -eq 0 ]]; then
  log "HATA: Kurulacak hiç template yok!"
  exit 1
fi

log "Kurulacak template sayısı: ${#ACTIVE_TEMPLATES[@]}"

# Template listesini göster
log "Template'ler:"
for i in "${!ACTIVE_TEMPLATES[@]}"; do
  IFS="|" read -r VMNAME _ <<<"${ACTIVE_TEMPLATES[$i]}"
  log "  [$i] $VMNAME"
done

# ------------------------------------------------------------
# ana akış
# ------------------------------------------------------------
log "==> Cloud templates provisioning started on host: $(hostname)"

# temiz başlangıç: eski blacklist dosyalarını sil
rm -f /tmp/.vmid_base_*_occupied

ensure_package "wget"
ensure_dir "$DEFAULT_IMG_DIR"

# retry loop for finding available base
attempt=0
max_attempts=5
while [[ $attempt -lt $max_attempts ]]; do
  log "=== Attempt $((attempt + 1)) of $max_attempts ==="
  
  # Her attempt'te VMID_BASE'i temizle
  unset VMID_BASE
  
  # blacklist durumunu göster
  log "Current blacklist status:"
  if ls /tmp/.vmid_base_*_occupied >/dev/null 2>&1; then
    for f in /tmp/.vmid_base_*_occupied; do
      log "  - $(basename "$f")"
    done
  else
    log "  (no blacklisted bases)"
  fi
  
  # Manuel test: 100 blacklist'te mi?
  if [[ -f "/tmp/.vmid_base_100_occupied" ]]; then
    log "MANUAL CHECK: Base 100 IS blacklisted (file exists)"
  else
    log "MANUAL CHECK: Base 100 is NOT blacklisted (file does not exist)"
  fi
  
  # Sadece stdout yakala, stderr terminale gitsin (debug için)
  log "About to call pick_vmid_base()..."
  VMID_BASE=$(pick_vmid_base)
  log "pick_vmid_base() returned: $VMID_BASE"
  
  if [[ "$VMID_BASE" == "none" ]]; then
    log "UYARI: uygun VMID base bulunamadı. Çıkıyorum."
    exit 1
  fi

  log "Selected VMID base: $VMID_BASE"

  success=true
  idx=0
  for entry in "${ACTIVE_TEMPLATES[@]}"; do
    IFS="|" read -r VMNAME IMG_URL IMG_FILE STORAGE BRIDGE MEMORY_MB <<<"$entry"
    VMID=$((VMID_BASE + idx))
    idx=$((idx + 1))

    # VM adını t{VMID}-{TEMPLATE_NAME} formatında oluştur
    VM_DISPLAY_NAME="t${VMID}-${VMNAME}"

    log "--- checking template: $VMID ($VM_DISPLAY_NAME) ---"

    # Template zaten var mı kontrol et
    if is_template_exists "$VMID"; then
      log "✓ Template already exists for VMID $VMID, skipping..."
      echo
      continue
    fi

    log "✗ Template missing for VMID $VMID, installing..."

    IMG_PATH="${DEFAULT_IMG_DIR}/${IMG_FILE}"

    download_if_missing "$IMG_URL" "$IMG_PATH"
    customize_cloud_image "$IMG_PATH"

    create_result=0
    create_or_update_vm "$VMID" "$VM_DISPLAY_NAME" "$MEMORY_MB" "$BRIDGE" || create_result=$?

    if [[ $create_result -eq 1 ]]; then
      log "Skipping VMID $VMID (belongs to another node)"
      echo
      continue
    elif [[ $create_result -eq 2 ]]; then
      blacklist_file="/tmp/.vmid_base_${VMID_BASE}_occupied"
      log "VM creation failed for $VMID, marking base $VMID_BASE as occupied"
      log "Creating blacklist file: $blacklist_file"
      touch "$blacklist_file" || log "ERROR: touch command failed!"
      chmod 666 "$blacklist_file" 2>/dev/null || true

      # dosya gerçekten oluşturuldu mu kontrol et
      if [[ -f "$blacklist_file" ]]; then
        log "✓ Blacklist file created: $blacklist_file"
        ls -la "$blacklist_file"
        log "Current blacklist files:"
        ls -la /tmp/.vmid_base_*_occupied 2>/dev/null || log "  (none)"
      else
        log "✗ FAILED to create blacklist file: $blacklist_file"
      fi
      success=false
      break
    fi

    import_disk_if_needed "$VMID" "$IMG_PATH" "$STORAGE"
    attach_cloudinit_and_boot "$VMID" "$STORAGE"
    make_template "$VMID"

    log "--- done: $VMID ($VMNAME) ---"
    echo
  done

  if [[ "$success" == "true" ]]; then
    log "✅ All templates processed successfully."
    exit 0
  fi

  # başarısız olduysa, bu base'i skip et ve tekrar dene
  log "Base $VMID_BASE failed, will retry with next available base..."
  log "Sleeping 2 seconds before retry..."
  sleep 2
  attempt=$((attempt + 1))
done

log "ERROR: Could not find available VMID base after $max_attempts attempts"
exit 1
