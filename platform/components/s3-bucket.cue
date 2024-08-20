"s3-bucket": {
	alias: ""
	annotations: {}
	attributes: workload: definition: {
		apiVersion: "aws-service/v1"
		kind:       "Bucket"
	}
	description: "AWS S3 Bucket"
	labels: {}
	type: "component"
}

template: {
	output: {
		apiVersion: "awsblueprints.io/v1alpha1"
		kind:       "ObjectStorage"
		metadata: {
          name: context.name
    }
		spec: {
		      compositionSelector: {
					      matchLabels: {
						    			"awsblueprints.io/provider": "aws"
						    			"awsblueprints.io/environment": parameter.environment
						    			"s3.awsblueprints.io/configuration": parameter.configuration
						    }
					}
					writeConnectionSecretToRef: {
								name: "\(context.name)-info"
					}
					resourceConfig: {
								providerConfigName: parameter.providerConfigName,
								region: parameter.region,
								tags: [
											{
												"key": "name",
												"value": context.name
											}
								]
					}
		}
	}
	parameter: {
        environment: string
        configuration: string
        providerConfigName: string
        region: string
  }
}