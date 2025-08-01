#!/bin/bash

# DeepWiki AWS Deployment Orchestration Script
# このスクリプトはAWSのCloudFormationスタックを正しい順序で実行します

set -e

# 設定
PROJECT_NAME="deepwiki"
REGION="ap-northeast-1"
CLOUDFORMATION_DIR="./cloudformation"

# カラー出力用
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ログ関数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${CYAN}=== $1 ===${NC}"
}

# エラーハンドリング
error_exit() {
    log_error "$1"
    exit 1
}

# 前提条件チェック
check_prerequisites() {
    log_step "Checking Prerequisites"
    
    # AWS CLIの確認
    if ! command -v aws &> /dev/null; then
        error_exit "AWS CLI is not installed. Please install AWS CLI v2."
    fi
    log_success "AWS CLI is available"
    
    # AWS認証の確認
    if ! aws sts get-caller-identity >/dev/null 2>&1; then
        error_exit "AWS CLI is not configured. Please run 'aws configure' first."
    fi
    
    local aws_account=$(aws sts get-caller-identity --query Account --output text)
    local aws_region=$(aws configure get region)
    log_success "AWS authenticated - Account: $aws_account, Region: $aws_region"
    
    # Dockerの確認
    if ! command -v docker &> /dev/null; then
        error_exit "Docker is not installed. Please install Docker Desktop."
    fi
    
    if ! docker --version >/dev/null 2>&1; then
        error_exit "Docker is not running. Please start Docker Desktop."
    fi
    log_success "Docker is available and running"
    
    # CloudFormationディレクトリの確認
    if [ ! -d "$CLOUDFORMATION_DIR" ]; then
        error_exit "CloudFormation directory not found: $CLOUDFORMATION_DIR"
    fi
    log_success "CloudFormation directory found"
    
    # 必要なスクリプトファイルの確認
    local required_scripts=(
        "deploy-vpc.sh"
        "deploy-efs.sh"
        "build-and-push-image.sh"
        "deploy-ecs.sh"
    )
    
    for script in "${required_scripts[@]}"; do
        if [ ! -f "$CLOUDFORMATION_DIR/$script" ]; then
            error_exit "Required script not found: $CLOUDFORMATION_DIR/$script"
        fi
        
        if [ ! -x "$CLOUDFORMATION_DIR/$script" ]; then
            log_warning "Script is not executable, making it executable: $script"
            chmod +x "$CLOUDFORMATION_DIR/$script"
        fi
    done
    log_success "All required scripts are available and executable"
    
    echo ""
}

# デプロイ方法の選択
select_deployment_method() {
    log_step "Select Deployment Method"
    
    echo "Please select the deployment method:"
    echo "1) Full deployment (VPC + EFS + Docker Build + ECS)"
    echo "2) Deploy infrastructure only (VPC + EFS)"
    echo "3) Deploy application only (Docker Build + ECS) - requires existing VPC and EFS"
    echo "4) Update Docker image only (build and push to existing ECR)"
    echo ""
    
    while true; do
        read -p "Enter your choice (1-4): " choice
        case $choice in
            1)
                DEPLOYMENT_METHOD="full"
                break
                ;;
            2)
                DEPLOYMENT_METHOD="infrastructure"
                break
                ;;
            3)
                DEPLOYMENT_METHOD="application"
                break
                ;;
            4)
                DEPLOYMENT_METHOD="docker_only"
                break
                ;;
            *)
                log_error "Invalid choice. Please enter 1, 2, 3, or 4."
                ;;
        esac
    done
    
    log_info "Selected deployment method: $DEPLOYMENT_METHOD"
    echo ""
}

# VPCスタックのデプロイ
deploy_vpc() {
    log_step "Deploying VPC and Network Infrastructure"
    
    cd "$CLOUDFORMATION_DIR"
    
    if ./deploy-vpc.sh; then
        log_success "VPC stack deployment completed"
    else
        error_exit "VPC stack deployment failed"
    fi
    
    cd - >/dev/null
    echo ""
}

# EFSスタックのデプロイ
deploy_efs() {
    log_step "Deploying Elastic File System (EFS)"
    
    cd "$CLOUDFORMATION_DIR"
    
    if ./deploy-efs.sh; then
        log_success "EFS stack deployment completed"
    else
        error_exit "EFS stack deployment failed"
    fi
    
    cd - >/dev/null
    echo ""
}

# Dockerイメージのビルドとプッシュ
build_and_push_docker() {
    log_step "Building and Pushing Docker Image"
    
    cd "$CLOUDFORMATION_DIR"
    
    if ./build-and-push-image.sh; then
        log_success "Docker image build and push completed"
    else
        error_exit "Docker image build and push failed"
    fi
    
    cd - >/dev/null
    echo ""
}

# ECSスタックのデプロイ
deploy_ecs() {
    log_step "Deploying ECS (Elastic Container Service)"
    
    cd "$CLOUDFORMATION_DIR"
    
    if ./deploy-ecs.sh; then
        log_success "ECS stack deployment completed"
    else
        error_exit "ECS stack deployment failed"
    fi
    
    cd - >/dev/null
    echo ""
}

# デプロイメント情報の表示
show_deployment_info() {
    log_step "Deployment Information"
    
    log_info "Retrieving deployment information..."
    
    # ECSスタックの出力を取得
    if aws cloudformation describe-stacks --stack-name deepwiki-ecs --region $REGION >/dev/null 2>&1; then
        echo ""
        echo -e "${GREEN}=== ECS Service Information ===${NC}"
        aws cloudformation describe-stacks \
            --stack-name deepwiki-ecs \
            --region $REGION \
            --query 'Stacks[0].Outputs[].{OutputKey:OutputKey,OutputValue:OutputValue}' \
            --output table
        
        # ECS サービスの詳細情報
        local cluster_name=$(aws cloudformation describe-stacks --stack-name deepwiki-ecs --region $REGION --query 'Stacks[0].Outputs[?OutputKey==`ECSClusterName`].OutputValue' --output text)
        local service_name=$(aws cloudformation describe-stacks --stack-name deepwiki-ecs --region $REGION --query 'Stacks[0].Outputs[?OutputKey==`ECSServiceName`].OutputValue' --output text)
        
        if [ -n "$cluster_name" ] && [ -n "$service_name" ]; then
            echo ""
            echo -e "${GREEN}=== ECS Service Status ===${NC}"
            aws ecs describe-services \
                --cluster $cluster_name \
                --services $service_name \
                --region $REGION \
                --query 'services[0].{ServiceName:serviceName,Status:status,RunningCount:runningCount,DesiredCount:desiredCount,TaskDefinition:taskDefinition}' \
                --output table
        fi
    fi
    
    echo ""
    log_success "Deployment completed successfully!"
    echo ""
    
    echo -e "${CYAN}Next Steps:${NC}"
    echo "1. Monitor your ECS service in the AWS Console"
    echo "2. Check CloudWatch logs for application startup"
    echo "3. Configure your domain name if needed"
    echo "4. Set up monitoring and alerts"
    echo ""
    
    echo -e "${CYAN}Useful Commands:${NC}"
    if [ -n "$cluster_name" ] && [ -n "$service_name" ]; then
        echo "• Check service status:"
        echo "  aws ecs describe-services --cluster $cluster_name --services $service_name --region $REGION"
        echo ""
        echo "• View service logs:"
        echo "  aws logs tail /ecs/deepwiki --follow --region $REGION"
        echo ""
        echo "• Force new deployment:"
        echo "  aws ecs update-service --cluster $cluster_name --service $service_name --force-new-deployment --region $REGION"
    fi
}

# 依存関係チェック（アプリケーションのみデプロイ用）
check_infrastructure_dependencies() {
    log_step "Checking Infrastructure Dependencies"
    
    # VPCスタックの確認
    if ! aws cloudformation describe-stacks --stack-name deepwiki-vpc-network --region $REGION >/dev/null 2>&1; then
        error_exit "VPC stack 'deepwiki-vpc-network' not found. Please deploy infrastructure first."
    fi
    
    local vpc_status=$(aws cloudformation describe-stacks --stack-name deepwiki-vpc-network --region $REGION --query 'Stacks[0].StackStatus' --output text)
    if [[ "$vpc_status" != "CREATE_COMPLETE" && "$vpc_status" != "UPDATE_COMPLETE" ]]; then
        error_exit "VPC stack is not in a ready state: $vpc_status"
    fi
    log_success "VPC stack is ready"
    
    # EFSスタックの確認
    if ! aws cloudformation describe-stacks --stack-name deepwiki-efs --region $REGION >/dev/null 2>&1; then
        error_exit "EFS stack 'deepwiki-efs' not found. Please deploy infrastructure first."
    fi
    
    local efs_status=$(aws cloudformation describe-stacks --stack-name deepwiki-efs --region $REGION --query 'Stacks[0].StackStatus' --output text)
    if [[ "$efs_status" != "CREATE_COMPLETE" && "$efs_status" != "UPDATE_COMPLETE" ]]; then
        error_exit "EFS stack is not in a ready state: $efs_status"
    fi
    log_success "EFS stack is ready"
    
    echo ""
}

# メイン実行関数
main() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                   DeepWiki AWS Deployment                    ║"
    echo "║                                                              ║"
    echo "║  This script will deploy DeepWiki to AWS using:             ║"
    echo "║  • VPC with public/private subnets                          ║"
    echo "║  • EFS for persistent storage                                ║"
    echo "║  • ECS Fargate for container orchestration                   ║"
    echo "║  • ECR for Docker image registry                             ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""
    
    check_prerequisites
    select_deployment_method
    
    case $DEPLOYMENT_METHOD in
        "full")
            log_info "Starting full deployment..."
            deploy_vpc
            deploy_efs
            deploy_ecs
            build_and_push_docker
            show_deployment_info
            ;;
        "infrastructure")
            log_info "Deploying infrastructure only..."
            deploy_vpc
            deploy_efs
            log_success "Infrastructure deployment completed!"
            echo ""
            log_info "To deploy the application, run this script again and select option 3."
            ;;
        "application")
            log_info "Deploying application only..."
            check_infrastructure_dependencies
            deploy_ecs
            build_and_push_docker
            show_deployment_info
            ;;
        "docker_only")
            log_info "Building and pushing Docker image only..."
            build_and_push_docker
            log_success "Docker image updated!"
            ;;
    esac
}

# スクリプトの実行
main "$@"