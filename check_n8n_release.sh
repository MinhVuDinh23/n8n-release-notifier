#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="known_versions.txt"
REPO="n8n-io/n8n"

if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
    echo "Thieu TELEGRAM_BOT_TOKEN hoac TELEGRAM_CHAT_ID trong environment" >&2
    exit 1
fi

releases_json=$(curl -sL --connect-timeout 15 "https://api.github.com/repos/${REPO}/releases?per_page=100")

# Chi lay ban STABLE that su: tag dang n8n@x.y.z VA prerelease=false
# n8n duy tri nhieu nhanh song song (1.x, 2.29.x, 2.30.x...) nen khong dua vao
# "moi nhat theo thoi gian" - phai theo doi TAT CA nhanh rieng biet
current_all=$(echo "$releases_json" | jq -r '
  [.[] | select(.tag_name | test("^n8n@[0-9]+\\.[0-9]+\\.[0-9]+$")) | select(.prerelease == false) | (.tag_name | sub("^n8n@";""))]
  | .[]
' | tr -d '\r')

if [ -z "$current_all" ]; then
    echo "Khong lay duoc danh sach release stable tu GitHub" >&2
    exit 1
fi

# Lan chay dau tien: chi luu toan bo trang thai hien co, khong bao (tranh spam lich su)
if [ ! -f "$STATE_FILE" ]; then
    echo "$current_all" | sort -V -u > "$STATE_FILE"
    echo "Lan dau chay, da luu $(wc -l < "$STATE_FILE") ban stable hien co, khong gui thong bao"
    exit 0
fi

known_all=$(cat "$STATE_FILE" | tr -d '\r')

# Dung file tam thuc thay vi comm + process substitution (<(...) khong on dinh
# tren mot so moi truong bash/MSYS - da verify bang test truc tiep)
known_tmp=$(mktemp)
current_tmp=$(mktemp)
trap 'rm -f "$known_tmp" "$current_tmp"' EXIT

echo "$known_all" | sort -u > "$known_tmp"
echo "$current_all" | sort -u > "$current_tmp"

new_versions=$(grep -Fxvf "$known_tmp" "$current_tmp" || true)

if [ -z "$new_versions" ]; then
    echo "Khong co ban stable moi"
    exit 0
fi

combined_pool=$(printf '%s\n%s\n' "$current_all" "$known_all" | sort -V -u)

# Don changelog: bo phan HTML/badge tu dong sinh (stage-review, cubic...), bo
# link markdown chi giu lai text, doi header ### thanh dong emoji cho de doc
clean_changelog() {
    printf '%s' "$1" \
      | sed '/<!--/,$d' \
      | sed -E 's/\[([^]]+)\]\([^)]+\)/\1/g' \
      | sed -E '/^## /d' \
      | sed -E 's/^### Bug Fixes[[:space:]]*$/🔧 Bug Fixes:/' \
      | sed -E 's/^### Features[[:space:]]*$/✨ Features:/' \
      | sed -E 's/^### (.+)/📌 \1:/' \
      | sed -E 's/^\* /• /' \
      | sed -E 's/\*\*([^*]+)\*\*/\1/g' \
      | cat -s \
      | sed -e '1{/^$/d}'
}

while IFS= read -r v; do
    [ -z "$v" ] && continue
    mm=$(echo "$v" | cut -d. -f1,2)

    # Danh sach cac ban CUNG nhanh major.minor (bao gom ca v), da sort tang dan theo semver
    siblings_with_self=$(echo "$combined_pool" | awk -F'.' -v mm="$mm" '{n=split($0,a,"."); if(a[1]"."a[2]==mm) print $0}' | sort -V)

    # Ban dung ngay TRUOC v trong danh sach cung nhanh (khong doan so, lay tu list that)
    previous_version=$(echo "$siblings_with_self" | grep -B1 -Fx "$v" | head -1)
    if [ "$previous_version" = "$v" ]; then
        previous_version=""
    fi

    release_body=$(echo "$releases_json" | jq -r --arg tag "n8n@${v}" \
      '.[] | select(.tag_name == $tag) | .body // "Khong co changelog"')
    release_body_clean=$(clean_changelog "$release_body")
    release_body_short=$(echo "$release_body_clean" | head -c 2000)

    message=$(cat <<EOF
🆕 N8N nhanh ${mm}.x co ban stable moi: ${v}
So voi ban gan nhat cung nhanh: ${previous_version:-khong co, day la ban dau tien cua nhanh nay}

📋 Changelog:
${release_body_short}
EOF
)

    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
      --data-urlencode "text=${message}" \
      -d "disable_web_page_preview=true" > /dev/null

    echo "Da bao ban: $v (truoc do cung nhanh: ${previous_version:-khong co})"
done <<< "$new_versions"

printf '%s\n%s\n' "$current_all" "$known_all" | sort -V -u > "$STATE_FILE"
echo "Da cap nhat trang thai"
