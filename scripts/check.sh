#!/bin/zsh
# Runs what CI checks for this branch's changes, so a pull request doesn't wait for CI to find them.
#
#   scripts/check.sh             script syntax, commit messages, the build and every test, and the tests of
#                                the pull request checks when .github/scripts changed
#   scripts/check.sh --commits   only the messages of the commits since main
#   scripts/check.sh --quick     only the build, when Swift files changed since the last quick check
#
# Claude Code runs it from .claude/settings.json: --hook-push before a git push, which a failing commit
# message stops, and --hook-stop when the agent stops, which a failing build sends back to work.
set -eu
cd "${0:A:h:h}"

base() { git merge-base origin/main HEAD 2> /dev/null || git rev-parse HEAD }

changed() { { git diff --name-only "$(base)"; git ls-files --others --exclude-standard; } | sort -u }

# commitlint from this checkout, or from the main checkout when a worktree has no node_modules. Without
# either, says so and passes.
check_commits() {
    local head=$(git rev-parse HEAD) from=$(base) root=$PWD
    [[ $head == $from ]] && return 0
    [[ -x node_modules/.bin/commitlint ]] || root=${$(git rev-parse --git-common-dir):A:h}
    if [[ ! -x $root/node_modules/.bin/commitlint ]]; then
        print -u2 "Skipped the commit messages: run npm ci first."
        return 0
    fi
    (cd "$root" && node_modules/.bin/commitlint --from "$from" --to "$head")
}

# Parses each changed script with the shell its first line names, as CI does.
check_scripts() {
    local script interpreter
    for script in ${(M)${(f)"$(changed)"}:#(scripts|examples)/*.sh}; do
        [[ -f $script ]] || continue
        interpreter=$(sed -n '1s/^#!//p' "$script")
        ${=interpreter} -n "$script" || return 1
    done
}

swift_changed() {
    ! git diff --quiet "$(base)" -- Sources Tests Package.swift Package.resolved ||
        [[ -n "$(git ls-files --others --exclude-standard -- Sources Tests)" ]]
}

# What the build reads, so a tree that already built doesn't build again.
swift_state() {
    {
        git diff "$(base)" -- Sources Tests Package.swift Package.resolved
        git ls-files --others --exclude-standard -- Sources Tests | while IFS= read -r file; do
            print -r -- "$file"
            cat -- "$file"
        done
    } | shasum | cut -d ' ' -f 1
}

check_quick() {
    local stamp=.build/check-quick state
    swift_changed || return 0
    state=$(swift_state)
    [[ -f $stamp && "$(< $stamp)" == "$state" ]] && return 0
    swift build --build-tests || return 1
    mkdir -p .build
    print -r -- "$state" > $stamp
}

# Before a Bash command: a git push waits for its commit messages. Exit 2 blocks the command.
hook_push() {
    local input=$(cat) command output
    [[ $input == *push* ]] || return 0
    if (( $+commands[jq] )); then
        command=$(jq -r '.tool_input.command // ""' <<< "$input" 2> /dev/null) || command=$input
    else
        command=$input
    fi
    [[ $command =~ 'git( [^;&|]*)? push' ]] || return 0
    if ! output=$(check_commits 2>&1); then
        print -u2 -r -- "A commit message would fail the Commit messages check; reword it before pushing:"
        print -u2 -r -- "$output"
        exit 2
    fi
}

# When the agent stops: a failing build sends it back to work, once. Exit 2 blocks the stop.
hook_stop() {
    local input=$(cat) output errors
    [[ $input =~ '"stop_hook_active"[[:space:]]*:[[:space:]]*true' ]] && return 0
    if ! output=$(check_quick 2>&1); then
        output=$(print -r -- "$output" | sed $'s/\e\\[[0-9;]*m//g')
        errors=$(print -r -- "$output" | grep -E ':[0-9]+:[0-9]+: error:' | head -20)
        [[ -n $errors ]] || errors=$(print -r -- "$output" | tail -20)
        print -u2 -r -- "The build fails; fix it before stopping:"
        print -u2 -r -- "$errors"
        exit 2
    fi
}

case ${1:-} in
    --commits) check_commits ;;
    --quick) check_quick ;;
    # STABLEBAR_SKIP_HOOKS turns the hooks off for one person, such as in .claude/settings.local.json.
    --hook-push) [[ -n ${STABLEBAR_SKIP_HOOKS:-} ]] || hook_push ;;
    --hook-stop) [[ -n ${STABLEBAR_SKIP_HOOKS:-} ]] || hook_stop ;;
    "")
        check_scripts
        check_commits
        swift build --build-tests
        swift test --skip-build
        if [[ -n ${(M)${(f)"$(changed)"}:#.github/scripts/*} ]]; then
            if [[ -d node_modules ]]; then
                node --test .github/scripts/*.test.mjs
            else
                print -u2 "Skipped the tests of the pull request checks: run npm ci first."
            fi
        fi
        ;;
    *)
        print -u2 "Usage: scripts/check.sh [--commits | --quick]"
        exit 64
        ;;
esac
