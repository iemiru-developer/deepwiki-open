#!/bin/bash

# DeepWiki Cache Cleanup Script
# このスクリプトはwikiキャッシュとデータベースキャッシュをクリアします

set -e

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

# 使用方法の表示
show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "OPTIONS:"
    echo "  -a, --all           Clear all caches (wikicache + databases + repos)"
    echo "  -w, --wiki          Clear wikicache only"
    echo "  -d, --database      Clear database cache only"
    echo "  -r, --repos         Clear downloaded repositories"
    echo "  -p, --project NAME  Clear cache for specific project (format: owner_repo)"
    echo "  -l, --list          List cached projects"
    echo "  -h, --help          Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 --all                    # Clear all caches"
    echo "  $0 --wiki                   # Clear wikicache only"
    echo "  $0 --project iemiru-developer_iemiru  # Clear specific project"
    echo "  $0 --list                   # List cached projects"
}

# Dockerコンテナの確認
check_docker_container() {
    if ! docker-compose ps deepwiki | grep -q "Up"; then
        log_error "DeepWiki container is not running. Please start it with 'docker-compose up -d'"
        exit 1
    fi
}

# キャッシュされたプロジェクトの一覧表示
list_cached_projects() {
    log_step "Listing Cached Projects"
    
    echo ""
    echo -e "${CYAN}Wiki Cache Files:${NC}"
    docker-compose exec -T deepwiki find /root/.adalflow/wikicache -name "*.json" -type f 2>/dev/null | while read file; do
        basename "$file" | sed 's/deepwiki_cache_github_//' | sed 's/_ja\.json$//'
    done || echo "No wiki cache files found"
    
    echo ""
    echo -e "${CYAN}Database Cache Files:${NC}"
    docker-compose exec -T deepwiki find /root/.adalflow/databases -name "*.pkl" -type f 2>/dev/null | while read file; do
        basename "$file" .pkl
    done || echo "No database cache files found"
    
    echo ""
    echo -e "${CYAN}Downloaded Repositories:${NC}"
    docker-compose exec -T deepwiki find /root/.adalflow/repos -maxdepth 1 -type d 2>/dev/null | tail -n +2 | while read dir; do
        basename "$dir"
    done || echo "No downloaded repositories found"
    
    echo ""
}

# wikicacheのクリア
clear_wikicache() {
    local project_name="$1"
    
    if [ -n "$project_name" ]; then
        log_step "Clearing Wiki Cache for Project: $project_name"
        local cache_file="/root/.adalflow/wikicache/deepwiki_cache_github_${project_name}_ja.json"
        if docker-compose exec -T deepwiki test -f "$cache_file"; then
            docker-compose exec -T deepwiki rm -f "$cache_file"
            log_success "Cleared wiki cache for $project_name"
        else
            log_warning "Wiki cache file not found for $project_name"
        fi
    else
        log_step "Clearing All Wiki Cache"
        if docker-compose exec -T deepwiki test -d /root/.adalflow/wikicache; then
            docker-compose exec -T deepwiki sh -c "rm -f /root/.adalflow/wikicache/*.json"
            log_success "Cleared all wiki cache files"
        else
            log_warning "Wiki cache directory not found"
        fi
    fi
}

# データベースキャッシュのクリア
clear_database_cache() {
    local project_name="$1"
    
    if [ -n "$project_name" ]; then
        log_step "Clearing Database Cache for Project: $project_name"
        local db_file="/root/.adalflow/databases/${project_name}.pkl"
        if docker-compose exec -T deepwiki test -f "$db_file"; then
            docker-compose exec -T deepwiki rm -f "$db_file"
            log_success "Cleared database cache for $project_name"
        else
            log_warning "Database cache file not found for $project_name"
        fi
    else
        log_step "Clearing All Database Cache"
        if docker-compose exec -T deepwiki test -d /root/.adalflow/databases; then
            docker-compose exec -T deepwiki sh -c "rm -f /root/.adalflow/databases/*.pkl"
            log_success "Cleared all database cache files"
        else
            log_warning "Database cache directory not found"
        fi
    fi
}

# ダウンロードしたリポジトリのクリア
clear_repos() {
    local project_name="$1"
    
    if [ -n "$project_name" ]; then
        log_step "Clearing Downloaded Repository for Project: $project_name"
        local repo_dir="/root/.adalflow/repos/$project_name"
        if docker-compose exec -T deepwiki test -d "$repo_dir"; then
            docker-compose exec -T deepwiki rm -rf "$repo_dir"
            log_success "Cleared repository for $project_name"
        else
            log_warning "Repository directory not found for $project_name"
        fi
    else
        log_step "Clearing All Downloaded Repositories"
        if docker-compose exec -T deepwiki test -d /root/.adalflow/repos; then
            docker-compose exec -T deepwiki sh -c "rm -rf /root/.adalflow/repos/*"
            log_success "Cleared all downloaded repositories"
        else
            log_warning "Repositories directory not found"
        fi
    fi
}

# メイン処理
main() {
    local clear_all=false
    local clear_wiki=false
    local clear_db=false
    local clear_repositories=false
    local list_projects=false
    local project_name=""
    
    # 引数の解析
    while [[ $# -gt 0 ]]; do
        case $1 in
            -a|--all)
                clear_all=true
                shift
                ;;
            -w|--wiki)
                clear_wiki=true
                shift
                ;;
            -d|--database)
                clear_db=true
                shift
                ;;
            -r|--repos)
                clear_repositories=true
                shift
                ;;
            -p|--project)
                project_name="$2"
                shift 2
                ;;
            -l|--list)
                list_projects=true
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
    
    # 引数が指定されていない場合
    if [[ "$clear_all" == false && "$clear_wiki" == false && "$clear_db" == false && "$clear_repositories" == false && "$list_projects" == false && -z "$project_name" ]]; then
        show_usage
        exit 1
    fi
    
    echo -e "${CYAN}"
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║                DeepWiki Cache Cleanup Tool                ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""
    
    check_docker_container
    
    if [ "$list_projects" == true ]; then
        list_cached_projects
        exit 0
    fi
    
    if [ "$clear_all" == true ]; then
        clear_wikicache "$project_name"
        clear_database_cache "$project_name"
        clear_repos "$project_name"
    else
        if [ "$clear_wiki" == true ]; then
            clear_wikicache "$project_name"
        fi
        
        if [ "$clear_db" == true ]; then
            clear_database_cache "$project_name"
        fi
        
        if [ "$clear_repositories" == true ]; then
            clear_repos "$project_name"
        fi
        
        if [ -n "$project_name" ] && [ "$clear_wiki" == false ] && [ "$clear_db" == false ] && [ "$clear_repositories" == false ]; then
            # プロジェクト名が指定されているが、他のオプションがない場合は全てクリア
            clear_wikicache "$project_name"
            clear_database_cache "$project_name"
            clear_repos "$project_name"
        fi
    fi
    
    echo ""
    log_success "Cache cleanup completed!"
    echo ""
    log_info "To see the current state of cached projects, run:"
    echo "  $0 --list"
    echo ""
}

# スクリプトの実行
main "$@"