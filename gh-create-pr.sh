#!/usr/bin/env bash

NO_AI=false
VERBOSITY=0  # 0 = quiet, 1 = info, 2 = debug

# ---------- Logging helpers ----------

log_info() {
  if [ "$VERBOSITY" -ge 1 ]; then
    echo "[gh-create-pr] $*"
  fi
}

log_debug() {
  if [ "$VERBOSITY" -ge 2 ]; then
    echo "[gh-create-pr][debug] $*"
  fi
}

# ---------- Helpers ----------

# Normalise Y/N-style answers to uppercase "Y" or "N"
normalize_yn() {
  local raw="$1"
  local upper
  upper=$(printf "%s" "$raw" | tr '[:lower:]' '[:upper:]')

  case "$upper" in
    Y|YES)
      echo "Y"
      ;;
    *)
      echo "N"
      ;;
  esac
}

# Detect whether tests are included based on changed file paths
detect_tests_from_files() {
  local files="$1"

  if [[ -z "$files" ]]; then
    echo "N"
    return
  fi

  # Matches:
  # - any path under test/, tests/, __tests__/
  # - *Test.php, *Tests.php
  # - *.test.(js/ts/jsx/tsx)
  # - *.spec.(js/ts/jsx/tsx)
  if printf "%s\n" "$files" | grep -E -q \
    '(^|/)(tests?|__tests__)/|Test\.php$|Tests\.php$|\.test\.(js|ts|jsx|tsx)$|\.spec\.(js|ts|jsx|tsx)$'
  then
    echo "Y"
  else
    echo "N"
  fi
}

# Auto-detect a sensible base branch
detect_base_branch() {
  if [[ -n "${PR_BASE_BRANCH:-}" ]]; then
    echo "$PR_BASE_BRANCH"
    return
  fi

  for candidate in develop main master; do
    if git show-ref --verify --quiet "refs/remotes/origin/$candidate"; then
      echo "$candidate"
      return
    fi
  done

  echo ""  # no obvious base
}

# ---------- Flag parsing ----------

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-ai)
      NO_AI=true
      shift
      ;;
    -v)
      VERBOSITY=1
      shift
      ;;
    -vv)
      VERBOSITY=2
      shift
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: gh-create-pr [--no-ai] [-v|-vv]"
      exit 1
      ;;
  esac
done

# ---------- Repo + branch ----------

log_info "Starting..."

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Not in a git repo."
  exit 1
fi

BRANCH=$(git rev-parse --abbrev-ref HEAD)
log_info "Current branch: $BRANCH"

# Jira ticket from branch (e.g. feature/FAB-62044-whatever)
if [[ "$BRANCH" =~ (FAB-[0-9]+) ]]; then
  TICKET="${BASH_REMATCH[1]}"
  log_info "Detected Jira ticket: $TICKET"
else
  echo "Could not detect Jira ticket from branch."
  read -r -p "Enter Jira ticket (e.g. FAB-62044): " TICKET
fi

JIRA_BASE_URL="${JIRA_BASE_URL:-https://immediateco.atlassian.net}"

# ---------- Base branch detection + confirmation ----------

AUTO_BASE_BRANCH=$(detect_base_branch)

BASE_BRANCH=""

if [[ -n "$AUTO_BASE_BRANCH" ]]; then
  echo "Base branch target: $AUTO_BASE_BRANCH"
  read -r -p "Is this the correct base branch for this PR? [Y/n]: " BASE_CONFIRM
  BASE_CONFIRM_LOWER=$(printf "%s" "$BASE_CONFIRM" | tr '[:upper:]' '[:lower:]')

  if [[ -z "$BASE_CONFIRM_LOWER" || "$BASE_CONFIRM_LOWER" == "y" || "$BASE_CONFIRM_LOWER" == "yes" ]]; then
    BASE_BRANCH="$AUTO_BASE_BRANCH"
  else
    read -r -p "Enter base branch name (without origin/, e.g. develop, main): " USER_BASE
    BASE_BRANCH="$USER_BASE"
  fi
else
  echo "Could not auto-detect a base branch (PR_BASE_BRANCH/develop/main/master)."
  read -r -p "Enter base branch for this PR (e.g. develop, main), or leave blank to diff vs HEAD: " USER_BASE
  BASE_BRANCH="$USER_BASE"
fi

# ---------- Compute diff + changed files ----------

CHANGED_FILES=""
DIFF=""
SHORT_DIFF=""

if [[ -n "$BASE_BRANCH" ]]; then
  if git show-ref --verify --quiet "refs/remotes/origin/$BASE_BRANCH"; then
    BASE_REF="origin/$BASE_BRANCH"
    log_info "Using base branch: $BASE_BRANCH (remote: $BASE_REF)"
    DIFF_RANGE="$BASE_REF...HEAD"
    CHANGED_FILES=$(git diff --name-only "$DIFF_RANGE")
    DIFF=$(git diff "$DIFF_RANGE")
  elif git show-ref --verify --quiet "refs/heads/$BASE_BRANCH"; then
    BASE_REF="$BASE_BRANCH"
    log_info "Using local base branch: $BASE_REF"
    DIFF_RANGE="$BASE_REF...HEAD"
    CHANGED_FILES=$(git diff --name-only "$DIFF_RANGE")
    DIFF=$(git diff "$DIFF_RANGE")
  else
    echo "Warning: base branch '$BASE_BRANCH' not found on origin or locally. Falling back to diff vs HEAD."
    DIFF_RANGE="HEAD"
    CHANGED_FILES=$(git diff --name-only)
    DIFF=$(git diff)
  fi
else
  log_info "No base branch provided; using diff vs HEAD."
  DIFF_RANGE="HEAD"
  CHANGED_FILES=$(git diff --name-only)
  DIFF=$(git diff)
fi

SHORT_DIFF=$(printf "%s" "$DIFF" | head -c 16000)

log_debug "Changed files list:"
log_debug "$CHANGED_FILES"

# Auto-detect tests
INCLUDES_TESTS=$(detect_tests_from_files "$CHANGED_FILES")
log_info "Auto-detected Includes Tests? -> $INCLUDES_TESTS"

# ---------- PR type + formatting flag ----------

echo
read -r -p "PR Type? (Feature/Bugfix) [F/B]: " PR_TYPE_INPUT
PR_TYPE_LOWER=$(printf "%s" "$PR_TYPE_INPUT" | tr '[:upper:]' '[:lower:]')

if [[ -z "$PR_TYPE_LOWER" || "$PR_TYPE_LOWER" == "f" || "$PR_TYPE_LOWER" == "feature" ]]; then
  PR_TYPE="Feature"
elif [[ "$PR_TYPE_LOWER" == "b" || "$PR_TYPE_LOWER" == "bug" || "$PR_TYPE_LOWER" == "bugfix" ]]; then
  PR_TYPE="Bugfix"
else
  PR_TYPE="$PR_TYPE_INPUT"
fi

read -r -p "Includes Formatting? (Y/N): " INCLUDES_FORMATTING_RAW
INCLUDES_FORMATTING=$(normalize_yn "$INCLUDES_FORMATTING_RAW")

AI_SUMMARY=""
AI_TITLE=""

# ---------- AI summary + title ----------

if [[ "$NO_AI" = false && -n "${OPENAI_API_KEY:-}" ]]; then
  echo "Generating AI summary and title (this may take a moment)..."

  # Summary
  REQUEST_JSON_SUMMARY=$(jq -n --arg diff "$SHORT_DIFF" '
    {
      model: "gpt-4.1-mini",
      messages: [
        {
          "role": "system",
          "content": "You are a senior engineer writing a concise and practical pull request description. Include two sections: Summary and Implementation details. Only include a Risks section if there are genuine, concrete risks relevant to reviewers. Avoid generic or obvious risks."
        },
        {
          "role": "user",
          "content": ("Generate a PR description for this git diff:\n\n" + $diff)
        }
      ]
    }
  ')

  AI_RESPONSE_SUMMARY=$(printf "%s" "$REQUEST_JSON_SUMMARY" | curl -s https://api.openai.com/v1/chat/completions \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -H "Content-Type: application/json" \
    -d @-)

  CURL_STATUS=$?
  log_debug "Summary curl status: $CURL_STATUS"

  if [ $CURL_STATUS -eq 0 ] && [ -n "$AI_RESPONSE_SUMMARY" ]; then
    DEBUG_FILE_SUM="/tmp/ghcreatepr-ai-summary.json"
    log_debug "Raw AI summary response saved to $DEBUG_FILE_SUM"
    printf "%s" "$AI_RESPONSE_SUMMARY" > "$DEBUG_FILE_SUM"

    FULL_MSG_SUMMARY=$(printf "%s" "$AI_RESPONSE_SUMMARY" | jq -r '
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

    log_debug "Parsed summary (first 120 chars): $(printf '%s' "$FULL_MSG_SUMMARY" | head -c 120)"

    if [[ "$FULL_MSG_SUMMARY" == ERROR_FROM_API:* ]]; then
      [ "$VERBOSITY" -ge 1 ] && echo "AI summary unavailable: ${FULL_MSG_SUMMARY#ERROR_FROM_API: }"
    elif [[ -n "$FULL_MSG_SUMMARY" ]]; then
      AI_SUMMARY="$FULL_MSG_SUMMARY"
      log_info "AI summary generated."
    fi
  else
    [ "$VERBOSITY" -ge 1 ] && echo "AI summary request failed; continuing without it."
  fi

  # Title (only if we have a summary)
  if [[ -n "$AI_SUMMARY" ]]; then
    log_info "Generating AI PR title from summary…"

    REQUEST_JSON_TITLE=$(jq -n --arg summary "$AI_SUMMARY" '
      {
        model: "gpt-4.1-mini",
        messages: [
          {
            "role": "system",
            "content": "You generate extremely short, human-readable pull request titles. Keep them under 80 characters where possible. Avoid marketing or hype language; be clear and factual."
          },
          {
            "role": "user",
            "content": ("Generate a concise PR title based on this summary:\n\n" + $summary)
          }
        ]
      }
    ')

    AI_RESPONSE_TITLE=$(printf "%s" "$REQUEST_JSON_TITLE" | curl -s https://api.openai.com/v1/chat/completions \
      -H "Authorization: Bearer $OPENAI_API_KEY" \
      -H "Content-Type: application/json" \
      -d @-)

    CURL_STATUS_TITLE=$?
    log_debug "Title curl status: $CURL_STATUS_TITLE"

    if [ $CURL_STATUS_TITLE -eq 0 ] && [ -n "$AI_RESPONSE_TITLE" ]; then
      DEBUG_FILE_TITLE="/tmp/ghcreatepr-ai-title.json"
      log_debug "Raw AI title response saved to $DEBUG_FILE_TITLE"
      printf "%s" "$AI_RESPONSE_TITLE" > "$DEBUG_FILE_TITLE"

      FULL_MSG_TITLE=$(printf "%s" "$AI_RESPONSE_TITLE" | jq -r '
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

      log_debug "Parsed title text (first 120 chars): $(printf '%s' "$FULL_MSG_TITLE" | head -c 120)"

      if [[ "$FULL_MSG_TITLE" == ERROR_FROM_API:* ]]; then
        [ "$VERBOSITY" -ge 1 ] && echo "AI title unavailable: ${FULL_MSG_TITLE#ERROR_FROM_API: }"
      elif [[ -n "$FULL_MSG_TITLE" ]]; then
        AI_TITLE=$(printf "%s" "$FULL_MSG_TITLE" | head -n1)
        log_info "AI suggested PR title: $AI_TITLE"
      fi
    else
      [ "$VERBOSITY" -ge 1 ] && echo "AI title request failed; continuing without AI title."
    fi
  fi
else
  log_info "AI disabled (NO_AI=$NO_AI); skipping summary/title generation."
fi

# ---------- PR title (with AI default if available) ----------

echo
if [[ -n "$AI_TITLE" ]]; then
  echo "AI suggested PR title: $AI_TITLE"
  read -r -p "PR title [leave blank to accept AI suggestion]: " PR_TITLE
  if [[ -z "$PR_TITLE" ]]; then
    PR_TITLE="$AI_TITLE"
  fi
else
  read -r -p "PR title: " PR_TITLE
  while [[ -z "$PR_TITLE" ]]; do
    echo "PR title is required."
    read -r -p "PR title: " PR_TITLE
  done
fi

# ---------- Human description prompt (after AI) ----------

echo
echo "Write your PR description / notes (optional, end with Ctrl+D):"
PR_DESCRIPTION_HUMAN=$(</dev/stdin || true)

# Combine descriptions:
# - Your notes (if any)
# - Blank line
# - AI summary (if any, no heading)
PR_DESCRIPTION="$PR_DESCRIPTION_HUMAN"

if [[ -n "$AI_SUMMARY" ]]; then
  if [[ -n "$PR_DESCRIPTION" ]]; then
    PR_DESCRIPTION+="

$AI_SUMMARY
"
  else
    PR_DESCRIPTION="$AI_SUMMARY"
  fi
fi

# ---------- Build final PR body ----------

PR_BODY=$(cat <<EOF
| Q                          | A
| -------------------------- | ---
| Jira Ticket                | [${TICKET}](${JIRA_BASE_URL}/browse/${TICKET})
| PR Type? (Feature/Bugfix)  | ${PR_TYPE}
| Includes Tests? (Y/N)      | ${INCLUDES_TESTS}
| Includes Formatting? (Y/N) | ${INCLUDES_FORMATTING}

Additional resources:
- [Coding Standards](https://immediateco.atlassian.net/wiki/spaces/TL/pages/5250998/Coding+standards)
- [Review Guidelines](https://immediateco.atlassian.net/wiki/spaces/TL/pages/5251007/Code+reviews)

${PR_DESCRIPTION}
EOF
)

echo
echo "===== PR TITLE ====="
echo "$PR_TITLE"
echo "===== PR BODY ====="
echo "$PR_BODY"
echo

read -r -p "Create PR? [Y/n] " CONFIRM
CONFIRM=${CONFIRM:-Y}

if [[ "$CONFIRM" != "Y" && "$CONFIRM" != "y" ]]; then
  log_info "Aborted."
  exit 0
fi

gh pr create \
  --title "$PR_TITLE" \
  --body "$PR_BODY"

log_info "Done."