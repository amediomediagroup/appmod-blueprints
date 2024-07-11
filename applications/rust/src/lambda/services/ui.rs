use rand::Rng;
use aws_sdk_dynamodb as ddb;
use std::collections::HashMap;
use rocket::serde::json::Json;
use aws_sdk_dynamodb::types::AttributeValue;
use rocket::{error, get, post, Responder, State};
use crate::types::{Menu, Page, Category, Product, UIResponder};
use aws_sdk_dynamodb::operation::query::{QueryError, QueryOutput};
use serde_dynamo::{from_item, from_items};

#[get("/menu/<menu_id>")]
pub async fn get_menu(menu_id: &str, db: &State<ddb::Client>) -> UIResponder<Vec<Menu>> {
    return match menu_id {
        "navbar" => {
            UIResponder::Ok(vec![
                Menu {
                    title: "AWS Store".to_string(),
                    path: "/".to_string(),
                },
                Menu {
                    title: "All".to_string(),
                    path: "/search".to_string(),
                },
                Menu {
                    title: "Shirts".to_string(),
                    path: "/search/shirts".to_string(),
                },
                Menu {
                    title: "Stickers".to_string(),
                    path: "/search/stickers".to_string(),
                }
            ].into())
        }
        "footer" => {
            UIResponder::Ok(vec![
                Menu {
                    title: "Home".to_string(),
                    path: "/".to_string(),
                },
                Menu {
                    title: "About".to_string(),
                    path: "/about".to_string(),
                },
                Menu {
                    title: "Terms & Conditions".to_string(),
                    path: "/terms-conditions".to_string(),
                },
                Menu {
                    title: "Privacy Policy".to_string(),
                    path: "/privacy-policy".to_string(),
                },
                Menu {
                    title: "FAQ".to_string(),
                    path: "/faq".to_string()
                }
            ].into())
        }
        _ => {
            UIResponder::Err(error!("Menu not found"))
        }
    }
}

#[get("/page/<page_handle>")]
pub async fn get_page(page_handle: String, db: &State<ddb::Client>) -> UIResponder<Page> {
    UIResponder::Ok(Page::default().into())
}

#[get("/pages")]
pub async fn get_pages(db: &State<ddb::Client>) -> UIResponder<Vec<Page>> {
    UIResponder::Ok(vec![Page::default()].into())
}

#[get("/category/<category_handle>")]
pub async fn get_category(
    category_handle: String,
    db: &State<ddb::Client>,
    table_name: &State<String>
) -> UIResponder<Category> {
    let table_name = table_name.inner();
    let results = db
        .query()
        .table_name(table_name)
        .key_condition_expression("partition_key = :pk_val AND begins_with(sort_key, :sk_val)")
        .expression_attribute_values(":pk_val", AttributeValue::S("CATEGORY".to_string()))
        .expression_attribute_values(":sk_val", AttributeValue::S(category_handle.clone()))
        .send()
        .await;

    let results = results.unwrap().items;

    println!("{:?}", results);

    match results {
        Some(items) => {
            // ensure that items only has one item in it
            if items.len() > 1 {
                UIResponder::Err(error!("More than one item found for this category"))
            } else {
                let item = items.get(0).unwrap();
                println!("{:?}", item);

                let category = Category {
                    partition_key: "".to_string(),
                    sort_key: "".to_string(),
                    path: category_handle,
                    category_id: item.get("id").unwrap().as_s().unwrap().to_string(),
                    title: item.get("name").unwrap().as_s().unwrap().to_string(),
                    description : item.get("name").unwrap().as_s().unwrap().to_string(),
                    products: vec![],
                };

                UIResponder::Ok(category.into())
            }

        },
        None => UIResponder::Err(error!("Looks like this category doesn't exist"))
    }
}

#[get("/category/<category_handle>/products")]
pub async fn get_category_products(
    category_handle: &str,
    db: &State<ddb::Client>,
    table_name: &State<String>
) -> UIResponder<Vec<Product>> {
    let table_name = table_name.inner();

    let results = db
        .query()
        .table_name(table_name)
        .key_condition_expression("partition_key = :prod AND sort_key = :sk")
        .expression_attribute_values(":prod", AttributeValue::S("CATEGORY".to_string()))
        .expression_attribute_values(":sk", AttributeValue::S(category_handle.to_string()))
        .send()
        .await;


    return match results {
        Ok(res) => {
            let categories: Vec<Category> = match from_items(res.items().to_vec()) {
                Ok(res) => {
                    // there should only be one category
                    if res.len() > 1 {
                        return UIResponder::Err(error!("More than one category found"))
                    } else {
                        res
                    }
                },
                Err(err) => {
                    println!("{:?}", err);
                    return UIResponder::Err(error!("Failed to convert from DDB to Front end"))
                }
            };

            let category: Category = categories.first().unwrap_or(&Category::default()).clone();

            let products: Vec<Product> = category.clone().products;

            UIResponder::Ok(products.into())
        },
        Err(err) => {
            println!("{:?}", err);
            UIResponder::Err(error!("Something went wrong"))
        }
    }
}

#[get("/categories")]
pub async fn get_categories(
    db: &State<ddb::Client>,
    table_name: &State<String>
) -> UIResponder<Vec<Category>> {
    let table_name = table_name.inner();

    let results = db
        .query()
        .table_name(table_name)
        .key_condition_expression("partition_key = :pk_val")
        .expression_attribute_values(":pk_val", AttributeValue::S("CATEGORY".to_string()))
        .send()
        .await;

    return match results {
        Ok(res) => {
            let categories: Vec<Category> = match from_items(res.items().to_vec()) {
                Ok(res) => res,
                Err(err) => {
                    println!("{:?}", err);
                    return UIResponder::Err(error!("Failed to convert from DDB to Front end"))
                }
            };

            UIResponder::Ok(categories.into())
        },
        Err(err) => {
            println!("{:?}", err);
            UIResponder::Err(error!("Something went wrong"))
        }
    }
}

#[get("/collection/<collection_handle>")]
pub async fn get_collection(
    collection_handle: &str,
    db: &State<ddb::Client>,
    table_name: &State<String>
) -> UIResponder<Vec<Product>> {
    let results = db
        .query()
        .table_name(table_name.to_string())
        .key_condition_expression("partition_key = :pk_val AND sort_key = :sk_val")
        .expression_attribute_values(":pk_val", AttributeValue::S("CATEGORY".to_string()))
        .expression_attribute_values(":sk_val", AttributeValue::S(collection_handle.to_string()))
        .send()
        .await;


    return match results {
        Ok(res) => {
            let products: Vec<Product> = match from_items(res.items().to_vec()) {
                Ok(res) => res,
                Err(err) => {
                    println!("{:?}", err);
                    return UIResponder::Err(error!("Failed to convert from DDB to Front end"))
                }
            };

            UIResponder::Ok(products.into())
        },
        Err(err) => {
            println!("{:?}", err);
            UIResponder::Err(error!("Something went wrong"))
        }
    }
}
