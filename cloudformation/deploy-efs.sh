#!/bin/bash

# EFS (Elastic File System) のデプロイスクリプト

set -e

# 設定
STACK_NAME="deepwiki-efs"
TEMPLATE_FILE="02-efs.yaml"
PROJECT_NAME="deepwiki"
REGION="ap-northeast-1"

# カラー出力用
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== DeepWiki EFS Stack Deployment ===${NC}"
echo "Stack Name: $STACK_NAME"
echo "Template: $TEMPLATE_FILE"
echo "Project Name: $PROJECT_NAME"
echo "Region: $REGION"
echo ""

# 依存関係のチェック
echo -e "${BLUE}Checking dependencies...${NC}"
VPC_STACK_NAME="deepwiki-vpc-network"

if ! aws cloudformation describe-stacks --stack-name $VPC_STACK_NAME --region $REGION >/dev/null 2>&1; then
    echo -e "${RED}Error: VPC stack '$VPC_STACK_NAME' not found.${NC}"
    echo "Please deploy the VPC stack first by running: ./deploy-vpc.sh"
    exit 1
fi

# VPCスタックのステータス確認
VPC_STACK_STATUS=$(aws cloudformation describe-stacks --stack-name $VPC_STACK_NAME --region $REGION --query 'Stacks[0].StackStatus' --output text)
if [[ "$VPC_STACK_STATUS" != "CREATE_COMPLETE" && "$VPC_STACK_STATUS" != "UPDATE_COMPLETE" ]]; then
    echo -e "${RED}Error: VPC stack is in status: $VPC_STACK_STATUS${NC}"
    echo "Please ensure the VPC stack is successfully deployed."
    exit 1
fi

echo -e "${GREEN}✓ VPC stack dependency satisfied${NC}"
echo ""

# テンプレートファイルの確認
if [ ! -f "$TEMPLATE_FILE" ]; then
    echo -e "${RED}Error: Template file '$TEMPLATE_FILE' not found${NC}"
    exit 1
fi

# EFS設定の確認
echo -e "${BLUE}EFS Configuration:${NC}"
echo "  ✓ Performance Mode: generalPurpose"
echo "  ✓ Throughput Mode: provisioned (100 MiB/s)"
echo "  ✓ Encryption: Enabled"
echo "  ✓ Backup: EFS native backup enabled"
echo "  ✓ Lifecycle Policy: Move to IA after 30 days"
echo "  ✓ Access Points: 4 (main, repos, databases, wikicache)"
echo ""

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
            --parameters ParameterKey=ProjectName,ParameterValue=$PROJECT_NAME \
            --region $REGION
        
        echo "Waiting for stack creation to complete..."
        echo -e "${YELLOW}Note: EFS creation may take a few minutes...${NC}"
        
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
            --parameters ParameterKey=ProjectName,ParameterValue=$PROJECT_NAME \
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
        --parameters ParameterKey=ProjectName,ParameterValue=$PROJECT_NAME \
        --region $REGION
    
    echo "Waiting for stack creation to complete..."
    echo -e "${YELLOW}Note: EFS creation may take a few minutes...${NC}"
    
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

# EFSの詳細情報を表示
echo ""
echo -e "${GREEN}=== EFS Details ===${NC}"
EFS_ID=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --region $REGION --query 'Stacks[0].Outputs[?OutputKey==`EFSFileSystemId`].OutputValue' --output text)

if [ -n "$EFS_ID" ]; then
    echo "File System ID: $EFS_ID"
    
    # EFSの状態を確認
    EFS_STATE=$(aws efs describe-file-systems --file-system-id $EFS_ID --region $REGION --query 'FileSystems[0].LifeCycleState' --output text)
    echo "EFS State: $EFS_STATE"
    
    if [ "$EFS_STATE" = "available" ]; then
        echo -e "${GREEN}✓ EFS is ready for use${NC}"
    else
        echo -e "${YELLOW}⚠ EFS is still being created. State: $EFS_STATE${NC}"
    fi
    
    echo ""
    echo "Mount command for testing:"
    echo "  sudo mount -t efs -o tls $EFS_ID:/ /mnt/efs"
fi

echo ""
echo -e "${GREEN}=== EFS Stack Deployment Complete ===${NC}"
echo ""
echo "Next steps:"
echo "1. Create ECR repository and push Docker image: ./build-and-push-image.sh"
echo "2. Deploy ECS stack: ./deploy-ecs.sh" 
echo "3. Deploy ALB stack: ./deploy-alb.sh"
echo ""
echo -e "${BLUE}EFS Features configured:${NC}"
echo "  ✓ Encryption at rest and in transit"
echo "  ✓ EFS native backup enabled"
echo "  ✓ Lifecycle policy for cost optimization"
echo "  ✓ Multiple access points for organized data storage:"
echo "    - Main data: /deepwiki-data"
echo "    - Repositories: /repos"
echo "    - Databases: /databases" 
echo "    - Wiki cache: /wikicache"