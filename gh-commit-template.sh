#!/usr/bin/env bash

# Commit + push helper that ONLY uses staged changes.
# - Does NOT run `git add`.
# - If nothing is staged, exits early.
# - Uses AI (if available) on the staged diff to suggest a commit message.

NO_AI=false

# Parse flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-ai)
      NO_AI=true
      shift
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: gacp [--no-ai]"
      exit 1
      ;;
  esac
done

echo "[gacp] Starting..."

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "[gacp] Not in a git repo."
  exit 1
fi

# Use ONLY staged changes
DIFF=$(git diff --cached)

if [ -z "$DIFF" ]; then
  echo "[gacp] No staged changes to commit."
  echo "[gacp] Please 'git add' the files you want to commit, then run this again."
  exit 1
fi

SUGGESTED_SUBJECT=""
SUGGESTED_BODY=""

echo "[gacp] NO_AI=${NO_AI}"

# ---------- AI block ----------
if [[ "$NO_AI" = false && -n "${OPENAI_API_KEY:-}" ]]; then
  if ! command -v jq >/dev/null 2>&1; then
    echo "[gacp] jq not found, skipping AI."
  elif ! command -v curl >/dev/null 2>&1; then
    echo "[gacp] curl not found, skipping AI."
  else
    echo "[gacp] Generating commit message with AI (using staged diff)..."
    SHORT_DIFF=$(printf "%s" "$DIFF" | head -c 12000)

    # Build the JSON request body safely with jq so $SHORT_DIFF is properly escaped
    REQUEST_JSON=$(jq -n --arg diff "$SHORT_DIFF" '
      {
        model: "gpt-4.1-mini",
        messages: [
          {
            role: "system",
            content: "You write concise, conventional Git commit messages. Output a short subject line, then a blank line, then an optional body."
          },
          {
            role: "user",
            content: ("Generate a commit message for this git diff:\n\n" + $diff)
          }
        ]
      }
    ')

    AI_RESPONSE=$(printf "%s" "$REQUEST_JSON" | curl -s https://api.openai.com/v1/chat/completions \
      -H "Authorization: Bearer $OPENAI_API_KEY" \
      -H "Content-Type: application/json" \
      -d @-)

    CURL_STATUS=$?

    echo "[gacp] curl exit status: $CURL_STATUS"

    if [ $CURL_STATUS -ne 0 ] || [ -z "$AI_RESPONSE" ]; then
      echo "[gacp] AI request failed or empty response. Falling back to manual."
    else
      DEBUG_FILE="/tmp/gacp-ai-response.json"
      printf "%s" "$AI_RESPONSE" > "$DEBUG_FILE"
      echo "[gacp] Raw AI response saved to: $DEBUG_FILE"

      # Try multiple known shapes, including error payloads
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

      JQ_STATUS=$?
      echo "[gacp] jq exit status: $JQ_STATUS"
      echo "[gacp] Parsed FULL_MSG (first 120 chars): $(printf '%s' "$FULL_MSG" | head -c 120)"

      if [ $JQ_STATUS -ne 0 ] || [ -z "$FULL_MSG" ]; then
        echo "[gacp] Failed to extract useful text from AI response. Falling back to manual."
      elif [[ "$FULL_MSG" == ERROR_FROM_API:* ]]; then
        echo "[gacp] OpenAI API error: ${FULL_MSG#ERROR_FROM_API: }"
        echo "[gacp] Falling back to manual."
      else
        SUGGESTED_SUBJECT=$(printf "%s" "$FULL_MSG" | head -n1)
        SUGGESTED_BODY=$(printf "%s" "$FULL_MSG" | tail -n +2)
        SUGGESTED_BODY=$(printf "%s" "$SUGGESTED_BODY" | sed '1{/^$/d;}')
        echo "[gacp] AI suggestion parsed successfully."
      fi
    fi
  fi
else
  echo "[gacp] AI disabled (NO_AI=${NO_AI}, OPENAI_API_KEY set? $( [ -n "${OPENAI_API_KEY:-}" ] && echo yes || echo no ))"
fi
# ---------- end AI block ----------

echo "[gacp] After AI block. Suggested subject: '${SUGGESTED_SUBJECT}'"

# If we have an AI suggestion, show it and ask whether to use it
if [[ -n "$SUGGESTED_SUBJECT" ]]; then
  echo
  echo "===== AI suggested commit message ====="
  echo "$SUGGESTED_SUBJECT"
  if [[ -n "$SUGGESTED_BODY" ]]; then
    echo
    echo "$SUGGESTED_BODY"
  fi
  echo "======================================="
  echo

  read -r -p "Use this AI-generated commit message? [Y/n] " USE_AI
  USE_AI=${USE_AI:-Y}

  if [[ "$USE_AI" == "Y" || "$USE_AI" == "y" ]]; then
    echo "[gacp] Using AI-generated message."
    if [[ -n "$SUGGESTED_BODY" ]]; then
      git commit -m "$SUGGESTED_SUBJECT" -m "$SUGGESTED_BODY"
    else
      git commit -m "$SUGGESTED_SUBJECT"
    fi
    BRANCH=$(git rev-parse --abbrev-ref HEAD)
    echo
    echo "[gacp] Pushing branch '$BRANCH'..."
    git push -u origin "$BRANCH"
    echo "[gacp] Done."
    exit 0
  fi

  echo "[gacp] User declined AI message; going manual."
fi

# Manual path: prompt for subject/body
echo
read -r -p "Commit subject: " SUBJECT
while [[ -z "$SUBJECT" ]]; do
  echo "Commit subject is required."
  read -r -p "Commit subject: " SUBJECT
done

echo
echo "Commit body (optional, end with Ctrl+D):"
BODY=$(</dev/stdin || true)

if [[ -n "$BODY" ]]; then
  git commit -m "$SUBJECT" -m "$BODY"
else
  git commit -m "$SUBJECT"
fi

BRANCH=$(git rev-parse --abbrev-ref HEAD)
echo
echo "[gacp] Pushing branch '$BRANCH'..."
git push -u origin "$BRANCH"
echo "[gacp] Done."