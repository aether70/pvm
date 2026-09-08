#!/usr/bin/env bash
# gui_dialogs.sh - Thin wrappers over zenity (Linux) and osascript (macOS) so
# the graphical front-ends read the same on both platforms.
#
# Sourcing this sets GUI to the toolkit in use, or leaves it empty when neither
# is available; callers decide whether that is fatal or a reason to fall back
# to the terminal.

GUI=""
if command -v zenity >/dev/null 2>&1; then
    GUI="zenity"
elif [ "$(uname -s)" = "Darwin" ] && command -v osascript >/dev/null 2>&1; then
    GUI="osascript"
fi

# ---- Dialog primitives ---------------------------------------------------
# Each wrapper hides the toolkit difference so the flow below reads the same
# regardless of which one is in use.

gui_error() {
    case "$GUI" in
        zenity)   zenity --error --title="Portable VM" --text="$1" 2>/dev/null ;;
        osascript) osascript -e "display alert \"Portable VM\" message \"$(printf '%s' "$1" | sed 's/"/\\"/g')\" as critical" >/dev/null 2>&1 ;;
    esac
}

gui_info() {
    case "$GUI" in
        zenity)    zenity --info --title="Portable VM" --text="$1" 2>/dev/null ;;
        osascript) osascript -e "display alert \"Portable VM\" message \"$(printf '%s' "$1" | sed 's/"/\\"/g')\"" >/dev/null 2>&1 ;;
    esac
}

# gui_confirm <text> -> 0 for yes, 1 for no
gui_confirm() {
    case "$GUI" in
        zenity)
            zenity --question --title="Portable VM" --text="$1" 2>/dev/null ;;
        osascript)
            local answer
            answer="$(osascript -e "button returned of (display dialog \"$(printf '%s' "$1" | sed 's/"/\\"/g')\" buttons {\"Cancel\", \"Continue\"} default button \"Continue\" with title \"Portable VM\")" 2>/dev/null)"
            [ "$answer" = "Continue" ] ;;
    esac
}

# gui_entry <prompt> [default] -> prints the value, returns 1 if cancelled
gui_entry() {
    local prompt="$1" default="${2:-}"
    case "$GUI" in
        zenity)
            zenity --entry --title="Portable VM" --text="$prompt" --entry-text="$default" 2>/dev/null ;;
        osascript)
            osascript -e "text returned of (display dialog \"$(printf '%s' "$prompt" | sed 's/"/\\"/g')\" default answer \"$default\" with title \"Portable VM\")" 2>/dev/null ;;
    esac
}

# gui_choose <prompt> <item>... -> prints the chosen item, returns 1 if cancelled
gui_choose() {
    local prompt="$1"; shift
    case "$GUI" in
        zenity)
            zenity --list --title="Portable VM" --text="$prompt" \
                   --column="Virtual Machines" "$@" 2>/dev/null ;;
        osascript)
            local list="" item
            for item in "$@"; do
                list="$list, \"$(printf '%s' "$item" | sed 's/"/\\"/g')\""
            done
            list="${list#, }"
            local picked
            picked="$(osascript -e "choose from list {$list} with title \"Portable VM\" with prompt \"$(printf '%s' "$prompt" | sed 's/"/\\"/g')\"" 2>/dev/null)"
            # AppleScript returns the literal string "false" when cancelled.
            if [ -z "$picked" ] || [ "$picked" = "false" ]; then
                return 1
            fi
            printf '%s' "$picked" ;;
    esac
}

gui_pick_iso() {
    case "$GUI" in
        zenity)
            zenity --file-selection --title="Select installer ISO" --file-filter="ISO images | *.iso *.img" 2>/dev/null ;;
        osascript)
            osascript -e 'POSIX path of (choose file with prompt "Select installer ISO" of type {"public.iso-image", "iso", "img"})' 2>/dev/null ;;
    esac
}

