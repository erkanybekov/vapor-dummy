#!/bin/bash

# Vapor Auth API Quick Start Script
# This script helps you get the application running quickly

set -e

echo "🚀 Vapor Auth API Quick Start"
echo "============================="
echo ""

# Check if .env exists
if [ ! -f .env ]; then
    echo "📝 Creating .env file from .env.example..."
    cp .env.example .env
    echo "✅ .env file created. Please edit it with your configuration."
    echo ""
fi

# Check Docker
if command -v docker &> /dev/null; then
    echo "🐳 Docker found. Starting PostgreSQL..."
    docker-compose up -d postgres
    echo "✅ PostgreSQL started on port 5432"
    echo ""
    
    # Wait for PostgreSQL to be ready
    echo "⏳ Waiting for PostgreSQL to be ready..."
    sleep 5
else
    echo "⚠️  Docker not found. Please ensure PostgreSQL is running locally."
    echo ""
fi

# Build the project
echo "🔨 Building the project..."
swift build

echo ""
echo "✅ Build complete!"
echo ""
echo "📦 Starting the server..."
echo "============================="
echo ""
echo "The server will start on http://localhost:8080"
echo ""
echo "Available endpoints:"
echo "  - GET  /health           - Health check"
echo "  - POST /api/auth/register - Register new user"
echo "  - POST /api/auth/login    - Login"
echo "  - GET  /api/auth/me       - Get current user (requires auth)"
echo "  - POST /api/auth/refresh  - Refresh token"
echo "  - POST /api/auth/logout   - Logout (requires auth)"
echo ""
echo "Press Ctrl+C to stop the server"
echo "============================="
echo ""

# Run the application
swift run
