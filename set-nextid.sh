#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Proxmox VMID Allocation Configuration Script
#
# Bu script cluster-level next-id aralığını ayarlar:
#   - 0-99,999: Template/özel işler için (manuel atama)
#   - 100,000+: Normal VM'ler için otomatik atama (nextid)
#
# NOT:
#   - Proxmox bu iş için "next-id" key'ini kullanır
#   - /etc/pve/datacenter.cfg dosyasını pvesh kendisi günceller
# ============================================================

log() { echo "[$(date +%H:%M:%S)] $*"; }

# Root kontrolü
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "Bu script root olarak çalışmalı (sudo $0)"
  exit 1
fi

if ! command -v pvesh >/dev/null 2>&1; then
  echo "pvesh komutu bulunamadı. Bu script sadece Proxmox host üzerinde çalıştırılmalı."
  exit 1
fi

DATACENTER_CFG="/etc/pve/datacenter.cfg"

log "Proxmox next-id VMID aralığı yapılandırılıyor..."
log "Hedef aralık: 100000 - 999999999 (otomatik atama)"

# datacenter.cfg varsa yedek al (opsiyonel ama güzel durur)
if [[ -f "$DATACENTER_CFG" ]]; then
  BACKUP_FILE="${DATACENTER_CFG}.backup.$(date +%Y%m%d_%H%M%S)"
  log "Mevcut datacenter.cfg bulundu, yedek oluşturuluyor: $BACKUP_FILE"
  cp "$DATACENTER_CFG" "$BACKUP_FILE"
else
  log "datacenter.cfg henüz yok, Proxmox gerekli gördüğünde oluşturacak."
fi

# next-id ayarını Proxmox API üzerinden set et
log "next-id ayarı uygulanıyor..."
pvesh set /cluster/options --next-id lower=100000,upper=999999999 >/dev/null

log "✅ next-id ayarı Proxmox cluster options içine yazıldı."

log ""
log "Güncel /cluster/options içinden next-id bilgisi:"
pvesh get /cluster/options | awk '
  /^next-id:/ {print; in_block=1; next}
  in_block && NF==0 {in_block=0}
  in_block {print}
'

log ""
log "Yeni datacenter.cfg içeriği (varsa):"
if [[ -f "$DATACENTER_CFG" ]]; then
  cat "$DATACENTER_CFG"
else
  log "datacenter.cfg henüz oluşturulmamış olabilir (bu normal)."
fi

log ""
log "📋 Özet:"
log "  - Template/özel VMID: 0-99,999 (manuel atama)"
log "  - Normal VM'ler: 100,000+ (otomatik atama, pvesh/GUI next-id)"
log ""
log "⚠️  Notlar:"
log "  - Bu ayar cluster'daki TÜM node'lar için geçerlidir"
log "  - Mevcut VM'lerin VMID'lerini değiştirmez"
log "  - Sadece yeni otomatik seçilecek ID'leri etkiler"
log ""

# Test et
log "Test ediliyor: pvesh get /cluster/nextid çıktısı..."
NEXT_ID="$(pvesh get /cluster/nextid 2>&1 || echo "test-failed")"

if [[ "$NEXT_ID" =~ ^[0-9]+$ ]] && (( NEXT_ID >= 100000 )); then
  log "✅ Test başarılı! Sonraki otomatik VMID: $NEXT_ID"
else
  log "⚠️  Test sonucu beklenenden farklı: $NEXT_ID"
  log "   (Gerekirse manuel VMID vermek için: qm create <vmid> --name <name>)"
fi

log ""
log "🎉 Konfigürasyon tamamlandı!"
