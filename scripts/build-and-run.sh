#!/bin/bash

# Privducai Build and Run Script
# This script builds and runs the Privducai macOS application

set -e

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

BUILD_SCHEME="Privducai"
BUILD_PROJECT="Privducai.xcodeproj"
BUILD_CONFIGURATION="${1:-Debug}"

echo -e "${YELLOW}Building and running Privducai...${NC}"

# Navigate to project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

# Build and run
if xcodebuild \
  -project "$BUILD_PROJECT" \
  -scheme "$BUILD_SCHEME" \
  -configuration "$BUILD_CONFIGURATION" \
  -destination "generic/platform=macOS" \
  build; then
  
  echo -e "${GREEN}✓ Build successful!${NC}"
  echo -e "${YELLOW}Launching app...${NC}"
  
  # Find and run the built app
  APP_PATH="build/$BUILD_CONFIGURATION/$BUILD_SCHEME.app"
  if [ -d "$APP_PATH" ]; then
    open "$APP_PATH"
    echo -e "${GREEN}✓ App launched!${NC}"
  else
    echo -e "${YELLOW}App not found at expected location, opening project in Xcode...${NC}"
    open "$PROJECT_ROOT/$BUILD_PROJECT"
  fi
else
  echo -e "${RED}✗ Build failed!${NC}"
  exit 1
fi
