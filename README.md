# gh-org-guard

Free-plan guardrails for an org where agents work as a bot member.
Every 10 minutes (GitHub Actions, in a repo the bot can't reach), `guard.sh`:

- adds or restores rulesets on every public repo that block force pushes and
  deletion of all branches and tags (no bypass), and
- removes the bot's direct Admin grant on any repo (GitHub makes a repo's creator
  Admin), so the bot falls back to the org base permission (Write) and can't
  edit those rulesets.

Requires: org base permission Write, a `GUARD_TOKEN` secret (fine-grained,
resource owner = the org, all repositories, Administration read/write).

Run once by hand: `ORG=homura-ai BOT=meowc-at GH_TOKEN=... ./guard.sh [repo]`
