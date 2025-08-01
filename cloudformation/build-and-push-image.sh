#!/bin/bash

# DockerイメージのビルドとECRへのプッシュスクリプト

set -e

# 設定
PROJECT_NAME="deepwiki"
REGION="ap-northeast-1"
IMAGE_TAG="latest"
STACK_NAME="deepwiki-ecs"

# カラー出力用
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== DeepWiki Docker Image Build and Push ===${NC}"
echo "Project: $PROJECT_NAME"
echo "Region: $REGION"
echo "Image Tag: $IMAGE_TAG"
echo ""

# ECSスタックの存在確認
echo -e "${BLUE}Checking ECS stack...${NC}"
if ! aws cloudformation describe-stacks --stack-name $STACK_NAME --region $REGION >/dev/null 2>&1; then
    echo -e "${RED}Error: ECS stack '$STACK_NAME' not found.${NC}"
    echo "Please deploy the ECS stack first by running: ./deploy-ecs.sh"
    exit 1
fi

# ECRリポジトリURIの取得
ECR_URI=$(aws cloudformation describe-stacks \
    --stack-name $STACK_NAME \
    --region $REGION \
    --query 'Stacks[0].Outputs[?OutputKey==`ECRRepositoryURI`].OutputValue' \
    --output text)

if [ -z "$ECR_URI" ]; then
    echo -e "${RED}Error: Could not retrieve ECR repository URI${NC}"
    exit 1
fi

echo -e "${GREEN}✓ ECR Repository URI: $ECR_URI${NC}"
echo ""

# プロジェクトルートディレクトリに移動
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

if [ ! -f "$PROJECT_ROOT/Dockerfile" ]; then
    echo -e "${RED}Error: Dockerfile not found in project root: $PROJECT_ROOT${NC}"
    echo "Please ensure you're running this script from the cloudformation directory"
    exit 1
fi

echo -e "${BLUE}Project root: $PROJECT_ROOT${NC}"
cd "$PROJECT_ROOT"

# Dockerの動作確認
echo -e "${BLUE}Checking Docker...${NC}"
if ! docker --version >/dev/null 2>&1; then
    echo -e "${RED}Error: Docker is not installed or not running${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Docker is available${NC}"

# ECRにログイン
echo -e "${BLUE}Logging in to ECR...${NC}"
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $ECR_URI

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Successfully logged in to ECR${NC}"
else
    echo -e "${RED}Error: Failed to login to ECR${NC}"
    exit 1
fi

echo ""

# Dockerイメージのビルド
echo -e "${BLUE}Building Docker image...${NC}"
echo "This may take several minutes..."

docker buildx build --platform linux/amd64 -t $PROJECT_NAME:$IMAGE_TAG .

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Docker image built successfully${NC}"
else
    echo -e "${RED}Error: Failed to build Docker image${NC}"
    exit 1
fi

# イメージサイズの確認
echo ""
echo -e "${BLUE}Image Details:${NC}"
docker images $PROJECT_NAME:$IMAGE_TAG --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.CreatedAt}}"

echo ""

# イメージにタグ付け
echo -e "${BLUE}Tagging image for ECR...${NC}"
docker tag $PROJECT_NAME:$IMAGE_TAG $ECR_URI:$IMAGE_TAG

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Image tagged successfully${NC}"
else
    echo -e "${RED}Error: Failed to tag image${NC}"
    exit 1
fi

# ECRにプッシュ
echo -e "${BLUE}Pushing image to ECR...${NC}"
echo "This may take several minutes depending on image size and network speed..."

docker push $ECR_URI:$IMAGE_TAG

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Image pushed successfully to ECR${NC}"
else
    echo -e "${RED}Error: Failed to push image to ECR${NC}"
    exit 1
fi

echo ""

# ECRリポジトリの情報を表示
echo -e "${GREEN}=== ECR Repository Details ===${NC}"
aws ecr describe-images \
    --repository-name $PROJECT_NAME \
    --region $REGION \
    --query 'imageDetails[0].{ImageTags:imageTags[0],ImageSizeInBytes:imageSizeInBytes,ImagePushedAt:imagePushedAt}' \
    --output table

# ECSサービスの更新が必要かチェック
echo ""
echo -e "${BLUE}Checking ECS service...${NC}"

CLUSTER_NAME=$(aws cloudformation describe-stacks \
    --stack-name $STACK_NAME \
    --region $REGION \
    --query 'Stacks[0].Outputs[?OutputKey==`ECSClusterName`].OutputValue' \
    --output text)

SERVICE_NAME=$(aws cloudformation describe-stacks \
    --stack-name $STACK_NAME \
    --region $REGION \
    --query 'Stacks[0].Outputs[?OutputKey==`ECSServiceName`].OutputValue' \
    --output text)

if [ -n "$CLUSTER_NAME" ] && [ -n "$SERVICE_NAME" ]; then
    echo "Cluster: $CLUSTER_NAME"
    echo "Service: $SERVICE_NAME"
    
    # サービスの現在の状態を確認
    CURRENT_TASK_DEF=$(aws ecs describe-services \
        --cluster $CLUSTER_NAME \
        --services $SERVICE_NAME \
        --region $REGION \
        --query 'services[0].taskDefinition' \
        --output text)
    
    echo "Current Task Definition: $CURRENT_TASK_DEF"
    
    echo ""
    echo -e "${YELLOW}To deploy the new image to ECS, you have two options:${NC}"
    echo ""
    echo "1. Force new deployment (recommended for testing):"
    echo "   aws ecs update-service --cluster $CLUSTER_NAME --service $SERVICE_NAME --force-new-deployment --region $REGION"
    echo ""
    echo "2. Update the ECS stack with a new image tag:"
    echo "   ./deploy-ecs.sh  # (will prompt for API keys again)"
    echo ""
    
    read -p "Would you like to force a new deployment now? (y/N): " -n 1 -r
    echo ""
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${BLUE}Forcing new deployment...${NC}"
        aws ecs update-service \
            --cluster $CLUSTER_NAME \
            --service $SERVICE_NAME \
            --force-new-deployment \
            --region $REGION \
            --output table
        
        echo -e "${GREEN}✓ New deployment initiated${NC}"
        echo "You can monitor the deployment progress in the AWS Console or using:"
        echo "aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME --region $REGION"
    fi
fi

echo ""
echo -e "${GREEN}=== Docker Build and Push Complete ===${NC}"
echo ""
echo "Summary:"
echo "  ✓ Docker image built successfully"
echo "  ✓ Image pushed to ECR: $ECR_URI:$IMAGE_TAG"
echo "  ✓ Ready for ECS deployment"

# ローカルイメージのクリーンアップ（オプション）
echo ""
read -p "Would you like to remove the local Docker images to save space? (y/N): " -n 1 -r
echo ""

if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${BLUE}Cleaning up local images...${NC}"
    docker rmi $PROJECT_NAME:$IMAGE_TAG $ECR_URI:$IMAGE_TAG 2>/dev/null || true
    echo -e "${GREEN}✓ Local images cleaned up${NC}"
fi