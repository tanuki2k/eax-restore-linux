#!/usr/bin/env bash
# PostToolUse hook (Edit|Write): lists player-facing strings an edit added or
# changed, and reminds Claude to run them past the copy-editor agent. Text
# written mid-edit reads like the code around it; this makes the wording a
# separate pass that can't be forgotten. Never blocks: always exits 0.

input="$(cat)"
file="$(jq -r '.tool_input.file_path // empty' <<<"$input")"
[ -n "$file" ] || exit 0

root="$(cd "$(dirname "$0")/../.." && pwd)"
rel="${file#"$root"/}"
case "$rel" in
    src/*.sh|tools/*.sh|tools/*.jq) kind=script ;;
    data/games/*.json) kind=data ;;
    *) exit 0 ;;
esac

# Only the lines this edit added, not every uncommitted change in the file —
# other work in progress would otherwise be listed again on every edit.
case "$(jq -r '.tool_name' <<<"$input")" in
    Edit)
        added="$(diff <(jq -r '.tool_input.old_string' <<<"$input") \
            <(jq -r '.tool_input.new_string' <<<"$input") | sed -n 's/^> //p')" ;;
    Write)
        before="$(git -C "$root" show "HEAD:$rel" 2>/dev/null)"
        added="$(diff <(printf '%s\n' "$before") \
            <(jq -r '.tool_input.content' <<<"$input") | sed -n 's/^> //p')" ;;
    *) exit 0 ;;
esac
[ -n "$added" ] || exit 0

if [ "$kind" == script ]; then
    helpers='print_[a-z_]+|confirm(_countdown)?|prompt|run_with_spinner|echo -e|printf'
    # A helper call with a quoted string, a continuation line of a multi-line
    # print_note/print_paragraph (just a quoted string), or prose of three or
    # more words assigned to a variable to print later.
    words="[A-Za-z']+ [A-Za-z']+ [A-Za-z']+"
    found="$(grep -E "^\s*[^#]*\b($helpers)\b[^\"]*\"|^\s*\"[^\"]*\"\s*\\\\?\s*\$|[A-Za-z_]+=\"[^\"]*$words" <<<"$added" |
        grep -vE '^\s*#|^\s*(local )?[a-z_]+\(\)' |
        sed -E 's/\$\{(GREEN|YELLOW|CYAN|WHITE|BOLD|DIM|NOTE|NC)\}//g; s/^\s+//')"
else
    fields='notes|store_details|patches|problem|fix|description|title|reason|follow_up'
    found="$(grep -E "\"($fields)\"\s*:\s*\"" <<<"$added" | grep -v '"url"' | sed -E 's/^\s+//; s/,$//')"
fi
[ -n "$found" ] || exit 0

msg="Player-facing text changed in $rel:
$found

Follow the player-text skill. Before handing over, run the copy-editor agent on
these strings, given as the player sees them (sample values filled in, the
screen lines around them, no code), then list the final wording for the user
under \"Text the player will see\"."

jq -n --arg m "$msg" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $m}}'
exit 0
