#!/bin/bash

# Script de Deploy ECS Simplificado - Projeto BIA
# Versão: 1.0.0

set -e

# Configurações
REGION="us-east-1"
ECR_REPO="bia"
CLUSTER="cluster-bia-alb"
SERVICE="service-bia-alb"
TASK_FAMILY="task-def-bia-alb"

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Obter commit hash
COMMIT_HASH=$(git rev-parse --short=7 HEAD)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_URI="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$ECR_REPO"

log_info "Iniciando deploy..."
log_info "Commit Hash: $COMMIT_HASH"
log_info "ECR URI: $ECR_URI"

# Login no ECR
log_info "Fazendo login no ECR..."
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com

# Build da imagem
log_info "Fazendo build da imagem Docker..."
docker build -t bia-app:$COMMIT_HASH -t bia-app:latest -t $ECR_URI:$COMMIT_HASH -t $ECR_URI:latest .

# Push da imagem
log_info "Fazendo push da imagem para ECR..."
docker push $ECR_URI:$COMMIT_HASH
docker push $ECR_URI:latest

# Obter task definition atual
log_info "Obtendo task definition atual..."
CURRENT_TASK_DEF=$(aws ecs describe-task-definition --task-definition $TASK_FAMILY --region $REGION --query 'taskDefinition' --output json)

# Criar nova task definition com nova imagem
log_info "Criando nova task definition..."
NEW_TASK_DEF=$(echo $CURRENT_TASK_DEF | jq --arg image "$ECR_URI:$COMMIT_HASH" '.containerDefinitions[0].image = $image | del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .placementConstraints, .compatibilities, .registeredAt, .registeredBy)')

# Registrar nova task definition
log_info "Registrando nova task definition..."
REGISTER_RESULT=$(echo $NEW_TASK_DEF | aws ecs register-task-definition --region $REGION --cli-input-json file:///dev/stdin --output json)

# Extrair número da revisão
NEW_REVISION=$(echo $REGISTER_RESULT | jq -r '.taskDefinition.revision')
log_success "Nova task definition criada: $TASK_FAMILY:$NEW_REVISION"

# Atualizar serviço
log_info "Atualizando serviço ECS..."
aws ecs update-service \
    --region $REGION \
    --cluster $CLUSTER \
    --service $SERVICE \
    --task-definition $TASK_FAMILY:$NEW_REVISION \
    --output json > /dev/null

log_success "Serviço atualizado com sucesso"
log_info "Aguardando estabilização do serviço..."

# Aguardar estabilização
aws ecs wait services-stable --region $REGION --cluster $CLUSTER --services $SERVICE

log_success "Deploy concluído com sucesso!"
log_info "Versão deployada: $COMMIT_HASH"
log_info "Task Definition: $TASK_FAMILY:$NEW_REVISION"
