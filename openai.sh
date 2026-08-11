#!/usr/bin/env bash
#
# OpenAI-Checker — check whether your IP falls in a region OpenAI serves.
#
# Nothing about OpenAI's policy is hardcoded as truth. At runtime this script:
#
#   1. asks Cloudflare, at OpenAI's own edge, which country it thinks you are in
#      -> https://chatgpt.com/cdn-cgi/trace
#   2. fetches OpenAI's current list of supported countries and territories
#      -> https://developers.openai.com/api/docs/supported-countries.md
#   3. cross-checks the IP against that country's registered ranges
#      -> https://github.com/ipverse/rir-ip  (RIR delegation data, with a CDN
#         fallback for networks that cannot reach raw.githubusercontent.com)
#
# A baked-in snapshot of (2) is used only if the live fetch fails, and the
# output says so rather than silently pretending to be current.
#
# https://github.com/liandu2024/OpenAI-Checker
#
# Based on OpenAI-Checker by Vincent Young (https://github.com/missuo).
# Released under the MIT License.

set -u
set -o pipefail

VERSION="2.0.0"

# ---------------------------------------------------------------- config ----

TRACE_HOSTS="chatgpt.com chat.openai.com"
OPENAI_DOCS_URL="https://developers.openai.com/api/docs/supported-countries.md"
IPVERSE_BASE="https://raw.githubusercontent.com/ipverse/rir-ip/master/country"
# Same repository via a CDN, for networks that cannot reach raw.githubusercontent
# .com. Only the range data has a fallback: losing it costs a cross-check, and
# it is the one source that is commonly unreachable while the others are fine.
IPVERSE_MIRROR="https://cdn.jsdelivr.net/gh/ipverse/rir-ip@master/country"
GEOIP_URL="https://api.ip.sb/geoip"
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

# --max-time is a budget for the whole transfer, not for the connection, so one
# value cannot serve both a 3KB docs page and 750KB of range data: 10s is
# generous for the former and too tight for the latter on a slow link. Fail fast
# on an unreachable host, but stay patient with one that is merely slow.
HTTP_CONNECT_TIMEOUT=10
HTTP_MAX_TIME=90         # bulk range data, ~750KB
HTTP_MAX_TIME_SMALL=20   # trace and geoip, a few hundred bytes each
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/openai-checker"
CACHE_TTL=86400          # 24h
USE_CACHE=1

TAB=$'\t'

# Fallback only. The live list is authoritative; this is a snapshot taken when
# this script was last updated, used when the network fetch fails.
SNAPSHOT_CODES="AF AL DZ AD AO AG AR AM AU AT AZ BS BH BD BB BE BZ BJ BT BO BA
BW BR BN BG BF BI CV KH CM CA CF TD CL CO KM CG CD CR CI HR CY CZ DK DJ DM DO
EC EG SV GQ ER EE SZ ET FJ FI FR GA GM GE DE GH GR GD GT GN GW GY HT VA HN HU
IS IN ID IQ IE IL IT JM JP JO KZ KE KI KW KG LA LV LB LS LR LY LI LT LU MG MW
MY MV ML MT MH MR MU MX FM MD MC MN ME MA MZ MM NA NR NP NL NZ NI NE NG MK NO
OM PK PW PS PA PG PY PE PH PL PT QA RO RW KN LC VC WS SM ST SA SN RS SC SL SG
SK SI SB SO ZA KR SS ES LK SR SE CH SD TW TJ TZ TH TL TG TO TT TN TR TM TV UG
UA AE GB US UY UZ VU VN YE ZM ZW"

# --------------------------------------------------------------- globals ----

SUPPORTED_MAP=""         # "<CODE><TAB><official name>" per line
SUPPORTED_CODES=""       # ISO 3166-1 alpha-2 codes, one per line
SUPPORTED_COUNT=0
LIST_MODE="snapshot"
UNMAPPED=""
EXIT_CODE=0
ANY_FAMILY=0
DEBUG=0

# ---------------------------------------------------------------- output ----

setup_colors() {
    if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]; then
        RED=$'\033[0;31m';   GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
        BLUE=$'\033[0;36m';  DIM=$'\033[2m';      BOLD=$'\033[1m'
        PLAIN=$'\033[0m'
    else
        RED=''; GREEN=''; YELLOW=''; BLUE=''; DIM=''; BOLD=''; PLAIN=''
    fi
}

info() { printf '%s%s%s\n' "$BLUE"   "$*" "$PLAIN"; }
warn() { printf '%s%s%s\n' "$YELLOW" "$*" "$PLAIN"; }
bad()  { printf '%s%s%s\n' "$RED"    "$*" "$PLAIN"; }
dim()  { printf '%s%s%s\n' "$DIM"    "$*" "$PLAIN"; }
rule() { dim "────────────────────────────────────────────────────────────"; }

# Two-column row: fixed-width label, then value (which may contain colours).
row() { printf '  %s%-13s%s %s\n' "$DIM" "$1" "$PLAIN" "$2"; }

die() { bad "$*" >&2; exit 1; }

# Diagnostics go to stderr so they never contaminate the paths and values that
# callers read from stdout. Always returns 0 — this must not steer control flow.
dbg() { [ "${DEBUG:-0}" -eq 1 ] && printf '[debug] %s\n' "$*" >&2; return 0; }

# ----------------------------------------------------------------- cache ----

file_age() {
    local f=$1 mt now
    [ -f "$f" ] || { echo 999999999; return 0; }

    # GNU/BusyBox form first, then BSD/macOS — and validate, don't trust the
    # exit status. GNU stat reads -f as "filesystem status" rather than as a
    # format flag, so `stat -f %m` there does not cleanly fail: it writes an
    # unrelated block starting with `File: "..."` to stdout. Chaining the two
    # with || concatenated both outputs into what was then used as an integer.
    mt=$(stat -c %Y "$f" 2>/dev/null)
    case "$mt" in ''|*[!0-9]*) mt=$(stat -f %m "$f" 2>/dev/null);; esac
    case "$mt" in ''|*[!0-9]*) echo 999999999; return 0;; esac

    now=$(date +%s)
    echo $(( now - mt ))
}

# fetch_cached <url> <cache-key> [mirror-url]
# Prints the path to the downloaded file. Tries the mirror if the primary fails,
# then a stale cache entry, before giving up.
fetch_cached() {
    local url=$1 key=$2 mirror=${3:-} dest tmp u crc

    dest="$CACHE_DIR/$key"

    if [ "$USE_CACHE" -eq 1 ] && [ -f "$dest" ] && \
       [ "$(file_age "$dest")" -lt "$CACHE_TTL" ]; then
        printf '%s\n' "$dest"
        return 0
    fi

    mkdir -p "$CACHE_DIR" 2>/dev/null || true
    tmp="$dest.$$.tmp"

    for u in "$url" "$mirror"; do
        [ -n "$u" ] || continue
        curl -fsSL --connect-timeout "$HTTP_CONNECT_TIMEOUT" \
             --max-time "$HTTP_MAX_TIME" --retry 1 -A "$UA" \
             -o "$tmp" "$u" 2>/dev/null
        crc=$?
        dbg "  curl exit=$crc wrote=$(wc -c < "$tmp" 2>/dev/null || echo 0)B  $u"
        if [ "$crc" -eq 0 ] && [ -s "$tmp" ]; then
            if mv -f "$tmp" "$dest" 2>/dev/null; then
                printf '%s\n' "$dest"
                return 0
            fi
            dbg "  mv failed: $tmp -> $dest"
        fi
    done

    dbg "  all sources failed for $key; free space below:"
    [ "${DEBUG:-0}" -eq 1 ] && df -k "$CACHE_DIR" >&2 2>/dev/null

    rm -f "$tmp" 2>/dev/null || true
    [ -f "$dest" ] && { printf '%s\n' "$dest"; return 0; }   # stale beats nothing
    return 1
}

# ------------------------------------------------------- country name map ----

# ISO 3166-1 alpha-2 code, then every name spelling that maps to it. Keys are
# normalised: lowercased, with each run of non-alphanumeric bytes collapsed to
# a single space (so "Côte d'Ivoire" becomes "c te d ivoire").
#
# This is ISO data, not policy data. It changes on the order of once a decade,
# unlike the list of supported regions, which is fetched live on every run.
CODE_TABLE='
AF|afghanistan
AL|albania
DZ|algeria
AD|andorra
AO|angola
AG|antigua and barbuda
AR|argentina
AM|armenia
AU|australia
AT|austria
AZ|azerbaijan
BS|bahamas|the bahamas
BH|bahrain
BD|bangladesh
BB|barbados
BE|belgium
BZ|belize
BJ|benin
BT|bhutan
BO|bolivia
BA|bosnia and herzegovina
BW|botswana
BR|brazil
BN|brunei|brunei darussalam
BG|bulgaria
BF|burkina faso
BI|burundi
CV|cabo verde|cape verde
KH|cambodia
CM|cameroon
CA|canada
CF|central african republic
TD|chad
CL|chile
CO|colombia
KM|comoros
CG|congo brazzaville|republic of the congo
CD|congo drc|congo kinshasa|democratic republic of the congo
CR|costa rica
CI|c te d ivoire|cote d ivoire|cote divoire|ivory coast
HR|croatia
CY|cyprus
CZ|czechia czech republic|czechia|czech republic
DK|denmark
DJ|djibouti
DM|dominica
DO|dominican republic
EC|ecuador
EG|egypt
SV|el salvador
GQ|equatorial guinea
ER|eritrea
EE|estonia
SZ|eswatini swaziland|eswatini|swaziland
ET|ethiopia
FJ|fiji
FI|finland
FR|france
GA|gabon
GM|gambia|the gambia
GE|georgia
DE|germany
GH|ghana
GR|greece
GD|grenada
GT|guatemala
GN|guinea
GW|guinea bissau
GY|guyana
HT|haiti
VA|holy see vatican city|holy see|vatican city|vatican
HN|honduras
HU|hungary
IS|iceland
IN|india
ID|indonesia
IQ|iraq
IE|ireland
IL|israel
IT|italy
JM|jamaica
JP|japan
JO|jordan
KZ|kazakhstan
KE|kenya
KI|kiribati
KW|kuwait
KG|kyrgyzstan
LA|laos|lao people s democratic republic
LV|latvia
LB|lebanon
LS|lesotho
LR|liberia
LY|libya
LI|liechtenstein
LT|lithuania
LU|luxembourg
MG|madagascar
MW|malawi
MY|malaysia
MV|maldives
ML|mali
MT|malta
MH|marshall islands
MR|mauritania
MU|mauritius
MX|mexico
FM|micronesia|federated states of micronesia
MD|moldova|republic of moldova
MC|monaco
MN|mongolia
ME|montenegro
MA|morocco
MZ|mozambique
MM|myanmar|burma
NA|namibia
NR|nauru
NP|nepal
NL|netherlands|the netherlands
NZ|new zealand
NI|nicaragua
NE|niger
NG|nigeria
MK|north macedonia|macedonia
NO|norway
OM|oman
PK|pakistan
PW|palau
PS|palestine|state of palestine
PA|panama
PG|papua new guinea
PY|paraguay
PE|peru
PH|philippines|the philippines
PL|poland
PT|portugal
QA|qatar
RO|romania
RW|rwanda
KN|saint kitts and nevis|st kitts and nevis
LC|saint lucia|st lucia
VC|saint vincent and the grenadines|st vincent and the grenadines
WS|samoa
SM|san marino
ST|sao tome and principe
SA|saudi arabia
SN|senegal
RS|serbia
SC|seychelles
SL|sierra leone
SG|singapore
SK|slovakia
SI|slovenia
SB|solomon islands
SO|somalia
ZA|south africa
KR|south korea|korea republic of|republic of korea
SS|south sudan
ES|spain
LK|sri lanka
SD|sudan
SR|suriname
SE|sweden
CH|switzerland
TW|taiwan
TJ|tajikistan
TZ|tanzania|united republic of tanzania
TH|thailand
TL|timor leste east timor|timor leste|east timor
TG|togo
TO|tonga
TT|trinidad and tobago
TN|tunisia
TR|turkey|turkiye|t rkiye
TM|turkmenistan
TV|tuvalu
UG|uganda
UA|ukraine with certain exceptions|ukraine
AE|united arab emirates
GB|united kingdom|united kingdom of great britain and northern ireland
US|united states of america|united states|usa
UY|uruguay
UZ|uzbekistan
VU|vanuatu
VN|vietnam|viet nam
YE|yemen
ZM|zambia
ZW|zimbabwe
'

# Reads country names on stdin, writes "<CODE><TAB><name>" per line.
# Names that cannot be mapped get "?" as the code so the caller can report
# them instead of silently dropping a region.
#
# A name is looked up whole first — the parenthetical is what distinguishes
# "Congo (Brazzaville)" from "Congo (DRC)" — then again with it removed, which
# absorbs new qualifiers like "Czechia (Czech Republic)".
map_names() {
    # Passed through the environment rather than -v: awk's -v assignment
    # rejects embedded newlines on BSD/BWK awk (macOS).
    CODE_TABLE="$CODE_TABLE" LC_ALL=C awk '
        function norm(s) {
            s = tolower(s)
            gsub(/[^a-z0-9]+/, " ", s)
            gsub(/^ +| +$/, "", s)
            return s
        }
        BEGIN {
            n = split(ENVIRON["CODE_TABLE"], rows, "\n")
            for (i = 1; i <= n; i++) {
                if (rows[i] == "") continue
                m = split(rows[i], f, "|")
                for (j = 2; j <= m; j++) MAP[f[j]] = f[1]
            }
        }
        {
            if ($0 == "") next
            k = norm($0)
            if (k in MAP) { print MAP[k] "\t" $0; next }
            bare = $0
            gsub(/\([^)]*\)/, "", bare)
            k = norm(bare)
            if (k in MAP) { print MAP[k] "\t" $0; next }
            print "?\t" $0
        }
    '
}

# -------------------------------------------------- supported-region list ----

load_supported() {
    local f names mapped="" count=0

    if f=$(fetch_cached "$OPENAI_DOCS_URL" "supported-countries.md"); then
        names=$(sed -n -E 's/^[[:space:]]*[-*][[:space:]]+//p' "$f" 2>/dev/null \
                | sed -E 's/[[:space:]]+$//')
        if [ -n "$names" ]; then
            mapped=$(printf '%s\n' "$names" | map_names)
            count=$(printf '%s\n' "$mapped" | grep -c "^[A-Z][A-Z]$TAB") || count=0
        fi
    fi

    # Sanity gate: if the docs page moves or its structure changes we would
    # parse a handful of stray bullets and report almost everything as
    # unsupported. Treat a suspiciously short list as a failed fetch.
    if [ "$count" -ge 100 ]; then
        LIST_MODE="live"
        SUPPORTED_MAP=$(printf '%s\n' "$mapped" | grep "^[A-Z][A-Z]$TAB")
        UNMAPPED=$(printf '%s\n' "$mapped" | sed -n "s/^?$TAB//p")
    else
        LIST_MODE="snapshot"
        # shellcheck disable=SC2086  # unquoted on purpose: split the snapshot
        # blob on whitespace into one code per line.
        SUPPORTED_MAP=$(printf '%s\n' $SNAPSHOT_CODES | grep -E '^[A-Z]{2}$')
        UNMAPPED=""
    fi

    SUPPORTED_CODES=$(printf '%s\n' "$SUPPORTED_MAP" | cut -f1 | sort -u)
    SUPPORTED_COUNT=$(printf '%s\n' "$SUPPORTED_CODES" | grep -c '^[A-Z][A-Z]$') || SUPPORTED_COUNT=0
}

# Here-strings rather than pipes throughout: grep -q and awk's exit both stop
# reading early, which under pipefail would turn a hit into a failed pipeline.
is_supported() {
    [ -n "$1" ] || return 1
    grep -qx "$1" <<<"$SUPPORTED_CODES"
}

# code2name <ISO2> -> the official name OpenAI publishes for that code.
code2name() {
    LC_ALL=C awk -F"$TAB" -v c="$1" \
        'NF > 1 && $1 == c { print $2; exit }' <<<"$SUPPORTED_MAP"
}

# ------------------------------------------------------------ CIDR checks ----

# ip_in_country <ip> <ISO2> <4|6>
#   0 = inside the country's registered ranges
#   1 = outside
#   2 = range data unavailable
# awk reads the file directly rather than being fed through a pipe: it exits as
# soon as it finds a match, which would SIGPIPE the writer and — under
# pipefail — mask the result as a pipeline failure.
ip_in_country() {
    local ip=$1 cc=$2 fam=$3 lc f rc

    # Ranges rather than the [:upper:]/[:lower:] classes: every tr supports
    # ranges, not every tr supports the classes. ISO 3166-1 codes are ASCII, so
    # the accent handling those classes would add is not needed here.
    # shellcheck disable=SC2018,SC2019
    lc=$(printf '%s' "$cc" | LC_ALL=C tr 'A-Z' 'a-z')
    dbg "ip_in_country: cc=$cc lc=$lc fam=$fam"
    case "$lc" in
        [a-z][a-z]) ;;
        *) dbg "  lowercase conversion produced [$lc], expected two letters"
           return 2;;
    esac

    if ! f=$(fetch_cached "$IPVERSE_BASE/$lc/aggregated.json" "cidr-$lc.json" \
                          "$IPVERSE_MIRROR/$lc/aggregated.json"); then
        dbg "  fetch failed: $IPVERSE_BASE/$lc/aggregated.json"
        return 2
    fi
    dbg "  data file: $f ($(wc -c < "$f" 2>/dev/null) bytes)"

    if [ "$fam" = "4" ]; then
        # [.] and [/] rather than \. and \/ — a bracket expression means the
        # literal character in every awk, while the handling of a backslash
        # before an ordinary character inside a regex literal is not portable.
        LC_ALL=C awk -v TARGET="$ip" '
            BEGIN {
                split(TARGET, t, ".")
                tv = ((t[1] * 256 + t[2]) * 256 + t[3]) * 256 + t[4]
            }
            {
                s = $0
                while (match(s, "[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+/[0-9]+")) {
                    tok = substr(s, RSTART, RLENGTH)
                    s   = substr(s, RSTART + RLENGTH)
                    seen = 1
                    split(tok, p, "/")
                    split(p[1], a, ".")
                    base = ((a[1] * 256 + a[2]) * 256 + a[3]) * 256 + a[4]
                    if (tv >= base && tv < base + 2 ^ (32 - p[2])) { found = 1; exit }
                }
            }
            END { exit(found ? 0 : (seen ? 1 : 2)) }
        ' "$f"
        rc=$?
        dbg "  ipv4 matcher rc=$rc (0=inside 1=outside 2=no prefixes parsed)"
        [ "$DEBUG" -eq 1 ] && dbg "  prefixes awk could parse: $(LC_ALL=C awk '
            { s = $0
              while (match(s, "[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+/[0-9]+")) {
                  n++; s = substr(s, RSTART + RLENGTH) } }
            END { print n + 0 }' "$f")"
        return $rc
    fi

    LC_ALL=C awk -v TARGET="$ip" '
        function pad(g) { while (length(g) < 4) g = "0" g; return g }
        # Expand any IPv6 form to exactly 32 hex digits.
        function expand(s,   k, L, R, nl, nr, i, n, out) {
            s = tolower(s)
            k = index(s, "::")
            out = ""
            if (k > 0) {
                L = substr(s, 1, k - 1); R = substr(s, k + 2)
                nl = (L == "") ? 0 : split(L, GL, ":")
                nr = (R == "") ? 0 : split(R, GR, ":")
                for (i = 1; i <= nl; i++)          out = out pad(GL[i])
                for (i = 1; i <= 8 - nl - nr; i++) out = out "0000"
                for (i = 1; i <= nr; i++)          out = out pad(GR[i])
            } else {
                n = split(s, G, ":")
                for (i = 1; i <= n; i++)           out = out pad(G[i])
            }
            return out
        }
        # 128-bit prefix comparison done on a bit string, since awk has no
        # integer type wide enough to hold an IPv6 address.
        function bits(s,   e, i, b) {
            e = expand(s); b = ""
            for (i = 1; i <= 32; i++) b = b H[substr(e, i, 1)]
            return b
        }
        BEGIN {
            H["0"]="0000"; H["1"]="0001"; H["2"]="0010"; H["3"]="0011"
            H["4"]="0100"; H["5"]="0101"; H["6"]="0110"; H["7"]="0111"
            H["8"]="1000"; H["9"]="1001"; H["a"]="1010"; H["b"]="1011"
            H["c"]="1100"; H["d"]="1101"; H["e"]="1110"; H["f"]="1111"
            tb = bits(TARGET)
        }
        {
            s = $0
            while (match(s, "[0-9a-fA-F:]+/[0-9]+")) {
                tok = substr(s, RSTART, RLENGTH)
                s   = substr(s, RSTART + RLENGTH)
                if (index(tok, ":") == 0) continue     # an IPv4 prefix or a bare number
                seen = 1
                split(tok, p, "/")
                n = p[2] + 0
                if (substr(bits(p[1]), 1, n) == substr(tb, 1, n)) { found = 1; exit }
            }
        }
        END { exit(found ? 0 : (seen ? 1 : 2)) }
    ' "$f"
    rc=$?
    dbg "  ipv6 matcher rc=$rc (0=inside 1=outside 2=no prefixes parsed)"
    return $rc
}

# -------------------------------------------------------- IP / geo lookup ----

# Pull one "key":"value" pair out of a JSON blob. Matches on the key, unlike
# counting quote-delimited fields, so it survives the provider reordering keys.
json_str() {
    LC_ALL=C awk -v k="$2" '
        BEGIN { pat = "\"" k "\"[ \t]*:[ \t]*\"" }
        match($0, pat) {
            rest = substr($0, RSTART + RLENGTH)
            q = index(rest, "\"")
            print (q > 0 ? substr(rest, 1, q - 1) : rest)
            exit
        }' <<<"$1"
}

# trace <4|6> -> "<ip><TAB><loc>" from a single request to OpenAI's edge.
trace() {
    local fam=$1 host out ip loc
    for host in $TRACE_HOSTS; do
        out=$(curl -fsS "-$fam" --connect-timeout "$HTTP_CONNECT_TIMEOUT" \
                   --max-time "$HTTP_MAX_TIME_SMALL" \
                   "https://$host/cdn-cgi/trace" 2>/dev/null) || continue
        ip=$(LC_ALL=C awk -F= '$1 == "ip"  { print $2; exit }' <<<"$out")
        loc=$(LC_ALL=C awk -F= '$1 == "loc" { print $2; exit }' <<<"$out")
        if [ -n "$ip" ]; then printf '%s\t%s' "$ip" "$loc"; return 0; fi
    done
    return 1
}

# geoip <ip> <4|6> -> "<org><TAB><country code>" from an independent provider.
geoip() {
    local ip=$1 fam=$2 json org cc
    json=$(curl -fsS "-$fam" --connect-timeout "$HTTP_CONNECT_TIMEOUT" \
                --max-time "$HTTP_MAX_TIME_SMALL" -A "$UA" \
                "$GEOIP_URL/$ip" 2>/dev/null) || json=""
    [ -n "$json" ] || return 1
    org=$(json_str "$json" organization)
    [ -n "$org" ] || org=$(json_str "$json" isp)
    [ -n "$org" ] || org=$(json_str "$json" asn_organization)
    cc=$(json_str "$json" country_code)
    printf '%s\t%s' "$org" "$cc"
}

is_real_ipv6() {
    case "$1" in
        ::ffff:*|::[0-9]*.[0-9]*) return 1;;   # IPv4-mapped / IPv4-compatible
        *:*) return 0;;
        *)   return 1;;
    esac
}

# ------------------------------------------------------------- per-family ----

check_family() {
    local fam=$1 label=$2
    local t ip loc g org geo_cc name cidr_rc disagree=0

    printf '\n%s[%s]%s\n' "$BOLD" "$label" "$PLAIN"

    if ! t=$(trace "$fam"); then
        dim "  no $label route to OpenAI's edge — skipped"
        return 0
    fi

    ip=${t%%"$TAB"*}
    loc=${t##*"$TAB"}

    if [ "$fam" = "6" ] && ! is_real_ipv6 "$ip"; then
        dim "  no native $label — the edge saw $ip (v4 tunnel or proxy); skipped"
        return 0
    fi

    ANY_FAMILY=1

    org=""; geo_cc=""
    if g=$(geoip "$ip" "$fam"); then
        org=${g%%"$TAB"*}
        geo_cc=${g##*"$TAB"}
    fi

    if [ -n "$org" ]; then
        row "IP" "$ip  $DIM($org)$PLAIN"
    else
        row "IP" "$ip"
    fi

    if [ -z "$loc" ]; then
        row "Edge geo" "${YELLOW}unknown$PLAIN  ${DIM}Cloudflare returned no location$PLAIN"
        row "Verdict" "${YELLOW}UNDETERMINED$PLAIN"
        EXIT_CODE=2
        return 0
    fi

    name=$(code2name "$loc")
    if [ -n "$name" ]; then
        row "Edge geo" "$loc  $DIM$name$PLAIN"
    else
        row "Edge geo" "$loc"
    fi

    # Second opinion on the country, from a provider unrelated to Cloudflare.
    if [ -n "$geo_cc" ]; then
        if [ "$geo_cc" = "$loc" ]; then
            row "Registry geo" "$geo_cc  ${DIM}agrees$PLAIN"
        else
            row "Registry geo" "${YELLOW}$geo_cc  disagrees with the edge$PLAIN"
            disagree=1
        fi
    fi

    # Third opinion: is the IP actually inside that country's allocated ranges?
    ip_in_country "$ip" "$loc" "$fam"; cidr_rc=$?
    case $cidr_rc in
        0) row "IP range" "${DIM}inside $loc's registered ranges$PLAIN";;
        1) row "IP range" "${YELLOW}outside $loc's registered ranges$PLAIN"; disagree=1;;
        *) row "IP range" "${DIM}range data unavailable$PLAIN";;
    esac

    if is_supported "$loc"; then
        row "Verdict" "${GREEN}SUPPORTED$PLAIN  ${DIM}$loc is on OpenAI's list$PLAIN"
    else
        row "Verdict" "${RED}NOT SUPPORTED$PLAIN  ${DIM}$loc is not on OpenAI's list$PLAIN"
        EXIT_CODE=1
    fi

    [ "$disagree" -eq 1 ] && \
        row "" "${YELLOW}sources disagree on the region — likely a VPN, relay or anycast IP$PLAIN"

    return 0
}

# ------------------------------------------------------------------ usage ----

usage() {
    cat <<'USAGE'
OpenAI Access Checker

  Checks whether your IP is in a country or territory that OpenAI serves,
  using OpenAI's own published list and RIR IP-range data, both fetched live.

Usage: openai.sh [options]

  --no-cache      ignore the local cache and refetch everything
  --debug         trace each lookup on stderr
  -h, --help      show this help
  -V, --version   show version

Exit status: 0 supported, 1 not supported, 2 undetermined.
USAGE
}

# ------------------------------------------------------------------- main ----

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --no-cache)   USE_CACHE=0;;
            --debug)      DEBUG=1;;
            -h|--help)    setup_colors; usage; exit 0;;
            -V|--version) echo "openai-checker $VERSION"; exit 0;;
            *) setup_colors; die "unknown option: $1  (try --help)";;
        esac
        shift
    done

    setup_colors
    command -v curl >/dev/null 2>&1 || die "curl is required but not installed."
    command -v awk  >/dev/null 2>&1 || die "awk is required but not installed."

    info "OpenAI Access Checker $VERSION"
    dim  "https://github.com/liandu2024/OpenAI-Checker"
    rule

    load_supported
    if [ "$LIST_MODE" = "live" ]; then
        row "Region list" "$SUPPORTED_COUNT regions  ${DIM}live from developers.openai.com$PLAIN"
    else
        row "Region list" "${YELLOW}$SUPPORTED_COUNT regions  built-in snapshot, live fetch failed$PLAIN"
    fi
    if [ -n "$UNMAPPED" ]; then
        printf '%s\n' "$UNMAPPED" | while IFS= read -r line; do
            [ -n "$line" ] && warn "  note: unrecognised region name \"$line\" — treated as unsupported"
        done
    fi

    check_family 4 IPv4
    check_family 6 IPv6

    if [ "$ANY_FAMILY" -eq 0 ]; then
        printf '\n'
        bad "Could not reach OpenAI's edge over IPv4 or IPv6."
        EXIT_CODE=2
    fi

    printf '\n'
    rule
    dim "This checks your IP's region only. Whether an account actually works"
    dim "also depends on its signup country, phone number and payment method."

    exit $EXIT_CODE
}

main "$@"
