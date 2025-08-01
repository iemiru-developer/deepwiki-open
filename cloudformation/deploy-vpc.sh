#!/bin/bash

# VPCとネットワークインフラストラクチャのデプロイスクリプト

set -e

# 設定
STACK_NAME="deepwiki-vpc-network"
TEMPLATE_FILE="01-vpc-network.yaml"
PROJECT_NAME="deepwiki"
REGION="ap-northeast-1"

# カラー出力用
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== DeepWiki VPC Network Stack Deployment ===${NC}"
echo "Stack Name: $STACK_NAME"
echo "Template: $TEMPLATE_FILE"
echo "Project Name: $PROJECT_NAME"
echo "Region: $REGION"
echo ""

# スタックが既に存在するかチェック
if aws cloudformation describe-stacks --stack-name $STACK_NAME --region $REGION >/dev/null 2>&1; then
    echo -e "${YELLOW}Stack $STACK_NAME already exists. Updating...${NC}"
    
    # Change Setを作成
    CHANGE_SET_NAME="update-$(date +%Y%m%d-%H%M%S)"
    echo "Creating change set: $CHANGE_SET_NAME"
    
    aws cloudformation create-change-set \
        --stack-name $STACK_NAME \
        --change-set-name $CHANGE_SET_NAME \
        --template-body file://$TEMPLATE_FILE \
        --parameters ParameterKey=ProjectName,ParameterValue=$PROJECT_NAME \
        --capabilities CAPABILITY_IAM \
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
        
        echo -e "${GREEN}Stack update completed successfully!${NC}"
    else
        echo "Change set execution cancelled."
        aws cloudformation delete-change-set \
            --stack-name $STACK_NAME \
            --change-set-name $CHANGE_SET_NAME \
            --region $REGION
        exit 0
    fi
else
    echo -e "${GREEN}Creating new stack...${NC}"
    
    # 新しいスタックを作成
    aws cloudformation create-stack \
        --stack-name $STACK_NAME \
        --template-body file://$TEMPLATE_FILE \
        --parameters ParameterKey=ProjectName,ParameterValue=$PROJECT_NAME \
        --capabilities CAPABILITY_IAM \
        --region $REGION
    
    echo "Waiting for stack creation to complete..."
    aws cloudformation wait stack-create-complete \
        --stack-name $STACK_NAME \
        --region $REGION
    
    echo -e "${GREEN}Stack creation completed successfully!${NC}"
fi

# スタックの出力を表示
echo -e "${GREEN}=== Stack Outputs ===${NC}"
aws cloudformation describe-stacks \
    --stack-name $STACK_NAME \
    --region $REGION \
    --query 'Stacks[0].Outputs[].{OutputKey:OutputKey,OutputValue:OutputValue}' \
    --output table

echo -e "${GREEN}=== VPC Network Infrastructure Deployment Complete ===${NC}"
echo ""
echo "Next steps:"
echo "1. Deploy EFS stack: ./deploy-efs.sh"
echo "2. Deploy ECR and build Docker image"
echo "3. Deploy ECS stack: ./deploy-ecs.sh"
echo "4. Deploy ALB stack: ./deploy-alb.sh"