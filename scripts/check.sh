#!/bin/zsh
# Runs what CI checks for this branch's changes, so a pull request doesn't wait for CI to find them.
#
#   scripts/check.sh                 script syntax, commit messages, the build and every test, and the tests
#                                    of the pull request checks when .github/scripts changed
#   scripts/check.sh --commits       only the messages of the commits since main
#   scripts/check.sh --quick         only the build, when Swift files changed since the last quick check
#   scripts/check.sh --install-hooks turns on the git hooks in .githooks for every worktree of this clone
#
# The git hooks call --message for each commit message as it's written and --pre-push for the commits a
# push sends, in every tool. Claude Code also calls --hook-stop when the agent stops, which a failing build
# sends back to work. STABLEBAR_SKIP_HOOKS turns all three off for one person.
set -eu
cd "${0:A:h:h}"

base() { git merge-base origin/main HEAD 2> /dev/null || git rev-parse HEAD }

changed() { { git diff --name-only "$(base)"; git ls-files --others --exclude-standard; } | sort -u }

# commitlint from this checkout, or from the main checkout when a worktree has no node_modules. Without
# either, says so and passes.
run_commitlint() {
    local root=$PWD
    [[ -x node_modules/.bin/commitlint ]] || root=${$(git rev-parse --git-common-dir):A:h}
    if [[ ! -x $root/node_modules/.bin/commitlint ]]; then
        print -u2 "Skipped the commit messages: run npm ci first."
        return 0
    fi
    (cd "$root" && node_modules/.bin/commitlint "$@")
}

check_commits() {
    local head=$(git rev-parse HEAD) from=$(base)
    [[ $head == $from ]] && return 0
    run_commitlint --from "$from" --to "$head"
}

# The refs a push sends arrive on standard input, one per line; each is checked from where it leaves main.
check_push() {
    local local_ref local_sha remote_ref remote_sha from
    while read -r local_ref local_sha remote_ref remote_sha; do
        [[ $local_sha =~ '^0+$' ]] && continue
        from=$(git merge-base origin/main "$local_sha" 2> /dev/null) || continue
        [[ $from == $local_sha ]] && continue
        run_commitlint --from "$from" --to "$local_sha" || return 1
    done
}

# Parses each changed script with the shell its first line names, as CI does.
check_scripts() {
    local script interpreter
    for script in ${(M)${(f)"$(changed)"}:#((scripts|examples)/*.sh|.githooks/*)}; do
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
    # Back at main's files after a quick build, build once more so the products match them again.
    swift_changed || [[ -f $stamp ]] || return 0
    state=$(swift_state)
    [[ -f $stamp && "$(< $stamp)" == "$state" ]] && return 0
    swift build --build-tests || return 1
    mkdir -p .build
    print -r -- "$state" > $stamp
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

install_hooks() {
    git config core.hooksPath .githooks
    print "Git now runs .githooks in every worktree of this clone: it checks each commit message as you write"
    print "it, and the messages a push sends."
}

hooks_off() { [[ -n ${STABLEBAR_SKIP_HOOKS:-} ]] }

case ${1:-} in
    --commits) check_commits ;;
    --quick) check_quick ;;
    --install-hooks) install_hooks ;;
    --message) hooks_off || run_commitlint --edit "${2:A}" ;;
    --pre-push) hooks_off || check_push ;;
    --hook-stop) hooks_off || hook_stop ;;
    "")
        [[ "$(git config --get core.hooksPath)" == .githooks ]] ||
            print -u2 "The git hooks are off: scripts/check.sh --install-hooks turns them on."
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
        print -u2 "Usage: scripts/check.sh [--commits | --quick | --install-hooks]"
        exit 64
        ;;
esac
