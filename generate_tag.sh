#!/bin/bash
set -e

REGION="us-east-2"

declare -A REPOS=(
  ["theomnilife-frontend-dummy"]="FRONTEND_TAG"
  ["reportautomationbackend-dummy"]="BACKEND_TAG"
  ["theomnilifecoreapi-dummy"]="COREAPI_TAG"
  ["omnilife-tonguecapture-dummy"]="TONGUE_TAG"
  ["activity-dashboard"]="ACTIVITY_TAG"
)

> .env

for REPO in "${!REPOS[@]}"; do
  VAR_NAME="${REPOS[$REPO]}"
  echo "🔎 Fetching latest tag for $REPO..."

  LATEST_TAG=$(aws ecr list-images \
    --region "$REGION" \
    --repository-name "$REPO" \
    --filter tagStatus=TAGGED \
    --query 'imageIds[*].imageTag' \
    --output text | tr '\t' '\n' | grep '^test-[0-9]\{8\}-[0-9]\{4\}$' | sort | tail -n 1)

  if [ -z "$LATEST_TAG" ]; then
    echo "❌ No valid tag found for $REPO"
    exit 1
  fi

  echo "$VAR_NAME=$LATEST_TAG" >> .env
  echo "✅ $VAR_NAME=$LATEST_TAG"
done
