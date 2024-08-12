# Ecommerce Lambda Function

This is a serverless application built with Rust and AWS Lambda that provides a backend for an e-commerce platform. It interacts with an AWS DynamoDB table to handle various operations related to products, categories, collections, and carts.

## Services

### Product Service

- `GET /products`: Retrieves a list of all products.
- `GET /product/<product_id>`: Retrieves details of a specific product.
- `GET /category/<category_id>/products`: Retrieves a list of products belonging to a specific category.
- `GET /collection/<collection_handle>`: Retrieves a list of products belonging to a specific collection.

### Category Service

- `GET /categories`: Retrieves a list of all categories.
- `GET /category/<category_id>`: Retrieves details of a specific category.

### Cart Service

- `POST /cart`: Creates a new cart.
- `POST /cart/<cart_id>/add`: Adds a product to the cart.
- `GET /cart/<cart_id>`: Retrieves the contents of a cart.
- `DELETE /cart/<cart_id>/remove/<product_id>`: Removes a product from the cart.

### UI Service

- `GET /menu`: Retrieves the menu structure (categories and collections).
- `GET /pages`: Retrieves a list of all pages.
- `GET /page/<page_id>`: Retrieves details of a specific page.

## Deployment Guide

To deploy this application to AWS Lambda, follow these steps:

1. **Set up AWS Credentials**: Configure your AWS credentials using the AWS CLI or by setting the `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` environment variables.

2. **Create a DynamoDB Table**: Create a DynamoDB table to store the application data. Make sure to update the 
3. `TABLE_NAME` environment variable with the name of your DynamoDB table.

3. **Build the Lambda Package**: Build the Rust application using the `cargo lambda build --release` command. 
4. This will create a deployment package in the `target/lambda/bootstrap` directory.

4. **Create the Lambda Function**: Create a new Lambda function using the AWS Lambda console or the AWS CLI. 
5. When creating the function, choose the "Author from scratch" option, and select the "Rust" runtime. Upload the deployment package created in the previous step.

5. **Configure Environment Variables**: Set the following environment variables for the Lambda function:
    - `TABLE_NAME`: The name of the DynamoDB table you created earlier.
    - `AWS_REGION`: The AWS region where your DynamoDB table is located.

6. **Set up API Gateway**: Create a new API Gateway and integrate it with the Lambda function. Configure the API Gateway
7. routes to match the service endpoints defined in this README.

7. **Deploy the API Gateway**: Deploy the API Gateway to make it publicly accessible.

8. **Test the Application**: Use tools like Postman or curl to test the various endpoints of the application.

