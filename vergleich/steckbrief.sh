#!/usr/bin/env bash
# Steckbrief eines Runners: misst nur, was im eigenen Job sichtbar ist (infra#2303-Folge, Vergleich GitHub / Blacksmith /
# maerkische, 20.11.2026). Keine Abtastung fremder Netze, keine Metadaten-Adressen, keine Geheimnisse in der Ausgabe.
# Aufruf: steckbrief.sh <phase kalt|warm> <runner-label>. Jede Messzeile beginnt mit "SB " und ist key=value.
# VERGLEICH_SCHNELL=1 laesst die schweren Teile weg (Selbstprobe auf einer Linux-Maschine).
set -u
export LC_ALL=C
PHASE=${1:-?}; LABEL=${2:-?}
T0=$(date +%s.%N)
sb() { printf 'SB %s=%s\n' "$1" "$(printf '%s' "$2" | tr '\n' ' ' | sed 's/  */ /g; s/ $//')"; }
dauer() { # dauer <key> <befehl...>: misst Wandzeit in s, rc dazu
  local a b rc; a=$(date +%s.%N); timeout 900 "${@:2}" >/dev/null 2>&1; rc=$?; b=$(date +%s.%N)
  sb "$1" "$(awk -v a="$a" -v b="$b" 'BEGIN{printf "%.1f", b-a}') s rc=$rc"; }
gruppe() { echo "::group::$1"; }
ende() { echo "::endgroup::"; }
SCHNELL=${VERGLEICH_SCHNELL:-0}
W=${RUNNER_TEMP:-/tmp}/sb; mkdir -p "$W"

gruppe "0 Rahmen"
sb phase "$PHASE"; sb label "$LABEL"; sb runner_name "${RUNNER_NAME:-?}"; sb zeit_utc "$(date -u +%FT%TZ)"
sb uptime_s "$(cut -d' ' -f1 /proc/uptime)"   # wie lange die Maschine vor dem Job schon lief
sb run "${GITHUB_RUN_ID:-?}/${GITHUB_RUN_ATTEMPT:-?}"
ende

gruppe "1 Maschine"
sb cpu_modell "$(lscpu | sed -n 's/^Model name: *//p' | head -1)"
sb cpus "$(nproc)"; sb lscpu_cpus "$(lscpu | sed -n 's/^CPU(s): *//p' | head -1)"
sb threads_je_kern "$(lscpu | sed -n 's/^Thread(s) per core: *//p')"
sb kerne_je_sockel "$(lscpu | sed -n 's/^Core(s) per socket: *//p')"
sb mhz_max "$(lscpu | sed -n 's/^CPU max MHz: *//p')"
sb hypervisor "$(lscpu | sed -n 's/^Hypervisor vendor: *//p')"
sb virt "$(systemd-detect-virt 2>/dev/null; true)"
sb dmi "$(cat /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name 2>/dev/null)"
sb kernel "$(uname -r)"
sb ram_gib "$(awk '/MemTotal/ {printf "%.1f", $2/1048576}' /proc/meminfo)"
sb swap_gib "$(awk '/SwapTotal/ {printf "%.1f", $2/1048576}' /proc/meminfo)"
sb platte_root "$(df -h / | awk 'NR==2 {print $2" gesamt, "$4" frei, "$1}')"
sb platte_arbeit "$(df -h "${GITHUB_WORKSPACE:-$PWD}" | awk 'NR==2 {print $2" gesamt, "$4" frei, "$1}')"
sb blockgeraete "$(lsblk -dno NAME,SIZE,ROTA,MODEL 2>/dev/null | tr -s ' ' | paste -sd ';' -)"
sb cgroup_cpu "$(cat /sys/fs/cgroup/cpu.max 2>/dev/null || echo -)"
sb cgroup_mem "$(cat /sys/fs/cgroup/memory.max 2>/dev/null || echo -)"
sb cpu_flags_avx512 "$(grep -c avx512f /proc/cpuinfo)"
ende

gruppe "2 Abbild"
sb image_os "${ImageOS:-?}"; sb image_version "${ImageVersion:-?}"
sb os "$(. /etc/os-release; echo "$PRETTY_NAME")"
sb docker "$(docker --version 2>/dev/null)"; sb node "$(node -v 2>/dev/null)"; sb python "$(python3 -V 2>&1)"
sb go "$(go version 2>/dev/null)"; sb java "$(command -v java >/dev/null && java -version 2>&1 | head -1)"; sb gcc "$(gcc --version 2>/dev/null | head -1)"
sb toolcache_gib "$(du -s "${RUNNER_TOOL_CACHE:-/opt/hostedtoolcache}" 2>/dev/null | awk '{printf "%.1f", $1/1048576}')"
# Nur NAMEN von Umgebungsvariablen, die auf Cache, Proxy, Spiegel oder den Anbieter deuten, nie Werte.
sb env_namen "$(env | cut -d= -f1 | grep -iE 'blacksmith|cache|proxy|mirror|registry|maerkische' | sort | paste -sd, -)"
# Ziel-HOST der Actions-Dienste (ohne Pfad, ohne Abfrage): zeigt, ob Cache/Artefakte umgeleitet werden.
for v in ACTIONS_CACHE_URL ACTIONS_RESULTS_URL ACTIONS_RUNTIME_URL; do
  sb "host_$v" "$(printf '%s' "${!v:-}" | sed -E 's#^[a-z]+://([^/]+).*#\1#')"; done
ende

gruppe "3 Netz"
sb nameserver "$(awk '/^nameserver/ {print $2}' /etc/resolv.conf | paste -sd, -)"
# Wo steht die Maschine: oeffentliche Adresse des Jobs bei ipinfo.io (Land, Ort, Netzbetreiber).
sb standort "$(curl -s --max-time 10 https://ipinfo.io/json | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("country"), d.get("region"), d.get("city"), d.get("org"))' 2>/dev/null)"
sb github_ms "$(curl -s -o /dev/null --max-time 10 -w '%{time_connect} %{time_appconnect} %{http_code}' https://github.com | awk '{printf "tcp=%.0f tls=%.0f code=%s", $1*1000, $2*1000, $3}')"
sb registry_ms "$(curl -s -o /dev/null --max-time 10 -w '%{time_connect} %{time_appconnect} %{http_code}' https://registry-1.docker.io/v2/ | awk '{printf "tcp=%.0f tls=%.0f code=%s", $1*1000, $2*1000, $3}')"
# Cloudflare nimmt hoechstens knapp 100 MB je Abruf an; 200 MB ergaben 403 und damit "0 Mbit/s"
# (Lauf 44824823030, gemessen 21.11.). Darum 90 MB, dreimal, und je Versuch den HTTP-Code dazu:
# eine Ablehnung darf nie als Messwert 0 erscheinen. Einzelner Ausfall am Mac: 50 MB hing 40 s.
if [ "$SCHNELL" = 1 ]; then n=10000000; else n=90000000; fi
dl=""; for _v in 1 2 3; do
  dl="$dl $(curl -s -o /dev/null --max-time 60 -w '%{http_code} %{speed_download}' "https://speed.cloudflare.com/__down?bytes=$n" \
         | awk '{ if ($1 == 200) printf "%.0f", $2*8/1e6; else printf "fehler(code=%s)", $1 }')"
done
sb download_mbit "${dl# }"
ende

gruppe "4 Einweg"
for m in /tmp/sb-marker "$HOME/sb-marker"; do sb "marker_vorher_$(basename "$(dirname "$m")")" "$( [ -e "$m" ] && cat "$m" || echo fehlt)"; done
echo "$PHASE ${GITHUB_RUN_ID:-?} $(date -u +%TZ)" | tee /tmp/sb-marker "$HOME/sb-marker" >/dev/null
ende

gruppe "5 Docker"
sb docker_info "$(docker info --format 'server={{.ServerVersion}} treiber={{.Driver}} spiegel={{.RegistryConfig.Mirrors}} ncpu={{.NCPU}} mem_gib={{.MemTotal}} root={{.DockerRootDir}}' 2>/dev/null)"
sb docker_images_vorher "$(docker images -q 2>/dev/null | wc -l | tr -d ' ')"
sb node22_vorher "$(docker image inspect node:22-bookworm >/dev/null 2>&1 && echo da || echo fehlt)"
[ "$SCHNELL" = 1 ] || dauer docker_pull_node22_s docker pull -q node:22-bookworm
ende

gruppe "6 Tempo"
dauer cpu_einzel_python_s python3 -c 'sum(i*i for i in range(30_000_000))'
if [ "$SCHNELL" != 1 ]; then
  dauer git_clone_linux_s git clone -q --depth 1 https://github.com/torvalds/linux "$W/linux"
  sb linux_mib "$(du -sm "$W/linux" 2>/dev/null | cut -f1)"; rm -rf "$W/linux"
  dauer git_clone_redis_s git clone -q --depth 1 --branch 7.4.1 https://github.com/redis/redis "$W/redis"
  dauer redis_make_s make -C "$W/redis" -j"$(nproc)" MALLOC=libc
  dauer dd_schreiben_2g_s dd if=/dev/zero of="$W/dd" bs=1M count=2048 oflag=direct
  sync; echo 3 | sudo -n tee /proc/sys/vm/drop_caches >/dev/null 2>&1
  dauer dd_lesen_2g_s dd if="$W/dd" of=/dev/null bs=1M iflag=direct
  rm -f "$W/dd"
fi
ende

sb gesamt_s "$(awk -v a="$T0" -v b="$(date +%s.%N)" 'BEGIN{printf "%.1f", b-a}')"
