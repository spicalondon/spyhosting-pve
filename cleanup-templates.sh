#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Proxmox cloud template cleanup script
#  - Belirtilen base numarasından başlayan template'leri siler
#  - --base parametresi zorunlu
#  - --dry-run ile önce simülasyon yapılabilir
#
# Kullanım:
#   ./cleanup-templates.sh --base 100                    # 100, 101, 102, 103... template'leri sil
#   ./cleanup-templates.sh --base 200 --dry-run          # sadece göster, silme
#   ./cleanup-templates.sh --base 100 --count 4          # sadece 4 template sil (100-103)
# ============================================================

log() { echo "[$(date +%H:%M:%S)] $*"; }

# Parametreler
VMID_BASE=""
DRY_RUN=0
TEMPLATE_COUNT=0  # 0 = sınırsız

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
        TEMPLATE_COUNT="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --help|-h)
        echo "Kullanım: $0 --base <vmid> [OPTIONS]"
        echo ""
        echo "Seçenekler:"
        echo "  --base <vmid>        VMID başlangıç numarası (zorunlu)"
        echo "                       Örnek: --base 100  (100, 101, 102... template'leri siler)"
        echo "  --count <number>     Kaç template silineceği (opsiyonel, varsayılan: tümü)"
        echo "                       Örnek: --count 4  (sadece 4 template siler)"
        echo "  --dry-run            Sadece göster, silme işlemi yapma"
        echo "  --help               Bu yardım mesajını göster"
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
  echo "Örnek: $0 --base 100"
  echo "Yardım için: $0 --help"
  exit 1
fi

# sayısal mı kontrol et
if ! [[ "$VMID_BASE" =~ ^[0-9]+$ ]]; then
  echo "HATA: --base sayısal bir değer olmalı!"
  exit 1
fi

log "==> Template cleanup started"
log "Base VMID: $VMID_BASE"
[[ $TEMPLATE_COUNT -gt 0 ]] && log "Template count limit: $TEMPLATE_COUNT"
[[ $DRY_RUN -eq 1 ]] && log "DRY RUN MODE (no actual deletion)"

# ------------------------------------------------------------
# template'i sil
# ------------------------------------------------------------
delete_template() {
  local vmid="$1"
  local conf="/etc/pve/qemu-server/${vmid}.conf"

  # config dosyası var mı?
  if [[ ! -f "$conf" ]]; then
    log "  ✗ VMID $vmid: config bulunamadı, atlıyorum"
    return 1
  fi

  # template mi kontrol et
  if ! grep -q "^template:" "$conf" 2>/dev/null; then
    log "  ✗ VMID $vmid: template değil, atlıyorum (normal VM olabilir)"
    return 1
  fi

  # template adını al
  local vm_name
  vm_name=$(grep "^name:" "$conf" | awk '{print $2}' || echo "unknown")

  if [[ $DRY_RUN -eq 1 ]]; then
    log "  [DRY-RUN] Would delete VMID $vmid ($vm_name)"
    return 0
  fi

  log "  Deleting template VMID $vmid ($vm_name)..."
  if qm destroy "$vmid" --purge 2>&1; then
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
checked_count=0
max_check=100  # güvenlik için max 100 VMID kontrol et

log ""
log "Scanning for templates starting from VMID $VMID_BASE..."
log ""

for offset in $(seq 0 $((max_check - 1))); do
  vmid=$((VMID_BASE + offset))

  # count limiti varsa ve ulaştıysak dur
  if [[ $TEMPLATE_COUNT -gt 0 ]] && [[ $deleted_count -ge $TEMPLATE_COUNT ]]; then
    log ""
    log "Reached template count limit ($TEMPLATE_COUNT), stopping."
    break
  fi

  checked_count=$((checked_count + 1))

  # template sil
  if delete_template "$vmid"; then
    deleted_count=$((deleted_count + 1))
  fi
done

log ""
log "==> Cleanup completed"
log "Templates checked: $checked_count"
log "Templates deleted: $deleted_count"

if [[ $DRY_RUN -eq 1 ]]; then
  log ""
  log "This was a DRY RUN. To actually delete, run without --dry-run flag."
fi
