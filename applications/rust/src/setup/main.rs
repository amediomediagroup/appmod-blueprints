#[path = "../lambda/types.rs"]
mod types;

use crate::types::{Category, Image, Product, ProductVariant};
use aws_config::default_provider::credentials::DefaultCredentialsChain;
use aws_config::default_provider::region::DefaultRegionChain;
use aws_config::Region;
use aws_sdk_dynamodb::types::{
    AttributeDefinition, KeySchemaElement, KeyType, OnDemandThroughput, ScalarAttributeType,
};
use aws_sdk_dynamodb::Client;
use aws_sdk_dynamodb::Error;
use image::GenericImageView;
use rand::seq::SliceRandom;
use rand::{thread_rng, Rng};
use serde::Deserialize;
use serde_dynamo::to_item;
use std::collections::HashMap;
use std::fs::File;
use uuid::Uuid;

#[derive(Deserialize, Debug, Clone)]
struct CSVProduct {
    category: String,
    product: String,
    name: String,
    variant: String,
    image_number: u32,
    file: String,
}

#[tokio::main]
async fn main() {
    let profile = "vshardul+q-apps-Admin";

    let region = DefaultRegionChain::builder()
        .profile_name(&profile)
        .build()
        .region()
        .await
        .unwrap_or(Region::from_static("us-east-1"));

    let creds = DefaultCredentialsChain::builder()
        .profile_name(&profile)
        .region(region.clone())
        .build()
        .await;

    let config = aws_config::from_env()
        .credentials_provider(creds)
        .region(region)
        .load()
        .await;
    let table_name = std::env::var("TABLE_NAME").unwrap_or(String::from("q-apps-table"));

    let client = Client::new(&config);

    // purge_table(&client, &table_name).await;

    let (products, categories) = csv_to_data();

    for product in &products {
        let product_item = match to_item(&product) {
            Ok(item) => item,
            Err(e) => {
                println!("Error converting product to item: {}", e);
                continue;
            }
        };
        match client
            .put_item()
            .table_name(&table_name)
            .set_item(Some(product_item))
            .send()
            .await
        {
            Ok(_) => {}
            Err(e) => {
                println!("Error putting product: {:?}", e);
            }
        };
    }

    for category in categories.values() {
        let category_item = match to_item(&category) {
            Ok(item) => item,
            Err(e) => {
                println!("Error converting category to item: {}", e);
                continue;
            }
        };
        match client
            .put_item()
            .table_name(&table_name)
            .set_item(Some(category_item))
            .send()
            .await
        {
            Ok(_) => {}
            Err(e) => {
                println!("Error putting category: {:?}", e);
            }
        };
    }

    let front_page_products: Vec<Product> = products
        .choose_multiple(&mut thread_rng(), 3)
        .cloned()
        .collect();

    let front_page_category = Category {
        partition_key: "CATEGORY".to_string(),
        sort_key: "FRONT_PAGE".to_string(),
        path: "front-page".to_string(),
        category_id: Uuid::new_v4().to_string(),
        title: "FRONT Page".to_string(),
        description: "Front Page".to_string(),
        products: front_page_products,
    };

    let front_page_cat_item = match to_item(&front_page_category) {
        Ok(item) => item,
        Err(e) => {
            println!("Error converting front page category to item: {}", e);
            return;
        }
    };
    match client
        .put_item()
        .table_name(&table_name)
        .set_item(Some(front_page_cat_item))
        .send()
        .await
    {
        Ok(_) => {}
        Err(e) => {
            println!("Error putting front page category: {:?}", e);
        }
    };
}

async fn purge_table(ddb_client: &Client, table_name: &String) {
    // delete table
    match ddb_client
        .delete_table()
        .table_name(table_name)
        .send()
        .await
    {
        Ok(_) => {}
        Err(e) => {
            println!("Error deleting table: {:?}", e);
        }
    }
    // wait 5 secs
    tokio::time::sleep(std::time::Duration::from_secs(5)).await;

    let pk = AttributeDefinition::builder()
        .attribute_name("partition_key")
        .attribute_type(ScalarAttributeType::S)
        .build()
        .unwrap();

    let sk = AttributeDefinition::builder()
        .attribute_name("sort_key")
        .attribute_type(ScalarAttributeType::S)
        .build()
        .unwrap();

    let ks = KeySchemaElement::builder()
        .attribute_name("partition_key")
        .key_type(KeyType::Hash)
        .attribute_name("sort_key")
        .key_type(KeyType::Range)
        .build()
        .unwrap();

    let throughput = OnDemandThroughput::builder()
        .max_read_request_units(5)
        .max_write_request_units(5);

    let create_table_response = ddb_client
        .create_table()
        .on_demand_throughput(throughput.build())
        .table_name(table_name)
        .key_schema(ks)
        .attribute_definitions(pk)
        .attribute_definitions(sk)
        .send()
        .await
        .unwrap();

    println!("Table created: {:?}", create_table_response);
}

fn csv_to_data() -> (Vec<Product>, HashMap<String, Category>) {
    let mut csv_products: Vec<CSVProduct> = Vec::new();
    let file = match File::open("./res/products.csv") {
        Ok(file) => file,
        Err(e) => panic!("Required file not found: {}", e),
    };

    let mut rdr = csv::Reader::from_reader(file);
    for result in rdr.deserialize() {
        let record: CSVProduct = match result {
            Ok(record) => record,
            Err(e) => {
                println!("Error: {}", e);
                continue;
            }
        };

        csv_products.push(record.clone());
    }

    let variants = extract_variants(&csv_products);
    let images = extract_images(&csv_products);

    // Build the product type
    let mut products: Vec<Product> = Vec::new();
    let mut categories: HashMap<String, Category> = HashMap::new();

    for csv_product in csv_products {
        let pre_existing_product: Vec<_> = products
            .iter()
            .filter(|p| p.name == csv_product.name)
            .collect();
        if !pre_existing_product.is_empty() {
            continue;
        }

        // construct Product from CSVProduct
        let product = Product {
            partition_key: "PRODUCT".to_string(),
            sort_key: csv_product.name.clone(),
            id: Uuid::new_v4().to_string(),
            name: csv_product.name.clone(),
            description: csv_product.name.clone(),
            inventory: rand::thread_rng().gen_range(1..=1000),
            options: vec![],
            variants: {
                let prod_vars = match variants.get(&csv_product.name) {
                    Some(variants) => variants,
                    None => &Vec::default(),
                };
                prod_vars
                    .iter()
                    .map(|v| Some(ProductVariant {
                        id: v.to_string(),
                        title: v.to_string(),
                        price: rand::thread_rng().gen_range(1..=100).to_string(),
                    }))
                    .collect()
            },
            images: {
                let prod_imgs = match images.get(&csv_product.name) {
                    Some(imgs) => imgs,
                    None => &Vec::default(),
                };
                prod_imgs
                    .iter()
                    .map(|image| {
                        let (width, height) = get_image_dimensions(image);
                        Image {
                            url: format!("https://d2pxm7bxcihgvo.cloudfront.net/{}", image.to_string()),
                            alt_text: format!("{} image", csv_product.name),
                            width,
                            height,
                        }
                    })
                    .collect()
            },
            price: rand::thread_rng().gen_range(1..=100).to_string(),
        };

        match categories.get_mut(&csv_product.category) {
            Some(category) => {
                category.products.push(product.clone());
            }
            None => {
                categories.insert(
                    csv_product.category.clone(),
                    Category {
                        partition_key: "CATEGORY".to_string(),
                        sort_key: csv_product.category.clone(),
                        path: format!("/search/{}", csv_product.category.clone()),
                        category_id: Uuid::new_v4().to_string(),
                        title: csv_product.category.clone(),
                        products: vec![product.clone()],
                        description: csv_product.category.clone(),
                    },
                );
            }
        }

        products.push(product);
    }

    (products, categories)
}

fn get_image_dimensions(file_name: &String) -> (usize, usize) {
    let path = format!("./res/images/{}", file_name);
    let img = match image::open(path) {
        Ok(img) => img,
        Err(e) => panic!("Error opening image: {}", e),
    };

    let (width, height) = img.dimensions();

    (width as usize, height as usize)
}

fn extract_variants(products: &Vec<CSVProduct>) -> HashMap<String, Vec<String>> {
    let mut variants: HashMap<String, Vec<String>> = HashMap::new();
    for product in products {
        if product.variant == "1" {
            continue;
        }
        match variants.get_mut(&product.name) {
            Some(variant) => {
                if !variant.contains(&product.variant) {
                    variant.push(product.variant.clone());
                }
            }
            None => {
                variants.insert(product.name.clone(), vec![product.variant.clone()]);
            }
        }
    }
    variants
}

fn extract_images(products: &Vec<CSVProduct>) -> HashMap<String, Vec<String>> {
    let mut images: HashMap<String, Vec<String>> = HashMap::new();
    for product in products {
        match images.get_mut(&product.name) {
            Some(image) => {
                if !image.contains(&product.file) {
                    image.push(product.file.clone());
                }
            }
            None => {
                images.insert(product.name.clone(), vec![product.file.clone()]);
            }
        }
    }
    images
}
