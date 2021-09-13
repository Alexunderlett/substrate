#!/usr/bin/env bash
#
# Ensure that a PR does not introduce downstream breakages on this project's dependents by
# performing checks using this branch's code. If dependents are specified as companions, they are
# patched to use the code we have in this branch; otherwise, we run the the checks against their
# default branch.

# Companion dependents are extracted from the PR's description when lines conform to the following
# formats:
# [cC]ompanion: $organization/$repo#567
# [cC]ompanion: $repo#567

#shellcheck source=../common/lib.sh
. "$(dirname "$0")/../common/lib.sh"

echo "
check_dependent_project
========================

This check ensures that this project's dependents do not suffer downstream breakages from new code
changes.
"

# FIXME: use base jq from CI when it gets updated to Ubuntu LTS
jq="$PWD/jq16"
curl -sqL https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 -o "$jq"
chmod +x "$jq"
echo "af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44  $jq" | sha256sum --check

set -eu -o pipefail
shopt -s inherit_errexit

die() {
  if [ "${1:-}" ]; then
    echo "$1" >&2
  fi
  exit 1
}

dependent_repo="$1"
this_repo="substrate"
this_repo_diener_arg="--substrate"
this_repo_dir="$PWD"
org="paritytech"

# Set the user name and email to make merging work
git config --global user.name 'CI system'
git config --global user.email '<>'
git config --global pull.rebase false

# Merge master into our branch so that the compilation takes into account how the code is going to
# going to perform when the code for this pull request lands on the target branch (à la pre-merge
# pipelines).
# Note that the target branch might not actually be master, but we default to it in the assumption
# of the common case. This could be refined in the future.
git pull origin master

our_crates=()
our_crates_source="git+https://github.com/$org/$this_repo"
discover_our_crates() {
  # workaround for early exits not being detected in command substitution
  # https://unix.stackexchange.com/questions/541969/nested-command-substitution-does-not-stop-a-script-on-a-failure-even-if-e-and-s
  local last_line

  local found
  while IFS= read -r crate; do
    last_line="$crate"
    # for avoiding duplicate entries
    for our_crate in "${our_crates[@]}"; do
      if [ "$crate" == "$our_crate" ]; then
        found=true
        break
      fi
    done
    if [ "${found:-}" ]; then
      unset found
    else
      our_crates+=("$crate")
    fi
  # dependents with {"source": null} are the ones we own, hence the getpath($p)==null in the jq
  # script below
  done < <(cargo metadata --quiet --format-version=1 | "$jq" -r '
    . as $in |
    paths |
    select(.[-1]=="source" and . as $p | $in | getpath($p)==null) as $path |
    del($path[-1]) as $path |
    $in | getpath($path + ["name"])
  ')
  if [ -z "${last_line+_}" ]; then
    die "No lines were read for cargo metadata of $PWD (some error probably occurred)"
  fi
}

match_their_crates() {
  local target_name="$1"
  local crates_not_found=()
  local found

  # workaround for early exits not being detected in command substitution
  # https://unix.stackexchange.com/questions/541969/nested-command-substitution-does-not-stop-a-script-on-a-failure-even-if-e-and-s
  local last_line

  # output will be consumed in the format:
  #   crate
  #   source
  #   crate
  #   ...
  local next="crate"
  while IFS= read -r line; do
    last_line="$line"
    case "$next" in
      crate)
        next="source"
        crate="$line"
      ;;
      source)
        next="crate"
        if [ "$line" == "$our_crates_source" ] || [[ "$line" == "$our_crates_source?"* ]]; then
          for our_crate in "${our_crates[@]}"; do
            if [ "$our_crate" == "$crate" ]; then
              found=true
              break
            fi
          done
          if [ "${found:-}" ]; then
            unset found
          else
            # for avoiding duplicate entries
            for crate_not_found in "${crates_not_found[@]}"; do
              if [ "$crate_not_found" == "$crate" ]; then
                found=true
                break
              fi
            done
            if [ "${found:-}" ]; then
              unset found
            else
              crates_not_found+=("$crate")
            fi
          fi
        fi
      ;;
      *)
        die "ERROR: Unknown state $next"
      ;;
    esac
  done < <(cargo metadata --quiet --format-version=1 | "$jq" -r '
    . as $in |
    paths(select(type=="string")) |
    select(.[-1]=="source") as $source_path |
    del($source_path[-1]) as $path |
    [$in | getpath($path + ["name"]), getpath($path + ["source"])] |
    .[]
  ')
  if [ -z "${last_line+_}" ]; then
    die "No lines were read for cargo metadata of $PWD (some error probably occurred)"
  fi

  if [ "${crates_not_found[@]}" ]; then
    echo -e "Errors during crate matching\n"
    printf "Failed to detect our crate \"%s\" referenced in $target_name\n" "${crates_not_found[@]}"
    echo -e "\nNote: this error generally happens if you have deleted or renamed a crate and did not update it in $target_name. Consider opening a companion pull request on $target_name and referencing it in this pull request's description like:\n$target_name companion: [your companion PR here]"
    die "Check failed"
  fi
}

patch_and_check_dependent() {
  match_their_crates "$(basename "$PWD")"
  diener patch --crates-to-patch "$this_repo_dir" "$this_repo_diener_arg" --path "Cargo.toml"
  cargo check --all-targets --workspace
}

process_companion_pr() {
  local companion_repo, pr_number

  # e.g. https://github.com/paritytech/polkadot/pull/123
  # or   polkadot#123
  local companion_expr="$1"
  if
    [[ "$companion_expr" =~ ^https://github\.com/$org/([^/]+)/pull/([[:digit:]]+) ]] ||
    [[ "$companion_expr" =~ ^$org/([^#]+)#([[:digit:]]+) ]] ||
    [[ "$companion_expr" =~ ^([^#]+)#([[:digit:]]+) ]]; then
    companion_repo="${BASH_REMATCH[1]}"
    pr_number="${BASH_REMATCH[2]}"
    echo "Parsed companion_repo=$companion_repo and pr_number=$pr_number from $companion_expr (trying to match companion_repo=$dependent_repo)"
  else
    die "Companion PR description had invalid format or did not belong to organization $org: $companion_expr"
  fi

  if [ "$companion_repo" != "$dependent_repo" ]; then
    return
  fi

  was_companion_found=true

  read -r mergeable pr_head_ref pr_head_sha < <(curl \
      -sSL \
      "$api_base/repos/$org/$companion_repo/pulls/$pr_number" | \
    "$jq" -r "\(mergeable) \(.head.ref) \(.head.sha)"
  )

  local expected_mergeable=true
  if [ "$mergeable" != "$expected_mergeable" ]; then
    die "Github API says ${companion_repo}'s PR $pr_number is not mergeable"
  fi

  git clone --depth 1 "https://github.com/$org/$companion_repo.git"
  pushd "$companion_repo" >/dev/null
  git fetch origin "pull/$pr_number/head:$pr_head_ref"
  git checkout "$pr_head_sha"

  echo "running checks for the companion $companion_expr of $companion_repo"
  patch_and_check_dependent

  popd >/dev/null
}

main() {
  discover_our_crates

  if [[ "$CI_COMMIT_REF_NAME" =~ ^[[:digit:]]+$ ]]; then
    echo "this is pull request number $CI_COMMIT_REF_NAME"

    # workaround for early exits not being detected in command substitution
    # https://unix.stackexchange.com/questions/541969/nested-command-substitution-does-not-stop-a-script-on-a-failure-even-if-e-and-s
    local last_line
    while IFS= read -r line; do
      echo "$line"
      last_line="$line"
      if ! [[ "$line" =~ [cC]ompanion:[[:space:]]*(.+) ]]; then
        continue
      fi

      echo "detected companion in PR description: ${BASH_REMATCH[1]}"
      process_companion_pr "${BASH_REMATCH[1]}"
    done < <(curl \
        -sSL \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        "$api_base/$this_repo/pulls/$CI_COMMIT_REF_NAME" | \
      "$jq" -r ".body"
    )
    if [ -z "${last_line+_}" ]; then
      die "No lines were read for the description of PR $pr_number (some error probably occurred)"
    fi
  fi

  if [ "${was_companion_found:-}" ]; then
    exit
  fi

  echo "running checks for the default branch of $dependent_repo"

  git clone --depth 1 "https://github.com/$org/$dependent_repo.git"
  pushd "$dependent_repo" >/dev/null

  patch_and_check_dependent

  popd >/dev/null
}
main
