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

ensure_ruleset() { # repo name
  local repo=$1 name=$2 id
  id=$(gh api "repos/$ORG/$repo/rulesets?includes_parents=false" --jq ".[] | select(.name==\"$name\") | .id" | head -1)
  if [ -n "$id" ]; then
    ruleset "$name" | gh api -X PUT "repos/$ORG/$repo/rulesets/$id" --input - >/dev/null
  else
    ruleset "$name" | gh api -X POST "repos/$ORG/$repo/rulesets" --input - >/dev/null
    echo "$repo: added ruleset $name"
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
    for rs in agent-guard-branches agent-guard-tags agent-guard-pr; do
      ensure_ruleset "$name" "$rs" || { echo "$name: $rs FAILED"; fail=1; }
    done
  fi
  direct=$(gh api "repos/$ORG/$name/collaborators?affiliation=direct&per_page=100" --jq ".[] | select(.login==\"$BOT\") | .role_name")
  if [ -n "$direct" ]; then
    gh api -X DELETE "repos/$ORG/$name/collaborators/$BOT" >/dev/null && echo "$name: removed direct $direct grant for $BOT" || { echo "$name: removing $BOT FAILED"; fail=1; }
  fi
done <<< "$repos"
exit $fail
