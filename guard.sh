#!/usr/bin/env bash
# Enforce agent guardrails on every repo in an org (works on GitHub Free):
#  - public repos: rulesets blocking force push and deletion on all branches and tags
#  - every repo: drop the bot's direct Admin grant (repo creators get Admin, which
#    could edit repo rulesets); the bot keeps the org base permission (Write).
# Needs GH_TOKEN with Administration read/write on the org's repos.
set -euo pipefail
ORG="${ORG:?set ORG}"; BOT="${BOT:?set BOT}"; ONLY_REPO="${1:-}"
fail=0

ruleset() { # name target
  jq -n --arg name "$1" --arg target "$2" '{
    name: $name, target: $target, enforcement: "active", bypass_actors: [],
    conditions: {ref_name: {include: ["~ALL"], exclude: []}},
    rules: [{type: "deletion"}, {type: "non_fast_forward"}]}'
}

ensure_ruleset() { # repo name target
  local repo=$1 name=$2 target=$3 id
  id=$(gh api "repos/$ORG/$repo/rulesets?includes_parents=false" --jq ".[] | select(.name==\"$name\") | .id" | head -1)
  if [ -n "$id" ]; then
    ruleset "$name" "$target" | gh api -X PUT "repos/$ORG/$repo/rulesets/$id" --input - >/dev/null
  else
    ruleset "$name" "$target" | gh api -X POST "repos/$ORG/$repo/rulesets" --input - >/dev/null
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
    ensure_ruleset "$name" agent-guard-branches branch || { echo "$name: branch ruleset FAILED"; fail=1; }
    ensure_ruleset "$name" agent-guard-tags tag || { echo "$name: tag ruleset FAILED"; fail=1; }
  fi
  direct=$(gh api "repos/$ORG/$name/collaborators?affiliation=direct&per_page=100" --jq ".[] | select(.login==\"$BOT\") | .role_name")
  if [ -n "$direct" ]; then
    gh api -X DELETE "repos/$ORG/$name/collaborators/$BOT" >/dev/null && echo "$name: removed direct $direct grant for $BOT" || { echo "$name: removing $BOT FAILED"; fail=1; }
  fi
done <<< "$repos"
exit $fail
