#!/bin/bash

# Enable error handling
set -e

echo "Starting deployment process..."

# Login to ECR
echo "Logging into ECR..."
aws ecr get-login-password --region us-east-2 | docker login --username AWS --password-stdin 878239241975.dkr.ecr.us-east-2.amazonaws.com

# Change to the correct directory
echo "Changing to project directory..."
cd /home/ubuntu/pnut-code/

# Stop existing containers
echo "Stopping existing containers..."
docker compose down

# Pull new images
echo "Pulling new images..."
docker compose pull --ignore-pull-failures

# Start containers
echo "Starting containers..."
docker compose up -d

# Clean up unused images
echo "Cleaning up unused images..."
docker system prune -f

echo "Deployment completed!"
