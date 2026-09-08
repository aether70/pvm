#!/usr/bin/env bash
# config.sh - dependency-free config.json reader for the Unix tree.
#
# Why this exists: config.json is the single source of truth shared with the
# PowerShell tree, but we cannot assume `jq` (or python3) is installed on an
# arbitrary host. This flattens JSON to "dotted.path<TAB>value" lines using only
# awk, which is guaranteed present on Linux and macOS.
#
# Supported: nested objects, strings, numbers, booleans, null. Arrays are
# flattened to path.<index> but the shipped config deliberately avoids them
# (lists are comma-separated strings) to keep this parser small.

# shellcheck disable=SC2016
_PVM_JSON_AWK='
function emitval(v) {
    if (nkeys <= 0) return
    p = keys[1]
    for (j = 2; j <= nkeys; j++) p = p "." keys[j]
    print p "\t" v
}
function popkey() { if (nkeys > 0) nkeys-- }
{ all = all $0 "\n" }
END {
    n = length(all); i = 1; nkeys = 0; depth = 0
    while (i <= n) {
        c = substr(all, i, 1)

        if (c == "\"") {
            i++; s = ""
            while (i <= n) {
                c2 = substr(all, i, 1)
                if (c2 == "\\") {
                    e = substr(all, i + 1, 1)
                    if (e == "n") s = s "\n"
                    else if (e == "t") s = s "\t"
                    else s = s e
                    i += 2; continue
                }
                if (c2 == "\"") { i++; break }
                s = s c2; i++
            }
            j = i
            while (j <= n && substr(all, j, 1) ~ /[ \t\r\n]/) j++
            if (substr(all, j, 1) == ":") {
                nkeys++; keys[nkeys] = s; i = j + 1
            } else {
                emitval(s); popkey()
            }
            continue
        }

        if (c == "{" || c == "[") {
            depth++; keymark[depth] = nkeys; isarr[depth] = (c == "["); aidx[depth] = 0
            i++; continue
        }

        if (c == "}" || c == "]") {
            m = keymark[depth] - 1
            nkeys = (m > 0 ? m : 0)
            depth--; i++; continue
        }

        if (c == "," || c == ":" || c ~ /[ \t\r\n]/) { i++; continue }

        # bare scalar: number, true, false, null
        s = ""
        while (i <= n) {
            c2 = substr(all, i, 1)
            if (c2 ~ /[,}\]\t\r\n ]/) break
            s = s c2; i++
        }
        if (s != "") {
            if (depth > 0 && isarr[depth]) {
                nkeys++; keys[nkeys] = aidx[depth]; aidx[depth]++
                emitval(s); popkey()
            } else {
                emitval(s); popkey()
            }
        }
    }
}
'

PVM_CONFIG_DATA=""

# config_load <path-to-config.json>
# Missing or unparseable config is not fatal; every caller supplies a default.
config_load() {
    local file="$1"
    PVM_CONFIG_DATA=""
    [ -f "$file" ] || return 0
    PVM_CONFIG_DATA="$(awk "$_PVM_JSON_AWK" "$file" 2>/dev/null)" || PVM_CONFIG_DATA=""
    return 0
}

# config_get <dotted.path> [default]
config_get() {
    local path="$1" default="${2-}" val
    if [ -n "$PVM_CONFIG_DATA" ]; then
        val="$(printf '%s\n' "$PVM_CONFIG_DATA" \
            | awk -F'\t' -v p="$path" '$1 == p { print $2; found = 1; exit } END { exit !found }')" \
            && { printf '%s' "$val"; return 0; }
    fi
    printf '%s' "$default"
}

# config_get_int <dotted.path> <default>
# Falls back to the default when the value is absent or not a plain integer.
config_get_int() {
    local val
    val="$(config_get "$1" "$2")"
    case "$val" in
        ''|*[!0-9]*) printf '%s' "$2" ;;
        *)           printf '%s' "$val" ;;
    esac
}
