# istio-adot-demo

Istio Demo with AWS Distribution of Open Telemetry and Datadog.

This example provides observability of Istio Service mesh with following destinations:
- Amazon Managed Prometheus, Amazon Managed Grafana, Kiali
- Datadog
- CloudWatch Metrics, XRAY, Service Lense

## Deployment Architecture
![Deployment Architecture](https://lucid.app/publicSegments/view/fb4a0216-b359-4d1b-9e89-e5fe27a739d4/image.png)

## Sample Application Architecture
This demonstration utilizes sample bookinfo example by Istio.

[![Istio Bookinfo Application](https://istio.io/latest/docs/examples/bookinfo/noistio.svg)](https://istio.io/latest/docs/examples/bookinfo/)

## Setup

### Pre Requisites
- [eksctl](https://docs.aws.amazon.com/eks/latest/userguide/eksctl.html)
- [awscli v2](https://aws.amazon.com/cli/)
- [jq](https://stedolan.github.io/jq/download/)
- [AWS Account](https://aws.amazon.com/free/)
- [VPC Setup](#vpc-setup)

### VPC Setup
This demo requires deployment across 3 AZ and a total of 6 subnets.

- 3 Public Subnets (Deployed in zones a, b, c) e.g. us-east-1a, us-east-1b, us-east-1c
- 3 Private App Subnets (Deployed in zones a,b,c )

If you do not have a VPC setupr eady, you may use: [VPC QuickStart Guide](https://aws-quickstart.github.io/quickstart-aws-vpc/)
to create reference VPC for this demo.

### Tag VPC Subnets

Follow [eks-vpc-subnet-discovery blog post](https://aws.amazon.com/premiumsupport/knowledge-center/eks-vpc-subnet-discovery/) to tag the 
public and private(app) subnets appropriately.

### Global Variables

```shell
export AWS_REGION=us-west-2
export AWS_PROFILE=intraedge-training
export AWS_DEFAULT_REGION=$AWS_REGION
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity | jq -r '.Account')
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
export ISTIO_VERSION=1.11.4
export INGRESS_HOST=$(kubectl -n istio-system get service istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
export INGRESS_PORT=$(kubectl -n istio-system get service istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="http2")].port}')
export SECURE_INGRESS_PORT=$(kubectl -n istio-system get service istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="https")].port}')
export TCP_INGRESS_PORT=$(kubectl -n istio-system get service istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="tcp")].port}')
export GATEWAY_URL=$INGRESS_HOST:$INGRESS_PORT
export KUBECONFIG=~/.kubeconfig/$STACK_NAME 

```

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
  - name: on-demand
    minSize: 1
    maxSize: 5
    desiredCapacity: 2
    instanceTypes: ['t3a.medium', 't3.medium']
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

  clusterEndpoints:
    publicAccess:  true
    privateAccess: true

cloudWatch:
  clusterLogging:
    enableTypes: ["audit"]
    logRetentionInDays: 7
  
secretsEncryption:
  keyARN: ${MASTER_ARN}

iam:
  withOIDC: true  

addons:
- name: vpc-cni
  version: 1.9.3
- name: coredns
  version: 1.8.4
- name: kube-proxy
  version: 1.21.2

EOF
```

### Create EKS Cluster

```shell
eksctl create cluster  -f ekscluster.yaml
```

### Setup Kubectl Config

```shell
export KUBECONFIG=~/.kubeconfig/$STACK_NAME 
eksctl utils write-kubeconfig $STACK_NAME  --kubeconfig $KUBECONFIG 
```

### Deploying Kubernetes Dashboard
See [EKS Dashboard Deployment Tutorial](https://docs.aws.amazon.com/eks/latest/userguide/dashboard-tutorial.html)
Deploy dashboard version v2.4.0

### ELB Service Linked Role

```shell
aws iam get-role --role-name "AWSServiceRoleForElasticLoadBalancing" || aws iam create-service-linked-role --aws-service-name "elasticloadbalancing.amazonaws.com"
```

### Setup Istio

```shell
istioctl install
```

### Setup Sample App

See [Istio BookInfo example for reference architecture](https://istio.io/latest/docs/examples/bookinfo/)

```shell
kubectl label namespace default istio-injection=enabled

kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.11/samples/bookinfo/platform/kube/bookinfo.yaml
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.11/samples/bookinfo/networking/bookinfo-gateway.yaml
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.11/samples/bookinfo/networking/destination-rule-all.yaml

export INGRESS_HOST=$(kubectl -n istio-system get service istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
export INGRESS_PORT=$(kubectl -n istio-system get service istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="http2")].port}')
export SECURE_INGRESS_PORT=$(kubectl -n istio-system get service istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="https")].port}')
export TCP_INGRESS_PORT=$(kubectl -n istio-system get service istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="tcp")].port}')
export GATEWAY_URL=$INGRESS_HOST:$INGRESS_PORT
```


### Observability Add Ons

```shell
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.11/samples/addons/grafana.yaml
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.11/samples/addons/jaeger.yaml

```

### AMP

#### AMP Workspace

```shell
aws amp create-workspace --alias $STACK_NAME
```

##### Create AMP Ingestion IAM Role

```shell
./scripts/createIRSA-AMPIngest.sh
```

See https://docs.aws.amazon.com/prometheus/latest/userguide/set-up-irsa.html#set-up-irsa-ingest for more details.

#### Create Prometheus ADOT Daemonset

```shell
export AMP_WORKSPACE_ID=$(aws amp list-workspaces | jq --arg amp_alias "$STACK_NAME"   -r '.workspaces | .[] | select(.alias == $amp_alias) | .workspaceId')
export AMP_ENDPOINT="https://aps-workspaces.$AWS_REGION.amazonaws.com/workspaces/$AMP_WORKSPACE_ID/api/v1/remote_write"
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity | jq -r '.Account')
cat manifests/prometheus-adot-daemonset.yaml | envsubst | kubectl apply -f -
```

### Sigv4 Admission Controller
We need this to allow injection of sidecar to Kiali to make calls to AWS

See https://github.com/aws-observability/aws-sigv4-proxy-admission-controller

```shell
kubectl create namespace aws-sigv4-proxy           
kubectl label namespace aws-sigv4-proxy  istio-injection=false
helm repo add eks https://aws.github.io/eks-charts
helm install aws-sigv4-proxy-admission-controller eks/aws-sigv4-proxy-admission-controller --namespace aws-sigv4-proxy
```

### Kiali

```shell
# Local
# kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.11/samples/addons/prometheus.yaml
# kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.11/samples/addons/kiali.yaml

# AMP
export STACK_NAME=istio-otel-demo
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity | jq -r '.Account')
export AMP_WORKSPACE_ID=$(aws amp list-workspaces | jq --arg amp_alias "$STACK_NAME"   -r '.workspaces | .[] | select(.alias == $amp_alias) | .workspaceId')
cat manifests/kiali.yaml | envsubst | kubectl apply -f -
```

To launch Kiali, execute
```shell
istioctl dashboard kiali
```

[Launch Kiali Dashboard](http://localhost:20001/kiali/console/graph/namespaces/?edges=trafficRate%2CresponseTime%2Crt95&traffic=grpc%2CgrpcRequest%2Chttp%2ChttpRequest%2Ctcp%2CtcpSent&graphType=versionedApp&namespaces=default&idleNodes=false&duration=60&refresh=15000&operationNodes=false&idleEdges=false&injectServiceNodes=true&layout=dagre)
