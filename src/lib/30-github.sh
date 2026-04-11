# ============================================================================
# MODULE: 30-github.sh
# GitHub integration: clone, push, PR, issues
# Source lines 11087-11192 of main-v2.7.3
# ============================================================================

cmd_github() {
  local sub="${1:-help}"; shift || true
  case "$sub" in
    status)
      git -C "${1:-.}" status 2>/dev/null || { err "Not a git repo"; return 1; }
      ;;
    commit)
      local msg="${*:-Auto-commit by AI CLI}"
      git add -A && git commit -m "$msg" && ok "Committed: $msg"
      ;;
    push)
      local branch; branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "${GITHUB_DEFAULT_BRANCH}")
      git push -u origin "$branch" && ok "Pushed to $branch"
      ;;
    pull)
      local branch; branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "${GITHUB_DEFAULT_BRANCH}")
      git pull origin "$branch" && ok "Pulled from $branch"
      ;;
    clone)
      [[ -z "${1:-}" ]] && { err "Usage: ai github clone <repo-url> [dir]"; return 1; }
      git clone "$1" "${2:-.}" && ok "Cloned: $1"
      ;;
    branch)
      local action="${1:-list}"; shift || true
      case "$action" in
        list)    git branch -a ;;
        new)     git checkout -b "${1:-feature/new}" && ok "Created branch: ${1:-feature/new}" ;;
        switch)  git checkout "${1:-main}" ;;
        delete)  git branch -d "${1:?branch name required}" ;;
        *) err "branch: list | new <name> | switch <name> | delete <name>" ;;
      esac
      ;;
    pr)
      # Create a PR via GitHub CLI if available, or print instructions
      if command -v gh &>/dev/null; then
        local title="${*:-PR by AI CLI}"
        gh pr create --title "$title" --body "Created by AI CLI v${VERSION}" && ok "PR created"
      else
        local branch; branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "feature")
        info "Install GitHub CLI (gh) to create PRs automatically"
        info "Or open: https://github.com/$(git remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]||;s/.git$//')/compare/${GITHUB_DEFAULT_BRANCH}...$branch"
      fi
      ;;
    issue)
      if command -v gh &>/dev/null; then
        case "${1:-list}" in
          list)   gh issue list ;;
          create) gh issue create --title "${2:-New Issue}" --body "${3:-}" ;;
          view)   gh issue view "${2:?issue number required}" ;;
          close)  gh issue close "${2:?issue number required}" ;;
          *)  gh issue list ;;
        esac
      else
        info "Install GitHub CLI (gh) for issue management"
        info "  Arch:   sudo pacman -S github-cli"
        info "  Ubuntu: sudo apt install gh"
      fi
      ;;
    log)
      git log --oneline --graph --decorate "${1:--20}" 2>/dev/null || git log --oneline -20
      ;;
    diff)
      git diff "${@}" 2>/dev/null || true
      ;;
    init)
      git init "${1:-.}" && ok "Initialized git repo in ${1:-.}"
      ;;
    token)
      if [[ -n "${1:-}" ]]; then
        GITHUB_TOKEN="$1"; save_config; ok "GitHub token saved"
      else
        echo "Token: ${GITHUB_TOKEN:-(not set)}"
      fi
      ;;
    user)
      if [[ -n "${1:-}" ]]; then
        GITHUB_USER="$1"; save_config; ok "GitHub user: $GITHUB_USER"
      else
        echo "User: ${GITHUB_USER:-(not set)}"
      fi
      ;;
    help|*)
      hdr "AI CLI — GitHub Integration (v2.5)"
      echo "  ai github status [dir]           Show git status"
      echo "  ai github commit \"<msg>\"          Stage all + commit"
      echo "  ai github push                   Push current branch"
      echo "  ai github pull                   Pull current branch"
      echo "  ai github clone <url> [dir]      Clone repo"
      echo "  ai github branch list/new/switch/delete"
      echo "  ai github pr [\"title\"]            Create pull request (needs gh)"
      echo "  ai github issue list/create/view/close"
      echo "  ai github log [-N]               Show recent commits"
      echo "  ai github diff [args]            Show diff"
      echo "  ai github init [dir]             Init new repo"
      echo "  ai github token <tok>            Save personal access token"
      echo "  ai github user <name>            Save GitHub username"
      ;;
  esac
}

# ════════════════════════════════════════════════════════════════════════════════
#  v2.5: RESEARCH PAPER SCRAPER — open-access only
#  Sources: arXiv, PubMed Central (PMC), bioRxiv, medRxiv, CORE, OpenAlex,
#           DOAJ, Semantic Scholar, Europe PMC
#  Citations: APA, MLA, Chicago, BibTeX, IEEE
# ════════════════════════════════════════════════════════════════════════════════
