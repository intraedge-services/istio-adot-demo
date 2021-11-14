# istio-adot-demo

Istio Demo with AWS Distribution of Open Telemetry

## Setup

### Global Variables

```shell
export AWS_REGION=us-west-2
export AWS_PROFILE=intraedge-training
export AWS_DEFAULT_REGION=$AWS_REGION
export MASTER_KEY_ALIAS=alias/istio-otel-demo
export STACK_NAME=istio-otel-demo
export VPC_ID=vpc-0cfa1f645447cb5a6
export PUBLIC_SUBNET_A=subnet-0fe287ae74454dc46
export PUBLIC_SUBNET_B=subnet-058a2ef4e51ca00c9
export PUBLIC_SUBNET_C=subnet-0599b1e3c2d7943d4
export APP_SUBNET_A=subnet-0f53e83250da3668c
export APP_SUBNET_B=subnet-0a9dadd002c3a37c0
export APP_SUBNET_C=subnet-0d65206e1eda99c5d
export MY_IP=$(curl icanhazip.com)
export MASTER_ARN=$(aws kms describe-key --key-id $MASTER_KEY_ALIAS --query KeyMetadata.Arn --output text)

```

### Pre Requisites
- [eksctl](https://docs.aws.amazon.com/eks/latest/userguide/eksctl.html)
- [awscli v2](https://aws.amazon.com/cli/)

### Login to AWS

```shell
aws sso login --profile=$AWS_PROFILE
```

### Create KMS Key

```shell
aws kms create-alias \
  --alias-name $MASTER_KEY_ALIAS \
  --target-key-id $(aws kms create-key --query KeyMetadata.Arn --output text)
export MASTER_ARN=$(aws kms describe-key --key-id $MASTER_KEY_ALIAS --query KeyMetadata.Arn --output text)

```

### Create EKS Cluster Config
```shell
cat << EOF > ekscluster.yaml
---
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: ${STACK_NAME}
  region: ${AWS_REGION}
  version: "1.21"

managedNodeGroups:
  - name: nodegroup
    minSize: 1
    maxSize: 5
    desiredCapacity: 1
    instanceType: t3a.small
    ssh:
      allow: false
    labels:
      role: worker
      type: on-demand
    volumeType: gp2
    volumeSize: 40
    volumeEncrypted: true
    disableIMDSv1: true
    disablePodIMDS: false
    instancePrefix: ${STACK_NAME}
    privateNetworking: true
    tags:
      nodegroup-role: worker
    iam:
        attachPolicyARNs:
          - arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy
          - arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy
          - arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
          - arn:aws:iam::aws:policy/service-role/AmazonEC2RoleforSSM

vpc:
  id: "${VPC_ID}"
  subnets:
    private:
      ${AWS_REGION}a:
          id: "${APP_SUBNET_A}"
      ${AWS_REGION}b:
          id: "${APP_SUBNET_B}"
      ${AWS_REGION}c:
          id: "${APP_SUBNET_C}"
    public:
      ${AWS_REGION}a:
          id: "${PUBLIC_SUBNET_A}"
      ${AWS_REGION}b:
          id: "${PUBLIC_SUBNET_B}"
      ${AWS_REGION}c:
          id: "${PUBLIC_SUBNET_C}"
  publicAccessCIDRs:
    - ${MY_IP}/32
cloudWatch:
  clusterLogging:
    enableTypes: ["audit"]
    logRetentionInDays: 7
  
secretsEncryption:
  keyARN: ${MASTER_ARN}

iam:
  withOIDC: true  

EOF
```

### Create EKS Cluster

```shell
eksctl create cluster  -f ekscluster.yaml
```
