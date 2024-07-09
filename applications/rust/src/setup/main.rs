#[path = "../lambda/types.rs"]
mod types;

use std::fs::File;
use csv::{Reader};
use aws_sdk_s3 as s3;
use aws_config::Region;
use aws_sdk_dynamodb as ddb;
use aws_config::default_provider::credentials::DefaultCredentialsChain;
use aws_config::default_provider::region::DefaultRegionChain;

fn main() {
    // read from ./res/products.csv
    let file = match File::open("./res/products.csv") {
        Ok(file) => file,
        Err(e) => panic!("Required file not found: {}", e)
    };

    let mut rdr = csv::Reader::from_reader(file);
    for result in rdr.records() {
        let record = result?;
        println!("{:?}", record);
    }
}