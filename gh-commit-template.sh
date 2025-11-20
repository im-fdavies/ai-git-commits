#!/usr/bin/env bash

set -euo pipefail

NO_AI=false

# Simple logging (off by default; toggle with VERBOSE=1 in env if you want)
log() {
  if [ "${VERBOSE:-0}" -ge 1 ]; then
    echo "[gh-commit-template] $*"
  fi
}

# ---------------
# Arg parsing
# ---------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-ai)
      NO_AI=true
      shift
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: gh-commit-template [--no-ai]"
      exit 1
      ;;
  esac
done

# ---------------
# Preconditions
# ---------------

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Not in a git repo."
  exit 1
fi

STAGED_DIFF=$(git diff --cached)

if [[ -z "$STAGED_DIFF" ]]; then
  echo "No staged changes to commit."
  echo "Stage files with 'git add' and then run gh-commit-template again."
  exit 1
fi

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
log "Branch: $CURRENT_BRANCH"

SUGGESTED_SUBJECT=""
COMMIT_MSG=""

# ---------------
# AI commit subject (single line)
# ---------------

if [[ "$NO_AI" = false && -n "${OPENAI_API_KEY:-}" ]]; then
  log "Generating commit subject with AI..."

  SHORT_DIFF=$(printf "%s" "$STAGED_DIFF" | head -c 16000)

  REQUEST_JSON=$(jq -n --arg diff "$SHORT_DIFF" '
    {
      model: "gpt-4.1-mini",
      messages: [
        {
          "role": "system",
          "content": "You write extremely concise Git commit messages. Output a SINGLE short commit subject line ONLY, no body, no bullet points, no explanations. Use imperative mood (e.g. \"Add X\", \"Fix Y\", \"Update Z\"). Keep it under 70 characters. Do NOT include ticket IDs, usernames, file names, or version numbers unless they are central to the change. Do NOT mention tests, formatting, or refactors unless that is the main purpose of the commit."
        },
        {
          "role": "user",
          "content": ("Generate a single-line Git commit subject for the following staged diff:\n\n" + $diff)
        }
      ]
    }
  ')

  AI_RESPONSE=$(printf "%s" "$REQUEST_JSON" | curl -s https://api.openai.com/v1/chat/completions \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -H "Content-Type: application/json" \
    -d @-)

  CURL_STATUS=$?
  log "curl exit status: $CURL_STATUS"

  if [ $CURL_STATUS -eq 0 ] && [ -n "$AI_RESPONSE" ]; then
    DEBUG_FILE="/tmp/gh-commit-template-ai.json"
    printf "%s" "$AI_RESPONSE" > "$DEBUG_FILE"
    log "Raw AI response saved to: $DEBUG_FILE"

    FULL_MSG=$(printf "%s" "$AI_RESPONSE" | jq -r '
      if .choices and .choices[0].message and .choices[0].message.content then
        .choices[0].message.content
      elif .output and .output[0].content and .output[0].content[0].text then
        .output[0].content[0].text
      elif .error and .error.message then
        "ERROR_FROM_API: " + .error.message
      else
        ""
      end
    ' 2>/dev/null)

    log "Parsed AI text (first 120 chars): $(printf '%s' "$FULL_MSG" | head -c 120)"

    if [[ "$FULL_MSG" == ERROR_FROM_API:* ]]; then
      echo "OpenAI API error: ${FULL_MSG#ERROR_FROM_API: }"
      echo "Falling back to manual commit message."
    elif [[ -n "$FULL_MSG" ]]; then
      # Use first line, trimmed
      SUGGESTED_SUBJECT=$(printf "%s" "$FULL_MSG" | head -n1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    fi
  else
    echo "Failed to contact OpenAI API. Falling back to manual commit message."
  fi
fi

# ---------------
# Confirm / edit / manual message
# ---------------

if [[ -n "$SUGGESTED_SUBJECT" ]]; then
  echo "AI suggested commit message:"
  echo "  $SUGGESTED_SUBJECT"
  echo
  read -r -p "Use this commit message? [Y/n]: " USE_AI
  USE_AI="${USE_AI:-Y}"

  if [[ "$USE_AI" =~ ^[Yy]$ ]]; then
    COMMIT_MSG="$SUGGESTED_SUBJECT"
  else
    read -r -p "Commit message: " COMMIT_MSG
  fi
else
  read -r -p "Commit message: " COMMIT_MSG
fi

while [[ -z "$COMMIT_MSG" ]]; do
  echo "Commit message cannot be empty."
  read -r -p "Commit message: " COMMIT_MSG
done

# ---------------
# Commit & push
# ---------------

echo "Committing with message:"
echo "  $COMMIT_MSG"
git commit -m "$COMMIT_MSG"

echo "Pushing branch: $CURRENT_BRANCH"
git push -u origin "$CURRENT_BRANCH"