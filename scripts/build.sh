#!/bin/bash

# Privducai Build Script
# This script builds the Privducai macOS application

set -e

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
BUILD_SCHEME="Privducai"
BUILD_PROJECT="Privducai.xcodeproj"
BUILD_CONFIGURATION="${1:-Debug}"
BUILD_DESTINATION="${2:-generic/platform=macOS}"

echo -e "${YELLOW}Building Privducai...${NC}"
echo "Scheme: $BUILD_SCHEME"
echo "Configuration: $BUILD_CONFIGURATION"
echo "Destination: $BUILD_DESTINATION"
echo ""

# Navigate to project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

# Build
if xcodebuild \
  -project "$BUILD_PROJECT" \
  -scheme "$BUILD_SCHEME" \
  -configuration "$BUILD_CONFIGURATION" \
  -destination "$BUILD_DESTINATION" \
  build; then
  echo -e "${GREEN}✓ Build successful!${NC}"
  exit 0
else
  echo -e "${RED}✗ Build failed!${NC}"
  exit 1
fi
