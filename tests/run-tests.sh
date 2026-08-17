#!/usr/bin/env bash
#
# Regression tests for the dispatcher.
#
#   ./tests/run-tests.sh            everything
#   SKIP_SLOW=1 ./tests/run-tests.sh   skip the install/uninstall round trip, which
#                                      compiles Swift and takes a while
#
# Two rules this file exists to honour, both from CLAUDE.md:
#
#   1. Test the script, not a copy of its logic. Every case below runs the real
#      hooks/claude-session-notifier.sh against a throwaway $HOME whose claude-banner is
#      a stub that prints its argv. Asserting on a reimplementation would pass forever
#      while the real thing broke.
#   2. Exit 0 proves nothing on its own. Every historical failure here exited 0, so these
#      assert on what the hook *emitted*, never on its status. What no automated check can
#      do is tell whether a window actually appeared — that still needs a human, and the
#      summary says so rather than implying this file covers it.
#
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$REPO_DIR/hooks/claude-session-notifier.sh"

PASS=0
FAIL=0
FAILED_NAMES=""

green() { printf '\033[32m%s\033[0m' "$*"; }
red()   { printf '\033[31m%s\033[0m' "$*"; }
dim()   { printf '\033[2m%s\033[0m'  "$*"; }

command -v jq >/dev/null 2>&1 || { echo "jq is required"; exit 1; }

# ── Harness ──────────────────────────────────────────────────────────────────
# A throwaway HOME whose claude-banner prints its arguments in a form that survives
# spaces and unicode: <arg><arg><arg>. The hook finds it at $HOME/.claude/hooks/bin.

FAKE_HOME="$(mktemp -d)"
trap 'rm -rf "$FAKE_HOME"' EXIT
mkdir -p "$FAKE_HOME/.claude/hooks/bin"
cat > "$FAKE_HOME/.claude/hooks/bin/claude-banner" <<'STUB'
#!/bin/bash
for a in "$@"; do printf '<%s>' "$a"; done
printf '\n'
STUB
chmod +x "$FAKE_HOME/.claude/hooks/bin/claude-banner"

# A transcript containing two ai-title entries, so tests can prove the LAST one wins.
TRANSCRIPT="$FAKE_HOME/transcript.jsonl"
{
  jq -nc '{type:"user", message:"hello"}'
  jq -nc '{type:"ai-title", aiTitle:"An earlier title"}'
  jq -nc '{type:"assistant", message:"hi"}'
  jq -nc '{type:"ai-title", aiTitle:"Fix the retry backoff"}'
} > "$TRANSCRIPT"

# Run the hook with a controlled environment. Every CLAUDE_BANNER_* var and every
# terminal variable is cleared first: inherited values from the developer's own shell
# would otherwise change what the hook emits and make a test pass for the wrong reason.
# Callers add their own assignments as trailing VAR=VAL arguments.
run_hook() {
  local payload="$1"; shift
  printf '%s' "$payload" | env \
    -u ITERM_SESSION_ID -u TERM_PROGRAM \
    -u CLAUDE_BANNER_TEXT -u CLAUDE_BANNER_TEXT_WAITING \
    -u CLAUDE_BANNER_SOUND -u CLAUDE_BANNER_SOUND_WAITING \
    -u CLAUDE_BANNER_DURATION -u CLAUDE_BANNER_NAME_SOURCE \
    HOME="$FAKE_HOME" CLAUDE_BANNER_SOUND=none CLAUDE_BANNER_SOUND_WAITING=none \
    "$@" bash "$HOOK" 2>/dev/null
}

check() { # check <name> <expected-substring> <actual>
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == *"$expected"* ]]; then
    PASS=$((PASS + 1)); printf '  %s %s\n' "$(green ✓)" "$name"
  else
    FAIL=$((FAIL + 1)); FAILED_NAMES="$FAILED_NAMES
    $name"
    printf '  %s %s\n' "$(red ✗)" "$name"
    printf '      expected to contain: %s\n' "$expected"
    printf '      actual:              %s\n' "${actual:-<empty>}"
  fi
}

check_not() { # check_not <name> <forbidden-substring> <actual>
  local name="$1" forbidden="$2" actual="$3"
  if [[ "$actual" != *"$forbidden"* ]]; then
    PASS=$((PASS + 1)); printf '  %s %s\n' "$(green ✓)" "$name"
  else
    FAIL=$((FAIL + 1)); FAILED_NAMES="$FAILED_NAMES
    $name"
    printf '  %s %s\n' "$(red ✗)" "$name"
    printf '      expected NOT to contain: %s\n' "$forbidden"
    printf '      actual:                  %s\n' "$actual"
  fi
}

check_prefix() { # check_prefix <name> <expected-start-of-output> <actual>
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected"* ]]; then
    PASS=$((PASS + 1)); printf '  %s %s\n' "$(green ✓)" "$name"
  else
    FAIL=$((FAIL + 1)); FAILED_NAMES="$FAILED_NAMES
    $name"
    printf '  %s %s\n' "$(red ✗)" "$name"
    printf '      expected to start with: %s\n' "$expected"
    printf '      actual:                 %s\n' "${actual:-<empty>}"
  fi
}

# "" as an expected substring matches everything, so silence needs its own assertion.
silent_or_output() { # silent_or_output <run_hook output>
  [[ -z "$1" ]] && printf 'SILENT' || printf '%s' "$1"
}

payload() { # payload <cwd> [extra-json-object]
  local extra="${2:-}"
  [[ -z "$extra" ]] && extra='{}'
  jq -nc --arg c "$1" --argjson extra "$extra" '{cwd:$c} + $extra'
}

printf '\nclaude-session-notifier — regression tests\n\n'

# ── Naming from the folder ───────────────────────────────────────────────────
printf '%s\n' "$(dim 'folder names')"

check "plain name" "<oz-A finished>" \
  "$(run_hook "$(payload /Users/x/oz-A)" CLAUDE_BANNER_NAME_SOURCE=folder)"

check "name with spaces survives as one argument" "<my project finished>" \
  "$(run_hook "$(payload '/Users/x/my project')" CLAUDE_BANNER_NAME_SOURCE=folder)"

check "hebrew" "<פרויקט finished>" \
  "$(run_hook "$(payload /Users/x/פרויקט)" CLAUDE_BANNER_NAME_SOURCE=folder)"

check "japanese" "<プロジェクト finished>" \
  "$(run_hook "$(payload /Users/x/プロジェクト)" CLAUDE_BANNER_NAME_SOURCE=folder)"

# Unicode must survive: an earlier global sanitiser replaced it and made the banner
# useless for anyone not working in ASCII.
check "emoji" "<🎉-repo finished>" \
  "$(run_hook "$(payload /Users/x/🎉-repo)" CLAUDE_BANNER_NAME_SOURCE=folder)"

long_name="$(printf 'a%.0s' {1..90})"
check "90-char name is capped at 64" "<$(printf 'a%.0s' {1..64}) finished>" \
  "$(run_hook "$(payload "/Users/x/$long_name")" CLAUDE_BANNER_NAME_SOURCE=folder)"

check "control characters are stripped" "<ab finished>" \
  "$(run_hook "$(jq -nc '{cwd:"/Users/x/a\u0001b"}')" CLAUDE_BANNER_NAME_SOURCE=folder)"

# ── Degenerate payloads ──────────────────────────────────────────────────────
printf '%s\n' "$(dim 'degenerate input')"

check "missing cwd" "<claude finished>" \
  "$(run_hook "$(jq -nc '{session_id:"abc"}')")"

check "malformed json" "<claude finished>" \
  "$(run_hook 'not json at all')"

check "empty stdin" "<claude finished>" \
  "$(run_hook '')"

check "cwd of /" "<claude finished>" \
  "$(run_hook "$(payload /)")"

check "cwd of ." "<claude finished>" \
  "$(run_hook "$(payload .)")"

# ── Injection ────────────────────────────────────────────────────────────────
printf '%s\n' "$(dim 'injection')"

# A directory name can be attacker-influenced: `git worktree add` derives it from a
# branch name, and branch names come from pull requests. The banner takes text through
# argv where nothing is special, so the payload must arrive intact and inert rather than
# mangled — mangling would mean someone added a global filter again.
evil='/Users/x/evil" & (do shell script "touch /tmp/csn-pwned") & "x'
out="$(run_hook "$(payload "$evil")" CLAUDE_BANNER_NAME_SOURCE=folder)"
check "injection payload reaches argv intact" '<csn-pwned") & "x finished>' "$out"
check "no command was executed" "absent" "$([ -e /tmp/csn-pwned ] && echo present || echo absent)"
rm -f /tmp/csn-pwned

# ── Titles ───────────────────────────────────────────────────────────────────
printf '%s\n' "$(dim 'session titles')"

check "folder is the default source, not the title" "<somerepo finished>" \
  "$(run_hook "$(payload /Users/x/somerepo "$(jq -nc --arg t "$TRANSCRIPT" '{transcript_path:$t}')")")"

check "title is used when opted in" "<Fix the retry backoff finished>" \
  "$(run_hook "$(payload /Users/x/somerepo "$(jq -nc --arg t "$TRANSCRIPT" '{transcript_path:$t}')")" \
     CLAUDE_BANNER_NAME_SOURCE=title)"

check "the LAST ai-title wins, not the first" "<Fix the retry backoff finished>" \
  "$(run_hook "$(payload /Users/x/somerepo "$(jq -nc --arg t "$TRANSCRIPT" '{transcript_path:$t}')")" \
     CLAUDE_BANNER_NAME_SOURCE=title)"

check_not "the earlier title is not used" "An earlier title" \
  "$(run_hook "$(payload /Users/x/somerepo "$(jq -nc --arg t "$TRANSCRIPT" '{transcript_path:$t}')")" \
     CLAUDE_BANNER_NAME_SOURCE=title)"

check "unreadable transcript falls back to the folder, not the generic label" "<somerepo finished>" \
  "$(run_hook "$(payload /Users/x/somerepo '{"transcript_path":"/nonexistent.jsonl"}')" \
     CLAUDE_BANNER_NAME_SOURCE=title)"

check "absent transcript_path falls back to the folder" "<somerepo finished>" \
  "$(run_hook "$(payload /Users/x/somerepo)" CLAUDE_BANNER_NAME_SOURCE=title)"

check "transcript with no ai-title falls back to the folder" "<somerepo finished>" \
  "$(run_hook "$(payload /Users/x/somerepo "$(jq -nc --arg t "$FAKE_HOME/.claude/settings.json" '{transcript_path:$t}')")" \
     CLAUDE_BANNER_NAME_SOURCE=title)"

# Key order and spacing must not matter: the reader parses each line rather than matching
# a literal, so a writer that emits the same data differently still works.
reordered="$FAKE_HOME/reordered.jsonl"
printf '{ "aiTitle" : "Reordered keys" ,  "type" : "ai-title" }\n' > "$reordered"
check "title is found regardless of key order or spacing" "<Reordered keys finished>" \
  "$(run_hook "$(payload /Users/x/somerepo "$(jq -nc --arg t "$reordered" '{transcript_path:$t}')")" \
     CLAUDE_BANNER_NAME_SOURCE=title)"

# The reader takes a byte window from the end, which starts mid-line. That partial line
# must be discarded rather than breaking the parse for everything after it.
big="$FAKE_HOME/big.jsonl"
: > "$big"
i=0; while [ $i -lt 400 ]; do jq -nc --arg p "$(printf 'x%.0s' {1..200})" '{type:"assistant",message:$p}' >> "$big"; i=$((i+1)); done
jq -nc '{type:"ai-title", aiTitle:"Title near the end"}' >> "$big"
i=0; while [ $i -lt 50 ]; do jq -nc '{type:"assistant",message:"tail"}' >> "$big"; i=$((i+1)); done
check "title found in a file larger than the read window" "<Title near the end finished>" \
  "$(run_hook "$(payload /Users/x/somerepo "$(jq -nc --arg t "$big" '{transcript_path:$t}')")" \
     CLAUDE_BANNER_NAME_SOURCE=title)"

# A title set early in a long session falls outside the window, so the full-file fallback
# has to still find it.
early="$FAKE_HOME/early.jsonl"
jq -nc '{type:"ai-title", aiTitle:"Titled at the very start"}' > "$early"
i=0; while [ $i -lt 500 ]; do jq -nc --arg p "$(printf 'y%.0s' {1..200})" '{type:"assistant",message:$p}' >> "$early"; i=$((i+1)); done
check "title outside the window is still found" "<Titled at the very start finished>" \
  "$(run_hook "$(payload /Users/x/somerepo "$(jq -nc --arg t "$early" '{transcript_path:$t}')")" \
     CLAUDE_BANNER_NAME_SOURCE=title)"

check "explicit folder source ignores an available title" "<somerepo finished>" \
  "$(run_hook "$(payload /Users/x/somerepo "$(jq -nc --arg t "$TRANSCRIPT" '{transcript_path:$t}')")" \
     CLAUDE_BANNER_NAME_SOURCE=folder)"

# folder is documented as an escape hatch for people who want this hook to read nothing
# but the path it is handed. That promise is about behaviour, not wording, so assert the
# code path itself never mentions the transcript outside the title branch.
title_branch_only=$(awk '/NAME_SOURCE" == "title"/{inside=1} inside&&/^fi$/{inside=0} !inside&&/transcript/{print}' "$HOOK" | grep -vc '^#' || true)
check "folder mode has no path to the transcript" "0" "$title_branch_only"

# A title is model-generated, so it is unpredictable in ways a path is not.
long_title="$FAKE_HOME/long-title.jsonl"
jq -nc --arg t "$(printf 'T%.0s' {1..120})" '{type:"ai-title", aiTitle:$t}' > "$long_title"
check "long title is capped at 64" "<$(printf 'T%.0s' {1..64}) finished>" \
  "$(run_hook "$(payload /Users/x/somerepo "$(jq -nc --arg t "$long_title" '{transcript_path:$t}')")" \
     CLAUDE_BANNER_NAME_SOURCE=title)"

ctrl_title="$FAKE_HOME/ctrl-title.jsonl"
jq -nc '{type:"ai-title", aiTitle:"we\u0001ird"}' > "$ctrl_title"
check "control characters in a title are stripped" "<weird finished>" \
  "$(run_hook "$(payload /Users/x/somerepo "$(jq -nc --arg t "$ctrl_title" '{transcript_path:$t}')")" \
     CLAUDE_BANNER_NAME_SOURCE=title)"

# ── Events ───────────────────────────────────────────────────────────────────
printf '%s\n' "$(dim 'events')"

check "Stop says finished" "<oz-A finished>" \
  "$(run_hook "$(payload /Users/x/oz-A '{"hook_event_name":"Stop"}')" CLAUDE_BANNER_NAME_SOURCE=folder)"

# A session blocked on a question never fires Stop, so this is the case the tool was
# silent for before Notification was registered.
check "Notification says needs you" "<oz-A needs you>" \
  "$(run_hook "$(payload /Users/x/oz-A '{"hook_event_name":"Notification"}')" CLAUDE_BANNER_NAME_SOURCE=folder)"

# Anything unfamiliar must behave like a turn ending rather than go quiet: silence is the
# one failure mode nobody notices.
# idle_prompt fires about a minute after the prompt goes quiet, which happens after every
# turn someone walks away from. Ringing for it would follow every "finished" with a
# spurious "needs you" and make the waiting signal meaningless.
check "idle_prompt notification is silent" "SILENT" \
  "$(silent_or_output "$(run_hook "$(payload /Users/x/oz-A '{"hook_event_name":"Notification","notification_type":"idle_prompt"}')" CLAUDE_BANNER_NAME_SOURCE=folder)")"

check "idle notification is silent" "SILENT" \
  "$(silent_or_output "$(run_hook "$(payload /Users/x/oz-A '{"hook_event_name":"Notification","notification_type":"idle"}')" CLAUDE_BANNER_NAME_SOURCE=folder)")"

check "permission_prompt still rings" "<oz-A needs you>" \
  "$(run_hook "$(payload /Users/x/oz-A '{"hook_event_name":"Notification","notification_type":"permission_prompt"}')" CLAUDE_BANNER_NAME_SOURCE=folder)"

check "elicitation still rings" "<oz-A needs you>" \
  "$(run_hook "$(payload /Users/x/oz-A '{"hook_event_name":"Notification","notification_type":"elicitation"}')" CLAUDE_BANNER_NAME_SOURCE=folder)"

# An unrecognised type rings rather than going quiet: a new kind of attention request
# nobody hears is worse than one extra banner.
check "an unknown notification_type still rings" "<oz-A needs you>" \
  "$(run_hook "$(payload /Users/x/oz-A '{"hook_event_name":"Notification","notification_type":"something_new"}')" CLAUDE_BANNER_NAME_SOURCE=folder)"

check "unknown event degrades to finished" "<oz-A finished>" \
  "$(run_hook "$(payload /Users/x/oz-A '{"hook_event_name":"SomethingNew"}')" CLAUDE_BANNER_NAME_SOURCE=folder)"

check "absent event degrades to finished" "<oz-A finished>" \
  "$(run_hook "$(payload /Users/x/oz-A)" CLAUDE_BANNER_NAME_SOURCE=folder)"

# ── Configuration ────────────────────────────────────────────────────────────
printf '%s\n' "$(dim 'configuration')"

check "custom text template" "<🎉 oz-A is done!>" \
  "$(run_hook "$(payload /Users/x/oz-A)" CLAUDE_BANNER_NAME_SOURCE=folder CLAUDE_BANNER_TEXT='🎉 %s is done!')"

check "custom waiting template" "<⏳ oz-A is blocked>" \
  "$(run_hook "$(payload /Users/x/oz-A '{"hook_event_name":"Notification"}')" \
     CLAUDE_BANNER_NAME_SOURCE=folder CLAUDE_BANNER_TEXT_WAITING='⏳ %s is blocked')"

check "custom duration is passed through" "<8>" \
  "$(run_hook "$(payload /Users/x/oz-A)" CLAUDE_BANNER_NAME_SOURCE=folder CLAUDE_BANNER_DURATION=8)"

# The template is user-supplied and must not be treated as a printf format string.
check "a % in the template is not interpreted" "<100% oz-A>" \
  "$(run_hook "$(payload /Users/x/oz-A)" CLAUDE_BANNER_NAME_SOURCE=folder CLAUDE_BANNER_TEXT='100% %s')"

# ── The argv contract ────────────────────────────────────────────────────────
printf '%s\n' "$(dim 'argv contract')"

# Every other case here substring-matches the concatenated argv, which cannot see
# *position*. Swapping the banner's first two arguments — so it draws "5" and waits
# "oz-A finished" seconds — left the whole suite green until this case existed. The
# binary reads argv positionally, so the order is part of the contract between the two
# halves of this project and needs one assertion that pins it exactly.
# Anchored at the start rather than matched whole: the third argument is the slot, and
# that comes from counting live banner processes, so a real banner on screen while the
# suite runs would make an exact match flaky. Positions 1 and 2 are the contract.
check_prefix "banner argv is message first, then duration" \
  "<oz-A finished><5>" \
  "$(run_hook "$(payload /Users/x/oz-A)" CLAUDE_BANNER_NAME_SOURCE=folder)"

# ── Click to focus ───────────────────────────────────────────────────────────
printf '%s\n' "$(dim 'click to focus')"

uuid="9D75B4DD-0CB4-4269-B3E3-8D670F89EE48"

check "iTerm2 session yields a focus target" "<--focus-iterm2><$uuid>" \
  "$(run_hook "$(payload /Users/x/oz-A)" CLAUDE_BANNER_NAME_SOURCE=folder \
     TERM_PROGRAM=iTerm.app ITERM_SESSION_ID="w0t2p0:$uuid")"

check_not "no iTerm2 means no focus flag" "--focus-iterm2" \
  "$(run_hook "$(payload /Users/x/oz-A)" CLAUDE_BANNER_NAME_SOURCE=folder)"

check_not "another terminal gets no focus flag" "--focus-iterm2" \
  "$(run_hook "$(payload /Users/x/oz-A)" CLAUDE_BANNER_NAME_SOURCE=folder \
     TERM_PROGRAM=Apple_Terminal ITERM_SESSION_ID="w0t0p0:$uuid")"

# The id reaches osascript, so a value that is not a uuid must be dropped rather than
# escaped-and-hoped-for.
check_not "a malformed session id is rejected" "--focus-iterm2" \
  "$(run_hook "$(payload /Users/x/oz-A)" CLAUDE_BANNER_NAME_SOURCE=folder \
     TERM_PROGRAM=iTerm.app ITERM_SESSION_ID='w0t0p0:not-a-uuid')"

# shellcheck disable=SC2016  # the single quotes are the point: this must reach the hook
# as literal text, exactly as a hostile environment would supply it. Expanding it here
# would run the payload in the test's own shell and prove nothing about the hook.
check_not "an injected session id is rejected" "--focus-iterm2" \
  "$(run_hook "$(payload /Users/x/oz-A)" CLAUDE_BANNER_NAME_SOURCE=folder \
     TERM_PROGRAM=iTerm.app ITERM_SESSION_ID='w0t0p0:$(touch /tmp/csn-pwned2)')"
rm -f /tmp/csn-pwned2

check_not "an empty ITERM_SESSION_ID is rejected" "--focus-iterm2" \
  "$(run_hook "$(payload /Users/x/oz-A)" CLAUDE_BANNER_NAME_SOURCE=folder \
     TERM_PROGRAM=iTerm.app ITERM_SESSION_ID='')"

# ── The dry run tells the truth ──────────────────────────────────────────────
printf '%s\n' "$(dim 'dry run')"

# Outside the slow block on purpose: --dry-run compiles nothing, so there is no reason
# to make anyone opt in to checking it.
#
# This is the output someone reads before deciding whether to let the installer near
# their settings.json, so it has to name everything the real run touches. It named only
# Stop for a while after Notification was added, which understated the change to a file
# people are right to be protective of.
dry=$(HOME="$FAKE_HOME" "$REPO_DIR/install.sh" --dry-run 2>/dev/null)
check "dry run names the Stop hook" "Stop" "$dry"
check "dry run names the Notification hook" "Notification" "$dry"
check "dry run promises the backup" "backing it up first" "$dry"
check_not "dry run does not claim to have done anything" "registered" "$dry"

# ── Install / uninstall round trip ───────────────────────────────────────────
if [[ "${SKIP_SLOW:-0}" != "1" ]] && command -v swiftc >/dev/null 2>&1; then
  printf '%s\n' "$(dim 'install / uninstall round trip')"

  RT="$(mktemp -d)"
  mkdir -p "$RT/.claude"
  # Foreign hooks on both events plus an unrelated setting: clobbering someone's
  # settings.json is the one unforgivable failure here.
  jq -n '{hooks:{Stop:[{hooks:[{type:"command",command:"/my/other-stop.sh"}]}],
                 Notification:[{hooks:[{type:"command",command:"/my/other-notif.sh"}]}]},
          otherSetting:"keep me"}' > "$RT/.claude/settings.json"

  # Twice, because re-running must update in place rather than register a duplicate.
  HOME="$RT" "$REPO_DIR/install.sh" >/dev/null 2>&1
  HOME="$RT" "$REPO_DIR/install.sh" >/dev/null 2>&1

  for event in Stop Notification; do
    n=$(jq --arg e "$event" \
      '[.hooks[$e][]?.hooks[]?.command | select(test("claude-session-notifier"))] | length' \
      "$RT/.claude/settings.json")
    check "install registers on $event exactly once" "1" "$n"
  done
  check "foreign Stop hook survives install" "/my/other-stop.sh" \
    "$(jq -r '[.hooks.Stop[].hooks[].command] | join(",")' "$RT/.claude/settings.json")"
  check "foreign Notification hook survives install" "/my/other-notif.sh" \
    "$(jq -r '[.hooks.Notification[].hooks[].command] | join(",")' "$RT/.claude/settings.json")"
  check "unrelated settings survive install" "keep me" \
    "$(jq -r .otherSetting "$RT/.claude/settings.json")"

  HOME="$RT" "$REPO_DIR/uninstall.sh" >/dev/null 2>&1

  check "uninstall leaves none of our entries" "0" \
    "$(jq '[.. | strings | select(test("claude-session-notifier"))] | length' "$RT/.claude/settings.json")"
  check "foreign Stop hook survives uninstall" "/my/other-stop.sh" \
    "$(jq -r '[.hooks.Stop[].hooks[].command] | join(",")' "$RT/.claude/settings.json")"
  check "foreign Notification hook survives uninstall" "/my/other-notif.sh" \
    "$(jq -r '[.hooks.Notification[].hooks[].command] | join(",")' "$RT/.claude/settings.json")"
  check "unrelated settings survive uninstall" "keep me" \
    "$(jq -r .otherSetting "$RT/.claude/settings.json")"
  check "hook file removed" "gone" \
    "$([ -e "$RT/.claude/hooks/claude-session-notifier.sh" ] && echo present || echo gone)"
  check "binary removed" "gone" \
    "$([ -e "$RT/.claude/hooks/bin/claude-banner" ] && echo present || echo gone)"

  rm -rf "$RT"
else
  printf '%s\n' "$(dim 'install / uninstall round trip — skipped')"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
printf '\n'
if [[ $FAIL -eq 0 ]]; then
  printf '  %s %d passed\n' "$(green ✓)" "$PASS"
else
  printf '  %s %d passed, %d failed:%s\n' "$(red ✗)" "$PASS" "$FAIL" "$FAILED_NAMES"
fi

# Say plainly what this file does not cover, so a green run is not mistaken for proof
# that the thing works. Every failure this project has had was invisible to exit codes.
printf '\n  %s\n' "$(dim 'Not covered: whether a window actually appears, whether the click')"
printf '  %s\n\n' "$(dim 'focuses the right tab, and whether the sound plays. Run ./install.sh.')"

[[ $FAIL -eq 0 ]]
