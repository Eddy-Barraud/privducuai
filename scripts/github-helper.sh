#!/bin/bash

# Privducai GitHub Helper Script
# This script helps with common GitHub operations

set -e

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
REPO_OWNER="${REPO_OWNER:-eddybarraud}"
REPO_NAME="${REPO_NAME:-Privducai}"
MAIN_BRANCH="${MAIN_BRANCH:-main}"

# Functions
print_menu() {
  echo -e "${BLUE}=== Privducai GitHub Helper ===${NC}"
  echo ""
  echo "1. Check build status"
  echo "2. View recent commits"
  echo "3. Create feature branch"
  echo "4. Check repository stats"
  echo "5. Exit"
  echo ""
}

check_build_status() {
  echo -e "${YELLOW}Checking build status...${NC}"
  
  # Check if gh CLI is installed
  if ! command -v gh &> /dev/null; then
    echo -e "${RED}GitHub CLI (gh) is not installed.${NC}"
    echo "Install it with: brew install gh"
    return 1
  fi
  
  # Get latest workflow run
  gh run list --repo "$REPO_OWNER/$REPO_NAME" --limit 1 --json status,conclusion,name,createdAt --template '{{range .}}Status: {{.status}} | Conclusion: {{.conclusion}} | {{.name}} ({{.createdAt}}){{"\n"}}{{end}}'
}

view_recent_commits() {
  echo -e "${YELLOW}Recent commits:${NC}"
  git log -10 --oneline --graph --decorate
}

create_feature_branch() {
  echo -n "Enter branch name (e.g., feature/my-feature): "
  read -r branch_name
  
  if [ -z "$branch_name" ]; then
    echo -e "${RED}Branch name cannot be empty.${NC}"
    return 1
  fi
  
  echo -e "${YELLOW}Creating branch: $branch_name${NC}"
  git checkout -b "$branch_name" "$MAIN_BRANCH"
  echo -e "${GREEN}✓ Branch created and switched!${NC}"
}

check_repo_stats() {
  echo -e "${YELLOW}Repository Statistics:${NC}"
  echo ""
  
  # Get commit count
  COMMIT_COUNT=$(git rev-list --count HEAD)
  echo -e "Total Commits: ${GREEN}$COMMIT_COUNT${NC}"
  
  # Get branch count
  BRANCH_COUNT=$(git branch -r | wc -l)
  echo -e "Remote Branches: ${GREEN}$BRANCH_COUNT${NC}"
  
  # Get file count
  FILE_COUNT=$(find . -type f -not -path './.git/*' -not -path './.DS_Store' | wc -l)
  echo -e "Total Files: ${GREEN}$FILE_COUNT${NC}"
  
  # Get repo size
  REPO_SIZE=$(du -sh .git | cut -f1)
  echo -e ".git Size: ${GREEN}$REPO_SIZE${NC}"
  
  # Get current branch
  CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
  echo -e "Current Branch: ${GREEN}$CURRENT_BRANCH${NC}"
  
  # Check git status
  echo ""
  echo -e "${YELLOW}Working Directory Status:${NC}"
  git status --short | head -5
}

# Main loop
while true; do
  print_menu
  
  read -p "Select an option: " choice
  echo ""
  
  case $choice in
    1)
      check_build_status
      ;;
    2)
      view_recent_commits
      ;;
    3)
      create_feature_branch
      ;;
    4)
      check_repo_stats
      ;;
    5)
      echo -e "${GREEN}Goodbye!${NC}"
      exit 0
      ;;
    *)
      echo -e "${RED}Invalid option. Please try again.${NC}"
      ;;
  esac
  
  echo ""
  read -p "Press Enter to continue..."
done
