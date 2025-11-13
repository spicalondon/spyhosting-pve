#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Proxmox VMID Allocation Configuration Script
#
# Bu script Proxmox datacenter.cfg dosyasını düzenleyerek
# VMID allocation range'ini ayarlar:
#   - 0-99999: Template'ler için rezerve (manuel atama)
#   - 100000+: Normal VM'ler için otomatik atama
# ============================================================

log() { echo "[$(date +%H:%M:%S)] $*"; }

# Root kontrolü
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "Bu script root olarak çalışmalı (sudo $0)"
  exit 1
fi

DATACENTER_CFG="/etc/pve/datacenter.cfg"

log "Proxmox datacenter.cfg dosyası kontrol ediliyor..."

# Datacenter.cfg yoksa oluştur
if [[ ! -f "$DATACENTER_CFG" ]]; then
  log "datacenter.cfg bulunamadı, yeni dosya oluşturuluyor..."
  touch "$DATACENTER_CFG"
fi

# Mevcut vm-id-allocation satırını kontrol et
if grep -q "^vm-id-allocation:" "$DATACENTER_CFG"; then
  log "Mevcut vm-id-allocation ayarı bulundu:"
  grep "^vm-id-allocation:" "$DATACENTER_CFG"

  # Backup al
  BACKUP_FILE="${DATACENTER_CFG}.backup.$(date +%Y%m%d_%H%M%S)"
  log "Backup oluşturuluyor: $BACKUP_FILE"
  cp "$DATACENTER_CFG" "$BACKUP_FILE"

  # Eski satırı sil
  log "Eski vm-id-allocation ayarı kaldırılıyor..."
  sed -i '/^vm-id-allocation:/d' "$DATACENTER_CFG"
else
  log "vm-id-allocation ayarı bulunamadı, yeni ayar eklenecek."
fi

# Yeni ayarı ekle
log "Yeni vm-id-allocation ayarı ekleniyor..."
echo "vm-id-allocation: range=100000-999999999" >> "$DATACENTER_CFG"

log "✅ Ayar başarıyla güncellendi!"
log ""
log "Yeni konfigürasyon:"
cat "$DATACENTER_CFG"
log ""
log "📋 Özet:"
log "  - Template'ler için rezerve: 0-99,999 (manuel atama)"
log "  - Normal VM'ler için: 100,000+ (otomatik atama)"
log ""
log "⚠️  DİKKAT:"
log "  - Bu ayar cluster'daki tüm node'lara otomatik yayılır"
log "  - Mevcut VM'lere etki etmez"
log "  - Sadece yeni oluşturulacak VM'ler için geçerlidir"
log ""

# Test et
log "Test ediliyor: Yeni VMID ne olacak?"
NEXT_ID=$(pvesh get /cluster/nextid 2>&1 || echo "test-failed")
if [[ "$NEXT_ID" =~ ^[0-9]+$ ]] && [[ $NEXT_ID -ge 100000 ]]; then
  log "✅ Test başarılı! Sonraki otomatik VMID: $NEXT_ID"
else
  log "⚠️  Test sonucu: $NEXT_ID"
  log "   (Manuel VMID atamak için: qm create <vmid> --name <name>)"
fi

log ""
log "🎉 Konfigürasyon tamamlandı!"
