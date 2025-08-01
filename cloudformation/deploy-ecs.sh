#!/bin/bash

# ECS (Elastic Container Service) のデプロイスクリプト

set -e

# 設定
STACK_NAME="deepwiki-ecs"
TEMPLATE_FILE="03-ecs.yaml"
PROJECT_NAME="deepwiki"
REGION="ap-northeast-1"

# カラー出力用
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== DeepWiki ECS Stack Deployment ===${NC}"
echo "Stack Name: $STACK_NAME"
echo "Template: $TEMPLATE_FILE"
echo "Project Name: $PROJECT_NAME"
echo "Region: $REGION"
echo ""

# 依存関係のチェック
echo -e "${BLUE}Checking dependencies...${NC}"

# VPCスタックのチェック
VPC_STACK_NAME="deepwiki-vpc-network"
if ! aws cloudformation describe-stacks --stack-name $VPC_STACK_NAME --region $REGION >/dev/null 2>&1; then
    echo -e "${RED}Error: VPC stack '$VPC_STACK_NAME' not found.${NC}"
    echo "Please deploy the VPC stack first by running: ./deploy-vpc.sh"
    exit 1
fi

VPC_STACK_STATUS=$(aws cloudformation describe-stacks --stack-name $VPC_STACK_NAME --region $REGION --query 'Stacks[0].StackStatus' --output text)
if [[ "$VPC_STACK_STATUS" != "CREATE_COMPLETE" && "$VPC_STACK_STATUS" != "UPDATE_COMPLETE" ]]; then
    echo -e "${RED}Error: VPC stack is in status: $VPC_STACK_STATUS${NC}"
    exit 1
fi
echo -e "${GREEN}✓ VPC stack dependency satisfied${NC}"

# EFSスタックのチェック
EFS_STACK_NAME="deepwiki-efs"
if ! aws cloudformation describe-stacks --stack-name $EFS_STACK_NAME --region $REGION >/dev/null 2>&1; then
    echo -e "${RED}Error: EFS stack '$EFS_STACK_NAME' not found.${NC}"
    echo "Please deploy the EFS stack first by running: ./deploy-efs.sh"
    exit 1
fi

EFS_STACK_STATUS=$(aws cloudformation describe-stacks --stack-name $EFS_STACK_NAME --region $REGION --query 'Stacks[0].StackStatus' --output text)
if [[ "$EFS_STACK_STATUS" != "CREATE_COMPLETE" && "$EFS_STACK_STATUS" != "UPDATE_COMPLETE" ]]; then
    echo -e "${RED}Error: EFS stack is in status: $EFS_STACK_STATUS${NC}"
    exit 1
fi
echo -e "${GREEN}✓ EFS stack dependency satisfied${NC}"

echo ""

# API キーの入力
echo -e "${BLUE}API Keys Configuration:${NC}"
echo "Please provide the required API keys for DeepWiki:"
echo ""

# OpenAI API Key (必須)
read -s -p "OpenAI API Key (required): " OPENAI_API_KEY
echo ""
if [ -z "$OPENAI_API_KEY" ]; then
    echo -e "${RED}Error: OpenAI API Key is required${NC}"
    exit 1
fi

# Google API Key (オプション)
read -s -p "Google API Key (optional, press Enter to skip): " GOOGLE_API_KEY
echo ""

# OpenRouter API Key (オプション)
read -s -p "OpenRouter API Key (optional, press Enter to skip): " OPENROUTER_API_KEY
echo ""

# Azure OpenAI (オプション)
read -s -p "Azure OpenAI API Key (optional, press Enter to skip): " AZURE_OPENAI_API_KEY
echo ""
if [ -n "$AZURE_OPENAI_API_KEY" ]; then
    read -p "Azure OpenAI Endpoint: " AZURE_OPENAI_ENDPOINT
    read -p "Azure OpenAI Version: " AZURE_OPENAI_VERSION
fi

echo ""

# ECS設定の確認
echo -e "${BLUE}ECS Configuration:${NC}"
echo "  ✓ Launch Type: Fargate"
echo "  ✓ CPU: 2048 (2 vCPU)"
echo "  ✓ Memory: 4096 MB (4 GB)"
echo "  ✓ Desired Count: 1"
echo "  ✓ Network: Public subnets with security group restrictions"
echo "  ✓ Auto Scaling: Enabled (1-10 instances)"
echo "  ✓ Container Insights: Enabled"
echo "  ✓ EFS Integration: Persistent storage"
echo "  ✓ Secrets Manager: API keys stored securely"
echo ""

# CIDR設定の確認
echo -e "${BLUE}Network Access Configuration:${NC}"
read -p "Enter CIDR block for allowed access (default: 0.0.0.0/0 for all): " ALLOWED_CIDR
if [ -z "$ALLOWED_CIDR" ]; then
    ALLOWED_CIDR="0.0.0.0/0"
fi
echo "Allowed CIDR: $ALLOWED_CIDR"
echo ""

# パラメータの構築
PARAMETERS="ParameterKey=ProjectName,ParameterValue=$PROJECT_NAME"
PARAMETERS="$PARAMETERS ParameterKey=OpenAIAPIKey,ParameterValue=$OPENAI_API_KEY"
PARAMETERS="$PARAMETERS ParameterKey=AllowedCIDR,ParameterValue=$ALLOWED_CIDR"

if [ -n "$GOOGLE_API_KEY" ]; then
    PARAMETERS="$PARAMETERS ParameterKey=GoogleAPIKey,ParameterValue=$GOOGLE_API_KEY"
fi

if [ -n "$OPENROUTER_API_KEY" ]; then
    PARAMETERS="$PARAMETERS ParameterKey=OpenRouterAPIKey,ParameterValue=$OPENROUTER_API_KEY"
fi

if [ -n "$AZURE_OPENAI_API_KEY" ]; then
    PARAMETERS="$PARAMETERS ParameterKey=AzureOpenAIAPIKey,ParameterValue=$AZURE_OPENAI_API_KEY"
    PARAMETERS="$PARAMETERS ParameterKey=AzureOpenAIEndpoint,ParameterValue=$AZURE_OPENAI_ENDPOINT"
    PARAMETERS="$PARAMETERS ParameterKey=AzureOpenAIVersion,ParameterValue=$AZURE_OPENAI_VERSION"
fi

# スタックが既に存在するかチェック
if aws cloudformation describe-stacks --stack-name $STACK_NAME --region $REGION >/dev/null 2>&1; then
    CURRENT_STATUS=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --region $REGION --query 'Stacks[0].StackStatus' --output text)
    echo -e "${YELLOW}Stack $STACK_NAME exists with status: $CURRENT_STATUS${NC}"
    
    if [[ "$CURRENT_STATUS" == "ROLLBACK_COMPLETE" || "$CURRENT_STATUS" == "CREATE_FAILED" ]]; then
        echo -e "${YELLOW}Deleting failed stack first...${NC}"
        aws cloudformation delete-stack --stack-name $STACK_NAME --region $REGION
        echo "Waiting for stack deletion..."
        aws cloudformation wait stack-delete-complete --stack-name $STACK_NAME --region $REGION
        echo -e "${GREEN}✓ Failed stack deleted successfully${NC}"
        
        # 新しいスタックを作成
        echo -e "${GREEN}Creating new stack...${NC}"
        aws cloudformation create-stack \
            --stack-name $STACK_NAME \
            --template-body file://$TEMPLATE_FILE \
            --parameters $PARAMETERS \
            --capabilities CAPABILITY_NAMED_IAM \
            --region $REGION
        
        echo "Waiting for stack creation to complete..."
        echo -e "${YELLOW}Note: ECS stack creation may take 5-10 minutes...${NC}"
        
        aws cloudformation wait stack-create-complete \
            --stack-name $STACK_NAME \
            --region $REGION
        
        echo -e "${GREEN}✓ Stack creation completed successfully!${NC}"
    else
        echo -e "${YELLOW}Updating existing stack...${NC}"
        
        # Change Setを作成
        CHANGE_SET_NAME="update-$(date +%Y%m%d-%H%M%S)"
        echo "Creating change set: $CHANGE_SET_NAME"
        
        aws cloudformation create-change-set \
            --stack-name $STACK_NAME \
            --change-set-name $CHANGE_SET_NAME \
            --template-body file://$TEMPLATE_FILE \
            --parameters $PARAMETERS \
            --capabilities CAPABILITY_NAMED_IAM \
            --region $REGION
        
        echo "Waiting for change set to be created..."
        aws cloudformation wait change-set-create-complete \
            --stack-name $STACK_NAME \
            --change-set-name $CHANGE_SET_NAME \
            --region $REGION
        
        # Change Setの内容を表示
        echo -e "${YELLOW}Change Set Summary:${NC}"
        aws cloudformation describe-change-set \
            --stack-name $STACK_NAME \
            --change-set-name $CHANGE_SET_NAME \
            --region $REGION \
            --query 'Changes[].{Action:Action,ResourceType:ResourceChange.ResourceType,LogicalId:ResourceChange.LogicalResourceId}' \
            --output table
        
        echo ""
        read -p "Do you want to execute this change set? (y/N): " -n 1 -r
        echo ""
        
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo "Executing change set..."
            aws cloudformation execute-change-set \
                --stack-name $STACK_NAME \
                --change-set-name $CHANGE_SET_NAME \
                --region $REGION
            
            echo "Waiting for stack update to complete..."
            aws cloudformation wait stack-update-complete \
                --stack-name $STACK_NAME \
                --region $REGION
            
            echo -e "${GREEN}✓ Stack update completed successfully!${NC}"
        else
            echo "Change set execution cancelled."
            aws cloudformation delete-change-set \
                --stack-name $STACK_NAME \
                --change-set-name $CHANGE_SET_NAME \
                --region $REGION
            exit 0
        fi
    fi
else
    echo -e "${GREEN}Creating new stack...${NC}"
    
    # 新しいスタックを作成
    aws cloudformation create-stack \
        --stack-name $STACK_NAME \
        --template-body file://$TEMPLATE_FILE \
        --parameters $PARAMETERS \
        --capabilities CAPABILITY_NAMED_IAM \
        --region $REGION
    
    echo "Waiting for stack creation to complete..."
    echo -e "${YELLOW}Note: ECS stack creation may take 5-10 minutes...${NC}"
    
    aws cloudformation wait stack-create-complete \
        --stack-name $STACK_NAME \
        --region $REGION
    
    echo -e "${GREEN}✓ Stack creation completed successfully!${NC}"
fi

# スタックの出力を表示
echo ""
echo -e "${GREEN}=== Stack Outputs ===${NC}"
aws cloudformation describe-stacks \
    --stack-name $STACK_NAME \
    --region $REGION \
    --query 'Stacks[0].Outputs[].{OutputKey:OutputKey,OutputValue:OutputValue}' \
    --output table

# ECRリポジトリの情報を表示
echo ""
echo -e "${GREEN}=== ECR Repository ===${NC}"
ECR_URI=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --region $REGION --query 'Stacks[0].Outputs[?OutputKey==`ECRRepositoryURI`].OutputValue' --output text)

if [ -n "$ECR_URI" ]; then
    echo "Repository URI: $ECR_URI"
    echo ""
    echo "Docker commands to build and push your image:"
    echo "  1. Build the image:"
    echo "     docker build -t $PROJECT_NAME ."
    echo ""
    echo "  2. Tag the image:"
    echo "     docker tag $PROJECT_NAME:latest $ECR_URI:latest"
    echo ""
    echo "  3. Login to ECR:"
    echo "     aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $ECR_URI"
    echo ""
    echo "  4. Push the image:"
    echo "     docker push $ECR_URI:latest"
fi

# ECSサービスの状態確認
echo ""
echo -e "${GREEN}=== ECS Service Status ===${NC}"
CLUSTER_NAME=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --region $REGION --query 'Stacks[0].Outputs[?OutputKey==`ECSClusterName`].OutputValue' --output text)
SERVICE_NAME=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --region $REGION --query 'Stacks[0].Outputs[?OutputKey==`ECSServiceName`].OutputValue' --output text)

if [ -n "$CLUSTER_NAME" ] && [ -n "$SERVICE_NAME" ]; then
    echo "Cluster: $CLUSTER_NAME"
    echo "Service: $SERVICE_NAME"
    
    # サービスの状態を取得
    SERVICE_STATUS=$(aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME --region $REGION --query 'services[0].status' --output text)
    RUNNING_COUNT=$(aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME --region $REGION --query 'services[0].runningCount' --output text)
    DESIRED_COUNT=$(aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME --region $REGION --query 'services[0].desiredCount' --output text)
    
    echo "Status: $SERVICE_STATUS"
    echo "Running Tasks: $RUNNING_COUNT/$DESIRED_COUNT"
    
    if [ "$RUNNING_COUNT" = "$DESIRED_COUNT" ] && [ "$SERVICE_STATUS" = "ACTIVE" ]; then
        echo -e "${GREEN}✓ ECS Service is running successfully${NC}"
    else
        echo -e "${YELLOW}⚠ ECS Service is still starting up${NC}"
    fi
fi

echo ""
echo -e "${GREEN}=== ECS Stack Deployment Complete ===${NC}"
echo ""
echo "Next steps:"
echo "1. Build and push Docker image to ECR: ./build-and-push-image.sh"
echo "2. Update ECS service with new image tag: ./deploy-ecs.sh"
echo "3. Access your application directly via public IP (see ECS console for task IPs)"
echo ""
echo -e "${BLUE}ECS Features configured:${NC}"
echo "  ✓ Fargate serverless containers"
echo "  ✓ Public subnet deployment with security group restrictions"
echo "  ✓ Auto scaling (CPU and Memory based)"
echo "  ✓ EFS persistent storage integration"
echo "  ✓ Secrets Manager for API keys"
echo "  ✓ CloudWatch logging and monitoring"
echo "  ✓ Mixed capacity providers (Fargate + Spot)"