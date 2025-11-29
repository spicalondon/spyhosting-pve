#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Proxmox VM soft stop script
#  - Belirtilen base numarasından başlayan VM'leri DURDURUR
#  - --base parametresi zorunlu
#  - Template'lere DOKUNMAZ (sadece normal VM'ler)
#  - Çalışan VM'lerde önce "qm shutdown", timeout olursa "qm stop"
#
# Kullanım:
#   ./soft-stop-vms.sh --base 100000
#   ./soft-stop-vms.sh --base 100000 --count 10
#   ./soft-stop-vms.sh --base 100000 --include-templates
#   ./soft-stop-vms.sh --base 100000 --dry-run
# ============================================================

log() { echo "[$(date +%H:%M:%S)] $*"; }

VMID_BASE=""
DRY_RUN=0
VM_COUNT=0            # 0 = sınırsız
INCLUDE_TEMPLATES=0   # template'leri de durdur?
SHUTDOWN_TIMEOUT=60   # qm shutdown timeout
MAX_CHECK=1000        # güvenlik için max VMID tarama

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
      --shutdown-timeout)
        SHUTDOWN_TIMEOUT="$2"
        shift 2
        ;;
      --help|-h)
        echo "Kullanım: $0 --base <vmid> [OPTIONS]"
        echo ""
        echo "Seçenekler:"
        echo "  --base <vmid>           VMID başlangıç numarası (zorunlu)"
        echo "  --count <number>        Kaç VM işleneceği (varsayılan: sınırsız)"
        echo "  --include-templates     Template'leri de işleme dahil et"
        echo "  --dry-run               Sadece göster, kapatma yapma"
        echo "  --shutdown-timeout <s>  qm shutdown timeout (varsayılan: 60)"
        echo ""
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
  echo "Bu script root olarak çalışmalı (sudo ./soft-stop-vms.sh ...)"
  exit 1
fi

parse_arguments "$@"

# --base zorunlu
if [[ -z "$VMID_BASE" ]]; then
  echo "HATA: --base parametresi zorunlu!"
  echo "Örnek: $0 --base 100000"
  exit 1
fi

# sayısal mı kontrol et
if ! [[ "$VMID_BASE" =~ ^[0-9]+$ ]]; then
  echo "HATA: --base sayısal bir değer olmalı!"
  exit 1
fi

log "==> VM soft stop started"
log "Base VMID: $VMID_BASE"
[[ $VM_COUNT -gt 0 ]] && log "VM count limit: $VM_COUNT"
[[ $INCLUDE_TEMPLATES -eq 1 ]] && log "Include templates: YES" || log "Include templates: NO (only VMs)"
[[ $DRY_RUN -eq 1 ]] && log "DRY RUN MODE (no actual stop)"

soft_stop_vm() {
  local vmid="$1"
  local conf="/etc/pve/qemu-server/${vmid}.conf"

  # config yoksa uğraşma
  if [[ ! -f "$conf" ]]; then
    return 1
  fi

  # template mi?
  local is_template=0
  if grep -q "^template:" "$conf" 2>/dev/null; then
    is_template=1
  fi

  if [[ $is_template -eq 1 ]] && [[ $INCLUDE_TEMPLATES -eq 0 ]]; then
    return 1
  fi

  local vm_name
  vm_name=$(grep "^name:" "$conf" | awk '{print $2}' || echo "unknown")

  local vm_status
  vm_status=$(qm status "$vmid" 2>/dev/null | awk '{print $2}' || echo "unknown")

  local vm_type="VM"
  [[ $is_template -eq 1 ]] && vm_type="TEMPLATE"

  # Çalışmıyorsa dokunma
  if [[ "$vm_status" != "running" ]]; then
    log "  Skipping $vm_type VMID $vmid ($vm_name) [status: $vm_status]"
    return 0
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    log "  [DRY-RUN] Would soft stop $vm_type VMID $vmid ($vm_name) [status: $vm_status]"
    return 0
  fi

  log "  Soft stopping $vm_type VMID $vmid ($vm_name)..."
  # Senin one-liner: shutdown, olmazsa stop
  if ! qm shutdown "$vmid" --timeout "$SHUTDOWN_TIMEOUT" 2>&1; then
    log "    Shutdown timeout/failed, falling back to qm stop..."
    qm stop "$vmid" 2>&1 || true
  fi

  sleep 2

  local vm_status_final
  vm_status_final=$(qm status "$vmid" 2>/dev/null | awk '{print $2}' || echo "unknown")

  if [[ "$vm_status_final" == "stopped" ]]; then
    log "  ✓ Successfully stopped VMID $vmid"
    return 0
  else
    log "  ✗ Failed to stop VMID $vmid (status: $vm_status_final)"
    return 1
  fi
}

stopped_count=0
skipped_count=0
checked_count=0

log ""
log "Scanning for VMs starting from VMID $VMID_BASE..."
log ""

for offset in $(seq 0 $((MAX_CHECK - 1))); do
  vmid=$((VMID_BASE + offset))

  # count limiti varsa ve ulaştıysak dur
  if [[ $VM_COUNT -gt 0 ]] && [[ $checked_count -ge $VM_COUNT ]]; then
    log ""
    log "Reached VM count limit ($VM_COUNT), stopping."
    break
  fi

  if [[ ! -f "/etc/pve/qemu-server/${vmid}.conf" ]]; then
    continue
  fi

  checked_count=$((checked_count + 1))

  if soft_stop_vm "$vmid"; then
    stopped_count=$((stopped_count + 1))
  else
    skipped_count=$((skipped_count + 1))
  fi
done

log ""
log "==> Soft stop completed"
log "VMs/Templates found: $checked_count"
log "VMs/Templates stopped: $stopped_count"
log "VMs/Templates skipped: $skipped_count"

if [[ $DRY_RUN -eq 1 ]]; then
  log ""
  log "This was a DRY RUN. To actually stop, run without --dry-run flag."
fi
