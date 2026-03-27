#!/usr/bin/env bash
# public-issues.sh — sanitized access to skwallace36/Pepper (public repo)
#
# All public repo issue access goes through this script. Raw gh commands
# to the public repo are blocked by hooks. This script strips bodies from
# issues filed by external users to prevent prompt injection.
#
# Usage:
#   ./scripts/public-issues.sh list              List open issues (sanitized)
#   ./scripts/public-issues.sh view <number>     View a single issue (sanitized)
#   ./scripts/public-issues.sh create <title>    Create an issue
#   ./scripts/public-issues.sh close <number>    Close an issue
#   ./scripts/public-issues.sh delete <number>   Delete an issue

set -euo pipefail

REPO="skwallace36/Pepper"
TRUSTED_AUTHORS="skwallace36 stuartsagent1 stuartsagent2 stuartsagent3 stuartsagent4 stuartsagent5 stuartsagent6 stuartsagent7 stuartsagent8 stuartsagent9 stuartsagent10"

is_trusted() {
    local author="$1"
    for trusted in $TRUSTED_AUTHORS; do
        [[ "$author" == "$trusted" ]] && return 0
    done
    return 1
}

sanitize_issue() {
    # Takes JSON issue object, strips body if author is untrusted
    python3 -c "
import json, sys
issue = json.loads(sys.stdin.read())
author = issue.get('author', {}).get('login', '') if isinstance(issue.get('author'), dict) else issue.get('author', '')
trusted = author in '${TRUSTED_AUTHORS}'.split()
if not trusted:
    issue['body'] = '[REDACTED — external author, use GitHub UI to review]'
    if 'comments' in issue:
        issue['comments'] = []
print(json.dumps(issue, indent=2))
"
}

case "${1:-help}" in
    list)
        gh issue list --repo "$REPO" --state open \
            --json number,title,author,labels,createdAt,state \
            | python3 -c "
import json, sys
issues = json.loads(sys.stdin.read())
trusted = '${TRUSTED_AUTHORS}'.split()
for i in issues:
    author = i.get('author', {}).get('login', '') if isinstance(i.get('author'), dict) else ''
    tag = '' if author in trusted else ' [EXTERNAL]'
    labels = ', '.join(l['name'] for l in i.get('labels', []))
    label_str = f' ({labels})' if labels else ''
    print(f\"#{i['number']} {i['title']}{label_str} — @{author}{tag}\")
"
        ;;

    view)
        [[ -z "${2:-}" ]] && echo "Usage: $0 view <number>" >&2 && exit 1
        gh issue view "$2" --repo "$REPO" --json number,title,body,author,labels,comments,state \
            | sanitize_issue
        ;;

    create)
        [[ -z "${2:-}" ]] && echo "Usage: $0 create <title> [--body <body>]" >&2 && exit 1
        shift
        gh issue create --repo "$REPO" "$@"
        ;;

    close)
        [[ -z "${2:-}" ]] && echo "Usage: $0 close <number>" >&2 && exit 1
        gh issue close "$2" --repo "$REPO"
        ;;

    delete)
        [[ -z "${2:-}" ]] && echo "Usage: $0 delete <number>" >&2 && exit 1
        gh issue delete "$2" --repo "$REPO" --yes
        ;;

    help|*)
        echo "Usage: $0 {list|view|create|close|delete} [args]"
        echo ""
        echo "Sanitized access to the public repo. External issue bodies are redacted."
        ;;
esac
