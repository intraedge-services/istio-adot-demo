#!/bin/bash -e

# See https://docs.aws.amazon.com/prometheus/latest/userguide/set-up-irsa.html#set-up-irsa-ingest
CLUSTER_NAME=$STACK_NAME
SERVICE_ACCOUNT_NAMESPACE=istio-system
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
OIDC_PROVIDER=$(aws eks describe-cluster --name $CLUSTER_NAME --query "cluster.identity.oidc.issuer" --output text | sed -e "s/^https:\/\///")
SERVICE_ACCOUNT_KIALI=kiali
SERVICE_ACCOUNT_IAM_KIALI_ROLE=$STACK_NAME-kiali
SERVICE_ACCOUNT_IAM_KIALI_AMP_POLICY=$STACK_NAME-kiali-amp
#
# Set up a trust policy designed for a specific combination of K8s service account and namespace to sign in from a Kubernetes cluster which hosts the OIDC Idp.
#
cat <<EOF > KialiAMPTrustPolicy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_PROVIDER}:sub": "system:serviceaccount:${SERVICE_ACCOUNT_NAMESPACE}:${SERVICE_ACCOUNT_KIALI}"
        }
      }
    }
  ]
}
EOF
#
# Set up the permission policy that grants ingest (remote write) permissions for all AMP workspaces
#
cat <<EOF > KialiAMPPermissionPolicyIngest.json
{
  "Version": "2012-10-17",
   "Statement": [
       {"Effect": "Allow",
        "Action": [
           "aps:GetSeries",
           "aps:GetLabels",
           "aps:GetMetricMetadata",
           "aps:QueryMetrics"
        ],
        "Resource": "*"
      }
   ]
}
EOF

function getRoleArn() {
  OUTPUT=$(aws iam get-role --role-name $1 --query 'Role.Arn' --output text 2>&1)

  # Check for an expected exception
  if [[ $? -eq 0 ]]; then
    echo $OUTPUT
  elif [[ -n $(grep "NoSuchEntity" <<< $OUTPUT) ]]; then
    echo ""
  else
    >&2 echo $OUTPUT
    return 1
  fi
}

#
# Create the IAM Role for kiali with the above trust policy
#
SERVICE_ACCOUNT_IAM_KIALI_ROLE_ARN=$(getRoleArn "$SERVICE_ACCOUNT_IAM_KIALI_ROLE")
if [ "$SERVICE_ACCOUNT_IAM_KIALI_ROLE_ARN" = "" ];
then
  #
  # Create the IAM role for service account
  #
  SERVICE_ACCOUNT_IAM_KIALI_ROLE_ARN=$(aws iam create-role \
  --role-name "$SERVICE_ACCOUNT_IAM_KIALI_ROLE" \
  --assume-role-policy-document file://KialiAMPTrustPolicy.json \
  --query "Role.Arn" --output text)
  #
  # Create an IAM permission policy
  #
  SERVICE_ACCOUNT_IAM_KIALI_AMP_POLICY_ARN=$(aws iam create-policy --policy-name "$SERVICE_ACCOUNT_IAM_KIALI_AMP_POLICY" \
  --policy-document file://KialiAMPPermissionPolicyIngest.json \
  --query 'Policy.Arn' --output text)
  #
  # Attach the required IAM policies to the IAM role created above
  #
  aws iam attach-role-policy \
  --role-name "$SERVICE_ACCOUNT_IAM_KIALI_ROLE" \
  --policy-arn "$SERVICE_ACCOUNT_IAM_KIALI_AMP_POLICY_ARN"
else
    echo "$SERVICE_ACCOUNT_IAM_KIALI_ROLE_ARN IAM role for ingest already exists"
fi
echo "$SERVICE_ACCOUNT_IAM_KIALI_ROLE_ARN"
#
# EKS cluster hosts an OIDC provider with a public discovery endpoint.
# Associate this IdP with AWS IAM so that the latter can validate and accept the OIDC tokens issued by Kubernetes to service accounts.
# Doing this with eksctl is the easier and best approach.
#
eksctl utils associate-iam-oidc-provider --cluster $CLUSTER_NAME --approve
rm KialiAMPTrustPolicy.json KialiAMPPermissionPolicyIngest.json
