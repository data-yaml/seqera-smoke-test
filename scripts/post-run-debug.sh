#!/bin/bash
# Debug post-run script - prints all environment variables
echo "=========================================="
echo "Post-Run Script Debug - Environment Variables"
echo "=========================================="
echo ""
echo "All NXF_* variables:"
env | grep "^NXF_" | sort
echo ""
echo "All params* variables:"
env | grep -i "^params" | sort
echo ""
echo "All environment variables:"
env | sort
echo ""
echo "=========================================="
