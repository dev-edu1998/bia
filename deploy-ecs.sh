#!/bin/bash

# Script de Deploy ECS - Projeto BIA
# Autor: Amazon Q
# Versão: 1.0.0

set -e

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configurações padrão
DEFAULT_REGION="us-east-1"
DEFAULT_CLUSTER="cluster-bia"
DEFAULT_SERVICE="service-bia"
DEFAULT_TASK_FAMILY="task-def-bia"
DEFAULT_ECR_REPO="bia"

# Função para exibir help
show_help() {
    echo -e "${BLUE}=== Script de Deploy ECS - Projeto BIA ===${NC}"
    echo ""
    echo -e "${YELLOW}DESCRIÇÃO:${NC}"
    echo "  Este script automatiza o processo de build, tag e deploy da aplicação BIA no ECS."
    echo "  Cada imagem é taggeada com o hash do commit atual para permitir rollbacks."
    echo ""
    echo -e "${YELLOW}USO:${NC}"
    echo "  $0 [OPÇÕES] COMANDO"
    echo ""
    echo -e "${YELLOW}COMANDOS:${NC}"
    echo "  deploy          Executa build, push e deploy completo"
    echo "  build           Apenas faz build da imagem com tag do commit"
    echo "  push            Apenas faz push da imagem para ECR"
    echo "  update-service  Apenas atualiza o serviço ECS"
    echo "  rollback        Faz rollback para uma versão anterior"
    echo "  list-images     Lista as últimas 10 imagens no ECR"
    echo "  help            Exibe esta ajuda"
    echo ""
    echo -e "${YELLOW}OPÇÕES:${NC}"
    echo "  -r, --region REGION        Região AWS (padrão: $DEFAULT_REGION)"
    echo "  -c, --cluster CLUSTER      Nome do cluster ECS (padrão: $DEFAULT_CLUSTER)"
    echo "  -s, --service SERVICE      Nome do serviço ECS (padrão: $DEFAULT_SERVICE)"
    echo "  -f, --family FAMILY        Família da task definition (padrão: $DEFAULT_TASK_FAMILY)"
    echo "  -e, --ecr-repo REPO        Nome do repositório ECR (padrão: $DEFAULT_ECR_REPO)"
    echo "  -t, --tag TAG              Tag específica para rollback"
    echo "  -h, --help                 Exibe esta ajuda"
    echo ""
    echo -e "${YELLOW}EXEMPLOS:${NC}"
    echo "  # Deploy completo com configurações padrão"
    echo "  $0 deploy"
    echo ""
    echo "  # Deploy em região específica"
    echo "  $0 --region us-west-2 deploy"
    echo ""
    echo "  # Apenas build da imagem"
    echo "  $0 build"
    echo ""
    echo "  # Rollback para uma tag específica"
    echo "  $0 rollback --tag abc1234"
    echo ""
    echo "  # Listar imagens disponíveis"
    echo "  $0 list-images"
    echo ""
    echo -e "${YELLOW}PRÉ-REQUISITOS:${NC}"
    echo "  - AWS CLI configurado"
    echo "  - Docker instalado e rodando"
    echo "  - Permissões para ECR, ECS e IAM"
    echo "  - Repositório ECR já criado"
    echo ""
    echo -e "${YELLOW}OBSERVAÇÕES:${NC}"
    echo "  - O script usa os últimos 8 caracteres do commit hash como tag"
    echo "  - Task definitions são versionadas automaticamente"
    echo "  - O rollback mantém a mesma configuração, apenas muda a imagem"
}

# Função para log colorido
log() {
    local level=$1
    shift
    case $level in
        "INFO")  echo -e "${GREEN}[INFO]${NC} $*" ;;
        "WARN")  echo -e "${YELLOW}[WARN]${NC} $*" ;;
        "ERROR") echo -e "${RED}[ERROR]${NC} $*" ;;
        "DEBUG") echo -e "${BLUE}[DEBUG]${NC} $*" ;;
    esac
}

# Função para verificar pré-requisitos
check_prerequisites() {
    log "INFO" "Verificando pré-requisitos..."
    
    # Verificar AWS CLI
    if ! command -v aws &> /dev/null; then
        log "ERROR" "AWS CLI não encontrado. Instale o AWS CLI primeiro."
        exit 1
    fi
    
    # Verificar Docker
    if ! command -v docker &> /dev/null; then
        log "ERROR" "Docker não encontrado. Instale o Docker primeiro."
        exit 1
    fi
    
    # Verificar se Docker está rodando
    if ! docker info &> /dev/null; then
        log "ERROR" "Docker não está rodando. Inicie o Docker primeiro."
        exit 1
    fi
    
    # Verificar se está em um repositório git
    if ! git rev-parse --git-dir &> /dev/null; then
        log "ERROR" "Não está em um repositório Git."
        exit 1
    fi
    
    log "INFO" "Pré-requisitos verificados com sucesso!"
}

# Função para obter informações do commit
get_commit_info() {
    COMMIT_HASH=$(git rev-parse HEAD)
    COMMIT_SHORT=$(echo $COMMIT_HASH | cut -c1-8)
    COMMIT_MESSAGE=$(git log -1 --pretty=%B | head -n1)
    
    log "INFO" "Commit atual: $COMMIT_SHORT"
    log "DEBUG" "Mensagem: $COMMIT_MESSAGE"
}

# Função para fazer login no ECR
ecr_login() {
    log "INFO" "Fazendo login no ECR..."
    
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region $REGION)
    ECR_URI="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"
    
    aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $ECR_URI
    
    log "INFO" "Login no ECR realizado com sucesso!"
}

# Função para build da imagem
build_image() {
    log "INFO" "Iniciando build da imagem..."
    
    IMAGE_TAG="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$ECR_REPO:$COMMIT_SHORT"
    IMAGE_LATEST="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$ECR_REPO:latest"
    
    # Build da imagem
    docker build -t $IMAGE_TAG -t $IMAGE_LATEST .
    
    log "INFO" "Build concluído!"
    log "INFO" "Imagem: $IMAGE_TAG"
}

# Função para push da imagem
push_image() {
    log "INFO" "Fazendo push da imagem para ECR..."
    
    docker push $IMAGE_TAG
    docker push $IMAGE_LATEST
    
    log "INFO" "Push concluído!"
}

# Função para criar nova task definition
create_task_definition() {
    log "INFO" "Criando nova task definition..."
    
    # Obter task definition atual
    CURRENT_TASK_DEF=$(aws ecs describe-task-definition \
        --task-definition $TASK_FAMILY \
        --region $REGION \
        --query 'taskDefinition' \
        --output json)
    
    if [ $? -ne 0 ]; then
        log "ERROR" "Falha ao obter task definition atual"
        exit 1
    fi
    
    # Atualizar imagem na task definition
    NEW_TASK_DEF=$(echo $CURRENT_TASK_DEF | jq --arg IMAGE "$IMAGE_TAG" '
        .containerDefinitions[0].image = $IMAGE |
        del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .placementConstraints, .compatibilities, .registeredAt, .registeredBy)
    ')
    
    # Registrar nova task definition
    NEW_TASK_ARN=$(echo $NEW_TASK_DEF | aws ecs register-task-definition \
        --region $REGION \
        --cli-input-json file:///dev/stdin \
        --query 'taskDefinition.taskDefinitionArn' \
        --output text)
    
    if [ $? -ne 0 ]; then
        log "ERROR" "Falha ao registrar nova task definition"
        exit 1
    fi
    
    log "INFO" "Nova task definition criada: $NEW_TASK_ARN"
}

# Função para atualizar serviço ECS
update_service() {
    log "INFO" "Atualizando serviço ECS..."
    
    aws ecs update-service \
        --cluster $CLUSTER \
        --service $SERVICE \
        --task-definition $TASK_FAMILY \
        --region $REGION \
        --query 'service.serviceName' \
        --output text
    
    if [ $? -ne 0 ]; then
        log "ERROR" "Falha ao atualizar serviço ECS"
        exit 1
    fi
    
    log "INFO" "Serviço atualizado com sucesso!"
    
    # Aguardar estabilização
    log "INFO" "Aguardando estabilização do serviço..."
    aws ecs wait services-stable \
        --cluster $CLUSTER \
        --services $SERVICE \
        --region $REGION
    
    log "INFO" "Serviço estabilizado!"
}

# Função para listar imagens
list_images() {
    log "INFO" "Listando últimas 10 imagens no ECR..."
    
    aws ecr describe-images \
        --repository-name $ECR_REPO \
        --region $REGION \
        --query 'sort_by(imageDetails,&imagePushedAt)[-10:].[imageTags[0],imagePushedAt]' \
        --output table
}

# Função para rollback
rollback() {
    if [ -z "$ROLLBACK_TAG" ]; then
        log "ERROR" "Tag para rollback não especificada. Use --tag TAG"
        exit 1
    fi
    
    log "INFO" "Iniciando rollback para tag: $ROLLBACK_TAG"
    
    # Verificar se a imagem existe
    aws ecr describe-images \
        --repository-name $ECR_REPO \
        --image-ids imageTag=$ROLLBACK_TAG \
        --region $REGION \
        --query 'imageDetails[0].imageTags[0]' \
        --output text &> /dev/null
    
    if [ $? -ne 0 ]; then
        log "ERROR" "Imagem com tag $ROLLBACK_TAG não encontrada"
        exit 1
    fi
    
    # Definir imagem para rollback
    IMAGE_TAG="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$ECR_REPO:$ROLLBACK_TAG"
    
    # Criar task definition e atualizar serviço
    create_task_definition
    update_service
    
    log "INFO" "Rollback concluído para tag: $ROLLBACK_TAG"
}

# Função principal de deploy
deploy() {
    check_prerequisites
    get_commit_info
    ecr_login
    build_image
    push_image
    create_task_definition
    update_service
    
    log "INFO" "Deploy concluído com sucesso!"
    log "INFO" "Tag da imagem: $COMMIT_SHORT"
}

# Parsing de argumentos
REGION=$DEFAULT_REGION
CLUSTER=$DEFAULT_CLUSTER
SERVICE=$DEFAULT_SERVICE
TASK_FAMILY=$DEFAULT_TASK_FAMILY
ECR_REPO=$DEFAULT_ECR_REPO
ROLLBACK_TAG=""
COMMAND=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -r|--region)
            REGION="$2"
            shift 2
            ;;
        -c|--cluster)
            CLUSTER="$2"
            shift 2
            ;;
        -s|--service)
            SERVICE="$2"
            shift 2
            ;;
        -f|--family)
            TASK_FAMILY="$2"
            shift 2
            ;;
        -e|--ecr-repo)
            ECR_REPO="$2"
            shift 2
            ;;
        -t|--tag)
            ROLLBACK_TAG="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        deploy|build|push|update-service|rollback|list-images|help)
            COMMAND="$1"
            shift
            ;;
        *)
            log "ERROR" "Opção desconhecida: $1"
            show_help
            exit 1
            ;;
    esac
done

# Verificar se comando foi especificado
if [ -z "$COMMAND" ]; then
    log "ERROR" "Comando não especificado"
    show_help
    exit 1
fi

# Executar comando
case $COMMAND in
    "help")
        show_help
        ;;
    "deploy")
        deploy
        ;;
    "build")
        check_prerequisites
        get_commit_info
        ecr_login
        build_image
        ;;
    "push")
        check_prerequisites
        get_commit_info
        ecr_login
        push_image
        ;;
    "update-service")
        check_prerequisites
        get_commit_info
        ecr_login
        create_task_definition
        update_service
        ;;
    "rollback")
        check_prerequisites
        ecr_login
        rollback
        ;;
    "list-images")
        list_images
        ;;
    *)
        log "ERROR" "Comando inválido: $COMMAND"
        show_help
        exit 1
        ;;
esac
