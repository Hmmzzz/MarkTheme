#!/bin/bash
set -e

# Build the packages
echo "Building packages..."
make package-all

# Extract version from Config.mk
VERSION=$(grep "PACKAGE_VERSION ?=" Config.mk | awk '{print $3}')

# Check if gh CLI is installed
if ! command -v gh &> /dev/null; then
    echo "GitHub CLI (gh) could not be found. Please install it to push releases."
    exit 1
fi

echo "Creating GitHub release for version $VERSION..."

# Find the generated deb files
DEB_FILES=$(find packages -name "*.deb" -type f)

if [ -z "$DEB_FILES" ]; then
    echo "No .deb files found in packages directory!"
    exit 1
fi

# Create a release and upload assets
gh release create "v$VERSION" \
    --title "MarkTheme64e v$VERSION" \
    --notes "Automated release of MarkTheme64e version $VERSION." \
    $DEB_FILES

echo "Release successfully published!"
