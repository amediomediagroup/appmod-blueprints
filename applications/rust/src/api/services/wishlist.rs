/***
    Implement the following routes:

        - POST /wishlist/new: Creates a new wishlist, returns a full wishlist object.
        - POST /wishlist/<wishlist_id>/add: Adds a product to the specified wishlist, expects the cart product in the posted json data
        - GET /wishlist/<wishlist_id>: Retrieves the contents of the specified wishlist.
        - POST /wishlist/<wishlist_id>/remove/: Removes a product from the wishlist, expects product ID in the posted json data

        Use AWS dynamodb to persist wishlist data. Design for concurrent requests, scalability, and performance.

        Requirements:

        - Proper error handling and HTTP status codes.
        - Unit tests for correctness.
        - Code documentation and Rust best practices.
        - Authentication and authorization for accessing/modifying wishlists.
        - Consider caching mechanisms for performance.

        Generate the Rust code for the wishlist service, including data structures, routes, handlers.
        Explain your implementation and design decisions briefly.
 */