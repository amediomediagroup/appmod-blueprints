# Integration Testing

We're using Artillery to load test our Rust Microservice, as this provides deep CI/CD
integration for a variety of platforms including automated promotions as supported by
CodePipeline and other DevOps Pipeline solutions.

Our system integrates with Argo Rollouts and Amazon Managed Prometheus to understand
success and failure metrics for our integration tests in the test environment before
being automatically promoted/rolled-back through Argo Rollouts.

Leveraging a version controlled load testing engine ensures that the Testing and QA
team can build out comprehensive integration tests for each of the new features wihtout
being blocked by the engineering team.

### Local Testing

To locally test your code, use the included `benchmark-local.yaml` file with the [Artillery
CLI](https://www.artillery.io/docs/get-started/get-artillery).

It uses a smaller and slower test against the microservice to not overwhelm your development
environment.

You can run the test with:
```bash
artillery run benchmark-local.yaml
```

### Testing on EKS

Included is the `benchmark.yaml`, `Dockerfile`, and Manifest required to setup the
Argo Rollout for any Kubernetes deployment with ArgoCD and Rollouts enabled and
configured.
It sets up the Artillery CLI, and then invokes it using our defined parameters in
the benchmark file. 


### Creating and Exporting reports

As part of the CI/CD system, we setup generating and exporting load testing reports to
establish a developer baseline for any new features. It lets the Ops team compare
their production environments against the developer baselines; and let's the Developer
teams understand how their application is behaving in an isolated environment and the
production environment.