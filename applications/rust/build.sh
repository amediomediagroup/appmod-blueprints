aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $ECR_REGISTRY
docker build -t $ECR_REGISTRY/app/rust-microservice:$CODEBUILD_RESOLVED_SOURCE_VERSION .
docker push $ECR_REGISTRY/app/rust-microservice:$CODEBUILD_RESOLVED_SOURCE_VERSION
cd integration
docker build -f Dockerfile -t $ECR_REGISTRY/$ECR_REPOSITORY:$CODEBUILD_RESOLVED_SOURCE_VERSION .d
docker push $ECR_REGISTRY/$ECR_REPOSITORY:$CODEBUILD_RESOLVED_SOURCE_VERSION
