mod types;
mod services;

use services::ui::*;
use services::cart::*;
use aws_config::Region;
use services::product::*;
use rocket::{self, routes};
use lambda_runtime::tracing;
use aws_sdk_dynamodb as ddb;
use aws_config::default_provider::region::DefaultRegionChain;
use aws_config::default_provider::credentials::DefaultCredentialsChain;
use lambda_web::{is_running_on_lambda, launch_rocket_on_lambda, LambdaError};

#[rocket::main]
async fn main() -> Result<(), LambdaError> {
    tracing::init_default_subscriber();

    let profile = "vshardul+q-apps-Admin";

    let region = DefaultRegionChain::builder()
        .profile_name(&profile)
        .build()
        .region().await
        .unwrap_or(Region::from_static("us-east-1"));

    let creds = DefaultCredentialsChain::builder()
        .profile_name(&profile)
        .region(region.clone())
        .build()
        .await;


    let config = aws_config::from_env().credentials_provider(creds).region(region).load().await;
    let table_name = std::env::var("TABLE_NAME").unwrap_or(String::from("q-apps-table"));

    let rocket = rocket::build()
        .manage(ddb::Client::new(&config))
        .manage(table_name)
        .mount("/", routes![
            create_cart, add_to_cart, get_cart, update_cart, remove_from_cart, 
            get_product, get_products,
            get_menu, get_page, get_pages, get_category, get_category_products, get_categories,
            get_collection
    ]);
    if is_running_on_lambda() {
        // Launch on AWS Lambda
        launch_rocket_on_lambda(rocket).await?;
    } else {
        // Launch local server
        let _ = rocket.launch().await?;
    }
    
    Ok(())
}
