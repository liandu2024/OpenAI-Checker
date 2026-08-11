#!/usr/bin/env bash
#
# Verification suite for openai.sh.
#
# Most of what this checks is upstream data that can change without warning:
# OpenAI adding a country, renaming one, or restructuring its docs page. Run it
# on a schedule — a failure here usually means the world moved, not that the
# script regressed.
#
# Usage: bash verify.sh [/path/to/repo]

REPO=${1:-$(cd "$(dirname "$0")" && pwd)}
SH="$REPO/openai.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    G=$'\033[0;32m'; R=$'\033[0;31m'; Y=$'\033[0;33m'; B=$'\033[1m'; P=$'\033[0m'
else
    G=''; R=''; Y=''; B=''; P=''
fi

ok()    { PASS=$((PASS+1)); printf '  %sPASS%s %s\n' "$G" "$P" "$1"; }
no()    { FAIL=$((FAIL+1)); printf '  %sFAIL%s %s\n' "$R" "$P" "$1"; }
chk()   { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got [$2] want [$3])"; fi; }
note()  { printf '  %s→ %s%s\n' "$Y" "$1" "$P"; }
head_() { printf '\n%s== %s ==%s\n' "$B" "$1" "$P"; }

[ -f "$SH" ] || { echo "not found: $SH"; exit 1; }

# Load the script's functions without running main().
sed 's/^main "\$@"$/:/' "$SH" > "$WORK/lib.sh"

# ---------------------------------------------------------------------------
head_ "1. Syntax and portability"
# ---------------------------------------------------------------------------
if bash -n "$SH" 2>/dev/null; then ok "bash -n"; else no "bash -n"; fi

if grep -qE 'declare -A|mapfile|readarray|\$\{[A-Za-z_]+,,|\$\{[A-Za-z_]+\^\^' "$SH"; then
    no "bash 3.2 compatible (found declare -A / mapfile / \${x,,})"
else
    ok "bash 3.2 compatible"
fi
note "running on $(bash --version | head -1)"

# ---------------------------------------------------------------------------
head_ "2. OpenAI's published list is reachable and parses"
# ---------------------------------------------------------------------------
URL=$(grep '^OPENAI_DOCS_URL=' "$SH" | cut -d'"' -f2)
note "source: $URL"

curl -fsSL --max-time 25 "$URL" > "$WORK/docs.md" 2>/dev/null
LIVE=$(grep -c '^- ' "$WORK/docs.md" 2>/dev/null || echo 0)
if [ "${LIVE:-0}" -ge 100 ]; then
    ok "docs page reachable, $LIVE regions listed"
else
    no "docs page unreachable or restructured (parsed $LIVE entries)"
fi

STATE=$(bash -c "source '$WORK/lib.sh' >/dev/null 2>&1; load_supported; echo \"\$LIST_MODE \$SUPPORTED_COUNT\"")
chk "loads in live mode" "${STATE% *}" "live"
chk "parsed count matches the docs page" "${STATE#* }" "$LIVE"

# ---------------------------------------------------------------------------
head_ "3. Every published region name maps to an ISO code"
# ---------------------------------------------------------------------------
# The likeliest way this script silently breaks: OpenAI adds a country whose
# name is not in CODE_TABLE, and it gets reported as unsupported.
sed 's/^- //' < "$WORK/docs.md" > /dev/null 2>&1
grep '^- ' "$WORK/docs.md" | sed 's/^- //' > "$WORK/names.txt"
MAPPED=$(bash -c "source '$WORK/lib.sh' >/dev/null 2>&1; map_names < '$WORK/names.txt'")
UNM=$(printf '%s\n' "$MAPPED" | grep -c '^?')
DUP=$(printf '%s\n' "$MAPPED" | cut -f1 | sort | uniq -d | grep -c .)

chk "no unmapped region names" "$UNM" "0"
chk "no two regions sharing a code" "$DUP" "0"
if [ "$UNM" != "0" ]; then
    printf '%s\n' "$MAPPED" | grep '^?' | sed 's/^?\t/    unmapped: /'
    note "add these to CODE_TABLE in openai.sh"
fi

# ---------------------------------------------------------------------------
head_ "4. The built-in fallback snapshot has not drifted"
# ---------------------------------------------------------------------------
SNAP=$(bash -c "source '$WORK/lib.sh' >/dev/null 2>&1
                printf '%s\n' \$SNAPSHOT_CODES | grep -E '^[A-Z]{2}$' | sort -u")
LIVEC=$(printf '%s\n' "$MAPPED" | grep '^[A-Z][A-Z]' | cut -f1 | sort -u)
ADDED=$(comm -23 <(printf '%s\n' "$LIVEC") <(printf '%s\n' "$SNAP") | tr '\n' ' ')
GONE=$(comm -13 <(printf '%s\n' "$LIVEC") <(printf '%s\n' "$SNAP") | tr '\n' ' ')

if [ -z "$ADDED$GONE" ]; then
    ok "snapshot matches the live list"
else
    no "snapshot has drifted — update SNAPSHOT_CODES in openai.sh"
    [ -n "$ADDED" ] && note "live has, snapshot missing: $ADDED"
    [ -n "$GONE" ]  && note "snapshot has, live dropped:  $GONE"
fi

# ---------------------------------------------------------------------------
head_ "5. CIDR matching (synthetic data, known answers)"
# ---------------------------------------------------------------------------
cat > "$WORK/cidr-xx.json" <<'J'
{"prefixes":{"ipv4":[ "10.0.0.0/8", "192.168.1.0/24", "203.0.113.128/25", "8.8.8.0/24" ],"ipv6":[]},"asn":53}
J
cat > "$WORK/cidr-yy.json" <<'J'
{"prefixes":{"ipv4":[],"ipv6":[ "2001:db8::/32", "2400:cb00::/32", "fe80::/10" ]},"asn":7}
J

RES=$(bash -c "
source '$WORK/lib.sh' >/dev/null 2>&1
CACHE_DIR='$WORK'; CACHE_TTL=999999999; USE_CACHE=1
for a in \
  '10.0.0.0 XX 4 0'        '10.255.255.255 XX 4 0'  '11.0.0.0 XX 4 1' \
  '9.255.255.255 XX 4 1'   '192.168.1.0 XX 4 0'     '192.168.1.255 XX 4 0' \
  '192.168.2.0 XX 4 1'     '203.0.113.127 XX 4 1'   '203.0.113.128 XX 4 0' \
  '203.0.113.255 XX 4 0'   '255.255.255.255 XX 4 1' '8.8.8.8 XX 4 0' \
  '2001:db8::1 YY 6 0'     '2001:db9::1 YY 6 1' \
  '2001:0db8:0000:0000:0000:0000:0000:0001 YY 6 0' \
  '2001:db8:ffff:ffff:ffff:ffff:ffff:ffff YY 6 0' \
  '2400:cb00:2049:1::a29f:1804 YY 6 0' \
  'fe7f:ffff::1 YY 6 1'    'fe80::1 YY 6 0'         'febf:ffff::1 YY 6 0' \
  'fec0::1 YY 6 1'         '::1 YY 6 1'             '1.2.3.4 QQ 4 2' ; do
  set -- \$a
  ip_in_country \"\$1\" \"\$2\" \"\$3\"; g=\$?
  [ \"\$g\" = \"\$4\" ] && echo \"ok\" || echo \"FAIL \$1 vs \$2 got=\$g want=\$4\"
done")
printf '%s\n' "$RES" | grep '^FAIL' | sed 's/^/    /'
chk "boundary cases" "$(printf '%s\n' "$RES" | grep -c '^FAIL')" "0"
note "$(printf '%s\n' "$RES" | grep -c '^ok') cases: /25 edges, the four fe80::/10 boundaries, compressed vs full IPv6"

# ---------------------------------------------------------------------------
head_ "6. RIR range data is reachable (the third signal)"
# ---------------------------------------------------------------------------
RIR=$(bash -c "source '$WORK/lib.sh' >/dev/null 2>&1
               ip_in_country 8.8.8.8 US 4; echo \$?")
case "$RIR" in
    0) ok "8.8.8.8 resolves inside US ranges" ;;
    1) no "8.8.8.8 reported outside US ranges — data source may have changed" ;;
    *) no "RIR range data unreachable (raw.githubusercontent.com blocked?)" ;;
esac

CN=$(bash -c "source '$WORK/lib.sh' >/dev/null 2>&1
              ip_in_country 223.5.5.5 US 4; echo \$?")
if [ "$CN" = "1" ]; then
    ok "223.5.5.5 (CN) correctly excluded from US"
else
    note "negative case inconclusive (rc=$CN)"
fi

# ---------------------------------------------------------------------------
head_ "7. Verdicts"
# ---------------------------------------------------------------------------
SUPP=$(bash -c "
source '$WORK/lib.sh' >/dev/null 2>&1; load_supported
for c in CN RU HK IR KP; do is_supported \$c && echo \"\$c=yes\" || echo \"\$c=no\"; done
for c in US GB JP VN EG SA UZ TW; do is_supported \$c && echo \"\$c=yes\" || echo \"\$c=no\"; done")
chk "CN/RU/HK/IR/KP unsupported" "$(printf '%s\n' "$SUPP" | grep -cE '^(CN|RU|HK|IR|KP)=yes')" "0"
chk "US/GB/JP/VN/EG/SA/UZ/TW supported" "$(printf '%s\n' "$SUPP" | grep -cE '^(US|GB|JP|VN|EG|SA|UZ|TW)=no')" "0"

# ---------------------------------------------------------------------------
head_ "8. Fallback when the docs page is unreachable"
# ---------------------------------------------------------------------------
FB=$(bash -c "
source '$WORK/lib.sh' >/dev/null 2>&1
OPENAI_DOCS_URL='https://developers.openai.com/api/docs/no-such-page-xyz.md'
CACHE_DIR='$WORK/empty'; load_supported
echo \"\$LIST_MODE \$SUPPORTED_COUNT\"")
chk "falls back to the snapshot" "${FB% *}" "snapshot"
chk "and is labelled as such, not silent" "${FB#* }" "$LIVE"

# ---------------------------------------------------------------------------
head_ "9. Exit codes, colour, and self-consistency"
# ---------------------------------------------------------------------------
bash "$SH" >/dev/null 2>&1;        chk "normal run"      "$?" "0"
bash "$SH" --bogus >/dev/null 2>&1; chk "bad option"      "$?" "1"
chk "no ANSI when piped" "$(bash "$SH" 2>/dev/null | grep -c $'\033')" "0"

# The install one-liner must point at this repo, not at whatever it was forked
# from — otherwise users run a different script than the one being tested here.
SLUG=$(grep -oE 'github\.com/[A-Za-z0-9_.-]+/OpenAI-Checker' "$SH" | head -1 | cut -d/ -f2-)
CDN=$(grep -oE 'cdn\.jsdelivr\.net/gh/[A-Za-z0-9_.-]+/OpenAI-Checker' "$REPO/README.md" | head -1 | cut -d/ -f3-)
chk "README install URL matches the script's own repo" "$CDN" "$SLUG"

# ---------------------------------------------------------------------------
head_ "10. Caching, and a clean stderr on a warm cache"
# ---------------------------------------------------------------------------
# Regression guard. `stat` differs between GNU and BSD, and a wrong probe there
# fails in a way that keeps the exit status at 0 while writing errors to stderr
# and silently disabling the cache — invisible to any check that only looks at
# exit codes, and invisible on a cold cache, since the age of a file that does
# not exist is never computed.
CACHEROOT="$WORK/xdg"
rm -rf "$CACHEROOT"
XDG_CACHE_HOME="$CACHEROOT" bash "$SH" >/dev/null 2>&1        # populate
CACHED="$CACHEROOT/openai-checker/supported-countries.md"

if [ -f "$CACHED" ]; then
    ok "cache populated on the first run"

    MARK="$WORK/mark"; : > "$MARK"
    ERR=$(XDG_CACHE_HOME="$CACHEROOT" bash "$SH" 2>&1 >/dev/null)
    chk "second run writes nothing to stderr" "$ERR" ""

    if [ -n "$(find "$CACHED" -newer "$MARK" 2>/dev/null)" ]; then
        no "cache not honoured — the second run refetched"
    else
        ok "cache honoured on the second run"
    fi
else
    no "cache was never populated ($CACHED absent)"
fi

# ---------------------------------------------------------------------------
printf '\n%s────────────────────────────────────────%s\n' "$B" "$P"
printf '  %sPASS %s%s    %sFAIL %s%s\n' "$G" "$PASS" "$P" "$R" "$FAIL" "$P"
if [ "$FAIL" -eq 0 ]; then
    printf '  %sall good%s\n' "$G" "$P"
    exit 0
fi
printf '  %ssee failures above%s\n' "$R" "$P"
exit 1
