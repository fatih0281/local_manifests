#!/bin/bash

# =================================================================
# Fatih's Universal Custom ROM Build Script (Github Cloud Edition)
# =================================================================

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
clear='\033[0m'
set -o pipefail

# ---------------------------------------------------------
# 1. ROM VE CİHAZ AYARLARI (DEĞİŞTİRİLEBİLİR)
# ---------------------------------------------------------
ROM_NAME="YAAP"
ROM_LINK="https://github.com/yaap/manifest"
ROM_BRANCH="sixteen"

DEVICE="r8q"
BUILD_TYPE="userdebug"  # user, userdebug veya eng
export TARGET_RELEASE=bp4a
LUNCH_CMD="lunch yaap_${DEVICE}-${BUILD_TYPE}"
# LUNCH_CMD="lunch yaap_${DEVICE}-bp4a-${BUILD_TYPE}" # ROM'a göre değişebilir (Örn: lunch lineage_r8q-userdebug)
BUILD_CMD="m yaap" # Lunaris/EvoX için 'm bacon', crDroid/Lineage için 'brunch ${DEVICE}'

# ---------------------------------------------------------
# 2. BUILD FLAGS (DERLEME BAYRAKLARI)
# ---------------------------------------------------------
USE_CUSTOM_FLAGS=false  # Sadece özel donanım bayrağı isteyen ROM'larda (Lunaris vb.) 'true' yap

# Her ROM'da standart olarak kalması gereken genel bilgiler
export BUILD_USERNAME="Fatih"
export BUILD_HOSTNAME="Build-Server"

# ---------------------------------------------------------
# 3. İMZA VE YÜKLEME AYARLARI
# ---------------------------------------------------------
USE_PRIVATE_KEYS=false # Kendi anahtarlarını ürettiğinde bunu 'true' yap
PRIVATE_KEYS_REPO="https://${GH_TOKEN}@github.com/KULLANICI_ADIN/priv-keys.git"

COMMON_IMAGES=("recovery.img" "boot.img")
OUT_DIR="out/target/product/${DEVICE}"
LOG="build.log"
ROM_ZIP="${OUT_DIR}/*${DEVICE}*.zip"

# ---------------------------------------------------------
# 4. TELEGRAM BOT AYARLARI
# ---------------------------------------------------------
BOT_TOKEN="8990362086:AAGV1fAidZgbIsOiQjfqwI9BVRqf6-1v1Uc"
CHAT_ID="574719563"
USER="@T4958"

# ===========================================
# YARDIMCI FONKSİYONLAR (TELEGRAM & STATS)
# ===========================================
function format_time() {
  local SECS=$1
  local h=$(( SECS / 3600 ))
  local m=$(( (SECS % 3600) / 60 ))
  local s=$(( SECS % 60 ))
  if [ "$h" -gt 0 ]; then echo "${h} sa ${m} dk ${s} sn"; else echo "${m} dk ${s} sn"; fi
}

function tg_post_msg() {
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -d chat_id="$CHAT_ID" -d parse_mode="Markdown" -d disable_web_page_preview="true" -d text="$1" > /dev/null
}

function tg_edit_msg() {
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/editMessageText" \
    -d chat_id="$CHAT_ID" -d message_id="$1" -d parse_mode="Markdown" -d disable_web_page_preview="true" -d text="$2" > /dev/null
}

function tg_send_file() {
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendDocument" \
    -F chat_id="$CHAT_ID" -F document=@"$1" -F caption="$2" > /dev/null
}

function tg_send_with_button() {
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -d chat_id="$CHAT_ID" -d parse_mode="Markdown" -d disable_web_page_preview="true" -d text="$1" \
    -d reply_markup='{"inline_keyboard": [[{"text": "🔄 Durumu Yenile", "callback_data": "refresh"}]]}' | jq -r '.result.message_id'
}

function tg_edit_with_button() {
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/editMessageText" \
    -d chat_id="$CHAT_ID" -d message_id="$1" -d parse_mode="Markdown" -d disable_web_page_preview="true" -d text="$2" \
    -d reply_markup='{"inline_keyboard": [[{"text": "🔄 Durumu Yenile", "callback_data": "refresh"}]]}' > /dev/null
}

function get_stats() {
  read -r _ u1 n1 s1 i1 w1 irq1 sirq1 st1 _ < /proc/stat
  sleep 1
  read -r _ u2 n2 s2 i2 w2 irq2 sirq2 st2 _ < /proc/stat

  idle1=$((i1 + w1)); idle2=$((i2 + w2))
  total1=$((u1 + n1 + s1 + i1 + w1 + irq1 + sirq1 + st1))
  total2=$((u2 + n2 + s2 + i2 + w2 + irq2 + sirq2 + st2))

  diff_idle=$((idle2 - idle1)); diff_total=$((total2 - total1))
  local CPU=0
  [ "$diff_total" -gt 0 ] && CPU=$(( 100 * (diff_total - diff_idle) / diff_total ))

  MEM_USED=$(free -m | awk '/Mem:/ {print $3}')
  MEM_TOTAL=$(free -m | awk '/Mem:/ {print $2}')
  LOAD=$(cut -d' ' -f1 /proc/loadavg)
  echo "$CPU|$MEM_USED|$MEM_TOTAL|$LOAD"
}

GOFILE_RETRY_MAX=3
function gofile_upload() {
  local FILE="$1"
  local FILENAME
  FILENAME=$(basename "$FILE")
  [ ! -f "$FILE" ] && return 1

  for SERVER in $(printf "%s\n" "${GOFILE_SERVERS[@]}" | shuf); do
    local ATTEMPT=0
    while [ "$ATTEMPT" -lt "$GOFILE_RETRY_MAX" ]; do
      ATTEMPT=$(( ATTEMPT + 1 ))
      RESPONSE=$(curl -4 --http1.1 -sf -F "file=@${FILE}" "https://${SERVER}.gofile.io/contents/uploadFile")
      LINK=$(echo "$RESPONSE" | jq -r '.data.downloadPage // empty')
      if [ -n "$LINK" ]; then
        echo "$LINK"
        return 0
      fi
      sleep 2
    done
  done
  return 1
}

function listen_refresh() {
  local OFFSET=0
  while true; do
    UPDATES=$(curl -s "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates?offset=${OFFSET}")
    COUNT=$(echo "$UPDATES" | jq '.result | length')
    if [ "$COUNT" -gt 0 ]; then
      for ((i=0; i<COUNT; i++)); do
        UPDATE=$(echo "$UPDATES" | jq -c ".result[$i]")
        UPDATE_ID=$(echo "$UPDATE" | jq '.update_id')
        OFFSET=$((UPDATE_ID + 1))
        CALLBACK=$(echo "$UPDATE" | jq -r '.callback_query.data // empty')
        MSG_ID=$(echo "$UPDATE" | jq -r '.callback_query.message.message_id // empty')

        if [ "$CALLBACK" = "refresh" ]; then
          CALLBACK_ID=$(echo "$UPDATE" | jq -r '.callback_query.id // empty')
          curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/answerCallbackQuery" -d callback_query_id="$CALLBACK_ID" > /dev/null
          
          STATS=$(get_stats)
          CPU=$(echo "$STATS" | cut -d'|' -f1)
          MEM_USED=$(echo "$STATS" | cut -d'|' -f2)
          MEM_TOTAL=$(echo "$STATS" | cut -d'|' -f3)
          LOAD=$(echo "$STATS" | cut -d'|' -f4)
          ELAPSED=$(( $(date +%s) - BUILD_START ))
          CONSOLE=$(grep -v '^\s*$' "$LOG" 2>/dev/null | tail -n1 | cut -c1-110)
          NOW_LOCAL=$(date +"%H:%M:%S")

          tg_edit_with_button "$MSG_ID" "
⚙️ *Derleniyor: ${ROM_NAME}*

📱 Cihaz: \`${DEVICE}\`
🏙️ *Tür*: \`${BUILD_TYPE}\`

*Sunucu Durumu*
💻 CPU: \`${CPU}%\`
💾 RAM: \`${MEM_USED}MB / ${MEM_TOTAL}MB\`
⚡ Yük: \`${LOAD}\`

🕛 Geçen Süre: $(format_time "$ELAPSED")
🔥 Durum: İnşa ediliyor...
📟 Log: \`${CONSOLE}\`

🔄 Son Yenileme: \`${NOW_LOCAL}\`"
        fi
      done
    fi
    sleep 3
  done
}

# ===========================================
# DERLEME FONKSİYONLARI
# ===========================================
function clean() {
  echo -e "${green}🧹 Eski kalıntılar temizleniyor...${clear}"
  rm -rf .repo/local_manifests
  rm -rf device/samsung/r8q device/samsung/sm8250-common
  rm -rf vendor/samsung/r8q vendor/samsung/sm8250-common
  rm -rf kernel/samsung/sm8250 hardware/samsung
}

function create_manifest() {
  echo -e "${green}📝 Cihaz Ağacı (Manifest) oluşturuluyor...${clear}"
  mkdir -p .repo/local_manifests
  
  cat << 'XML' > .repo/local_manifests/r8q.xml
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <project path="device/samsung/r8q" name="fatih0281/device_samsung_r8q" remote="github" revision="yaap" />
  <project path="device/samsung/sm8250-common" name="fatih0281/device_samsung_sm8250-common" remote="github" revision="yaap" />
  <project path="vendor/samsung/r8q" name="TheMuppets/proprietary_vendor_samsung_r8q" remote="github" revision="lineage-23.2" />
  <project path="vendor/samsung/sm8250-common" name="TheMuppets/proprietary_vendor_samsung_sm8250-common" remote="github" revision="lineage-23.2" />
  <project path="kernel/samsung/sm8250" name="LineageOS/android_kernel_samsung_sm8250" remote="github" revision="lineage-23.2" />
  <project path="hardware/samsung" name="yumeerin/hardware_samsung" remote="github" revision="16.2" />
</manifest>
XML
}

function apply_build_flags() {
  if [ "$USE_CUSTOM_FLAGS" = true ]; then
    echo -e "${green}🚩 Özel derleme bayrakları (Build Flags) sisteme enjekte ediliyor...${clear}"
    export TARGET_CUSTOM_UDFPS=true
    export WITH_GMS=true
    export WITH_GMS_COMMS_SUITE=false
    export WITH_PIXEL_LAUNCHER=false
    export TARGET_USE_MAPS=true
    export TARGET_USE_FILES=false
    export TARGET_USE_GPHOTOS=false
    export TARGET_USE_WALLPAPERS=true
    export USE_REALITY_ENGINE=true
    export SURFACE_FLINGER_BOOST=true
  else
    echo -e "${yellow}ℹ️ Özel derleme bayrakları kapalı. Standart kurallar geçerli.${clear}"
  fi
}

function sync_sources() {
  echo -e "${green}🔄 Kaynak kodlar çekiliyor...${clear}"
  repo init -u "${ROM_LINK}" -b "${ROM_BRANCH}" --git-lfs --depth=1
  
  if [ -f /opt/crave/resync.sh ]; then
    /opt/crave/resync.sh
  else
    repo sync -c -j$(nproc --all) --force-sync --no-clone-bundle --no-tags
  fi

  if [ "$USE_PRIVATE_KEYS" = true ]; then
    echo -e "${green}🔑 Özel imza anahtarları indiriliyor...${clear}"
    rm -rf vendor/lineage-priv/keys
    git clone "$PRIVATE_KEYS_REPO" -b main vendor/lineage-priv/keys
  fi
}

function setup_env() {
  echo -e "${green}⚙️ Ortam hazırlanıyor...${clear}"
  source build/envsetup.sh
  
  apply_build_flags 
  
  eval "$LUNCH_CMD"
  mka installclean
}

function build_rom() {
  echo -e "${green}🚀 Motor ateşleniyor: ${BUILD_CMD}${clear}"
  touch "$LOG"
  eval "$BUILD_CMD" 2>&1 | tee "$LOG" &
  BUILD_PID=$!
  wait "$BUILD_PID"
  return $?
}

# ===========================================
# ANA AKIŞ (MAIN)
# ===========================================
BUILD_START=$(date +%s)
NOW=$(date -u +"%Y-%m-%d %H:%M:%S UTC")

clean
create_manifest

tg_post_msg "
🤖 *${ROM_NAME}* Derlemesi Başladı!
📱 *Cihaz*: \`${DEVICE}\`
🏙️ *Tür*: \`${BUILD_TYPE}\`
⌛ *Zaman*: \`${NOW}\`"

PROGRESS_MSG_ID=$(tg_send_with_button "🚀 Derleme sürüyor... Yüzdeleri izlemek için 🔄 Durumu Yenile'ye bas!")

listen_refresh &
LISTENER_PID=$!

sync_sources
setup_env
build_rom
STATUS=$?

kill "$LISTENER_PID" 2>/dev/null
wait "$LISTENER_PID" 2>/dev/null

BUILD_END=$(date +%s)
TIME=$(( BUILD_END - BUILD_START ))
TIME_FMT=$(format_time "$TIME")

if [ "$STATUS" -eq 0 ]; then
  mapfile -t GOFILE_SERVERS < <(curl -s "https://api.gofile.io/servers" | jq -r '.data.servers[].name')
  mapfile -t ROM_ZIPS < <(compgen -G "$ROM_ZIP" 2>/dev/null)
  
  if [ "${#ROM_ZIPS[@]}" -eq 0 ]; then
    tg_post_msg "⚠️ Derleme başarılı ama ZIP dosyası bulunamadı."
    exit 1
  fi

  tg_edit_msg "$PROGRESS_MSG_ID" "
⚙️ *${ROM_NAME} Tamamlandı!*
📱 Cihaz: \`${DEVICE}\`
🔥 Durum: ✅ Başarılı
🕛 Süre: ${TIME_FMT}
📦 Dosyalar GoFile'a yükleniyor..."

  UPLOAD_MSG=""
  IMG_MSG=""

  # ZIP Yükleme
  for ZIP in "${ROM_ZIPS[@]}"; do
    [ -f "$ZIP" ] || continue
    FILENAME=$(basename "$ZIP")
    LINK=$(gofile_upload "$ZIP")
    if [ -n "$LINK" ]; then
      UPLOAD_MSG="${UPLOAD_MSG}📦 [${FILENAME}](${LINK})\n"
    else
      UPLOAD_MSG="${UPLOAD_MSG}⚠️ Yükleme başarısız: \`${FILENAME}\`\n"
    fi
  done

  # Recovery / Boot İmajı Yükleme
  for IMG in "${COMMON_IMAGES[@]}"; do
    FILEPATH="${OUT_DIR}/${IMG}"
    if [ -f "$FILEPATH" ]; then
      LINK=$(gofile_upload "$FILEPATH")
      if [ -n "$LINK" ]; then
        IMG_MSG="${IMG_MSG}🔧 [${IMG}](${LINK})\n"
      fi
    fi
  done

  FINAL_MSG="
🎉 *${ROM_NAME} | ${DEVICE} İndirmeye Hazır!*
━━━━━━━━━━━━━━━━━━
$(echo -e "$UPLOAD_MSG")
$(echo -e "$IMG_MSG")

👤 Geliştirici: \`${USER}\`
🕛 Süre: ${TIME_FMT}"

  tg_post_msg "$FINAL_MSG"
else
  tg_edit_msg "$PROGRESS_MSG_ID" "
⚙️ *Derleme Çöktü: ${ROM_NAME}*
📱 Cihaz: \`${DEVICE}\`
🔥 Durum: ❌ FAILED
🕛 Geçen Süre: ${TIME_FMT}"

  tail -n 120 "$LOG" > error_tail.log
  tg_send_file "error_tail.log" "📜 Hata Logu (Son 120 Satır)"
  rm -f error_tail.log
fi
