# Solr demo catalogue

You have a `solr` MCP server connected to a read-only view of a small product catalogue.
Search and inspect it freely. Writes are not possible: the Solr endpoint behind this
server refuses them, so do not try to index, change schemas, or create collections or
aliases. If asked to, say that this connection is read-only.

## Collections

- `products` - one document per product. Unique key `product_oid` (e.g. `P0001`).
  Fields: `title`, `description` (full text), `brand`, `category` (exact strings, e.g.
  `Clothing > Outdoor`).
- `skus` - one document per sellable variant of a product (product x merchant x variant).
  Unique key `sku_oid` (e.g. `S00001`). Fields: `product_oid` (links to `products`),
  `merchant_id`, `colour`, `size`, `price` (GBP), `currency`, `stock`, `in_stock`.

The collections are separate and there is no cross-collection join tool. To answer a
question that spans both, query one collection, then filter the other with the
`product_oid` values you found, e.g. `fq=product_oid:(P0001 OR P0002)`.

## Tips

- **Make tool calls one at a time.** Do not call the `solr` tools in parallel (for example
  `get-collection-stats` on two collections at once): the server can lose a response and then
  stop answering. Wait for each result before the next call.

- The collections and fields above are complete and exact (case-sensitive), so search
  straight away. Only call `list-collections` or `get-schema` if a query fails or the user
  asks what exists.
- Use full text (`q`) against `products.title` / `products.description`, and filters
  (`fq`) on the exact-string fields (`brand`, `category`, `colour`, `size`, `merchant_id`).
- Prices are per SKU and differ by merchant; a product has no price of its own.
