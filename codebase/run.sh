#!/bin/bash
# KeyRemapper — launch script
# Usage: ./run.sh [port]

cd "$(dirname "$0")"

# Compile Swift helper if needed
if [ ! -f keyboard_layout ] || [ keyboard_layout.swift -nt keyboard_layout ]; then
    echo "Compiling keyboard layout helper…"
    swiftc keyboard_layout.swift -o keyboard_layout 2>&1
    if [ $? -ne 0 ]; then
        echo "Error: Failed to compile Swift helper."
        exit 1
    fi
fi

# Start the server
python3 app.py "${1:-5173}"
