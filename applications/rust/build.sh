AWS_REGION=us-west-2
CODEBUILD_RESOLVED_SOURCE_VERSION=latest
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --output text --query Account)
ECR_REGISTRY=$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com
ECR_REPOSITORY=moderneng/rust-microservice
aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $ECR_REGISTRY
docker build -f Dockerfile --no-cache --platform linux/amd64 -t $ECR_REGISTRY/moderneng/rust-microservice:$CODEBUILD_RESOLVED_SOURCE_VERSION .
docker push $ECR_REGISTRY/moderneng/rust-microservice:$CODEBUILD_RESOLVED_SOURCE_VERSION
#cd integration
#docker build -f Dockerfile -t $ECR_REGISTRY/$ECR_REPOSITORY:$CODEBUILD_RESOLVED_SOURCE_VERSION .
#docker push $ECR_REGISTRY/$ECR_REPOSITORY:$CODEBUILD_RESOLVED_SOURCE_VERSION