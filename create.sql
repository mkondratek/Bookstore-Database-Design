DROP TABLE IF EXISTS books CASCADE;
DROP TABLE IF EXISTS orders CASCADE;
DROP TABLE IF EXISTS genres CASCADE;
DROP TABLE IF EXISTS authors CASCADE;
DROP TABLE IF EXISTS reviews CASCADE;
DROP TABLE IF EXISTS shippers CASCADE;
DROP TABLE IF EXISTS discounts CASCADE;
DROP TABLE IF EXISTS customers CASCADE;
DROP TABLE IF EXISTS employees CASCADE;
DROP TABLE IF EXISTS publishers CASCADE;
DROP TABLE IF EXISTS books_genres CASCADE;
DROP TABLE IF EXISTS orders_details CASCADE;
DROP TABLE IF EXISTS books_discounts CASCADE;
DROP TABLE IF EXISTS customers_discounts CASCADE;

DROP VIEW IF EXISTS book_adder;
DROP VIEW IF EXISTS books_rank;

DROP FUNCTION IF EXISTS is_phonenumber();
DROP FUNCTION IF EXISTS give_discount();
DROP FUNCTION IF EXISTS is_available();
DROP FUNCTION IF EXISTS has_bought();
DROP FUNCTION IF EXISTS is_isbn();

DROP RULE IF EXISTS adder
ON book_adder;

CREATE OR REPLACE FUNCTION has_bought()
  RETURNS TRIGGER AS $$
BEGIN
  IF (SELECT count(book_id) AS a
      FROM orders_details
        JOIN orders ON orders_details.order_id = orders.id
      WHERE customer_id = new.customer_id AND book_id LIKE new.book_id) = 0
  THEN RAISE EXCEPTION 'CUSTOMER HAS NOT BOUGHT THIS BOOK'; END IF;

  IF (SELECT count(book_id)
      FROM reviews
      WHERE
        book_id LIKE new.book_id AND customer_id = new.customer_id) > 0
  THEN
    DELETE FROM reviews
    WHERE customer_id = NEW.customer_id AND book_id LIKE NEW.book_id;
  END IF;

  RETURN new;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION give_discount()
  RETURNS TRIGGER AS $$
DECLARE id  BIGINT DEFAULT NULL;
        val NUMERIC DEFAULT NULL;
BEGIN
  val = (SELECT max(discounts.value)
         FROM discounts
           JOIN customers_discounts ON discounts.id = customers_discounts.discount_id
         WHERE customer_id = new.customer_id);
  id = (SELECT discounts.id
        FROM discounts
          JOIN customers_discounts ON discounts.id = customers_discounts.discount_id
        WHERE customer_id = new.customer_id AND discounts.value = val);
  new.discount_id = id;
  RETURN new;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION is_phonenumber()
  RETURNS TRIGGER AS $$
DECLARE tmp NUMERIC;
BEGIN
  IF (length(new.phone_number) != 9)
  THEN RAISE EXCEPTION 'INVALID PHONE NUMBER'; END IF;
  tmp = new.phone_number :: NUMERIC;
  RETURN new;
  EXCEPTION WHEN OTHERS
  THEN RAISE EXCEPTION 'INVALID PHONE NUMBER';
    RETURN new;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION is_isbn()
  RETURNS TRIGGER AS $$
DECLARE tmp NUMERIC DEFAULT 11;
BEGIN
  IF (length(new.isbn) = 13)
  THEN tmp = (11 - (
                     substr(NEW.isbn, 1, 1) :: NUMERIC * 10 +
                     substr(NEW.isbn, 3, 1) :: NUMERIC * 9 +
                     substr(NEW.isbn, 4, 1) :: NUMERIC * 8 +
                     substr(NEW.isbn, 5, 1) :: NUMERIC * 7 +
                     substr(NEW.isbn, 7, 1) :: NUMERIC * 6 +
                     substr(NEW.isbn, 8, 1) :: NUMERIC * 5 +
                     substr(NEW.isbn, 9, 1) :: NUMERIC * 4 +
                     substr(NEW.isbn, 10, 1) :: NUMERIC * 3 +
                     substr(NEW.isbn, 11, 1) :: NUMERIC * 2)
                   % 11) % 11;
  END IF;
  IF ((length(NEW.isbn) = 17
       AND (
             substr(NEW.isbn, 1, 1) :: NUMERIC +
             substr(NEW.isbn, 2, 1) :: NUMERIC * 3 +
             substr(NEW.isbn, 3, 1) :: NUMERIC +
             substr(NEW.isbn, 5, 1) :: NUMERIC * 3 +
             substr(NEW.isbn, 6, 1) :: NUMERIC +
             substr(NEW.isbn, 8, 1) :: NUMERIC * 3 +
             substr(NEW.isbn, 9, 1) :: NUMERIC +
             substr(NEW.isbn, 10, 1) :: NUMERIC * 3 +
             substr(NEW.isbn, 11, 1) :: NUMERIC +
             substr(NEW.isbn, 12, 1) :: NUMERIC * 3 +
             substr(NEW.isbn, 14, 1) :: NUMERIC +
             substr(NEW.isbn, 15, 1) :: NUMERIC * 3)
           % 10 = substr(NEW.isbn, 17, 1) :: NUMERIC)
      OR (length(new.isbn) = 13
          AND ((tmp = 10 AND substr(new.isbn, 13, 1) = 'X')
               OR tmp = substr(NEW.isbn, 13, 1) :: NUMERIC))
  )
  THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'INVALID ISBN';
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION is_nip()
  RETURNS TRIGGER AS $$
DECLARE
  tmp NUMERIC DEFAULT 11;
BEGIN
  IF (length(new.nip) = 0)
  THEN new.nip = NULL;
    RETURN new; END IF;
  IF (length(new.nip) = 10)
  THEN tmp = ((substr(NEW.nip, 1, 1) :: NUMERIC * 6 +
               substr(new.nip, 2, 1) :: NUMERIC * 5 +
               substr(NEW.nip, 3, 1) :: NUMERIC * 7 +
               substr(NEW.nip, 4, 1) :: NUMERIC * 2 +
               substr(NEW.nip, 5, 1) :: NUMERIC * 3 +
               substr(NEW.nip, 6, 1) :: NUMERIC * 4 +
               substr(NEW.nip, 7, 1) :: NUMERIC * 5 +
               substr(NEW.nip, 8, 1) :: NUMERIC * 6 +
               substr(NEW.nip, 9, 1) :: NUMERIC * 7)
              % 11);
  END IF;
  IF tmp != substr(NEW.nip, 10, 1) :: NUMERIC
  THEN
    RAISE EXCEPTION 'INVALID NIP';
  END IF;
  RETURN new;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION set_rank()
  RETURNS TRIGGER AS $$
DECLARE
  val      NUMERIC DEFAULT 0;
  quantity BIGINT;
  disc     RECORD;
  customer BIGINT;
BEGIN
  customer = (SELECT customer_id
              FROM orders
              WHERE id = new.order_id);

  quantity = (SELECT coalesce(sum(orders_details.amount), 0)
              FROM orders
                LEFT JOIN orders_details ON orders.id = orders_details.order_id
              WHERE orders.customer_id = customer
              LIMIT 1);

  FOR disc IN SELECT
                customer_id,
                discount_id
              FROM customers_discounts
                LEFT JOIN discounts ON discounts.id = customers_discounts.discount_id
              WHERE customer_id = customer AND
                    (discounts.name LIKE 'Bronze Client Rank' OR discounts.name LIKE 'Silver Client Rank' OR
                     discounts.name LIKE 'Gold Client Rank' OR discounts.name LIKE 'Platinum Client Rank')
              LIMIT 1 LOOP

    val = (SELECT coalesce(max(discounts.value), 0)
           FROM discounts
           WHERE discounts.id = disc.discount_id);

    IF quantity > 40 AND val < 0.12
    THEN
      DELETE FROM customers_discounts
      WHERE discount_id = disc.discount_id AND customer_id = customer;
      INSERT INTO customers_discounts (customer_id, discount_id) VALUES (customer, 4);
    ELSIF quantity > 30 AND val < 0.08
      THEN
        DELETE FROM customers_discounts
        WHERE discount_id = disc.discount_id AND customer_id = customer;
        INSERT INTO customers_discounts (customer_id, discount_id) VALUES (customer, 3);
    ELSIF quantity > 20 AND val < 0.05
      THEN
        DELETE FROM customers_discounts
        WHERE discount_id = disc.discount_id AND customer_id = customer;
        INSERT INTO customers_discounts (customer_id, discount_id) VALUES (customer, 2);
    END IF;
  END LOOP;

  IF quantity > 10 AND val < 0.03 AND disc IS NULL
  THEN
    INSERT INTO customers_discounts (customer_id, discount_id) VALUES (customer, 1);
  END IF;

  RETURN new;
END;
$$ LANGUAGE plpgsql;

CREATE TABLE authors (
  id           SERIAL PRIMARY KEY,
  first_name   VARCHAR(100),
  second_name  VARCHAR(100),
  company_name VARCHAR(100),
  CHECK ((first_name IS NOT NULL AND second_name IS NOT NULL)
         OR company_name IS NOT NULL)
);

CREATE UNIQUE INDEX authors_ind_1
  ON authors (first_name, second_name)
  WHERE company_name IS NULL;
CREATE UNIQUE INDEX authors_ind_2
  ON authors (company_name)
  WHERE company_name IS NOT NULL;

CREATE TABLE genres (
  id   SERIAL PRIMARY KEY,
  name VARCHAR(100) UNIQUE NOT NULL
);

CREATE TABLE publishers (
  id   SERIAL PRIMARY KEY,
  name VARCHAR(100) UNIQUE NOT NULL
);

CREATE TABLE books (
  --isbn13 format: xxx-xx-xxxxx-xx-x
  --isbn10 format: x-xxx-xxxxx-x
  isbn               VARCHAR PRIMARY KEY,
  title              VARCHAR(100) NOT NULL,
  publication_date   DATE CHECK (publication_date <= now()),
  edition            INT,
  available_quantity INT          NOT NULL DEFAULT 0 CHECK (available_quantity >= 0),
  price              NUMERIC(6, 2) CHECK (price > 0),
  author             SERIAL REFERENCES authors (id) ON DELETE CASCADE,
  publisher          SERIAL REFERENCES publishers (id) ON DELETE CASCADE
);

CREATE TABLE books_genres (
  book_id  VARCHAR REFERENCES books (isbn) ON DELETE CASCADE,
  genre_id SERIAL REFERENCES genres (id) ON DELETE CASCADE,
  PRIMARY KEY (book_id, genre_id)
);

CREATE TABLE customers (
  id           SERIAL PRIMARY KEY,
  first_name   VARCHAR(100)        NOT NULL,
  last_name    VARCHAR(100)        NOT NULL,
  login        VARCHAR(100) UNIQUE NOT NULL,
  passwordHash VARCHAR(100)        ,
  postal_code  VARCHAR(6)          NOT NULL,
  street       VARCHAR(100)        NOT NULL,
  building_no  VARCHAR(5)          NOT NULL,
  flat_no      VARCHAR(5),
  city         VARCHAR(100)        NOT NULL,
  nip          VARCHAR(10),
  phone_number VARCHAR(9)
);

CREATE TABLE shippers (
  id           SERIAL PRIMARY KEY,
  name         VARCHAR(100) NOT NULL,
  phone_number VARCHAR(9)
);

CREATE TABLE discounts (
  id    SERIAL PRIMARY KEY,
  name  VARCHAR(100),
  value NUMERIC(2, 2) DEFAULT 0 CHECK (value >= 0.00 AND value <= 1.00)
);

CREATE TABLE customers_discounts (
  customer_id SERIAL REFERENCES customers (id) ON DELETE CASCADE,
  discount_id SERIAL REFERENCES discounts (id) ON DELETE CASCADE
);

CREATE TABLE books_discounts (
  book_id     VARCHAR REFERENCES books (isbn) ON DELETE CASCADE,
  discount_id SERIAL REFERENCES discounts (id) ON DELETE CASCADE
);

CREATE TABLE orders (
  id          SERIAL PRIMARY KEY,
  customer_id SERIAL NOT NULL REFERENCES customers (id) ON DELETE CASCADE,
  date        DATE    DEFAULT now() CHECK (date <= now()),
  discount_id BIGINT REFERENCES discounts (id) ON DELETE CASCADE,
  shipper     BIGINT NOT NULL REFERENCES shippers (id) ON DELETE CASCADE,
  state       VARCHAR DEFAULT 'AWAITING'
    CHECK (state = 'AWAITING' OR state = 'PAID' OR state = 'SENT')
);

CREATE TABLE orders_details (
  book_id  VARCHAR REFERENCES books (isbn) ON DELETE CASCADE,
  order_id BIGINT NOT NULL REFERENCES orders (id) ON DELETE CASCADE,
  amount   INTEGER CHECK (amount > 0)
);

CREATE TABLE reviews (
  id          SERIAL PRIMARY KEY,
  book_id     VARCHAR NOT NULL REFERENCES books (isbn) ON DELETE CASCADE,
  customer_id BIGINT  NOT NULL REFERENCES customers (id) ON DELETE CASCADE,
  review      INTEGER CHECK (review BETWEEN 0 AND 10),
  date        DATE DEFAULT now()
);

CREATE TRIGGER rank_setter
AFTER INSERT OR UPDATE ON orders_details
FOR EACH ROW EXECUTE PROCEDURE set_rank();

CREATE TRIGGER nip_check
BEFORE INSERT OR UPDATE ON customers
FOR EACH ROW EXECUTE PROCEDURE is_nip();

CREATE TRIGGER discounter
BEFORE INSERT OR UPDATE ON orders
FOR EACH ROW EXECUTE PROCEDURE give_discount();

CREATE TRIGGER isbn_ckeck
BEFORE INSERT OR UPDATE ON books
FOR EACH ROW EXECUTE PROCEDURE is_isbn();

CREATE TRIGGER phonenumber_check_customers
BEFORE INSERT OR UPDATE ON shippers
FOR EACH ROW EXECUTE PROCEDURE is_phonenumber();

CREATE TRIGGER phonenumber_check_shippers
BEFORE INSERT OR UPDATE ON shippers
FOR EACH ROW EXECUTE PROCEDURE is_phonenumber();

CREATE TRIGGER hasbook_check
BEFORE INSERT OR UPDATE ON reviews
FOR EACH ROW EXECUTE PROCEDURE has_bought();

CREATE OR REPLACE VIEW book_adder AS (
  SELECT
    books.isbn,
    books.title,
    books.publication_date,
    books.edition,
    books.available_quantity,
    books.price,
    authors.first_name,
    authors.second_name,
    authors.company_name,
    publishers.name AS publisher
  FROM books
    JOIN authors ON books.author = authors.id
    JOIN publishers ON books.publisher = publishers.id
  WHERE 1 = 0);

CREATE RULE checkdate AS ON INSERT TO reviews DO ALSO (
  DELETE FROM reviews
  WHERE date > now() AND customer_id = new.customer_id AND book_id = new.book_id;
);

CREATE RULE adder AS ON INSERT TO book_adder DO INSTEAD (
  INSERT INTO authors (first_name, second_name, company_name)
  VALUES (new.first_name, new.second_name, new.company_name)
  ON CONFLICT DO NOTHING;
  INSERT INTO publishers (name) VALUES (new.publisher)
  ON CONFLICT DO NOTHING;

  INSERT INTO books (isbn, title, publication_date, edition, available_quantity, price, author, publisher)
  VALUES (new.isbn, new.title, new.publication_date, new.edition, new.available_quantity, new.price,
          (SELECT id
           FROM authors
           WHERE (authors.first_name LIKE new.first_name AND authors.second_name LIKE new.second_name) OR
                 authors.company_name LIKE new.company_name
           LIMIT 1),
          (SELECT id
           FROM publishers
           WHERE name LIKE new.publisher
           LIMIT 1));
);

CREATE OR REPLACE VIEW books_rank AS (
  SELECT
    isbn,
    title,
    rate,
    sold,
    array(SELECT DISTINCT name
          FROM books_genres
            JOIN genres ON books_genres.genre_id = genres.id
          WHERE book_id LIKE isbn) AS genres
  FROM (SELECT
          books.isbn                   AS isbn,
          title                        AS title,
          avg(review) :: NUMERIC(4, 2) AS rate,
          sum(s.sold)                  AS sold
        FROM books
          JOIN reviews ON books.isbn = reviews.book_id
          JOIN (SELECT
                  isbn,
                  coalesce(sum(amount), 0) AS sold
                FROM books
                  LEFT JOIN orders_details ON books.isbn = orders_details.book_id
                GROUP BY isbn) AS s ON s.isbn LIKE books.isbn
        GROUP BY books.isbn) AS o
  ORDER BY sold DESC, rate DESC
);

CREATE OR REPLACE FUNCTION is_available()
  RETURNS TRIGGER AS $$
BEGIN
  IF new.amount <= 0
  THEN
    RETURN NULL;
  END IF;
  IF new.amount > (SELECT books.available_quantity
                   FROM books
                   WHERE new.book_id = books.isbn
                   LIMIT 1)
  THEN
    RAISE EXCEPTION 'NOT AVAILABLE';
  END IF;
  RETURN new;
END; $$
LANGUAGE plpgsql;

CREATE TRIGGER available_check
BEFORE INSERT OR UPDATE ON orders_details
FOR EACH ROW EXECUTE PROCEDURE is_available();
