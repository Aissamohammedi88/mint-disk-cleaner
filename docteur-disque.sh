#!/usr/bin/env bash
# =============================================================================
#  DOCTEUR DISQUE v1.0 — pour Linux Mint (fonctionne aussi sur Ubuntu/Debian)
#
#  Que fait cet outil ?
#    1. Audit           : trouve QUI remplit le disque (Timeshift, logs, caches,
#                         corbeille, fichiers "fantômes", gros dossiers...)
#    2. Benchmark       : vitesse écriture/lecture du disque avant/après nettoyage
#    3. Nettoyage       : par étapes, Oui/Non pour chaque catégorie
#                         (Timeshift gardé à 3 snapshots par défaut)
#    4. Sticky bit      : audit + correction de /tmp, /var/tmp, /dev/shm
#                         + scan des dossiers "écrivables par tous" sans sticky bit
#    5. Surveillance    : systemd timer qui purge logs/journal/cache apt
#                         automatiquement quand le disque dépasse 85 %
#    6. Vidéo MP4       : résumé animé avant/après + résultat du benchmark
#
#  Utilisation (depuis ton utilisateur normal — sudo sera demandé au besoin) :
#     chmod +x docteur-disque.sh
#     ./docteur-disque.sh            → menu interactif
#     ./docteur-disque.sh --demo     → vidéo d'exemple (chiffres fictifs)
#     ./docteur-disque.sh --help     → toutes les options
#
#  Rien n'est supprimé sans ta confirmation (le mode auto ne touche que les
#  logs / journal / cache apt / flatpak inutilisés — jamais tes documents).
# =============================================================================
set -u
export LC_ALL=C

VERSION="1.0"
THRESHOLD="${DD_SEUIL:-85}"            # seuil % de la surveillance auto
BENCH_MB="${DD_BENCH_MB:-512}"         # taille du test d'écriture du benchmark
SUDO=""
NONINT=0
BENCH_TMP=""
VIDEO_TMP=""
FREED_TOTAL=0

# ---------------------------------------------------------------- couleurs ---
if [ -t 1 ]; then
    C_R=$'\e[1;31m'; C_G=$'\e[1;32m'; C_Y=$'\e[1;33m'; C_B=$'\e[1;36m'
    C_W=$'\e[1;37m'; C_0=$'\e[0m'
else
    C_R=""; C_G=""; C_Y=""; C_B=""; C_W=""; C_0=""
fi
msg()  { printf '%s\n' "$*"; }
ok()   { printf '%s✔ %s%s\n' "$C_G" "$*" "$C_0"; }
warn() { printf '%s⚠ %s%s\n' "$C_Y" "$*" "$C_0"; }
err()  { printf '%s✘ %s%s\n' "$C_R" "$*" "$C_0"; }
info() { printf '%sℹ %s%s\n' "$C_B" "$*" "$C_0"; }
sep()  { msg "────────────────────────────────────────────────────────────────"; }

banner() {
    clear 2>/dev/null || true
    msg ""
    msg "${C_W}  ╔══════════════════════════════════════════════════════════╗${C_0}"
    msg "${C_W}  ║           DOCTEUR DISQUE v$VERSION — Linux Mint           ║${C_0}"
    msg "${C_W}  ╚══════════════════════════════════════════════════════════╝${C_0}"
    msg ""
}

# ------------------------------------------------------------------ divers ---
# HOME réel : si le script est lancé via sudo, on garde le home de l'utilisateur
if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
    HOMEDIR=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    HOMEDIR="$HOME"
fi
STATE_DIR="$HOMEDIR/.docteur-disque"
STATE="$STATE_DIR/etat.conf"
mkdir -p "$STATE_DIR" 2>/dev/null || true

ensure_sudo() {
    if [ "$(id -u)" -eq 0 ]; then SUDO=""; return 0; fi
    if command -v sudo >/dev/null 2>&1; then
        if sudo -v 2>/dev/null; then SUDO="sudo"; return 0; fi
    fi
    warn "sudo indisponible — les étapes système seront incomplètes."
    warn "Relance avec sudo configuré pour des chiffres complets."
    return 1
}

disk_pct()   { df -P / 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}'; }
used_bytes() { df -B1 -P / 2>/dev/null | awk 'NR==2{print $3}'; }

hr() {  # octets → lisible
    awk -v b="${1:-0}" 'BEGIN{
        if (b >= 1073741824)      printf "%.1f Go", b/1073741824;
        else if (b >= 1048576)    printf "%.1f Mo", b/1048576;
        else if (b >= 1024)       printf "%.1f Ko", b/1024;
        else                      printf "%d oct", b;
    }'
}
to_bytes() {  # "1.2G" / "500M" → octets (sortie de journalctl --disk-usage)
    awk -v s="$1" 'BEGIN{
        v = s + 0;
        if (s ~ /T/) v *= 1099511627776;
        else if (s ~ /G/) v *= 1073741824;
        else if (s ~ /M/) v *= 1048576;
        else if (s ~ /K/) v *= 1024;
        printf "%d", v;
    }'
}
sudu() {  # du (Ko convertis en octets) avec sudo si possible, 0 si absent/illisible
    [ -e "$1" ] || { echo 0; return; }
    $SUDO du -sk "$1" 2>/dev/null | awk '{print $1*1024}'
}
dub() {  # du utilisateur (Ko convertis en octets)
    [ -e "$1" ] || { echo 0; return; }
    du -sk "$1" 2>/dev/null | awk '{print $1*1024}'
}

# ------------------------------------------------------------ état (clés) ---
st_set() {
    if grep -q "^$1=" "$STATE" 2>/dev/null; then
        sed -i "s|^$1=.*|$1=$2|" "$STATE" 2>/dev/null
    else
        echo "$1=$2" >> "$STATE" 2>/dev/null
    fi
}
st_get() { grep "^$1=" "$STATE" 2>/dev/null | tail -n1 | cut -d= -f2-; }

ask() {  # ask "question ?" [defaut] → 0 = oui ; en mode non-interactif : non
    [ "$NONINT" = 1 ] && return 1
    local a; read -r -p "$1 [${2:-O}/n] : " a || a="n"
    a=${a:-${2:-O}}
    [[ "$a" =~ ^[oOyY1] ]] && return 0 || return 1
}
pause() {
    [ "$NONINT" = 1 ] && return 0
    read -r -p $'\nEntrée pour continuer... ' _ </dev/tty 2>/dev/null || read -r -p $'\nEntrée pour continuer... ' _
}

# =============================================================== AUDIT =======
collect_sizes() {  # mémorise l'état "AVANT" pour la vidéo
    st_set disk_pct_before   "$(disk_pct)"
    st_set used_bytes_before "$(used_bytes)"
    st_set ts_size_before    "$(sudu /timeshift)"
    st_set log_size_before   "$(sudu /var/log)"
    st_set apt_size_before   "$(sudu /var/cache/apt/archives)"
    st_set cache_size_before "$(dub "$HOMEDIR/.cache")"
    st_set trash_size_before "$(dub "$HOMEDIR/.local/share/Trash")"
}

recent_writers() {  # fichiers modifiés depuis < 60 s (pour attraper le coupable)
    msg ""
    info "Fichiers modifiés durant les 60 dernières secondes (> 10 Mo) :"
    msg "   (relance cette commande PENDANT que le disque se remplit pour attraper le coupable)"
    local n=0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        msg "   $line"; n=$((n+1))
    done < <(timeout 40 find / -xdev -type f -mmin -1 -size +10M -exec du -h {} + 2>/dev/null | head -12)
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        msg "   $line"; n=$((n+1))
    done < <(timeout 30 find "$HOMEDIR" -xdev -type f -mmin -1 -size +10M -exec du -h {} + 2>/dev/null | head -8)
    [ "$n" -eq 0 ] && msg "   (aucun gros fichier écrit en ce moment)"
}

audit_disk() {
    banner
    msg "${C_W}  AUDIT DU DISQUE${C_0}"
    sep
    ensure_sudo || true
    collect_sizes

    local pct; pct=$(disk_pct)
    msg ""
    ok "Partition / remplie à ${pct} %"
    df -h / 2>/dev/null | awk 'NR==2{printf "   capacité : %s   utilisé : %s   libre : %s\n", $2, $3, $4}'
    if mountpoint -q /timeshift 2>/dev/null; then
        msg "   /timeshift est une partition séparée :"
        df -h /timeshift 2>/dev/null | awk 'NR==2{printf "   capacité : %s   utilisé : %s   libre : %s\n", $2, $3, $4}'
    fi
    if [ "$(findmnt -n -o FSTYPE / 2>/dev/null)" = "btrfs" ]; then
        info "Système btrfs : du sous-estime les snapshots Timeshift (ils partagent les blocs)."
    fi

    msg ""
    msg "${C_W}  Les gros suspects :${C_0}"
    printf "   %-22s %s\n" "Timeshift (/timeshift)" "$(hr "$(st_get ts_size_before)")"
    printf "   %-22s %s\n" "Logs système (/var/log)" "$(hr "$(st_get log_size_before)")"
    local js
    js=$($SUDO journalctl --disk-usage 2>/dev/null | awk '/take up/{print $(NF-4)}')
    [ -n "$js" ] && printf "   %-22s %s\n" "Journal systemd" "$(hr "$(to_bytes "$js")")"
    printf "   %-22s %s\n" "Cache APT" "$(hr "$(st_get apt_size_before)")"
    printf "   %-22s %s\n" "Cache utilisateur" "$(hr "$(st_get cache_size_before)")"
    printf "   %-22s %s\n" "Corbeille" "$(hr "$(st_get trash_size_before)")"
    printf "   %-22s %s\n" "/var/tmp" "$(hr "$(sudu /var/tmp)")"
    printf "   %-22s %s\n" "/tmp" "$(hr "$(sudu /tmp)")"
    [ -d /var/lib/flatpak ] && printf "   %-22s %s\n" "Flatpak" "$(hr "$(sudu /var/lib/flatpak)")"
    [ -d /var/lib/snapd ]   && printf "   %-22s %s\n" "Snap" "$(hr "$(sudu /var/lib/snapd)")"

    if command -v timeshift >/dev/null 2>&1; then
        local nts
        nts=$($SUDO timeshift --list 2>/dev/null | grep -cE '[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}')
        info "Timeshift : ${nts:-0} snapshot(s) enregistré(s) — le nettoyage gardera les 3 plus récents."
    else
        info "Timeshift n'est pas installé (ce n'est donc pas lui qui remplit le disque)."
    fi

    msg ""
    msg "${C_W}  Fichiers « fantômes » (supprimés mais encore ouverts par un programme) :${C_0}"
    if command -v lsof >/dev/null 2>&1; then
        local n=0
        while IFS='|' read -r c p s nm; do
            [ -n "$c" ] || continue
            printf "   %-14s PID %-7s %10s  %s\n" "$c" "$p" "$(hr "$s")" "$nm"
            n=$((n+1))
        done < <($SUDO lsof -nP +L1 2>/dev/null | awk '$7 ~ /^[0-9]+$/ && $7 > 104857600 {printf "%s|%s|%s|%s\n", $1, $2, $7, $9}' | head -10)
        [ "$n" -eq 0 ] && msg "   (aucun) — un fichier fantôme > 100 Mo disparaît au redémarrage du programme qui le garde."
    else
        msg "   (lsof absent — installe-le avec : sudo apt install lsof)"
    fi

    msg ""
    msg "${C_W}  Plus gros dossiers de / (peut prendre 1-2 min) :${C_0}"
    timeout 180 du -x --max-depth=2 / 2>/dev/null | sort -rn | head -14 | \
        while read -r s p; do [ -n "$s" ] && printf "   %10s  %s\n" "$(hr "$((s * 1024))")" "$p"; done

    msg ""
    msg "${C_W}  Plus gros fichiers (> 200 Mo) :${C_0}"
    { timeout 90 find / -xdev -type f -size +200M -exec du -k {} + 2>/dev/null;
      timeout 40 find "$HOMEDIR" -xdev -type f -size +200M -exec du -k {} + 2>/dev/null; } \
        | sort -rn | awk '!v[$2]++' | head -12 | \
        while read -r s p; do [ -n "$s" ] && printf "   %10s  %s\n" "$(hr "$((s * 1024))")" "$p"; done

    recent_writers

    if [ "${pct:-0}" -ge 95 ]; then
        msg ""
        err "  DISQUE À ${pct} % — ACTIONS D'URGENCE (copie-colle si besoin) :"
        msg "    sudo journalctl --vacuum-size=100M     # journal systemd à 100 Mo"
        msg "    sudo apt-get clean                     # cache des paquets .deb"
        msg "    ./docteur-disque.sh                    # puis menu 3 (nettoyage guidé)"
    fi
    sep
    info "Chiffres enregistrés dans $STATE (servent à la vidéo avant/après)."
}

# ============================================================ BENCHMARK ======
parse_speed() {  # sortie stderr de dd (LC_ALL=C) → Mo/s
    awk '{
        for (i = 1; i <= NF; i++) {
            if ($i == "MB/s") { printf "%.1f", $(i-1);      exit }
            if ($i == "GB/s") { printf "%.1f", $(i-1)*1000; exit }
            if ($i == "kB/s") { printf "%.2f", $(i-1)/1000; exit }
            if ($i == "B/s")  { printf "%.3f", $(i-1)/1000000; exit }
        }
    }'
}

bench_once() {  # $1 = dossier de test → affiche "écriture lecture" en Mo/s
    local dir="$1"
    local tmp="$dir/.docteur-bench.tmp"
    BENCH_TMP="$tmp"
    trap 'rm -f "$BENCH_TMP" 2>/dev/null' INT TERM
    local w r
    printf "   test d'écriture (%s Mo) ... " "$BENCH_MB" >&2
    w=$(LC_ALL=C dd if=/dev/zero of="$tmp" bs=1M count="$BENCH_MB" conv=fsync 2>&1 >/dev/null | parse_speed)
    sync
    if [ "$(id -u)" -eq 0 ]; then
        echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    elif [ -n "$SUDO" ]; then
        $SUDO sh -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null || true
    fi
    printf "   test de lecture ... " >&2
    r=$(LC_ALL=C dd if="$tmp" of=/dev/null bs=1M 2>&1 >/dev/null | parse_speed)
    rm -f "$tmp" 2>/dev/null; BENCH_TMP=""
    trap - INT TERM
    printf '%s %s\n' "${w:-NA}" "${r:-NA}"
}

bench_main() {  # bench_main before|after
    local tag="$1"
    ensure_sudo || true
    msg ""
    msg "${C_W}  BENCHMARK DISQUE ($tag)${C_0}"
    sep
    # réduit la taille du test si le disque est plein (ton cas : 0 octet libre !)
    local avail dir="$HOMEDIR"
    avail=$(df -B1 -P "$dir" 2>/dev/null | awk 'NR==2{print $4}')
    if [ -n "$avail" ] && [ "$avail" -lt $((2 * 1048576 * BENCH_MB)) ]; then
        BENCH_MB=$(( avail / 1048576 / 3 ))
        if [ "$BENCH_MB" -lt 64 ]; then
            err "Moins de 64 Mo libres : impossible de faire le benchmark. Nettoie d'abord (menu 3)."
            return 1
        fi
        warn "Disque presque plein : test réduit à ${BENCH_MB} Mo."
    fi
    local res w r
    res=$(bench_once "$dir")
    w=${res%% *}; r=${res##* }
    st_set "bench_w_$tag" "$w"
    st_set "bench_r_$tag" "$r"
    msg ""
    ok "Écriture : ${w:-NA} Mo/s      Lecture : ${r:-NA} Mo/s"
    info "Test synthétique (dd) : les Mo/s réels varient selon les fichiers. ${BENCH_MB} Mo écrits puis relus."
    msg ""
}

# ============================================================ NETTOYAGE ======
clean_timeshift() {
    msg ""
    msg "${C_W}  [1/9] Timeshift — snapshots${C_0}"
    sep
    ensure_sudo || return
    command -v timeshift >/dev/null 2>&1 || [ -d /timeshift ] || {
        info "Timeshift n'est pas installé — étape ignorée."; return; }

    local -a snaps=()
    declare -A SNAPDIR=()
    if command -v timeshift >/dev/null 2>&1; then
        mapfile -t snaps < <($SUDO timeshift --list 2>/dev/null \
            | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}' | sort -u)
    fi
    if [ ${#snaps[@]} -eq 0 ]; then
        while IFS= read -r d; do
            [ -n "$d" ] || continue
            snaps+=("$(basename "$d")")
            SNAPDIR["$(basename "$d")"]="$d"
        done < <($SUDO find /timeshift -maxdepth 5 -type d -name info.json 2>/dev/null | sed 's|/info\.json$||')
    fi

    if [ ${#snaps[@]} -eq 0 ]; then
        info "Aucun snapshot trouvé."; return; fi

    msg "   ${#snaps[@]} snapshot(s) trouvé(s) :"
    local s total_keep=0
    for s in "${snaps[@]}"; do
        local sz=0
        [ -n "${SNAPDIR[$s]:-}" ] && sz=$(sudu "${SNAPDIR[$s]}")
        printf "   %s   (%s)\n" "$s" "$(hr "$sz")"
    done

    local KEEP=3
    local a
    read -r -p "   Garder combien de snapshots les plus récents ? [3] : " a || a=3
    a=${a:-3}; [[ "$a" =~ ^[0-9]+$ ]] && KEEP=$a

    local total=${#snaps[@]}
    if [ "$total" -le "$KEEP" ]; then
        ok "Rien à supprimer ($total snapshot(s), limite $KEEP)."
        return
    fi

    local -a todel=()
    for s in "${snaps[@]:0:$((total - KEEP))}"; do todel+=("$s"); done
    msg "   À supprimer (les $((total - KEEP)) plus anciens) :"
    local free_est=0
    for s in "${todel[@]}"; do
        local sz=0
        [ -n "${SNAPDIR[$s]:-}" ] && sz=$(sudu "${SNAPDIR[$s]}")
        free_est=$((free_est + sz))
        printf "     ✗ %s   (%s)\n" "$s" "$(hr "$sz")"
    done
    warn "Un snapshot supprimé est perdu DÉFINITIVEMENT (plus de restauration possible à cette date)."

    ask "Supprimer ces $((total - KEEP)) snapshot(s) (≈ $(hr "$free_est")) ?" O || { info "Étape passée."; return; }

    local btrfs=0
    [ "$(findmnt -n -o FSTYPE /timeshift 2>/dev/null)" = "btrfs" ] && btrfs=1
    local freed=0
    for s in "${todel[@]}"; do
        if command -v timeshift >/dev/null 2>&1; then
            if $SUDO timeshift --delete --snapshot "$s" >/dev/null 2>&1; then
                :  # gain mesuré plus bas : taille /timeshift avant - après
            else
                if [ "$btrfs" = 1 ]; then
                    warn "Échec CLI sur $s — utilise l'application Timeshift (mode btrfs)."
                elif [ -n "${SNAPDIR[$s]:-}" ]; then
                    warn "CLI en échec sur $s — suppression directe du dossier."
                    $SUDO rm -rf -- "${SNAPDIR[$s]}"
                fi
            fi
        elif [ -n "${SNAPDIR[$s]:-}" ]; then
            $SUDO rm -rf -- "${SNAPDIR[$s]}"
        fi
    done
    # mesure réelle du gain : taille avant - taille après
    local after; after=$(sudu /timeshift)
    local before; before=$(st_get ts_size_before)
    [ -n "$before" ] && freed=$(( before > after ? before - after : 0 ))
    FREED_TOTAL=$((FREED_TOTAL + freed))
    ok "Timeshift : libéré ≈ $(hr "$freed")"
}

clean_journal() {
    msg ""
    msg "${C_W}  [2/9] Journal systemd${C_0}"
    sep
    command -v journalctl >/dev/null 2>&1 || { info "journald absent — ignoré."; return; }
    ensure_sudo || return
    local js b
    js=$($SUDO journalctl --disk-usage 2>/dev/null | awk '/take up/{print $(NF-4)}')
    [ -z "$js" ] && { info "Journal inaccessible ou vide."; return; }
    b=$(to_bytes "$js")
    msg "   Le journal occupe actuellement $(hr "$b")."
    ask "Le réduire à 100 Mo ? (les vieux logs systèmes sont effacés, rien d'important)" O || { info "Étape passée."; return; }
    $SUDO journalctl --vacuum-size=100M >/dev/null 2>&1
    local js2 a
    js2=$($SUDO journalctl --disk-usage 2>/dev/null | awk '/take up/{print $(NF-4)}')
    a=0; [ -n "$js2" ] && a=$(to_bytes "$js2")
    local f=$(( b > a ? b - a : 0 ))
    FREED_TOTAL=$((FREED_TOTAL + f))
    ok "Journal : libéré $(hr "$f")"
}

clean_varlog() {
    msg ""
    msg "${C_W}  [3/9] Vieilles archives de logs (/var/log)${C_0}"
    sep
    ensure_sudo || return
    local -a olds=()
    mapfile -t olds < <($SUDO find /var/log -type f \( -name "*.gz" -o -name "*.xz" -o -name "*.old" -o -name "*.1" -o -name "*.2" -o -name "*.3" -o -name "*.4" -o -name "*.5" -o -name "*.6" -o -name "*.7" -o -name "*.8" -o -name "*.9" -o -regex ".*\.[0-9]+" \) 2>/dev/null)
    if [ ${#olds[@]} -eq 0 ]; then
        info "Aucune archive de log à supprimer."; return; fi
    local t=0 f
    for f in "${olds[@]}"; do t=$((t + $(sudu "$f"))); done
    msg "   ${#olds[@]} archive(s) de logs (rotate.gz/xz/old) : $(hr "$t")"
    ask "Supprimer ces archives ? (logrotate en recréera si besoin)" O || { info "Étape passée."; return; }
    for f in "${olds[@]}"; do $SUDO rm -f -- "$f"; done
    FREED_TOTAL=$((FREED_TOTAL + t))
    ok "Logs : libéré $(hr "$t")"

    # gros logs ACTIFS (> 100 Mo) : proposés au tronquage
    local -a bigs=()
    mapfile -t bigs < <($SUDO find /var/log -maxdepth 1 -type f -size +100M ! -name "*.gz" 2>/dev/null)
    if [ ${#bigs[@]} -gt 0 ]; then
        warn "Logs ACTIFS anormalement gros (un programme écrit trop dedans !) :"
        local bf
        for bf in "${bigs[@]}"; do printf "     %s  %s\n" "$(hr "$(sudu "$bf")")" "$bf"; done
        if ask "Tronquer ces logs actifs ? (le service continue d'écrire dedans après)" O; then
            local bt=0
            for bf in "${bigs[@]}"; do bt=$((bt + $(sudu "$bf"))); $SUDO truncate -s 0 -- "$bf"; done
            FREED_TOTAL=$((FREED_TOTAL + bt))
            ok "Tronqué : $(hr "$bt")"
            warn "Si ce log regrossit vite → menu « a » pour identifier le programme coupable."
        fi
    fi
}

clean_apt() {
    msg ""
    msg "${C_W}  [4/9] Cache APT${C_0}"
    sep
    ensure_sudo || return
    local b; b=$(sudu /var/cache/apt/archives)
    msg "   Cache des paquets .deb téléchargés : $(hr "$b")"
    ask "Vider le cache APT ? (les paquets se retéléchargeront si besoin)" O || { info "Étape passée."; return; }
    $SUDO apt-get clean >/dev/null 2>&1
    local a; a=$(sudu /var/cache/apt/archives)
    local f=$(( b > a ? b - a : 0 ))
    FREED_TOTAL=$((FREED_TOTAL + f))
    ok "APT : libéré $(hr "$f")"

    local nrem
    nrem=$(LC_ALL=C $SUDO apt-get -s autoremove 2>/dev/null | grep -c '^Remv' || true)
    if [ "${nrem:-0}" -gt 0 ]; then
        msg "   apt autoremove peut retirer $nrem paquet(s) devenu(s) inutile(s)."
        ask "Lancer sudo apt-get autoremove ?" O || { info "Étape passée."; return; }
        $SUDO apt-get autoremove -y >/dev/null 2>&1
        ok "autoremove terminé (gain compté dans le total global)."
    fi
}

clean_usercache() {
    msg ""
    msg "${C_W}  [5/9] Cache utilisateur (~/.cache)${C_0}"
    sep
    local b; b=$(dub "$HOMEDIR/.cache")
    msg "   Cache utilisateur : $(hr "$b")"
    if [ "$b" -eq 0 ]; then info "Cache déjà vide."; return; fi

    local th; th=$(dub "$HOMEDIR/.cache/thumbnails")
    if [ "$th" -gt 0 ]; then
        msg "   Miniatures d'images (thumbnails) : $(hr "$th")"
        ask "Supprimer les miniatures ? (elles se recréent automatiquement)" O && {
            rm -rf "$HOMEDIR/.cache/thumbnails/"* 2>/dev/null
            FREED_TOTAL=$((FREED_TOTAL + th))
            ok "Miniatures : libéré $(hr "$th")"
        }
    fi
    warn "Vider TOUT le cache : ferme d'abord tes navigateurs/applis (elles retéléchargeront leurs données)."
    ask "Vider tout ~/.cache ?" n || { info "Étape passée."; return; }
    local a; a=$(dub "$HOMEDIR/.cache")
    find "$HOMEDIR/.cache" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null
    local f=$(( a > 0 ? a : 0 ))
    FREED_TOTAL=$((FREED_TOTAL + f))
    ok "Cache utilisateur : libéré ≈ $(hr "$f")"
}

clean_trash() {
    msg ""
    msg "${C_W}  [6/9] Corbeille${C_0}"
    sep
    local T="$HOMEDIR/.local/share/Trash"
    local b; b=$(dub "$T")
    if [ "$b" -eq 0 ]; then info "Corbeille déjà vide."; return; fi
    msg "   La corbeille contient $(hr "$b") de fichiers supprimés."
    warn "Irréversible : les fichiers de la corbeille seront définitivement perdus."
    ask "Vider la corbeille ?" n || { info "Étape passée."; return; }
    local a; a=$(dub "$T")
    if command -v gio >/dev/null 2>&1; then
        gio trash --empty 2>/dev/null || rm -rf "$T/files/"* "$T/info/"* 2>/dev/null
    else
        rm -rf "$T/files/"* "$T/info/"* 2>/dev/null
    fi
    FREED_TOTAL=$((FREED_TOTAL + a))
    ok "Corbeille : libéré ≈ $(hr "$a")"
}

clean_flatpak() {
    msg ""
    msg "${C_W}  [7/9] Flatpak inutilisés${C_0}"
    sep
    command -v flatpak >/dev/null 2>&1 || { info "Flatpak absent — ignoré."; return; }
    local b; b=$(sudu /var/lib/flatpak)
    msg "   Taille actuelle de Flatpak : $(hr "$b")"
    ask "Supprimer les runtimes/extensions flatpak devenus inutilisés ?" O || { info "Étape passée."; return; }
    $SUDO flatpak uninstall --unused -y >/dev/null 2>&1 || flatpak uninstall --unused -y >/dev/null 2>&1
    local a; a=$(sudu /var/lib/flatpak)
    local f=$(( b > a ? b - a : 0 ))
    FREED_TOTAL=$((FREED_TOTAL + f))
    ok "Flatpak : libéré $(hr "$f")"
}

clean_snap() {
    msg ""
    msg "${C_W}  [8/9] Snap — vieilles révisions${C_0}"
    sep
    command -v snap >/dev/null 2>&1 || { info "Snap absent (normal sur Mint) — ignoré."; return; }
    ensure_sudo || return
    local -a olds=()
    mapfile -t olds < <(snap list --all 2>/dev/null | awk '/disabled|désactivé/{print $1 "@" $3}')
    if [ ${#olds[@]} -eq 0 ]; then info "Aucune vieille révision snap."; return; fi
    local o
    msg "   ${#olds[@]} vieille(s) révision(s) snap gardée(s) en double :"
    for o in "${olds[@]}"; do printf "     %s\n" "$o"; done
    ask "Supprimer ces vieilles révisions ?" O || { info "Étape passée."; return; }
    for o in "${olds[@]}"; do
        local nm rev; nm=${o%@*}; rev=${o##*@}
        $SUDO snap remove "$nm" --revision="$rev" >/dev/null 2>&1 || true
    done
    ok "Vieilles révisions snap supprimées."
}

clean_crash() {
    msg ""
    msg "${C_W}  [9/9] Rapports de plantage et core dumps${C_0}"
    sep
    local b=0 d
    for d in /var/crash /var/lib/systemd/coredump; do b=$((b + $(sudu "$d"))); done
    if [ "$b" -eq 0 ]; then info "Rien ici."; return; fi
    msg "   Rapports de plantage : $(hr "$b")"
    ask "Supprimer ? (utiles seulement pour déboguer un bug)" O || { info "Étape passée."; return; }
    ensure_sudo || return
    $SUDO rm -rf /var/crash/* /var/lib/systemd/coredump/* 2>/dev/null
    FREED_TOTAL=$((FREED_TOTAL + b))
    ok "Plantages : libéré $(hr "$b")"
}

measure_after() {
    st_set disk_pct_after   "$(disk_pct)"
    st_set used_bytes_after "$(used_bytes)"
    st_set ts_size_after    "$(sudu /timeshift)"
    st_set log_size_after   "$(sudu /var/log)"
    st_set apt_size_after   "$(sudu /var/cache/apt/archives)"
    st_set cache_size_after "$(dub "$HOMEDIR/.cache")"
    st_set trash_size_after "$(dub "$HOMEDIR/.local/share/Trash")"
    local ub ua
    ub=$(st_get used_bytes_before); ua=$(st_get used_bytes_after)
    if [ -n "$ub" ] && [ -n "$ua" ]; then
        local f=$(( ub - ua )); [ "$f" -lt 0 ] && f=0
        st_set freed_total "$f"
        FREED_TOTAL=$f
    fi
}

clean_main() {
    banner
    msg "${C_W}  NETTOYAGE GUIDÉ — tu réponds O/n à chaque étape${C_0}"
    sep
    [ -z "$(st_get ts_size_before)" ] && collect_sizes
    FREED_TOTAL=0
    clean_timeshift
    clean_journal
    clean_varlog
    clean_apt
    clean_usercache
    clean_trash
    clean_flatpak
    clean_snap
    clean_crash
    measure_after

    msg ""
    sep
    local pb pa
    pb=$(st_get disk_pct_before); pa=$(st_get disk_pct_after)
    ok "DISQUE : ${pb:-?} % avant  →  ${pa:-?} % après"
    ok "ESPACE LIBÉRÉ (mesuré sur la partition) : $(hr "$(st_get freed_total)")"
    info "Prochaine étape conseillée : menu 4 (benchmark après nettoyage) puis menu 7 (vidéo)."
    msg ""
}

# ============================================================ STICKY BIT =====
sticky_main() {
    banner
    msg "${C_W}  STICKY BIT — audit et correction${C_0}"
    sep
    info "Le sticky bit (le « t » dans les droits, ex. drwxrwxrwt) interdit à un"
    info "utilisateur de supprimer les fichiers des autres dans un dossier public."
    info "/tmp, /var/tmp et /dev/shm DOIVENT l'avoir sur Linux Mint."
    msg ""
    ensure_sudo || true
    local report="$STATE_DIR/rapport-sticky.txt"
    : > "$report"

    local d mode own grp fixed=0
    for d in /tmp /var/tmp /dev/shm; do
        [ -d "$d" ] || continue
        read -r mode own grp < <(stat -c '%a %U %G' "$d")
        if [ "$mode" = "1777" ]; then
            ok "  $d : mode $mode ($own:$grp) — sticky bit présent, tout est bon ✓"
        else
            warn "  $d : mode $mode ($own:$grp) — sticky bit ABSENT ou mauvais réglage"
            echo "$d mode=$mode owner=$own:$grp" >> "$report"
            if [ "$NONINT" = 1 ]; then
                info "    → correction : sudo chown root:root $d && sudo chmod 1777 $d"
            elif ask "Corriger $d maintenant (chmod 1777, propriétaire root) ?" O; then
                $SUDO chown root:root "$d" 2>/dev/null
                $SUDO chmod 1777 "$d"
                ok "    $d corrigé ✓"
                fixed=$((fixed+1))
            fi
        fi
    done

    msg ""
    msg "${C_W}  Scan des AUTRES dossiers écrivables par tous sans sticky bit (≤ 2 min) :${C_0}"
    local -a bad=()
    mapfile -t bad < <(timeout 120 find / -xdev \
        \( -path /tmp -o -path /var/tmp -o -path /dev/shm \) -prune \
        -o -type d -perm -0002 ! -perm -1000 -print 2>/dev/null)
    if [ ${#bad[@]} -eq 0 ]; then
        ok "  Aucun autre dossier à problème trouvé ✓"
    else
        local p
        for p in "${bad[@]}"; do
            warn "  $p écrivable par tous SANS sticky bit"
            echo "autre:$p" >> "$report"
            if [ "$NONINT" = 0 ] && ask "Ajouter le sticky bit sur $p ?" n; then
                $SUDO chmod +t "$p" && ok "    sticky bit ajouté ✓" && fixed=$((fixed+1))
            fi
        done
    fi

    msg ""
    msg "${C_W}  Fichiers modifiables par TOUS le monde (info sécurité) :${C_0}"
    local -a ww=()
    mapfile -t ww < <(timeout 60 find / -xdev -type f -perm -0002 2>/dev/null | head -20)
    if [ ${#ww[@]} -eq 0 ]; then
        ok "  Aucun ✓"
    else
        local p2
        for p2 in "${ww[@]}"; do warn "  $p2"; echo "fichier:$p2" >> "$report"; done
        info "Vérifie que ces fichiers sont censés être écrivables par tous."
    fi

    msg ""
    if [ "$fixed" -gt 0 ]; then ok "Corrections appliquées : $fixed"; fi
    info "Rapport : $report"
    msg ""
}

# ==================================================== SURVEILLANCE AUTO ======
auto_install() {
    msg ""
    msg "${C_W}  SURVEILLANCE AUTOMATIQUE (seuil ${THRESHOLD} %)${C_0}"
    sep
    ensure_sudo || { err "sudo requis pour installer la surveillance."; return 1; }

    msg "   Installation du nettoyeur automatique ..."
    $SUDO tee /usr/local/bin/docteur-disque-auto.sh >/dev/null <<'AUTOEOF'
#!/bin/bash
# Généré par docteur-disque.sh — nettoie SEULEMENT quand le disque dépasse le seuil.
# Ne touche JAMAIS aux documents, photos, Timeshift ou corbeille.
THRESHOLD=@THRESHOLD@
LOG=/var/log/docteur-disque-auto.log
pct=$(df -P / | awk 'NR==2{gsub("%","");print $5}')
[ -z "$pct" ] && exit 0
[ "$pct" -lt "$THRESHOLD" ] && exit 0
echo "[$(date '+%F %T')] disque a ${pct}% (seuil ${THRESHOLD}%) : auto-nettoyage" >> "$LOG"
journalctl --vacuum-size=100M >/dev/null 2>&1
apt-get clean >/dev/null 2>&1
find /var/log -type f \( -name "*.gz" -o -name "*.xz" -o -name "*.old" -o -name "*.1" \) -mtime +2 -delete 2>/dev/null
pct2=$(df -P / | awk 'NR==2{gsub("%","");print $5}')
if [ "$pct2" -ge "$THRESHOLD" ] && command -v flatpak >/dev/null 2>&1; then
    flatpak uninstall --unused -y >/dev/null 2>&1
fi
pct3=$(df -P / | awk 'NR==2{gsub("%","");print $5}')
echo "    -> apres nettoyage : ${pct3}%" >> "$LOG"
if [ "$pct3" -ge 95 ]; then
    echo "    !! disque encore plein a ${pct3}% : lance ./docteur-disque.sh (menu audit) pour trouver le coupable" >> "$LOG"
fi
AUTOEOF
    $SUDO sed -i "s/@THRESHOLD@/$THRESHOLD/" /usr/local/bin/docteur-disque-auto.sh
    $SUDO chmod 755 /usr/local/bin/docteur-disque-auto.sh

    $SUDO tee /etc/systemd/system/docteur-disque.service >/dev/null <<'UNITEOF'
[Unit]
Description=Docteur Disque : auto-nettoyage si le disque est plein

[Service]
Type=oneshot
ExecStart=/usr/local/bin/docteur-disque-auto.sh
Nice=19
IOSchedulingClass=idle
UNITEOF

    $SUDO tee /etc/systemd/system/docteur-disque.timer >/dev/null <<'TIMEREOF'
[Unit]
Description=Docteur Disque : vérifie le disque toutes les 15 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=15min
AccuracySec=1min

[Install]
WantedBy=timers.target
TIMEREOF

    $SUDO systemctl daemon-reload
    $SUDO systemctl enable --now docteur-disque.timer >/dev/null 2>&1
    if systemctl is-enabled docteur-disque.timer >/dev/null 2>&1; then
        ok "Surveillance installée et ACTIVE ✓"
        info "Elle vérifie toutes les 15 min : si / dépasse ${THRESHOLD} % → purge journal + cache apt + vieilles archives de logs."
        info "Journal des actions : /var/log/docteur-disque-auto.log"
        info "Pour changer le seuil : édite THRESHOLD dans /usr/local/bin/docteur-disque-auto.sh"
    else
        err "Le timer n'a pas démarré — regarde : systemctl status docteur-disque.timer"
    fi
    msg ""
}

auto_uninstall() {
    msg ""
    msg "${C_W}  DÉSINSTALLATION DE LA SURVEILLANCE AUTO${C_0}"
    sep
    ensure_sudo || return 1
    $SUDO systemctl disable --now docteur-disque.timer >/dev/null 2>&1 || true
    $SUDO rm -f /etc/systemd/system/docteur-disque.timer \
                /etc/systemd/system/docteur-disque.service \
                /usr/local/bin/docteur-disque-auto.sh
    $SUDO systemctl daemon-reload
    ok "Surveillance désinstallée ✓ (le journal /var/log/docteur-disque-auto.log est conservé)"
    msg ""
}

auto_status() {
    if systemctl is-enabled docteur-disque.timer >/dev/null 2>&1; then
        ok "Surveillance auto : ACTIVE (vérification toutes les 15 min)"
        [ -r /var/log/docteur-disque-auto.log ] && tail -n 5 /var/log/docteur-disque-auto.log
    else
        info "Surveillance auto : non installée (menu 6 pour l'installer)"
    fi
}

# ================================================================ VIDÉO ======
esc() {  # échappe pour drawtext (les textes évitent déjà : ' , % autant que possible)
    local t=$1
    t=${t//\\/\\\\}
    t=${t//:/\\:}
    t=${t//,/\\,}
    t=${t//%/"\\\\%"}   # drawtext reçoit \\% → affiche % sans warning "Stray %"
    t=${t//\'/"\\'"}
    printf '%s' "$t"
}
dt() {  # dt <x> <y> <taille> <couleur> <texte> [B=bold]
    local fnt="$FONT_R"
    [ "${6:-}" = "B" ] && fnt="$FONT_B"
    printf 'drawtext=fontfile=%s:fontcolor=%s:fontsize=%s:x=%s:y=%s:text=%s' \
        "$fnt" "$4" "$3" "$1" "$2" "'$(esc "$5")'"
}
bar_track() {  # fond de barre
    printf 'drawbox=x=500:y=%s:w=480:h=30:color=0x222835@0.85:t=fill' "$1"
}
bar_fill() {  # barre colorée
    printf 'drawbox=x=500:y=%s:w=%s:h=30:color=%s@0.95:t=fill' "$1" "$2" "$3"
}

render_frame() {  # render_frame <filtres> <fichier.png>
    ffmpeg -loglevel error -y -f lavfi -i 'color=c=0x0E1116:s=1280x720' \
        -vf "$1" -frames:v 1 "$2" 2>/dev/null
}

demo_state() {  # chiffres fictifs pour voir la vidéo sans rien faire
    st_set disk_pct_before 97;          st_set disk_pct_after 41
    st_set used_bytes_before $((470000000000)); st_set used_bytes_after $((199000000000))
    st_set ts_size_before $((104 * 1073741824)); st_set ts_size_after $((21 * 1073741824))
    st_set log_size_before $((8 * 1073741824));  st_set log_size_after $((209715200))
    st_set apt_size_before $((3221225472));      st_set apt_size_after $((52428800))
    st_set cache_size_before $((5855145984));    st_set cache_size_after $((1258291200))
    st_set trash_size_before $((12 * 1073741824)); st_set trash_size_after 0
    st_set bench_w_before 412.3; st_set bench_r_before 512.8
    st_set bench_w_after 455.7;  st_set bench_r_after 548.2
    st_set freed_total $((271000000000))
}

video_make() {
    msg ""
    msg "${C_W}  VIDÉO RÉCAPITULATIVE MP4${C_0}"
    sep
    command -v ffmpeg >/dev/null 2>&1 || {
        err "ffmpeg absent. Installe-le : sudo apt install ffmpeg  — puis relance."
        return 1
    }
    FONT_R=$(find /usr/share/fonts -name 'DejaVuSans.ttf' 2>/dev/null | head -n1)
    FONT_B=$(find /usr/share/fonts -name 'DejaVuSans-Bold.ttf' 2>/dev/null | head -n1)
    [ -z "$FONT_R" ] && FONT_R=$(fc-match -f '%{file}' 'sans' 2>/dev/null)
    [ -z "$FONT_B" ] && FONT_B="$FONT_R"
    [ -z "$FONT_R" ] && { err "Aucune police trouvée."; return 1; }

    # ---- données : avant ----
    local pct_b pct_a tsb lsb apb ccb trb tsa lsa apa cca tra freed NOAFTER=0
    pct_b=$(st_get disk_pct_before)
    if [ -z "$pct_b" ]; then
        info "Pas encore d'audit enregistré — je mesure l'état actuel (ça servira d'« avant »)."
        collect_sizes; pct_b=$(st_get disk_pct_before)
    fi
    tsb=$(st_get ts_size_before);  lsb=$(st_get log_size_before)
    apb=$(st_get apt_size_before); ccb=$(st_get cache_size_before); trb=$(st_get trash_size_before)

    pct_a=$(st_get disk_pct_after)
    if [ -z "$pct_a" ]; then
        pct_a="$pct_b"; NOAFTER=1
        tsa=$tsb; lsa=$lsb; apa=$apb; cca=$ccb; tra=$trb
    else
        tsa=$(st_get ts_size_after);   lsa=$(st_get log_size_after)
        apa=$(st_get apt_size_after);  cca=$(st_get cache_size_after); tra=$(st_get trash_size_after)
        [ -z "$tsa" ] && tsa=$tsb; [ -z "$lsa" ] && lsa=$lsb
        [ -z "$apa" ] && apa=$apb; [ -z "$cca" ] && cca=$ccb; [ -z "$tra" ] && tra=$trb
    fi
    freed=$(st_get freed_total)
    [ -z "$freed" ] && freed=0

    local bw_b br_b bw_a br_a
    bw_b=$(st_get bench_w_before); br_b=$(st_get bench_r_before)
    bw_a=$(st_get bench_w_after);  br_a=$(st_get bench_r_after)

    local maxb maxw maxr
    maxb=$(awk -v a="$tsb" -v b="$lsb" -v c="$apb" -v d="$ccb" -v e="$trb" \
        'BEGIN{m=a; if(b>m)m=b; if(c>m)m=c; if(d>m)m=d; if(e>m)m=e; print (m>0?m:1)}')
    maxw=$(awk -v x="$bw_b" -v y="$bw_a" 'BEGIN{m=(x+0>y+0?x:y); print (m>0?m:1)}')
    maxr=$(awk -v x="$br_b" -v y="$br_a" 'BEGIN{m=(x+0>y+0?x:y); print (m>0?m:1)}')

    local T; T=$(mktemp -d /tmp/docteur-video.XXXXXX)
    VIDEO_TMP="$T"   # global : le trap doit survivre à la sortie de la fonction
    trap 'rm -rf "$VIDEO_TMP" 2>/dev/null' EXIT INT TERM
    local idx=1 out="$T/f"

    render() {
        render_frame "$1" "$(printf '%s_%04d.png' "$out" "$idx")" || {
            err "Échec du rendu d'une image (drawtext/ffmpeg)."
            return 1
        }
        idx=$((idx+1))
        return 0
    }

    local -a labels=("Disque utilisé" "Timeshift" "Logs système" "Cache APT" "Cache utilisateur" "Corbeille")
    local -a cols=(0xFF6B6B 0xFFA94D 0xFFD43B 0x74C0FC 0xB197FC 0x38D9A9)

    sizes_scene() {  # $1 titre  $2 couleur titre  $3 grow(1-4)  $4=mode(before/after)
        local titre="$1" tcol="$2" g="$3" mode="$4"
        local -a vals
        local soustitre
        if [ "$mode" = "before" ]; then
            vals=("$pct_b" "$tsb" "$lsb" "$apb" "$ccb" "$trb")
            soustitre="État du disque AVANT le nettoyage"
        else
            vals=("$pct_a" "$tsa" "$lsa" "$apa" "$cca" "$tra")
            soustitre="État du disque APRÈS le nettoyage"
            [ "$NOAFTER" = 1 ] && soustitre="Pas encore nettoyé — lance le menu 3 avant"
        fi
        local -a parts=()
        parts+=("$(dt '(w-text_w)/2' 110 54 "$tcol" "$titre" B)")
        parts+=("$(dt '(w-text_w)/2' 185 30 0x9AA3B2 "$soustitre")")
        local i y v w vt
        for i in 0 1 2 3 4 5; do
            y=$((250 + i * 66))
            v=${vals[$i]}
            if [ "$i" -eq 0 ]; then
                w=$(awk -v p="$v" -v gg="$g" 'BEGIN{x=p/100*480*gg/4; if(x>480)x=480; if(p>0 && x<2)x=2; if(x<0)x=0; printf "%d", x}')
                vt="${v} sur 100"
            else
                w=$(awk -v vv="$v" -v m="$maxb" -v gg="$g" 'BEGIN{x=vv/m*480*gg/4; if(x>480)x=480; if(vv>0 && x<2)x=2; if(x<0)x=0; printf "%d", x}')
                vt=$(hr "$v")
            fi
            parts+=("$(bar_track "$y")")
            # drawbox avec w=0 dessinerait une barre pleine largeur : on ne dessine
            # la barre colorée que si la valeur est non nulle
            [ "$w" != "0" ] && parts+=("$(bar_fill "$y" "$w" "${cols[$i]}")")
            parts+=("$(dt 80 "$((y + 2))" 24 0xE9ECF1 "${labels[$i]}")")
            parts+=("$(dt '1240-text_w' "$y" 26 0xF5F5F5 "$vt")")
        done
        local IFS=','
        printf '%s' "${parts[*]}"
    }

    bench_scene() {  # $1 grow
        local g="$1"
        local -a parts=()
        parts+=("$(dt '(w-text_w)/2' 110 54 0x74C0FC "BENCHMARK DU DISQUE" B)")
        parts+=("$(dt '(w-text_w)/2' 185 30 0x9AA3B2 "Vitesse mesuree avec dd — en Mo par seconde")")
        local -a bl=("Écriture avant" "Écriture après" "Lecture avant" "Lecture après")
        local -a bv=("${bw_b:-NA}" "${bw_a:-NA}" "${br_b:-NA}" "${br_a:-NA}")
        local -a bc=(0xFF6B6B 0x51CF66 0xFF6B6B 0x51CF66)
        local i y v w vt
        for i in 0 1 2 3; do
            y=$((260 + i * 78))
            v="${bv[$i]}"
            if [ "$v" = "NA" ]; then
                w=0; vt="n.d."
            else
                if [ $i -le 1 ]; then m="$maxw"; else m="$maxr"; fi
                w=$(awk -v vv="$v" -v mm="$m" -v gg="$g" 'BEGIN{x=vv/mm*480*gg/4; if(x>480)x=480; if(vv>0 && x<2)x=2; if(x<0)x=0; printf "%d", x}')
                vt="${v} Mo/s"
            fi
            parts+=("$(bar_track "$y")")
            [ "$w" != "0" ] && parts+=("$(bar_fill "$y" "$w" "${bc[$i]}")")
            parts+=("$(dt 80 "$((y + 2))" 24 0xE9ECF1 "${bl[$i]}")")
            parts+=("$(dt '1240-text_w' "$y" 26 0xF5F5F5 "$vt")")
        done
        local IFS=','
        printf '%s' "${parts[*]}"
    }

    summary_scene() {
        local -a parts=()
        parts+=("$(dt '(w-text_w)/2' 110 54 0x51CF66 "RÉSUMÉ DOCTEUR DISQUE" B)")
        local surveil="Surveillance auto : non installée"
        if systemctl is-enabled docteur-disque.timer >/dev/null 2>&1; then
            surveil="Surveillance auto : ACTIVE (seuil ${THRESHOLD}%)"
        fi
        local l1="Disque : ${pct_b} sur 100 avant → ${pct_a} sur 100 après"
        local l2="Espace libéré : $(hr "$freed")"
        local l3="Écriture : ${bw_b:-n.d.} → ${bw_a:-n.d.} Mo/s   Lecture : ${br_b:-n.d.} → ${br_a:-n.d.} Mo/s"
        local l5="Timeshift limité à 3 snapshots + surveillance du disque"
        parts+=("$(dt 120 220 32 0xF5F5F5 "$l1")")
        parts+=("$(dt 120 290 32 0x51CF66 "$l2")")
        parts+=("$(dt 120 360 28 0xF5F5F5 "$l3")")
        parts+=("$(dt 120 430 28 0x9AA3B2 "$surveil")")
        parts+=("$(dt 120 500 28 0x9AA3B2 "$l5")")
        parts+=("$(dt '(w-text_w)/2' 640 22 0x5C6370 "Généré par docteur-disque.sh v$VERSION")")
        local IFS=','
        printf '%s' "${parts[*]}"
    }

    title_scene() {
        local -a parts=()
        parts+=("$(dt '(w-text_w)/2' 250 74 0xF5F5F5 "DOCTEUR DISQUE" B)")
        parts+=("$(dt '(w-text_w)/2' 370 30 0x9AA3B2 "Audit — Nettoyage — Benchmark — Surveillance")")
        parts+=("$(dt '(w-text_w)/2' 430 26 0x5C6370 "$(hostname) — $(date '+%d/%m/%Y %H:%M')")")
        local IFS=','
        printf '%s' "${parts[*]}"
    }

    # ---- rendu des 5 scènes ----
    local k f
    info "Rendu des images (39 frames) ..."
    for k in 1 2 3 4; do render "$(title_scene)" || return 1; done
    for k in 1 2 3 4 5 6 7 8 9; do
        g=$(( k > 4 ? 4 : k ))
        render "$(sizes_scene "AVANT NETTOYAGE" 0xFF6B6B "$g" before)" || return 1
    done
    for k in 1 2 3 4 5 6 7 8 9; do
        g=$(( k > 4 ? 4 : k ))
        render "$(sizes_scene "APRÈS NETTOYAGE" 0x51CF66 "$g" after)" || return 1
    done
    for k in 1 2 3 4 5 6 7 8 9 10; do
        g=$(( k > 4 ? 4 : k ))
        render "$(bench_scene "$g")" || return 1
    done
    for k in 1 2 3 4 5 6 7; do render "$(summary_scene)" || return 1; done

    local nf; nf=$(ls "$T" 2>/dev/null | grep -c '\.png$' || true)
    if [ "${nf:-0}" -lt 20 ]; then
        err "Le rendu a produit seulement $nf images — ffmpeg/drawtext a probablement échoué."
        return 1
    fi

    local OUT="${OUT_VIDEO:-}"
    if [ -z "$OUT" ]; then
        OUT="$PWD/docteur-disque-rapport.mp4"
        [ -w "$PWD" ] || OUT="$HOMEDIR/docteur-disque-rapport.mp4"
    fi
    [ -e "$OUT" ] && OUT="${OUT%.mp4}-$(date +%H%M%S).mp4"
    info "Encodage MP4 ($nf frames, ~20 s) ..."
    if ! ffmpeg -loglevel error -y -framerate 2 -i "$T/f_%04d.png" \
            -c:v libx264 -preset medium -crf 22 -pix_fmt yuv420p -r 24 \
            -movflags +faststart "$OUT" 2>/dev/null; then
        err "L'encodage a échoué."
        return 1
    fi
    rm -rf "$T" 2>/dev/null; VIDEO_TMP=""; trap - EXIT INT TERM

    ok "Vidéo créée : $OUT"
    command -v ffprobe >/dev/null 2>&1 && \
        ffprobe -v error -show_entries format=duration,size -of default=noprint_wrappers=1 "$OUT" | sed 's/^/   /'
    msg ""
}

# ================================================================ MENU =======
usage() {
    cat <<EOF
DOCTEUR DISQUE v$VERSION — audit, nettoyage, benchmark, sticky bit, surveillance, vidéo

Usage : ./docteur-disque.sh [option]
  Sans option : menu interactif.

  --audit          audit complet (lecture seule, rien n'est supprimé)
  --bench-before   benchmark disque AVANT nettoyage
  --bench-after    benchmark disque APRÈS nettoyage
  --sticky         audit sticky bit (lecture seule)
  --video          génère la vidéo MP4 depuis les chiffres enregistrés
  --demo           vidéo d'exemple avec des chiffres fictifs
  --auto-install   installe la surveillance auto ≥ ${THRESHOLD}% (sudo requis)
  --auto-remove    désinstalle la surveillance auto
  --help           cette aide

Variables : DD_SEUIL=85  DD_BENCH_MB=512  OUT_VIDEO=/chemin/video.mp4
EOF
}

menu() {
    while true; do
        banner
        msg "   État actuel : partition / remplie à $(disk_pct) %"
        auto_status
        msg ""
        msg "   ${C_W}1)${C_0}  Audit complet — qui remplit le disque ?"
        msg "   ${C_W}2)${C_0}  Benchmark disque AVANT nettoyage"
        msg "   ${C_W}3)${C_0}  Nettoyage guidé par étapes (Oui/Non à chaque catégorie)"
        msg "   ${C_W}4)${C_0}  Benchmark disque APRÈS nettoyage"
        msg "   ${C_W}5)${C_0}  Sticky bit : audit + correction"
        msg "   ${C_W}6)${C_0}  Installer la surveillance auto (purge si ≥ ${THRESHOLD} %)"
        msg "   ${C_W}7)${C_0}  Générer la vidéo MP4 récapitulative"
        msg "   ${C_W}8)${C_0}  TOUT enchaîner (1 → 7)"
        msg "   ${C_W}9)${C_0}  Désinstaller la surveillance auto"
        msg "   ${C_W}a)${C_0}  Qui écrit sur le disque en ce moment ?"
        msg "   ${C_W}0)${C_0}  Quitter"
        msg ""
        local c
        read -r -p "   Ton choix : " c
        case "$c" in
            1) audit_disk; pause ;;
            2) bench_main before; pause ;;
            3) clean_main; pause ;;
            4) bench_main after; pause ;;
            5) sticky_main; pause ;;
            6) auto_install; pause ;;
            7) video_make; pause ;;
            8)
                ensure_sudo || true
                audit_disk; pause
                bench_main before; pause
                clean_main; pause
                bench_main after; pause
                sticky_main; pause
                ask "Installer la surveillance auto (${THRESHOLD} %) ?" O && auto_install
                video_make
                pause
                ;;
            9) auto_uninstall; pause ;;
            a) recent_writers; pause ;;
            0|q) msg "Au revoir — pense à lancer le menu 7 pour ta vidéo !"; exit 0 ;;
            *) warn "Choix invalide." ;;
        esac
    done
}

# ================================================================ MAIN =======
mkdir -p "$STATE_DIR" 2>/dev/null || true
case "${1:---menu}" in
    --audit)        NONINT=1; audit_disk ;;
    --bench-before) NONINT=1; bench_main before ;;
    --bench-after)  NONINT=1; bench_main after ;;
    --sticky)       NONINT=1; sticky_main ;;
    --video)        NONINT=1; video_make ;;
    --demo)         NONINT=1; demo_state; video_make ;;
    --auto-install) NONINT=1; auto_install ;;
    --auto-remove)  NONINT=1; auto_uninstall ;;
    --help|-h)      usage ;;
    *)              NONINT=0; menu ;;
esac
