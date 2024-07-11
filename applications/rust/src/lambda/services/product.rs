use rocket::{error, get, post, State};
use rocket::http::Status;
use rocket::response::status;
use crate::types::{Product, ProductVariant, UIResponder};
use lambda_runtime::Error;
use aws_sdk_dynamodb as ddb;
use aws_sdk_dynamodb::operation::query::{QueryError, QueryOutput};
use aws_sdk_dynamodb::types::AttributeValue;
use rand::Rng;
use rocket::serde::json::Json;
use serde_dynamo::from_item;

#[get("/product/<id>")]
pub async fn get_product(id: &str, db: &State<ddb::Client>) -> UIResponder<Product> {
    let results = db
        .query()
        .table_name("Product")
        .key_condition_expression("partition_key = :pk_val")
        .expression_attribute_values(":pk_val", AttributeValue::S("PRODUCT".to_string()))
        .filter_expression("id = :id")
        .expression_attribute_values(":id", AttributeValue::S(id.to_string()))
        .send()
        .await;

    match results {
        Ok(output) => {
            let items = output.items().to_vec();
            if items.len() > 1 {
                // if there's more than one item, something is wrong
                UIResponder::Err(error!("Error getting product: multiple items found"))
            } else if items.len() == 0 {
                // if there's no items, something is wrong
                UIResponder::Err(error!("Error getting product: no items found"))
            } else {
                // let product: Product = from_item(items.get(0))?;

                // let product = Product {
                //     id: item.get("id").unwrap().as_s().unwrap().to_string(),
                //     name: item.get("name").unwrap().as_s().unwrap().to_string(),
                //     description: item.get("name").unwrap().as_s().unwrap().to_string(),
                //     inventory: 0,
                //     variants: vec![],
                //     price: "".to_string(),
                //     options: vec![],
                //     images: vec![],
                // };
                UIResponder::Ok(Product::default().into())
            }
        }
        Err(e) => {
            UIResponder::Err(error!("Error getting product: {:?}", e))
        }
    }
}

#[post("/products", format="json", data="<search_val>")]
pub async fn get_products(
    search_val: String,
    db: &State<ddb::Client>,
    table_name: &State<String>
) -> UIResponder<Vec<Product>> {
    let results = db
        .query()
        .table_name(table_name.to_string())
        .key_condition_expression("partition_key = :pk_val")
        .expression_attribute_values(":pk_val", AttributeValue::S("PRODUCT".to_string()))
        .filter_expression("contains(product, :name)")
        .expression_attribute_values(":name", AttributeValue::S(search_val.to_string()))
        .send()
        .await;

    match results {
        Ok(output) => {
            let items = output.items();
            let mut products = vec![];
            for item in items {
                let product = Product {
                    partition_key: "".to_string(),
                    sort_key: "".to_string(),
                    id: item.get("id").unwrap().as_s().unwrap().to_string(),
                    name: item.get("name").unwrap().as_s().unwrap().to_string(),
                    description: item.get("name").unwrap().as_s().unwrap().to_string(),
                    inventory: 0,
                    variants: vec![],
                    price: "".to_string(),
                    options: vec![],
                    images: vec![],
                };
                products.push(product);
            }
            UIResponder::Ok(products.into())
        }
        Err(e) => {
            UIResponder::Err(error!("Error searching for products: {:?}", e))
        }
    }
}

// pub async fn reconstruct_product(product_id: &str, db: &ddb::Client, table_name: &str) -> Product {
//     let results = db
//         .query()
//         .table_name(table_name)
//         .key_condition_expression("partition_key = :pk_val")
//         .expression_attribute_values(":pk_val", AttributeValue::S("PRODUCT".to_string()))
//         .filter_expression("id = :product_id")
//         .expression_attribute_values(":product_id", AttributeValue::S(product_id.to_string()))
//         .send()
//         .await;
//
//     let results = match results {
//         Ok(output) => output.items().to_vec(),
//         Err(e) => todo!()
//     };
//
// }