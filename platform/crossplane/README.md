# Crossplane Compostion and Examples

This folder contains examples for deploying AWS resources using the following providers

- [AWS Provider](https://github.com/crossplane/provider-aws)

## Pre-requisites:
 - EKS Cluster. Please [eksctl](https://eksctl.io/usage/creating-and-managing-clusters/) or [cdk eks blueprints](https://github.com/aws-quickstart/cdk-eks-blueprints) to boostrap your EKS cluster.
 - [Crossplane deployment](https://github.com/crossplane/provider-aws) in bootstrap cluster.
 - [ProviderConfig](https://marketplace.upbound.io/providers/crossplane-contrib/provider-kubernetes/v0.11.4/resources/kubernetes.crossplane.io/ProviderConfig/v1alpha1) deployment with injected identity.
 - Argo installed on EKS cluster.

## AWS Provider
The following steps demonstrates AWS example composition deployment with **AWS Provider**

### Deploy Composition/XRD for Amazon RDS and Amazon Aurora

Run the following Argo application to deploy Composition/XRDs for Amazon RDS:

```shell
kubectl apply -f ./crossplane-compositions.yaml
```

Upon deployment of Argo application, run the following examples to create Amazon RDS and Amazon Aurora postgres cluster:

```shell
kubectl apply -f ./examples/
```