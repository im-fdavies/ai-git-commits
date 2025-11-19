# Smart Git Helpers

AI-powered Git workflow automation tools for streamlined commits and pull requests.

## Quick Start

Run the setup script to install and configure everything:

```bash
./quickstart.sh
```

This will:
- Create symlinks for the helper scripts in `~/.local/bin` (or your chosen directory)
- Add the install directory to your PATH
- Check for required dependencies and optionally install them
- Configure environment variables (OpenAI API key, Jira base URL)
- Verify GitHub CLI authentication

After setup, reload your shell:

```bash
exec $SHELL -l
```

## Requirements

### Required Tools
- **git** - Version control
- **gh** - GitHub CLI (for PR creation)
- **jq** - JSON processor (for AI features)
- **curl** - HTTP client (for AI features)

On macOS with Homebrew:
```bash
brew install git gh jq curl
```

### GitHub Authentication
Authenticate with GitHub CLI:
```bash
gh auth login
```

## Environment Variables

### Required
- **JIRA_BASE_URL** - Your Jira instance URL
  - Default: `https://immediateco.atlassian.net`
  - Example: `export JIRA_BASE_URL="https://yourcompany.atlassian.net"`

### Optional
- **OPENAI_API_KEY** - OpenAI API key for AI-powered commit messages and PR descriptions
  - Required only if you want AI assistance
  - Get your key from: https://platform.openai.com/api-keys
  - Example: `export OPENAI_API_KEY="sk-..."`

- **PR_BASE_BRANCH** - Default base branch for PRs
  - If not set, auto-detects from: `develop`, `main`, or `master`
  - Example: `export PR_BASE_BRANCH="develop"`

## Available Commands

### gh-commit-template

AI-assisted commit and push workflow. Only commits staged changes.

**Usage:**
```bash
gh-commit-template [--no-ai]
```

**Arguments:**
- `--no-ai` - Skip AI commit message generation

**Behavior:**
1. Checks for staged changes (exits if none found)
2. Generates AI commit message suggestion from staged diff (if enabled)
3. Prompts to accept or write custom message
4. Commits and pushes to current branch

**Example:**
```bash
# Stage your changes first
git add src/feature.js

# Run the helper
gh-commit-template

# Or skip AI
gh-commit-template --no-ai
```

### gh-create-pr

Create GitHub pull requests with optional AI-generated summaries and titles.

**Usage:**
```bash
gh-create-pr [--no-ai] [-v|-vv]
```

**Arguments:**
- `--no-ai` - Skip AI summary and title generation
- `-v` - Verbose output (info level)
- `-vv` - Very verbose output (debug level)

**Behavior:**
1. Detects Jira ticket from branch name (e.g., `feature/FAB-12345-description`)
2. Auto-detects base branch (develop/main/master)
3. Computes diff and changed files
4. Auto-detects if tests are included
5. Generates AI summary and title (if enabled)
6. Prompts for PR metadata (type, formatting, title, description)
7. Creates PR with formatted body including Jira link and metadata table

**Example:**
```bash
# Create PR with AI assistance
gh-create-pr

# Create PR without AI
gh-create-pr --no-ai

# Debug mode
gh-create-pr -vv
```

**Branch Naming Convention:**
Your branch should include the Jira ticket ID:
- `feature/FAB-12345-add-user-auth`
- `bugfix/FAB-67890-fix-login-error`

## Features

### AI-Powered Assistance
When `OPENAI_API_KEY` is configured:
- **Commit messages**: Analyzes staged diff to suggest conventional commit messages
- **PR summaries**: Generates comprehensive PR descriptions with Summary, Implementation details, and Risks sections
- **PR titles**: Creates concise, descriptive PR titles (under 80 characters)

### Smart Detection
- **Base branch**: Auto-detects `develop`, `main`, or `master`
- **Jira tickets**: Extracts ticket ID from branch name
- **Test inclusion**: Detects test files in changed files:
  - Paths under `test/`, `tests/`, `__tests__/`
  - Files matching `*Test.php`, `*Tests.php`
  - Files matching `*.test.(js|ts|jsx|tsx)`, `*.spec.(js|ts|jsx|tsx)`

### PR Template
Generated PRs include:
- Metadata table (Jira ticket, PR type, tests, formatting)
- Links to coding standards and review guidelines
- Your custom description
- AI-generated summary (if enabled)

## Troubleshooting

### "No staged changes to commit"
Stage your files first:
```bash
git add <files>
gh-commit-template
```

### "gh is NOT authenticated"
Run GitHub authentication:
```bash
gh auth login
```

### AI features not working
1. Verify `OPENAI_API_KEY` is set: `echo $OPENAI_API_KEY`
2. Check API key is valid at https://platform.openai.com/api-keys
3. Ensure `jq` and `curl` are installed
4. Check debug files: `/tmp/gacp-ai-response.json`, `/tmp/ghcreatepr-ai-*.json`

### "Could not detect Jira ticket"
Ensure your branch name includes the ticket ID:
```bash
git checkout -b feature/FAB-12345-my-feature
```

## License

MIT
