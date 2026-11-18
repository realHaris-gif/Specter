#!/usr/bin/env bash
set -e
echo "Bootstrapping Specter development environment..."

# Python virtual environment for reference lab
python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
if [ -f "lab/requirements.txt" ]; then
    pip install -r lab/requirements.txt
fi

# Run Swift tests if Swift is available
if command -v swift &> /dev/null; then
    echo "Running Swift tests..."
    cd core/SpecterCore && swift test && cd ../..
fi

echo "Bootstrap complete!"
