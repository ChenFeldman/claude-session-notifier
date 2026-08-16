#!/usr/bin/env bash
#
# Regression tests for the dispatcher.
#
#   ./tests/run-tests.sh               everything
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

# Run the hook with a controlled environment. Every CLAUDE_BANNER_* variable is cleared
# first: an inherited value from the developer's own shell would otherwise change what
# the hook emits and make a case pass for the wrong reason. Callers add their own as
# trailing VAR=VAL arguments.
run_hook() {
  local payload="$1"; shift
  printf '%s' "$payload" | env \
    -u CLAUDE_BANNER_TEXT -u CLAUDE_BANNER_SOUND -u CLAUDE_BANNER_DURATION \
    HOME="$FAKE_HOME" CLAUDE_BANNER_SOUND=none \
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

payload() { # payload <cwd>
  jq -nc --arg c "$1" '{cwd:$c}'
}

printf '\nclaude-session-notifier — regression tests\n\n'

# ── Naming ───────────────────────────────────────────────────────────────────
printf '%s\n' "$(dim 'names')"

check "plain name" "<oz-A finished>" \
  "$(run_hook "$(payload /Users/x/oz-A)")"

check "name with spaces survives as one argument" "<my project finished>" \
  "$(run_hook "$(payload '/Users/x/my project')")"

# Unicode must survive: an earlier global sanitiser replaced it and made the banner
# useless for anyone not working in ASCII.
check "hebrew" "<פרויקט finished>" \
  "$(run_hook "$(payload /Users/x/פרויקט)")"

check "japanese" "<プロジェクト finished>" \
  "$(run_hook "$(payload /Users/x/プロジェクト)")"

check "emoji" "<🎉-repo finished>" \
  "$(run_hook "$(payload /Users/x/🎉-repo)")"

long_name="$(printf 'a%.0s' {1..90})"
check "90-char name is capped at 64" "<$(printf 'a%.0s' {1..64}) finished>" \
  "$(run_hook "$(payload "/Users/x/$long_name")")"

check "control characters are stripped" "<ab finished>" \
  "$(run_hook "$(jq -nc '{cwd:"/Users/x/ab"}')")"

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
# mangled — mangling would mean someone reintroduced a global filter.
evil='/Users/x/evil" & (do shell script "touch /tmp/csn-pwned") & "x'
check "injection payload reaches argv intact" '<csn-pwned") & "x finished>' \
  "$(run_hook "$(payload "$evil")")"
check "no command was executed" "absent" \
  "$([ -e /tmp/csn-pwned ] && echo present || echo absent)"
rm -f /tmp/csn-pwned

# ── Configuration ────────────────────────────────────────────────────────────
printf '%s\n' "$(dim 'configuration')"

check "custom text template" "<🎉 oz-A is done!>" \
  "$(run_hook "$(payload /Users/x/oz-A)" CLAUDE_BANNER_TEXT='🎉 %s is done!')"

check "custom duration is passed through" "<8>" \
  "$(run_hook "$(payload /Users/x/oz-A)" CLAUDE_BANNER_DURATION=8)"

# The template is user-supplied and must not be treated as a printf format string.
check "a % in the template is not interpreted" "<100% oz-A>" \
  "$(run_hook "$(payload /Users/x/oz-A)" CLAUDE_BANNER_TEXT='100% %s')"

# ── Install / uninstall round trip ───────────────────────────────────────────
if [[ "${SKIP_SLOW:-0}" != "1" ]] && command -v swiftc >/dev/null 2>&1; then
  printf '%s\n' "$(dim 'install / uninstall round trip')"

  RT="$(mktemp -d)"
  mkdir -p "$RT/.claude"
  # A foreign hook plus an unrelated setting: clobbering someone's settings.json is the
  # one unforgivable failure here.
  jq -n '{hooks:{Stop:[{hooks:[{type:"command",command:"/my/other-stop.sh"}]}]},
          otherSetting:"keep me"}' > "$RT/.claude/settings.json"

  # Twice, because re-running must update in place rather than register a duplicate.
  HOME="$RT" "$REPO_DIR/install.sh" >/dev/null 2>&1
  HOME="$RT" "$REPO_DIR/install.sh" >/dev/null 2>&1

  check "install registers exactly once" "1" \
    "$(jq '[.hooks.Stop[]?.hooks[]?.command | select(test("claude-session-notifier"))] | length' \
       "$RT/.claude/settings.json")"
  check "foreign hook survives install" "/my/other-stop.sh" \
    "$(jq -r '[.hooks.Stop[].hooks[].command] | join(",")' "$RT/.claude/settings.json")"
  check "unrelated settings survive install" "keep me" \
    "$(jq -r .otherSetting "$RT/.claude/settings.json")"

  HOME="$RT" "$REPO_DIR/uninstall.sh" >/dev/null 2>&1

  check "uninstall leaves none of our entries" "0" \
    "$(jq '[.. | strings | select(test("claude-session-notifier"))] | length' \
       "$RT/.claude/settings.json")"
  check "foreign hook survives uninstall" "/my/other-stop.sh" \
    "$(jq -r '[.hooks.Stop[].hooks[].command] | join(",")' "$RT/.claude/settings.json")"
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
printf '\n  %s\n' "$(dim 'Not covered: whether a window actually appears and whether the')"
printf '  %s\n\n' "$(dim 'sound plays. Those need a person and ./install.sh.')"

[[ $FAIL -eq 0 ]]
