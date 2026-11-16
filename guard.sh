#!/usr/bin/env bash
# Enforce agent guardrails on every repo in an org (works on GitHub Free):
#  - public repos: rulesets blocking force push and deletion on the default branch and all tags,
#    and requiring a PR (no approval) for the default branch, which org owners may bypass
#  - every repo: drop the bot's direct Admin grant (repo creators get Admin, which
#    could edit repo rulesets); the bot keeps the org base permission (Write).
# Needs GH_TOKEN with Administration read/write on the org's repos.
set -euo pipefail
ORG="${ORG:?set ORG}"; BOT="${BOT:?set BOT}"; ONLY_REPO="${1:-}"
fail=0

ruleset() { # name
  case "$1" in
    agent-guard-branches) # default branch: no force push or deletion, no bypass
      jq -n '{name: "agent-guard-branches", target: "branch", enforcement: "active", bypass_actors: [],
        conditions: {ref_name: {include: ["~DEFAULT_BRANCH"], exclude: []}},
        rules: [{type: "deletion"}, {type: "non_fast_forward"}]}' ;;
    agent-guard-tags) # all tags: no moving or deletion, no bypass
      jq -n '{name: "agent-guard-tags", target: "tag", enforcement: "active", bypass_actors: [],
        conditions: {ref_name: {include: ["~ALL"], exclude: []}},
        rules: [{type: "deletion"}, {type: "non_fast_forward"}]}' ;;
    agent-guard-pr) # default branch: changes go through a PR (no approval needed); org owners may push directly
      jq -n '{name: "agent-guard-pr", target: "branch", enforcement: "active",
        bypass_actors: [{actor_id: 1, actor_type: "OrganizationAdmin", bypass_mode: "always"}],
        conditions: {ref_name: {include: ["~DEFAULT_BRANCH"], exclude: []}},
        rules: [{type: "pull_request", parameters: {required_approving_review_count: 0,
          dismiss_stale_reviews_on_push: false, require_code_owner_review: false,
          require_last_push_approval: false, required_review_thread_resolution: false}}]}' ;;
  esac
}

# True if every value in the wanted ruleset matches the existing one. Fields GitHub
# adds on its own (ids, extra pull_request defaults) are ignored, and owner bypass
# entries are compared by type and mode only (GitHub may not echo their actor_id).
matches() { # want have
  jq -n --argjson w "$1" --argjson h "$2" '
    def norm: if (.bypass_actors|type) == "array"
      then .bypass_actors |= map(if .actor_type == "OrganizationAdmin" then del(.actor_id) else . end) else . end;
    def sub($w; $h):
      if ($w|type) == "object" then ($h|type) == "object" and all($w|keys[]; . as $k | sub($w[$k]; $h[$k]))
      elif ($w|type) == "array" then ($h|type) == "array" and ($w|length) == ($h|length)
        and all(range($w|length); . as $i | sub($w[$i]; $h[$i]))
      else $w == $h end;
    sub($w|norm; $h|norm)' | grep -qx true
}

ensure_ruleset() { # repo name existing-list-json
  local repo=$1 name=$2 list=$3 id want have
  want=$(ruleset "$name")
  id=$(jq -r --arg n "$name" '.[] | select(.name == $n) | .id' <<< "$list" | head -1)
  if [ -z "$id" ]; then
    gh api -X POST "repos/$ORG/$repo/rulesets" --input - <<< "$want" >/dev/null || return 1
    echo "$repo: added ruleset $name"
    return
  fi
  have=$(gh api "repos/$ORG/$repo/rulesets/$id") || return 1
  if ! matches "$want" "$have"; then
    gh api -X PUT "repos/$ORG/$repo/rulesets/$id" --input - <<< "$want" >/dev/null || return 1
    echo "$repo: restored ruleset $name (was: $(jq -c '{enforcement, bypass_actors, conditions, rules}' <<< "$have"))"
  fi
}

if [ -n "$ONLY_REPO" ]; then
  repos=$(gh api "repos/$ORG/$ONLY_REPO" --jq '"\(.name) \(.visibility) \(.archived)"')
else
  repos=$(gh api --paginate "orgs/$ORG/repos?per_page=100&type=all" --jq '.[] | "\(.name) \(.visibility) \(.archived)"')
fi

while read -r name vis archived; do
  [ -z "$name" ] && continue
  [ "$archived" = true ] && continue
  if [ "$vis" = public ]; then
    list=$(gh api "repos/$ORG/$name/rulesets?includes_parents=false") || { echo "$name: listing rulesets FAILED"; fail=1; list=""; }
    if [ -n "$list" ]; then
      for rs in agent-guard-branches agent-guard-tags agent-guard-pr; do
        ensure_ruleset "$name" "$rs" "$list" || { echo "$name: $rs FAILED"; fail=1; }
      done
    fi
  fi
  direct=$(gh api "repos/$ORG/$name/collaborators?affiliation=direct&per_page=100" --jq ".[] | select(.login==\"$BOT\") | .role_name")
  if [ -n "$direct" ]; then
    gh api -X DELETE "repos/$ORG/$name/collaborators/$BOT" >/dev/null && echo "$name: removed direct $direct grant for $BOT" || { echo "$name: removing $BOT FAILED"; fail=1; }
  fi
done <<< "$repos"
exit $fail
