#!/bin/bash

# Build script for PaceRunner
# Now using Swift Package for shared code - much simpler!

set -e  # Exit on error

IPHONE_DEVICE="iPhone 17"

echo "🧹 Cleaning..."
xcodebuild clean -quiet

echo "🔨 Building PaceRunner..."
xcodebuild -scheme "PaceRunner" \
  -destination "platform=iOS Simulator,name=$IPHONE_DEVICE" \
  build

echo "✅ Build complete!"
