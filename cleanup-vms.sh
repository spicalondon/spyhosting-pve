#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Proxmox VM cleanup script
#  - Belirtilen base numarasından başlayan VM'leri siler
#  - --base parametresi zorunlu
#  - --dry-run ile önce simülasyon yapılabilir
#  - Template'lere DOKUNMAZ (sadece normal VM'ler)
#
# Kullanım:
#   ./cleanup-vms.sh --base 1000                    # 1000, 1001, 1002... VM'leri sil
#   ./cleanup-vms.sh --base 2000 --dry-run          # sadece göster, silme
#   ./cleanup-vms.sh --base 1000 --count 10         # sadece 10 VM sil (1000-1009)
#   ./cleanup-vms.sh --base 1000 --include-templates # template'leri de sil
# ============================================================

log() { echo "[$(date +%H:%M:%S)] $*"; }

# Parametreler
VMID_BASE=""
DRY_RUN=0
VM_COUNT=0  # 0 = sınırsız
INCLUDE_TEMPLATES=0  # template'leri de sil mi?

# ------------------------------------------------------------
# parametre parse
# ------------------------------------------------------------
parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --base)
        VMID_BASE="$2"
        shift 2
        ;;
      --count)
        VM_COUNT="$2"
        shift 2
        ;;
      --include-templates)
        INCLUDE_TEMPLATES=1
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --help|-h)
        echo "Kullanım: $0 --base <vmid> [OPTIONS]"
        echo ""
        echo "Seçenekler:"
        echo "  --base <vmid>           VMID başlangıç numarası (zorunlu)"
        echo "                          Örnek: --base 1000  (1000, 1001, 1002... VM'leri siler)"
        echo "  --count <number>        Kaç VM silineceği (opsiyonel, varsayılan: tümü)"
        echo "                          Örnek: --count 10  (sadece 10 VM siler)"
        echo "  --include-templates     Template'leri de sil (varsayılan: sadece VM'ler)"
        echo "  --dry-run               Sadece göster, silme işlemi yapma"
        echo "  --help                  Bu yardım mesajını göster"
        echo ""
        echo "NOT: Varsayılan olarak sadece normal VM'ler silinir, template'ler korunur."
        echo "     Template'leri de silmek için --include-templates kullanın."
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

# --base zorunlu
if [[ -z "$VMID_BASE" ]]; then
  echo "HATA: --base parametresi zorunlu!"
  echo "Örnek: $0 --base 1000"
  echo "Yardım için: $0 --help"
  exit 1
fi

# sayısal mı kontrol et
if ! [[ "$VMID_BASE" =~ ^[0-9]+$ ]]; then
  echo "HATA: --base sayısal bir değer olmalı!"
  exit 1
fi

log "==> VM cleanup started"
log "Base VMID: $VMID_BASE"
[[ $VM_COUNT -gt 0 ]] && log "VM count limit: $VM_COUNT"
[[ $INCLUDE_TEMPLATES -eq 1 ]] && log "Include templates: YES" || log "Include templates: NO (only VMs)"
[[ $DRY_RUN -eq 1 ]] && log "DRY RUN MODE (no actual deletion)"

# ------------------------------------------------------------
# VM'i sil
# ------------------------------------------------------------
delete_vm() {
  local vmid="$1"
  local conf="/etc/pve/qemu-server/${vmid}.conf"

  # config dosyası var mı?
  if [[ ! -f "$conf" ]]; then
    return 1  # yok, atla
  fi

  # template mi kontrol et
  local is_template=0
  if grep -q "^template:" "$conf" 2>/dev/null; then
    is_template=1
  fi

  # template ise ve include_templates=0 ise atla
  if [[ $is_template -eq 1 ]] && [[ $INCLUDE_TEMPLATES -eq 0 ]]; then
    return 1  # template, atla
  fi

  # VM adını al
  local vm_name
  vm_name=$(grep "^name:" "$conf" | awk '{print $2}' || echo "unknown")

  # VM durumunu kontrol et
  local vm_status
  vm_status=$(qm status "$vmid" 2>/dev/null | awk '{print $2}' || echo "unknown")

  local vm_type="VM"
  [[ $is_template -eq 1 ]] && vm_type="TEMPLATE"

  if [[ $DRY_RUN -eq 1 ]]; then
    log "  [DRY-RUN] Would delete $vm_type VMID $vmid ($vm_name) [status: $vm_status]"
    return 0
  fi

  # Çalışan VM'i durdur
  if [[ "$vm_status" == "running" ]]; then
    log "  Stopping running $vm_type VMID $vmid ($vm_name)..."
    qm stop "$vmid" --timeout 10 2>&1 || qm stop "$vmid" --skiplock 2>&1 || true
    sleep 2
  fi

  log "  Deleting $vm_type VMID $vmid ($vm_name)..."
  if qm destroy "$vmid" --purge --skiplock 2>&1; then
    log "  ✓ Successfully deleted VMID $vmid"
    return 0
  else
    log "  ✗ Failed to delete VMID $vmid"
    return 1
  fi
}

# ------------------------------------------------------------
# ana döngü
# ------------------------------------------------------------
deleted_count=0
skipped_count=0
checked_count=0
max_check=1000  # güvenlik için max 1000 VMID kontrol et

log ""
log "Scanning for VMs starting from VMID $VMID_BASE..."
log ""

for offset in $(seq 0 $((max_check - 1))); do
  vmid=$((VMID_BASE + offset))

  # count limiti varsa ve ulaştıysak dur
  if [[ $VM_COUNT -gt 0 ]] && [[ $deleted_count -ge $VM_COUNT ]]; then
    log ""
    log "Reached VM count limit ($VM_COUNT), stopping."
    break
  fi

  # config var mı kontrol et
  if [[ ! -f "/etc/pve/qemu-server/${vmid}.conf" ]]; then
    continue  # yok, atla (log'a ekleme, gürültü olmasın)
  fi

  checked_count=$((checked_count + 1))

  # VM sil
  if delete_vm "$vmid"; then
    deleted_count=$((deleted_count + 1))
  else
    skipped_count=$((skipped_count + 1))
  fi
done

log ""
log "==> Cleanup completed"
log "VMs/Templates found: $checked_count"
log "VMs/Templates deleted: $deleted_count"
log "VMs/Templates skipped: $skipped_count"

if [[ $DRY_RUN -eq 1 ]]; then
  log ""
  log "This was a DRY RUN. To actually delete, run without --dry-run flag."
fi
