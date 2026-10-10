CREATE TABLE orders (
  id INTEGER PRIMARY KEY,
  total DECIMAL(10,2),
  customer_id INTEGER REFERENCES customers(id)
);

CREATE TABLE customers (
  id INTEGER PRIMARY KEY,
  email TEXT
);

CREATE INDEX orders_customer_idx ON orders (customer_id);
