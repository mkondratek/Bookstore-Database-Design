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
INSERT INTO book_adder
(isbn, title, publication_date, edition, available_quantity, price, first_name, second_name, company_name, publisher)
VALUES
  ('978-62-82077-46-4', 'Trywialne dowody - Logika i Teoria Mnogości', DATE '1909-08-26', 1, 33, 68.80, NULL, NULL,
   'Wsród Matematyki', 'Pentakill'),
  ('978-66-52710-99-7', 'Wiersze Anlityczne', DATE '1957-08-24', 1, 52, 78.20, 'Wiktor', 'Nowak', NULL, 'Gambit Kaczmarkowski'),
  ('978-93-09965-40-9', 'On jest w internecie', DATE '1909-09-14', 1, 54, 96.60, NULL, NULL, 'Piąta Ściana', 'Pies Filemon'),
  ('978-79-47426-94-0', 'Piraci z Satori u wybrzeży CME', DATE '2000-11-15', 1, 37, 73.90, 'Weronika', 'Piotrowska', NULL, 'Kot Reksio'),
  ('978-58-79768-35-0', 'Podręcznik Tracha', DATE '1955-11-14', 3, 71, 110.50, 'Kornel', 'Goldberg', NULL, 'Kruca Fix'),
  ('978-26-16866-55-7', 'Dyskretny TCS, tom II', DATE '1923-03-03', 1, 73, 19.60, 'Bartłomiej', 'Adamczyk', NULL, 'Wesoła Szkoła'),
  ('978-51-96834-91-8', 'Noc w Bonarce', DATE '1900-08-20', 1, 27, 43.80, 'Katarzyna', 'Cebulska', NULL, 'Extra Ciemne'),
  ('978-82-94547-43-8', 'Nic nie działa', DATE '1971-04-26', 1, 35, 82.30, 'Sandra', 'Kazimierczak', NULL, 'Loki'),
  ('978-90-69351-21-4', 'Filet śmierci', DATE '1903-03-30', 4, 68, 15.50, 'Kornel', 'Hoser', NULL, 'Atakałke'),
  ('978-05-68350-24-7', 'Legenda o Lajkoniku', DATE '1913-08-07', 4, 53, 127.30, NULL, NULL, 'Poczta Polska', 'Atakałke'),
  ('978-10-15567-32-0', 'Żółci i w QUE - wyścigi submitów', DATE '1906-09-28', 1, 52, 36.10, 'Grzegorz', 'Wiśniewski', NULL, 'WSSP'),
  ('978-51-33563-64-4', 'A smakowało Ci to? Whisky wczoraj i dziś', DATE '1963-08-21', 1, 51, 86.20, 'Jan', 'Tanenbaum', NULL, 'Pentakill'),
  ('978-47-29403-93-1', 'Sens życia, a operatory przypisania', DATE '2015-09-26', 1, 36, 70.60, 'Henryk', 'Bobak', NULL, 'Siedmiu Krasnoludków'),
  ('978-03-26475-98-0', 'Piraci z Satori i zemsta RTE', DATE '1979-02-11', 1, 64, 104.30, NULL, NULL, 'Encylopedia Informatyki', 'Drux'),
  ('978-45-43223-75-9', 'Czerwony odkurzacz spod ściany', DATE '2006-01-20', 4, 56, 110.80, 'Kamila', 'Krysicka', NULL, 'Babunia'),
  ('978-20-96834-48-4', 'Jedyny oryginalny kret', DATE '2009-07-17', 1, 48, 108.20, 'Zuzanna', 'Dura', NULL, 'Pentakill'),
  ('978-05-12554-44-6', 'Nasza klasa', DATE '1841-03-22', 1, 41, 101.80, 'Henryk', 'Dąbrowkski', NULL, 'Loki'),
  ('978-20-49946-06-2', 'Co jest lepsze od dźwięku spadających z urwiska programistów javy?', DATE '1846-05-10', 1, 47, 63.0, 'Iwona', 'Słowacka', NULL, 'Kot Reksio'),
  ('978-31-75798-39-8', 'Miki zabrał internet', DATE '1958-02-04', 1, 30, 52.70, 'Adam', 'Krysicki', NULL, 'ASCT'),
  ('978-53-96820-70-2', 'Dlaczego Satori nie działa?, czyli ważne problemy ludzkości', DATE '1999-09-01', 1, 42, 46.70, 'Kornel', 'Monarek', NULL, 'Kruca Fix'),
  ('978-32-79944-80-0', 'Cornelius bananowy', DATE '2004-07-21', 1, 44, 70.90, NULL, NULL, 'Współczesne rozwój', 'Podziemie'),
  ('978-27-09742-93-9', 'Noc na kampusie WMiI 2', DATE '1928-08-28', 1, 35, 62.50, 'Filip', 'Sienkiewicz', NULL, 'Atakałke'),
  ('978-48-31459-66-6', 'Czego nie wiesz o kokosach? Piosenka "The Coconut Song"', DATE '1900-12-21', 1, 46, 55.40, 'Janusz', 'Krysicki', NULL, 'Extra Ciemne'),
  ('978-34-35195-60-8', 'Piraci z Satori w wymiarze EXT', DATE '1957-08-01', 1, 42, 103.30, 'Jan', 'Monarek', NULL, 'Pies Filemon'),
  ('978-00-56400-97-1', 'Znowu karny...', DATE '2014-09-02', 4, 73, 95.40, NULL, NULL, 'Dreamteam', 'Podziemie'),
  ('978-79-00130-40-8', 'Polakom nie kibicuje', DATE '1966-03-26', 1, 65, 129.70, 'Tomasz', 'Woźniak', NULL, 'Babunia'),
  ('978-83-39028-32-8', 'Jak pozbyć się ANSa na pierwszym teście?', DATE '1980-03-09', 1, 47, 17.10, 'Zuzanna', 'Jachowicz', NULL, 'Loki'),
  ('978-30-79974-26-3', 'Dyskretny TCS', DATE '1963-05-30', 1, 44, 104.50, 'Janusz', 'Nowak', NULL, 'Atakałke'),
  ('978-73-62814-70-6', 'Piraci z Satori w krainie TLE', DATE '1986-10-17', 2, 60, 12.10, 'Paweł', 'Kazimierczak', NULL, 'ASCT'),
  ('978-51-93468-20-8', 'Introduction to hungar heaps', DATE '1915-06-26', 1, 53, 91.70, 'Jan', 'Dębska', NULL, 'NGU'),
  ('978-50-77648-87-6', 'Matematyka Konkretna', DATE '1984-02-24', 1, 30, 152.30, 'Łukasz', 'Monarek', NULL, 'Gambit Kaczmarkowski'),
  ('978-41-36186-05-0', 'Domki z dirta w Minecraft', DATE '1975-06-14', 1, 67, 152.30, 'Alicja', 'Witkowska', NULL, 'WSSP'),
  ('978-36-02155-51-6', 'Kopnij pięć razy i zadziała', DATE '1959-08-04', 1, 29, 114.0, 'Kamila', 'Kondratek', NULL, 'Pentakill'),
  ('978-28-75201-24-1', 'Smakołyki ATOMu', DATE '1993-11-23', 1, 53, 11.80, 'Kamila', 'Wojciechowska', NULL, 'WSSP'),
  ('978-05-44062-74-0', 'TCS - Tanie Czyszczenie i Sprzątanie', DATE '1983-06-12', 1, 27, 35.20, 'Paulina', 'Sienkiewicz', NULL, 'Kruca Fix'),
  ('978-79-31446-90-1', 'Noc na kampusie WMiI', DATE '1917-12-26', 1, 37, 89.50, 'Jarosław', 'Homoncik', NULL, 'Kruti'),
  ('978-71-44226-85-5', 'Jak zbalansować siednmiowarstwowe drzewo binarne?', DATE '2002-12-10', 1, 17, 59.30, 'Piotr', 'Grabowski', NULL, 'ASCT'),
  ('978-53-46337-70-4', 'Kto gdzie? Kto z kim? Zajscia. Czyli jak nie nazywać tabel', DATE '2005-07-21', 1, 59, 103.20, 'Hans', 'Kaczmarek', NULL, 'Januszex'),
  ('978-96-00175-74-5', 'Oddaj buta', DATE '1937-12-25', 1, 36, 63.90, 'Jan', 'Klemens', NULL, 'Pies Filemon'),
  ('978-86-65773-79-2', 'Docent czyli jak zniszczyć polską kuchnie', DATE '1988-05-26', 1, 38, 68.90, 'Felicyta', 'Jaworska', NULL, 'ASCT'),
  ('978-78-60046-69-0', 'Z serii klasyka gatunku, czyli ANS na pierwszym teście', DATE '1937-02-05', 1, 51, 86.40, 'Bożydar', 'Jaworski', NULL, 'Kruca Fix'),
  ('978-30-80070-70-5', 'Sztuka wyboru czyli obważanek z seram czy sezamem', DATE '1911-07-30', 1, 62, 31.90, 'Hans', 'Zieliński', NULL, 'Atakałke'),
  ('978-66-09831-75-3', '7 paluszków na stole', DATE '1950-10-10', 2, 60, 84.90, 'Elżbieta', 'Kaczmarek', NULL, 'WSSP'),
  ('978-86-64942-96-4', 'Mrówki największe i najsilniejsze', DATE '1957-10-07', 1, 59, 138.60, 'Mateusz', 'Kaczmarek', NULL, 'Afro'),
  ('978-00-79377-11-9', 'Piraci z Satori i skrzynia ANSów', DATE '1919-10-28', 1, 20, 59.20, 'Wiktor', 'Kazimierczak', NULL, 'Podziemie'),
  ('978-34-67169-07-3', 'DIY - hangerheaps with Jack Kurek', DATE '1903-11-26', 1, 26, 16.80, 'Katarzyna', 'Wiśniewska', NULL, 'Drux'),
  ('978-71-88713-50-8', 'Na parapecie', DATE '1932-03-08', 3, 22, 26.10, 'Weronika', 'Cebulska', NULL, 'Kruti'),
  ('978-50-79860-65-4', 'Opłacalność wymiany plecaka w Trachu', DATE '1869-05-17', 2, 49, 37.60, 'Małgorzata', 'Mazur', NULL, 'Wesoła Szkoła'),
  ('978-05-18968-85-4', 'Pair Programinig', DATE '1959-04-18', 4, 24, 132.80, 'Weronika', 'Mickiewicz', NULL, 'Pentakill'),
  ('978-58-12517-61-2', '12 dowodów Kamili', DATE '1992-01-07', 4, 64, 106.40, 'Tomasz', 'Mełech', NULL, 'Kruti'),
  ('978-59-93843-98-2', 'Igrzyska Tracha', DATE '1889-04-26', 2, 41, 30.90, 'Franciszek', 'Filtz', NULL, 'WSSP'),
  ('978-03-19379-22-4', 'Kontratak', DATE '1906-04-02', 1, 59, 27.20, 'Maciek', 'Dudek', NULL, 'Kot Reksio'),
  ('978-48-10313-42-0', 'Rozmowa na plantacji', DATE '1959-06-21', 2, 73, 140.60, 'Anna', 'Dura', NULL, 'Januszex'),
  ('8-379-32742-X', 'Bez matki nie ma chatki', DATE '1943-07-19', 2, 19, 119.60, 'Jakub', 'Woźniak', NULL, 'Afro'),
  ('1-435-73862-4', 'Bez matki że przymarznie cap do kozy', DATE '1884-04-29', 1, 54, 86.70, NULL, NULL, 'Gazeta WMiI', 'Pentakill'),
  ('2-342-96369-6', 'Bez matki ale na całe życie', DATE '1977-01-24', 1, 16, 90.70, 'Brygida', 'Pupa', NULL, 'Siedmiu Krasnoludków'),
  ('2-265-10974-6', 'Bez matki póki jeszcze czas', DATE '1977-10-24', 1, 55, 80.80, 'Bartłomiej', 'Mełech', NULL, 'Kot Reksio'),
  ('8-207-74950-4', 'Bez matki byk się ocieli', DATE '1989-06-01', 1, 19, 127.90, 'Joanna', 'Mełech', NULL, 'Wesoła Szkoła'),
  ('9-181-66565-2', 'Bez matki to drugiemu niewola', DATE '1969-05-26', 1, 69, 73.10, 'Franciszek', 'Schneider', NULL, 'Siedmiu Krasnoludków'),
  ('9-330-73476-6', 'Bez matki to go nie minie', DATE '1982-05-24', 1, 75, 135.30, 'Katarzyna', 'Nowicka', NULL, 'Januszex'),
  ('7-131-62625-2', 'Bez matki to zima przejada', DATE '1983-04-01', 1, 73, 28.40, 'Karolina', 'Dostojewska', NULL, 'WSSP'),
  ('4-502-18561-2', 'Bez matki dom wesołym czyni', DATE '1991-10-07', 1, 37, 42.0, 'Weronika', 'Goldberg', NULL, 'WSSP'),
  ('7-648-28542-8', 'Bez matki wrócić ziarno na śniadanie', DATE '1988-04-16', 1, 18, 114.40, 'Mateusz', 'Kostrikin', NULL, 'Gambit Kaczmarkowski'),
  ('3-613-10050-9', 'Bez matki jak się kto przepości', DATE '1967-06-29', 3, 50, 120.80, 'Szymon', 'Dębska', NULL, 'ASCT'),
  ('7-674-80113-6', 'Bez matki pada aż do Zuzanny', DATE '1903-04-30', 1, 42, 72.20, 'Tomasz', 'Zieliński', NULL, 'WSSP'),
  ('0-358-15689-0', 'Bez matki znać jabłuszko na jabłoni', DATE '1902-05-15', 4, 36, 31.80, 'Mikołaj', 'Dura', NULL, 'Januszex'),
  ('0-097-31291-6', 'Bez matki jesień krótka, szybko mija', DATE '1994-07-26', 4, 19, 169.20, 'Łukasz', 'Głowacka', NULL, 'NGU'),
  ('1-929-82191-3', 'Bez matki to się diabeł cieszy', DATE '1907-05-12', 2, 15, 44.30, NULL, NULL, 'Współczesne rozwój', 'Wesoła Szkoła'),
  ('6-563-85697-7', 'Bez matki zwykle nastaje posucha', DATE '1941-06-30', 1, 52, 138.20, 'Filip', 'Homoncik', NULL, 'Extra Ciemne'),
  ('2-957-54517-9', 'Bez matki piekła nie ma', DATE '1944-11-15', 1, 20, 69.20, 'Mateusz', 'Kamiński', NULL, 'Kot Reksio'),
  ('6-254-69347-X', 'Bez matki piekło gore', DATE '1854-05-30', 1, 69, 21.10, 'Bożydar', 'Kamiński', NULL, 'ASCT'),
  ('9-366-95869-9', 'Bez matki tym bardziej nosa zadziera', DATE '1465-05-07', 4, 66, 74.0, 'Mikołaj', 'Tyminśka', NULL, 'Babunia'),
  ('3-204-42710-2', 'Bez matki tym wyżej głowę nosi', DATE '2012-12-29', 3, 55, 119.60, NULL, NULL, 'Uniwersytet Koloni Krężnej', 'Podziemie'),
  ('6-026-55108-5', 'Bez matki tym więcej chce', DATE '1960-05-11', 1, 61, 119.40, 'Henryk', 'Woźniak', NULL, 'Januszex'),
  ('8-367-23769-2', 'Bez matki tym spokojniej śpisz', DATE '1983-08-21', 1, 64, 64.60, 'Andrzej', 'Kamiński', NULL, 'ASCT'),
  ('3-491-58415-9', 'Bez matki tym bardziej gryzie', DATE '1946-09-25', 1, 47, 96.0, 'Dariusz', 'Stępień', NULL, 'Kot Reksio'),
  ('5-640-70773-9', 'Bez matki tak cię cenią', DATE '1987-11-14', 1, 57, 142.20, 'Alicja', 'Schneider', NULL, 'WSSP'),
  ('1-310-47717-5', 'Bez matki kij się znajdzie', DATE '1955-07-24', 1, 50, 117.50, 'Małgorzata', 'Monarek', NULL, 'Loki'),
  ('7-938-45157-6', 'Bez matki to się diabeł cieszy', DATE '1972-11-02', 1, 79, 107.10, 'Piotr', 'Malinowski', NULL, 'Afro'),
  ('8-615-98526-X', 'Bez matki tak się koniec grudnia nosi', DATE '1959-06-09', 1, 67, 142.80, 'Tomasz', 'Goldberg', NULL, 'Kruca Fix'),
  ('0-996-48453-1', 'Bez matki to się lubi co się ma', DATE '1903-09-16', 4, 37, 137.20, 'Karolina', 'Wojciechowska', NULL, 'Kruti'),
  ('3-586-18506-5', 'Bez matki pora powiedzieć „b”', DATE '1940-03-09', 1, 20, 67.80, 'Jarosław', 'Dębska', NULL, 'Babunia'),
  ('5-513-44050-4', 'Bez matki to z dobrego konia', DATE '1987-01-05', 2, 44, 30.60, 'Kamila', 'Helik', NULL, 'Loki'),
  ('2-334-00114-7', 'Bez matki to z dobrego konia', DATE '2009-09-04', 1, 64, 103.40, 'Agnieszka', 'Schmidt', NULL, 'Siedmiu Krasnoludków'),
  ('8-011-13440-X', 'Bez matki temu czas', DATE '2012-10-28', 3, 79, 83.70, 'Joanna', 'Stępień', NULL, 'Atakałke'),
  ('0-001-60391-4', 'Bez matki za przewodnika', DATE '2000-08-26', 1, 12, 88.90, 'Mateusz', 'Jachowicz', NULL, 'Wesoła Szkoła'),
  ('8-488-29842-0', 'Bez matki cygana powiesili', DATE '2007-05-19', 1, 52, 68.70, 'Jacek', 'Schneider', NULL, 'Kot Reksio'),
  ('0-845-14093-0', 'Bez matki oka nie wykole', DATE '1930-04-29', 1, 18, 106.50, 'Paweł', 'Wiśniewski', NULL, 'Januszex'),
  ('8-760-86031-6', 'Bez matki mało mleka daje', DATE '1915-04-24', 1, 22, 49.0, 'Zuzanna', 'Dudek', NULL, 'Pentakill'),
  ('1-179-65828-0', 'Bez matki trochę zimy, trochę lata', DATE '1922-09-11', 2, 20, 72.40, 'Weronika', 'Grabowska', NULL, 'Gambit Kaczmarkowski'),
  ('4-593-63554-3', 'Bez matki nie wart i kołacza', DATE '1975-07-16', 3, 37, 16.50, 'Łukasz', 'Dąbrowkski', NULL, 'NGU'),
  ('1-485-02226-6', 'Bez matki ponieśli i wilka', DATE '1819-08-01', 1, 41, 68.50, 'Michał', 'Krysicki', NULL, 'Drux'),
  ('2-604-11818-1', 'Bez matki nikt nie wie', DATE '1498-08-18', 1, 39, 36.0, 'Mikołaj', 'Sejko', NULL, 'Loki'),
  ('2-824-94000-X', 'Będą takie mrozy nie ma chatki', DATE '1909-09-25', 3, 86, 54.70, 'Kornel', 'Krysicki', NULL, 'Kot Reksio'),
  ('8-129-54778-3', 'Będą takie mrozy że przymarznie cap do kozy', DATE '1911-01-22', 1, 23, 91.70, 'Filip', 'Zieliński', NULL, 'Atakałke'),
  ('9-817-11951-3', 'Będą takie mrozy ale na całe życie', DATE '1962-07-26', 3, 57, 121.20, 'Kornel', 'Słowacki', NULL, 'Afro'),
  ('3-915-70380-X', 'Będą takie mrozy póki jeszcze czas', DATE '1986-06-13', 1, 67, 15.30, 'Jan', 'Woźniak', NULL, 'Siedmiu Krasnoludków'),
  ('7-865-31646-1', 'Będą takie mrozy byk się ocieli', DATE '1903-09-12', 4, 35, 50.90, 'Franciszek', 'Nowicki', NULL, 'Babunia'),
  ('9-887-75632-6', 'Będą takie mrozy to drugiemu niewola', DATE '2012-05-15', 1, 39, 25.50, 'Katarzyna', 'Mickiewicz', NULL, 'Gambit Kaczmarkowski'),
  ('3-426-31630-7', 'Będą takie mrozy to go nie minie', DATE '1964-11-29', 1, 43, 24.90, NULL, NULL, 'Poczta Polska', 'Afro'),
  ('6-343-23885-9', 'Będą takie mrozy to zima przejada', DATE '1999-03-22', 1, 76, 12.90, 'Paweł', 'Słowacki', NULL, 'Januszex'),
  ('6-241-72416-9', 'Będą takie mrozy dom wesołym czyni', DATE '1524-03-03', 1, 40, 89.10, 'Piotr', 'Kamiński', NULL, 'Kruca Fix'),
  ('1-267-84125-7', 'Będą takie mrozy wrócić ziarno na śniadanie', DATE '2014-10-29', 1, 60, 142.20, 'Maciek', 'Krysicki', NULL, 'Drux'),
  ('3-528-33212-3', 'Będą takie mrozy jak się kto przepości', DATE '1966-11-15', 2, 41, 164.60, 'Weronika', 'Monarek', NULL, 'Kruti'),
  ('1-866-69289-5', 'Będą takie mrozy pada aż do Zuzanny', DATE '1977-10-13', 1, 67, 20.0, NULL, NULL, 'TCS WPROST', 'Drux'),
  ('0-418-20126-9', 'Będą takie mrozy znać jabłuszko na jabłoni', DATE '1999-12-25', 1, 47, 91.10, 'Aleksandra', 'Kamińska', NULL, 'Kot Reksio'),
  ('4-703-20760-5', 'Będą takie mrozy jesień krótka, szybko mija', DATE '1914-02-15', 1, 50, 31.90, 'Wiktor', 'Mełech', NULL, 'Drux'),
  ('8-858-19512-4', 'Będą takie mrozy to się diabeł cieszy', DATE '1905-09-04', 1, 61, 42.20, 'Paulina', 'Dębska', NULL, 'Babunia'),
  ('7-100-38088-X', 'Będą takie mrozy zwykle nastaje posucha', DATE '1934-08-07', 1, 24, 91.0, 'Andrzej', 'Sienkiewicz', NULL, 'Gambit Kaczmarkowski'),
  ('2-365-45965-X', 'Będą takie mrozy piekła nie ma', DATE '1943-12-23', 1, 19, 43.20, 'Michał', 'Dąbrowkski', NULL, 'Loki'),
  ('1-304-44821-5', 'Będą takie mrozy piekło gore', DATE '1937-07-21', 1, 69, 26.0, 'Bożydar', 'Krysicki', NULL, 'Wesoła Szkoła'),
  ('6-457-56071-7', 'Będą takie mrozy tym bardziej nosa zadziera', DATE '1959-06-28', 1, 33, 29.20, 'Jarosław', 'Wojciechowski', NULL, 'Kruti'),
  ('2-816-08255-5', 'Będą takie mrozy tym wyżej głowę nosi', DATE '1962-12-10', 1, 21, 34.50, 'Grzegorz', 'Wojciechowski', NULL, 'Januszex'),
  ('5-718-03731-0', 'Będą takie mrozy tym więcej chce', DATE '1903-11-05', 3, 25, 94.0, 'Jan', 'Bobak', NULL, 'Podziemie'),
  ('8-781-83004-1', 'Będą takie mrozy tym spokojniej śpisz', DATE '1995-04-07', 3, 62, 45.80, 'Henryk', 'Witkowski', NULL, 'Atakałke'),
  ('6-778-26509-4', 'Będą takie mrozy tym bardziej gryzie', DATE '1900-05-13', 1, 59, 51.50, 'Kamila', 'Hoser', NULL, 'Extra Ciemne'),
  ('2-494-25105-2', 'Będą takie mrozy tak cię cenią', DATE '1994-04-07', 1, 67, 81.20, 'Mateusz', 'Tanenbaum', NULL, 'Loki'),
  ('6-864-60177-3', 'Będą takie mrozy kij się znajdzie', DATE '1946-07-06', 1, 53, 75.80, 'Felicyta', 'Dąbrowkska', NULL, 'Kruti'),
  ('3-180-55049-X', 'Będą takie mrozy to się diabeł cieszy', DATE '1982-01-16', 4, 54, 42.0, 'Grzegorz', 'Majewski', NULL, 'Januszex'),
  ('0-639-68248-0', 'Będą takie mrozy tak się koniec grudnia nosi', DATE '2009-09-14', 1, 81, 61.10, 'Mateusz', 'Tanenbaum', NULL, 'Kruti'),
  ('1-585-68119-9', 'Będą takie mrozy to się lubi co się ma', DATE '1982-12-05', 3, 20, 111.80, 'Bożydar', 'Adamczyk', NULL, 'Babunia'),
  ('9-243-88163-9', 'Będą takie mrozy pora powiedzieć „b”', DATE '1987-09-22', 1, 57, 153.10, 'Aleksandra', 'Dudek', NULL, 'Wesoła Szkoła'),
  ('4-543-45809-5', 'Będą takie mrozy to z dobrego konia', DATE '1968-01-13', 1, 52, 149.80, 'Karolina', 'Helik', NULL, 'Pies Filemon'),
  ('3-976-53317-3', 'Będą takie mrozy to z dobrego konia', DATE '1952-02-01', 1, 74, 53.90, 'Joanna', 'Lewandowska', NULL, 'Drux'),
  ('9-661-59057-5', 'Będą takie mrozy temu czas', DATE '1926-12-22', 1, 44, 107.80, 'Kamila', 'Kostrikin', NULL, 'Podziemie'),
  ('3-661-55918-4', 'Będą takie mrozy za przewodnika', DATE '1958-11-22', 3, 55, 35.50, 'Adam', 'Schneider', NULL, 'Siedmiu Krasnoludków'),
  ('5-822-57810-1', 'Będą takie mrozy cygana powiesili', DATE '1989-08-23', 1, 51, 56.30, 'Filip', 'Bobak', NULL, 'WSSP'),
  ('6-350-20962-1', 'Będą takie mrozy oka nie wykole', DATE '1989-11-19', 4, 15, 191.30, 'Joanna', 'Krysicka', NULL, 'ASCT'),
  ('4-185-66817-1', 'Będą takie mrozy mało mleka daje', DATE '1913-03-01', 1, 53, 35.20, 'Hans', 'Kamiński', NULL, 'Januszex'),
  ('4-644-38515-8', 'Będą takie mrozy trochę zimy, trochę lata', DATE '1952-12-19', 1, 23, 58.70, 'Andrzej', 'Bobak', NULL, 'Drux'),
  ('2-291-74938-2', 'Będą takie mrozy nie wart i kołacza', DATE '1905-01-23', 2, 18, 26.0, 'Piotr', 'Homoncik', NULL, 'Kot Reksio'),
  ('8-813-93597-8', 'Będą takie mrozy ponieśli i wilka', DATE '1973-01-09', 1, 19, 120.10, 'Franciszek', 'Klemens', NULL, 'Siedmiu Krasnoludków'),
  ('8-356-15420-0', 'Będą takie mrozy nikt nie wie', DATE '1938-10-10', 1, 68, 6.70, 'Felicyta', 'Sienkiewicz', NULL, 'WSSP'),
  ('9-797-40016-6', 'Biedny kupuje jedną kapotę nie ma chatki', DATE '1990-06-07', 1, 15, 24.60, 'Jan', 'Homoncik', NULL, 'GGWP'),
  ('2-056-24331-8', 'Biedny kupuje jedną kapotę że przymarznie cap do kozy', DATE '1911-05-05', 1, 58, 60.80, 'Anna', 'Gołąbek', NULL, 'Januszex'),
  ('3-710-96352-4', 'Biedny kupuje jedną kapotę ale na całe życie', DATE '1845-03-10', 1, 48, 80.40, 'Bożydar', 'Nowakowski', NULL, 'Pies Filemon'),
  ('3-762-71203-4', 'Biedny kupuje jedną kapotę póki jeszcze czas', DATE '1990-03-28', 4, 52, 188.60, 'Jarosław', 'Schneider', NULL, 'Siedmiu Krasnoludków'),
  ('5-884-22306-4', 'Biedny kupuje jedną kapotę byk się ocieli', DATE '1985-11-23', 1, 58, 77.80, 'Jakub', 'Kazimierczak', NULL, 'Siedmiu Krasnoludków'),
  ('1-860-53069-9', 'Biedny kupuje jedną kapotę to drugiemu niewola', DATE '1835-07-03', 1, 38, 88.30, 'Iwona', 'Jaworska', NULL, 'GGWP'),
  ('5-430-45037-5', 'Biedny kupuje jedną kapotę to go nie minie', DATE '1819-02-01', 4, 83, 174.70, 'Sandra', 'Kondratek', NULL, 'Siedmiu Krasnoludków'),
  ('7-226-69099-3', 'Biedny kupuje jedną kapotę to zima przejada', DATE '1960-03-04', 1, 49, 135.50, 'Jakub', 'Majewski', NULL, 'Drux'),
  ('0-074-26643-8', 'Biedny kupuje jedną kapotę dom wesołym czyni', DATE '1983-10-28', 4, 53, 73.60, 'Grzegorz', 'Sejko', NULL, 'Atakałke'),
  ('8-590-31005-1', 'Biedny kupuje jedną kapotę wrócić ziarno na śniadanie', DATE '1981-07-19', 1, 12, 47.0, 'Henryk', 'Nowicki', NULL, 'Podziemie'),
  ('8-310-49550-1', 'Biedny kupuje jedną kapotę jak się kto przepości', DATE '1996-07-04', 1, 39, 194.20, 'Kornel', 'Pawlak', NULL, 'Podziemie'),
  ('1-202-78880-7', 'Biedny kupuje jedną kapotę pada aż do Zuzanny', DATE '1988-01-01', 2, 52, 177.70, 'Weronika', 'Gross', NULL, 'Podziemie'),
  ('7-872-88403-8', 'Biedny kupuje jedną kapotę znać jabłuszko na jabłoni', DATE '1947-08-13', 1, 55, 101.20, 'Piotr', 'Dura', NULL, 'Podziemie'),
  ('1-589-75840-4', 'Biedny kupuje jedną kapotę jesień krótka, szybko mija', DATE '1947-09-01', 1, 49, 101.40, 'Małgorzata', 'Kamińska', NULL, 'NGU'),
  ('1-005-74373-8', 'Biedny kupuje jedną kapotę to się diabeł cieszy', DATE '2013-04-28', 2, 29, 111.0, 'Jarosław', 'Kondratek', NULL, 'Kruti'),
  ('3-965-47765-X', 'Biedny kupuje jedną kapotę zwykle nastaje posucha', DATE '1970-01-22', 4, 55, 126.10, 'Weronika', 'Klemens', NULL, 'Pentakill'),
  ('0-471-52219-8', 'Biedny kupuje jedną kapotę piekła nie ma', DATE '1943-04-06', 3, 27, 69.40, 'Szymon', 'Gołąbek', NULL, 'GGWP'),
  ('0-531-95869-8', 'Biedny kupuje jedną kapotę piekło gore', DATE '1938-10-10', 1, 40, 71.40, 'Felicyta', 'Wojciechowska', NULL, 'ASCT'),
  ('7-857-57200-4', 'Biedny kupuje jedną kapotę tym bardziej nosa zadziera', DATE '1972-09-21', 2, 66, 5.80, 'Wiktor', 'Nowak', NULL, 'Wesoła Szkoła'),
  ('0-606-09656-6', 'Biedny kupuje jedną kapotę tym wyżej głowę nosi', DATE '1962-09-03', 3, 66, 37.70, 'Mateusz', 'Majewski', NULL, 'Siedmiu Krasnoludków'),
  ('0-498-02608-6', 'Biedny kupuje jedną kapotę tym więcej chce', DATE '1905-06-15', 1, 71, 83.80, 'Szymon', 'Dostojewski', NULL, 'GGWP'),
  ('5-342-94612-3', 'Biedny kupuje jedną kapotę tym spokojniej śpisz', DATE '1973-03-10', 1, 40, 64.90, 'Wiktor', 'Hoser', NULL, 'Afro'),
  ('6-560-14566-2', 'Biedny kupuje jedną kapotę tym bardziej gryzie', DATE '1966-11-28', 1, 20, 109.60, 'Paulina', 'Lewandowska', NULL, 'NGU'),
  ('8-921-80742-X', 'Biedny kupuje jedną kapotę tak cię cenią', DATE '1992-12-03', 1, 31, 29.20, 'Katarzyna', 'Kamińska', NULL, 'Podziemie'),
  ('2-540-82106-5', 'Biedny kupuje jedną kapotę kij się znajdzie', DATE '1942-06-06', 1, 21, 33.10, 'Franciszek', 'Dostojewski', NULL, 'Afro'),
  ('6-492-73023-2', 'Biedny kupuje jedną kapotę to się diabeł cieszy', DATE '1998-07-22', 1, 65, 133.50, 'Katarzyna', 'Goldberg', NULL, 'ASCT'),
  ('4-613-07912-8', 'Biedny kupuje jedną kapotę tak się koniec grudnia nosi', DATE '1904-07-02', 1, 45, 51.0, 'Henryk', 'Wojciechowski', NULL, 'Afro'),
  ('0-921-18921-4', 'Biedny kupuje jedną kapotę to się lubi co się ma', DATE '1914-06-03', 1, 50, 71.20, 'Agnieszka', 'Dostojewska', NULL, 'Drux'),
  ('4-502-60483-6', 'Biedny kupuje jedną kapotę pora powiedzieć „b”', DATE '1978-02-17', 1, 51, 76.0, 'Agnieszka', 'Malinowska', NULL, 'Atakałke'),
  ('3-068-90395-5', 'Biedny kupuje jedną kapotę to z dobrego konia', DATE '1942-02-26', 2, 42, 38.30, 'Rafał', 'Adamczyk', NULL, 'ASCT'),
  ('0-905-36794-4', 'Biedny kupuje jedną kapotę to z dobrego konia', DATE '1984-06-17', 1, 65, 100.60, 'Alicja', 'Słowacka', NULL, 'GGWP'),
  ('1-129-14019-9', 'Biedny kupuje jedną kapotę temu czas', DATE '1957-06-25', 1, 63, 188.40, 'Mikołaj', 'Mazur', NULL, 'Kruti'),
  ('5-727-25866-9', 'Biedny kupuje jedną kapotę za przewodnika', DATE '2005-07-24', 1, 47, 161.90, 'Szymon', 'Malinowski', NULL, 'GGWP'),
  ('1-443-01228-9', 'Biedny kupuje jedną kapotę cygana powiesili', DATE '1725-02-10', 1, 39, 99.40, 'Felicyta', 'Kaczmarek', NULL, 'Babunia'),
  ('8-429-56499-3', 'Biedny kupuje jedną kapotę oka nie wykole', DATE '1962-07-19', 1, 63, 66.80, 'Brygida', 'Krysicka', NULL, 'Podziemie'),
  ('2-440-82434-8', 'Biedny kupuje jedną kapotę mało mleka daje', DATE '2013-11-03', 1, 20, 87.60, NULL, NULL, 'Wsród Matematyki', 'NGU'),
  ('5-529-96352-8', 'Biedny kupuje jedną kapotę trochę zimy, trochę lata', DATE '1949-08-28', 4, 24, 148.0, 'Anna', 'Pawlak', NULL, 'Wesoła Szkoła'),
  ('2-561-41862-6', 'Biedny kupuje jedną kapotę nie wart i kołacza', DATE '1973-10-01', 1, 31, 76.50, 'Szymon', 'Schneider', NULL, 'Kruca Fix'),
  ('0-247-29380-6', 'Biedny kupuje jedną kapotę ponieśli i wilka', DATE '1999-10-06', 3, 57, 127.20, 'Paulina', 'Dura', NULL, 'Pies Filemon'),
  ('1-491-09448-6', 'Biedny kupuje jedną kapotę nikt nie wie', DATE '1991-10-17', 1, 61, 27.70, 'Aleksandra', 'Nowakowska', NULL, 'Drux'),
  ('9-019-02594-5', 'Bierz nogi za pas nie ma chatki', DATE '2002-03-26', 1, 46, 9.30, 'Michał', 'Mickiewicz', NULL, 'GGWP'),
  ('9-684-29658-4', 'Bierz nogi za pas że przymarznie cap do kozy', DATE '1866-10-12', 1, 51, 38.20, 'Andrzej', 'Kamiński', NULL, 'Extra Ciemne'),
  ('4-078-08505-9', 'Bierz nogi za pas ale na całe życie', DATE '2005-10-27', 1, 74, 121.30, 'Sandra', 'Kazimierczak', NULL, 'Kruca Fix'),
  ('8-698-73872-9', 'Bierz nogi za pas póki jeszcze czas', DATE '1943-12-16', 1, 64, 16.80, 'Małgorzata', 'Gradek', NULL, 'Kruti'),
  ('7-315-42130-0', 'Bierz nogi za pas byk się ocieli', DATE '2008-05-11', 4, 62, 34.70, 'Piotr', 'Gołąbek', NULL, 'NGU'),
  ('6-233-90818-3', 'Bierz nogi za pas to drugiemu niewola', DATE '1857-10-02', 3, 31, 60.0, 'Rafał', 'Mełech', NULL, 'Gambit Kaczmarkowski'),
  ('2-640-51494-6', 'Bierz nogi za pas to go nie minie', DATE '1951-03-25', 1, 70, 121.30, 'Rafał', 'Helik', NULL, 'Babunia'),
  ('4-501-42704-3', 'Bierz nogi za pas to zima przejada', DATE '1909-02-07', 1, 51, 18.70, 'Karolina', 'Mełech', NULL, 'Kot Reksio'),
  ('9-998-73376-6', 'Bierz nogi za pas dom wesołym czyni', DATE '1991-09-21', 1, 58, 73.60, 'Zuzanna', 'Hoser', NULL, 'Gambit Kaczmarkowski'),
  ('5-019-10811-1', 'Bierz nogi za pas wrócić ziarno na śniadanie', DATE '1928-11-24', 3, 59, 79.0, 'Małgorzata', 'Dąbrowkska', NULL, 'Afro'),
  ('1-051-00131-5', 'Bierz nogi za pas jak się kto przepości', DATE '1963-03-12', 1, 53, 43.70, 'Rafał', 'Kondratek', NULL, 'Extra Ciemne'),
  ('5-579-10961-X', 'Bierz nogi za pas pada aż do Zuzanny', DATE '1960-11-15', 1, 30, 112.20, 'Filip', 'Majewski', NULL, 'Extra Ciemne'),
  ('8-398-07496-5', 'Bierz nogi za pas znać jabłuszko na jabłoni', DATE '1953-01-01', 1, 39, 24.0, 'Mateusz', 'Kazimierczak', NULL, 'ASCT'),
  ('4-154-15003-0', 'Bierz nogi za pas jesień krótka, szybko mija', DATE '1911-04-22', 1, 20, 73.50, 'Janusz', 'Nowak', NULL, 'Kruti'),
  ('0-243-90644-7', 'Bierz nogi za pas to się diabeł cieszy', DATE '1995-03-20', 1, 31, 45.30, 'Rafał', 'Gradek', NULL, 'Afro'),
  ('8-024-04847-7', 'Bierz nogi za pas zwykle nastaje posucha', DATE '1990-11-25', 1, 30, 49.10, 'Szymon', 'Mazur', NULL, 'Wesoła Szkoła'),
  ('8-749-82108-3', 'Bierz nogi za pas piekła nie ma', DATE '1960-12-18', 1, 38, 28.50, 'Anna', 'Klemens', NULL, 'NGU'),
  ('6-348-64505-3', 'Bierz nogi za pas piekło gore', DATE '2012-08-19', 1, 26, 99.40, 'Jacek', 'Dudek', NULL, 'Afro'),
  ('2-945-90048-3', 'Bierz nogi za pas tym bardziej nosa zadziera', DATE '1779-09-29', 1, 40, 94.30, 'Bartłomiej', 'Pawlak', NULL, 'WSSP'),
  ('1-368-01948-X', 'Bierz nogi za pas tym wyżej głowę nosi', DATE '1906-05-06', 1, 52, 17.50, 'Andrzej', 'Głowacka', NULL, 'Drux'),
  ('1-114-43713-1', 'Bierz nogi za pas tym więcej chce', DATE '1914-01-11', 1, 72, 105.50, 'Andrzej', 'Wiśniewski', NULL, 'Siedmiu Krasnoludków'),
  ('6-788-81106-7', 'Bierz nogi za pas tym spokojniej śpisz', DATE '1943-12-11', 2, 24, 24.60, 'Mateusz', 'Klemens', NULL, 'Wesoła Szkoła'),
  ('2-404-58158-9', 'Bierz nogi za pas tym bardziej gryzie', DATE '1916-12-10', 3, 65, 61.50, 'Kornel', 'Krysicki', NULL, 'Afro'),
  ('8-671-61785-8', 'Bierz nogi za pas tak cię cenią', DATE '1990-04-28', 1, 53, 115.80, NULL, NULL, 'Wsród Matematyki', 'Pies Filemon'),
  ('1-296-27687-2', 'Bierz nogi za pas kij się znajdzie', DATE '1928-07-07', 1, 51, 53.20, 'Kamila', 'Bobak', NULL, 'Kruca Fix'),
  ('9-250-07293-7', 'Bierz nogi za pas to się diabeł cieszy', DATE '1900-08-15', 1, 44, 69.0, 'Rafał', 'Klemens', NULL, 'Kruca Fix'),
  ('5-700-11283-3', 'Bierz nogi za pas tak się koniec grudnia nosi', DATE '1943-04-14', 1, 62, 129.90, 'Weronika', 'Kondratek', NULL, 'Pentakill'),
  ('7-424-50470-3', 'Bierz nogi za pas to się lubi co się ma', DATE '1950-07-26', 2, 19, 44.30, 'Maciek', 'Hoser', NULL, 'Loki'),
  ('5-063-13740-7', 'Bierz nogi za pas pora powiedzieć „b”', DATE '1930-09-23', 1, 30, 35.90, 'Brygida', 'Kucharczyk', NULL, 'Januszex'),
  ('6-600-16291-0', 'Bierz nogi za pas to z dobrego konia', DATE '1969-05-01', 1, 35, 109.20, 'Anna', 'Nowakowska', NULL, 'Kruti'),
  ('3-237-69571-8', 'Bierz nogi za pas to z dobrego konia', DATE '1985-11-19', 1, 45, 115.20, 'Janusz', 'Klemens', NULL, 'Babunia'),
  ('0-728-75203-4', 'Bierz nogi za pas temu czas', DATE '1985-05-26', 3, 50, 33.10, 'Filip', 'Kucharczyk', NULL, 'Babunia'),
  ('3-332-25156-2', 'Bierz nogi za pas za przewodnika', DATE '1958-05-28', 1, 37, 172.70, 'Maciek', 'Głowacka', NULL, 'Extra Ciemne'),
  ('9-500-65417-2', 'Bierz nogi za pas cygana powiesili', DATE '1904-11-14', 1, 56, 47.20, 'Bożydar', 'Stępień', NULL, 'Babunia'),
  ('3-267-85487-3', 'Bierz nogi za pas oka nie wykole', DATE '1959-10-20', 1, 33, 38.20, 'Alicja', 'Hoser', NULL, 'WSSP'),
  ('6-757-28185-6', 'Bierz nogi za pas mało mleka daje', DATE '1925-02-09', 1, 33, 55.80, 'Piotr', 'Pupa', NULL, 'Gambit Kaczmarkowski'),
  ('1-948-52629-8', 'Bierz nogi za pas trochę zimy, trochę lata', DATE '1999-02-19', 1, 42, 129.30, 'Katarzyna', 'Cebulska', NULL, 'Podziemie'),
  ('7-721-65323-1', 'Bierz nogi za pas nie wart i kołacza', DATE '2002-08-15', 1, 42, 22.0, 'Mateusz', 'Kazimierczak', NULL, 'GGWP'),
  ('3-997-36670-5', 'Bierz nogi za pas ponieśli i wilka', DATE '1948-06-25', 1, 62, 87.60, NULL, NULL, 'Encylopedia Informatyki', 'Pentakill'),
  ('3-393-02801-4', 'Bierz nogi za pas nikt nie wie', DATE '1939-06-12', 1, 36, 38.50, 'Andrzej', 'Johansen', NULL, 'Afro'),
  ('4-603-15620-0', 'Bogatemu to nie ma chatki', DATE '1944-06-11', 1, 62, 79.40, 'Jacek', 'Kostrikin', NULL, 'Wesoła Szkoła'),
  ('5-535-57372-8', 'Bogatemu to że przymarznie cap do kozy', DATE '1945-01-25', 1, 59, 35.50, 'Wiktor', 'Sienkiewicz', NULL, 'Wesoła Szkoła'),
  ('9-477-62220-6', 'Bogatemu to ale na całe życie', DATE '1967-12-23', 1, 29, 20.50, 'Agnieszka', 'Nowicka', NULL, 'Siedmiu Krasnoludków'),
  ('0-151-86773-9', 'Bogatemu to póki jeszcze czas', DATE '1986-04-06', 1, 59, 69.30, NULL, NULL, 'Uniwersytet Koloni Krężnej', 'Drux'),
  ('4-647-10747-7', 'Bogatemu to byk się ocieli', DATE '1902-12-06', 3, 40, 79.60, 'Hans', 'Goldberg', NULL, 'Pies Filemon'),
  ('8-437-39377-9', 'Bogatemu to to drugiemu niewola', DATE '1919-01-09', 1, 44, 106.10, 'Katarzyna', 'Johansen', NULL, 'Pentakill'),
  ('3-328-82449-9', 'Bogatemu to to go nie minie', DATE '1979-09-07', 1, 47, 179.80, 'Andrzej', 'Johansen', NULL, 'Afro'),
  ('0-840-27567-6', 'Bogatemu to to zima przejada', DATE '2000-12-07', 4, 53, 144.70, 'Aleksandra', 'Dąbrowkska', NULL, 'Siedmiu Krasnoludków'),
  ('5-717-74834-5', 'Bogatemu to dom wesołym czyni', DATE '2008-06-02', 1, 30, 33.10, NULL, NULL, 'Uniwersytet Koloni Krężnej', 'Siedmiu Krasnoludków'),
  ('4-555-57229-7', 'Bogatemu to wrócić ziarno na śniadanie', DATE '1943-04-29', 1, 44, 44.30, NULL, NULL, 'FAKTCS', 'Wesoła Szkoła'),
  ('4-537-27372-0', 'Bogatemu to jak się kto przepości', DATE '1910-10-18', 2, 34, 39.70, 'Jacek', 'Goldberg', NULL, 'ASCT'),
  ('9-451-20959-X', 'Bogatemu to pada aż do Zuzanny', DATE '1962-07-01', 1, 33, 58.80, 'Zuzanna', 'Nowakowska', NULL, 'Afro'),
  ('9-508-01453-9', 'Bogatemu to znać jabłuszko na jabłoni', DATE '1985-07-14', 3, 24, 29.20, 'Brygida', 'Wojciechowska', NULL, 'Atakałke'),
  ('1-698-88519-9', 'Bogatemu to jesień krótka, szybko mija', DATE '1986-09-02', 1, 47, 127.30, 'Weronika', 'Kazimierczak', NULL, 'Podziemie'),
  ('7-844-13513-1', 'Bogatemu to to się diabeł cieszy', DATE '1988-07-26', 3, 7, 61.30, 'Jan', 'Nowak', NULL, 'Kot Reksio'),
  ('2-199-56993-4', 'Bogatemu to zwykle nastaje posucha', DATE '1854-07-22', 4, 31, 93.30, 'Kamila', 'Gradek', NULL, 'Siedmiu Krasnoludków'),
  ('8-181-02593-8', 'Bogatemu to piekła nie ma', DATE '1920-03-16', 1, 33, 100.80, 'Jakub', 'Homoncik', NULL, 'ASCT'),
  ('4-863-44648-9', 'Bogatemu to piekło gore', DATE '2013-08-18', 1, 35, 84.90, 'Bożydar', 'Homoncik', NULL, 'Siedmiu Krasnoludków'),
  ('1-249-10975-2', 'Bogatemu to tym bardziej nosa zadziera', DATE '1906-06-30', 1, 34, 86.20, 'Maciek', 'Dostojewski', NULL, 'Pentakill'),
  ('1-451-28587-6', 'Bogatemu to tym wyżej głowę nosi', DATE '1946-02-14', 4, 57, 162.30, NULL, NULL, 'Poczta Polska', 'Januszex'),
  ('4-272-70641-1', 'Bogatemu to tym więcej chce', DATE '1925-10-18', 4, 51, 97.20, 'Jacek', 'Mazur', NULL, 'Pentakill'),
  ('7-650-22496-1', 'Bogatemu to tym spokojniej śpisz', DATE '1943-11-11', 4, 67, 58.50, NULL, NULL, 'Encylopedia Informatyki', 'Loki'),
  ('9-365-61449-X', 'Bogatemu to tym bardziej gryzie', DATE '2004-10-27', 2, 71, 54.0, 'Szymon', 'Stępień', NULL, 'Babunia'),
  ('6-771-86453-7', 'Bogatemu to tak cię cenią', DATE '1932-04-17', 2, 49, 126.30, 'Agnieszka', 'Mełech', NULL, 'Kruti'),
  ('5-536-49411-2', 'Bogatemu to kij się znajdzie', DATE '1983-12-29', 1, 39, 13.60, 'Iwona', 'Sienkiewicz', NULL, 'NGU'),
  ('9-852-02739-5', 'Bogatemu to to się diabeł cieszy', DATE '1965-11-11', 1, 18, 55.90, 'Mikołaj', 'Dąbrowkski', NULL, 'Pentakill'),
  ('5-048-14534-8', 'Bogatemu to tak się koniec grudnia nosi', DATE '1996-05-24', 1, 20, 15.40, 'Joanna', 'Kaczmarek', NULL, 'Extra Ciemne'),
  ('8-251-62321-9', 'Bogatemu to to się lubi co się ma', DATE '1927-05-06', 1, 13, 28.0, 'Henryk', 'Monarek', NULL, 'Pentakill'),
  ('7-469-94165-7', 'Bogatemu to pora powiedzieć „b”', DATE '2001-02-15', 1, 49, 26.70, 'Adam', 'Grabowski', NULL, 'NGU'),
  ('3-412-28989-2', 'Bogatemu to to z dobrego konia', DATE '1900-03-29', 3, 54, 84.40, 'Grzegorz', 'Sejko', NULL, 'NGU'),
  ('7-838-48473-1', 'Bogatemu to to z dobrego konia', DATE '1903-09-07', 1, 54, 105.10, 'Agnieszka', 'Dura', NULL, 'WSSP'),
  ('8-709-17967-4', 'Bogatemu to temu czas', DATE '1906-02-13', 1, 43, 61.40, 'Filip', 'Pawlak', NULL, 'Januszex'),
  ('3-329-40842-1', 'Bogatemu to za przewodnika', DATE '2007-06-18', 1, 46, 83.80, 'Bożydar', 'Dudek', NULL, 'Pies Filemon'),
  ('1-007-95036-6', 'Bogatemu to cygana powiesili', DATE '1976-07-11', 1, 36, 122.0, 'Łukasz', 'Malinowski', NULL, 'Afro'),
  ('1-365-47566-2', 'Bogatemu to oka nie wykole', DATE '2009-01-03', 1, 60, 104.80, 'Anna', 'Kaczmarek', NULL, 'WSSP'),
  ('4-069-79234-1', 'Bogatemu to mało mleka daje', DATE '1731-11-03', 1, 51, 86.40, 'Michał', 'Johansen', NULL, 'Kot Reksio'),
  ('6-534-99459-3', 'Bogatemu to trochę zimy, trochę lata', DATE '1952-10-01', 1, 40, 19.10, 'Felicyta', 'Kamińska', NULL, 'Kot Reksio'),
  ('2-605-18352-1', 'Bogatemu to nie wart i kołacza', DATE '1998-07-30', 4, 60, 88.30, 'Paweł', 'Głowacka', NULL, 'ASCT'),
  ('1-286-42377-5', 'Bogatemu to ponieśli i wilka', DATE '1981-03-14', 1, 56, 104.50, NULL, NULL, 'Dreamteam', 'Kot Reksio'),
  ('6-216-74894-7', 'Bogatemu to nikt nie wie', DATE '1972-05-01', 2, 15, 74.20, 'Janusz', 'Dostojewski', NULL, 'Atakałke'),
  ('3-355-51969-3', 'Co jednemu swawola nie ma chatki', DATE '1924-08-11', 1, 57, 86.30, 'Elżbieta', 'Dudek', NULL, 'WSSP'),
  ('2-699-44319-0', 'Co jednemu swawola że przymarznie cap do kozy', DATE '1402-11-17', 1, 19, 21.70, 'Aleksandra', 'Majewska', NULL, 'Afro'),
  ('9-272-11911-1', 'Co jednemu swawola ale na całe życie', DATE '1943-05-06', 1, 69, 120.80, 'Weronika', 'Schneider', NULL, 'Kot Reksio'),
  ('9-839-44237-6', 'Co jednemu swawola póki jeszcze czas', DATE '1908-09-27', 1, 57, 104.50, 'Tomasz', 'Kaczmarek', NULL, 'Pies Filemon'),
  ('9-864-45496-X', 'Co jednemu swawola byk się ocieli', DATE '1958-11-14', 1, 66, 111.50, NULL, NULL, 'Uniwersytet Koloni Krężnej', 'ASCT'),
  ('0-840-06914-6', 'Co jednemu swawola to drugiemu niewola', DATE '1991-04-23', 2, 21, 59.30, 'Brygida', 'Kucharczyk', NULL, 'Siedmiu Krasnoludków'),
  ('9-594-91254-5', 'Co jednemu swawola to go nie minie', DATE '1915-08-29', 1, 29, 54.90, NULL, NULL, 'Uniwersytet Koloni Krężnej', 'ASCT'),
  ('0-820-44196-1', 'Co jednemu swawola to zima przejada', DATE '2002-02-09', 1, 53, 110.90, 'Tomasz', 'Głowacka', NULL, 'Gambit Kaczmarkowski'),
  ('7-617-13556-4', 'Co jednemu swawola dom wesołym czyni', DATE '1930-12-06', 1, 35, 75.10, 'Brygida', 'Lewandowska', NULL, 'WSSP'),
  ('9-013-60977-5', 'Co jednemu swawola wrócić ziarno na śniadanie', DATE '1394-09-19', 1, 88, 92.40, 'Anna', 'Monarek', NULL, 'GGWP'),
  ('4-905-30643-4', 'Co jednemu swawola jak się kto przepości', DATE '1991-02-04', 1, 15, 24.0, 'Agnieszka', 'Stępień', NULL, 'Afro'),
  ('5-464-91508-7', 'Co jednemu swawola pada aż do Zuzanny', DATE '1922-11-16', 1, 50, 21.0, 'Michał', 'Woźniak', NULL, 'Gambit Kaczmarkowski'),
  ('4-476-85071-5', 'Co jednemu swawola znać jabłuszko na jabłoni', DATE '1970-10-01', 1, 39, 185.70, 'Jakub', 'Klemens', NULL, 'Extra Ciemne'),
  ('5-369-30628-1', 'Co jednemu swawola jesień krótka, szybko mija', DATE '1947-01-12', 1, 57, 45.0, 'Anna', 'Gross', NULL, 'Loki'),
  ('7-609-45407-9', 'Co jednemu swawola to się diabeł cieszy', DATE '1904-02-08', 1, 59, 110.50, 'Łukasz', 'Witkowski', NULL, 'Loki'),
  ('7-722-79870-5', 'Co jednemu swawola zwykle nastaje posucha', DATE '1935-07-15', 3, 48, 102.20, 'Katarzyna', 'Homoncik', NULL, 'Kruca Fix'),
  ('6-628-50772-6', 'Co jednemu swawola piekła nie ma', DATE '2001-05-20', 1, 39, 30.90, 'Hans', 'Jachowicz', NULL, 'Drux'),
  ('8-445-42162-X', 'Co jednemu swawola piekło gore', DATE '1928-09-17', 1, 42, 27.40, 'Elżbieta', 'Jachowicz', NULL, 'Kruti'),
  ('4-827-70336-1', 'Co jednemu swawola tym bardziej nosa zadziera', DATE '1900-02-02', 1, 27, 43.70, 'Mikołaj', 'Neumann', NULL, 'Pies Filemon'),
  ('8-492-06235-5', 'Co jednemu swawola tym wyżej głowę nosi', DATE '1987-05-14', 1, 51, 106.10, 'Piotr', 'Kazimierczak', NULL, 'Siedmiu Krasnoludków'),
  ('6-055-35159-5', 'Co jednemu swawola tym więcej chce', DATE '2011-09-28', 1, 54, 39.10, 'Adam', 'Sienkiewicz', NULL, 'Pentakill'),
  ('1-914-39484-4', 'Co jednemu swawola tym spokojniej śpisz', DATE '1928-01-19', 1, 68, 8.30, 'Małgorzata', 'Górska', NULL, 'Afro'),
  ('4-624-45371-9', 'Co jednemu swawola tym bardziej gryzie', DATE '1904-04-08', 1, 71, 42.0, NULL, NULL, 'TCS times', 'Pentakill'),
  ('9-285-55949-2', 'Co jednemu swawola tak cię cenią', DATE '1978-11-10', 1, 59, 104.10, 'Dariusz', 'Górski', NULL, 'Kot Reksio'),
  ('1-052-57444-0', 'Co jednemu swawola kij się znajdzie', DATE '1913-04-27', 3, 41, 98.30, 'Katarzyna', 'Homoncik', NULL, 'Januszex'),
  ('6-198-61943-5', 'Co jednemu swawola to się diabeł cieszy', DATE '1999-04-13', 1, 33, 71.60, 'Jan', 'Woźniak', NULL, 'ASCT'),
  ('9-366-64952-1', 'Co jednemu swawola tak się koniec grudnia nosi', DATE '1962-06-12', 1, 33, 68.40, 'Małgorzata', 'Kaczmarek', NULL, 'Loki'),
  ('4-169-16394-X', 'Co jednemu swawola to się lubi co się ma', DATE '1911-02-13', 2, 67, 21.10, 'Aleksandra', 'Johansen', NULL, 'Extra Ciemne'),
  ('2-056-29901-1', 'Co jednemu swawola pora powiedzieć „b”', DATE '1932-11-24', 1, 59, 74.80, 'Jarosław', 'Kostrikin', NULL, 'GGWP'),
  ('2-108-54002-4', 'Co jednemu swawola to z dobrego konia', DATE '1948-04-06', 1, 45, 35.80, 'Łukasz', 'Cebulski', NULL, 'Drux'),
  ('4-992-61382-9', 'Co jednemu swawola to z dobrego konia', DATE '1931-11-21', 1, 36, 33.90, NULL, NULL, 'Dreamteam', 'GGWP'),
  ('3-545-22241-1', 'Co jednemu swawola temu czas', DATE '1928-11-08', 1, 35, 41.70, 'Grzegorz', 'Jaworski', NULL, 'Siedmiu Krasnoludków'),
  ('1-691-63800-5', 'Co jednemu swawola za przewodnika', DATE '1928-03-09', 2, 30, 155.20, 'Agnieszka', 'Kostrikin', NULL, 'Siedmiu Krasnoludków'),
  ('8-533-25938-7', 'Co jednemu swawola cygana powiesili', DATE '1912-01-24', 1, 24, 53.0, 'Paulina', 'Głowacka', NULL, 'NGU'),
  ('1-066-46271-2', 'Co jednemu swawola oka nie wykole', DATE '1904-12-18', 1, 18, 137.50, 'Maciek', 'Piotrowski', NULL, 'ASCT'),
  ('9-622-03389-X', 'Co jednemu swawola mało mleka daje', DATE '2004-08-14', 1, 40, 67.30, 'Adam', 'Wiśniewski', NULL, 'Afro'),
  ('4-145-84308-8', 'Co jednemu swawola trochę zimy, trochę lata', DATE '1955-04-04', 1, 74, 107.20, 'Weronika', 'Filtz', NULL, 'Kruca Fix'),
  ('3-102-56391-0', 'Co jednemu swawola nie wart i kołacza', DATE '1937-03-22', 4, 40, 118.20, 'Jarosław', 'Woźniak', NULL, 'Pies Filemon'),
  ('5-003-46548-3', 'Co jednemu swawola ponieśli i wilka', DATE '1104-07-14', 1, 25, 109.50, NULL, NULL, 'Poczta Polska', 'Kruca Fix'),
  ('4-338-02513-1', 'Co jednemu swawola nikt nie wie', DATE '2003-06-27', 1, 38, 43.10, 'Jarosław', 'Sejko', NULL, 'Atakałke'),
  ('4-606-64125-8', 'Co komu pisane nie ma chatki', DATE '1976-11-25', 1, 35, 104.80, 'Franciszek', 'Neumann', NULL, 'Pies Filemon'),
  ('1-373-61169-3', 'Co komu pisane że przymarznie cap do kozy', DATE '1857-09-12', 1, 38, 106.90, 'Agnieszka', 'Homoncik', NULL, 'Siedmiu Krasnoludków'),
  ('9-998-23396-8', 'Co komu pisane ale na całe życie', DATE '1973-06-06', 1, 40, 110.10, 'Paweł', 'Totenbach', NULL, 'Extra Ciemne'),
  ('1-127-42732-6', 'Co komu pisane póki jeszcze czas', DATE '1956-08-02', 1, 73, 21.40, NULL, NULL, 'FAKTCS', 'ASCT'),
  ('2-649-32346-9', 'Co komu pisane byk się ocieli', DATE '1940-09-28', 1, 39, 81.90, 'Michał', 'Grabowski', NULL, 'NGU'),
  ('7-626-64304-6', 'Co komu pisane to drugiemu niewola', DATE '1992-02-03', 1, 54, 111.80, 'Szymon', 'Kucharczyk', NULL, 'ASCT'),
  ('6-792-98025-0', 'Co komu pisane to go nie minie', DATE '2008-03-12', 1, 40, 50.10, 'Hans', 'Kondratek', NULL, 'Atakałke'),
  ('8-020-30744-3', 'Co komu pisane to zima przejada', DATE '1909-02-24', 3, 61, 77.80, 'Agnieszka', 'Witkowska', NULL, 'Podziemie'),
  ('7-849-44985-1', 'Co komu pisane dom wesołym czyni', DATE '1904-07-30', 2, 31, 105.0, NULL, NULL, 'Uniwersytet Koloni Krężnej', 'Loki'),
  ('9-305-20205-5', 'Co komu pisane wrócić ziarno na śniadanie', DATE '1995-02-16', 1, 64, 41.50, 'Hans', 'Piotrowski', NULL, 'Loki'),
  ('5-563-57653-1', 'Co komu pisane jak się kto przepości', DATE '1772-06-24', 1, 53, 7.50, 'Łukasz', 'Majewski', NULL, 'Kruti'),
  ('5-198-84377-6', 'Co komu pisane pada aż do Zuzanny', DATE '1936-11-16', 1, 45, 67.80, NULL, NULL, 'Piąta Ściana', 'Babunia'),
  ('0-024-30160-4', 'Co komu pisane znać jabłuszko na jabłoni', DATE '1989-07-05', 4, 33, 79.80, 'Paweł', 'Neumann', NULL, 'Babunia'),
  ('3-316-73710-3', 'Co komu pisane jesień krótka, szybko mija', DATE '1977-10-18', 1, 23, 49.40, 'Kornel', 'Głowacka', NULL, 'Kot Reksio'),
  ('1-769-42278-1', 'Co komu pisane to się diabeł cieszy', DATE '1939-10-07', 2, 31, 79.70, 'Joanna', 'Malinowska', NULL, 'Januszex'),
  ('3-353-06286-6', 'Co komu pisane zwykle nastaje posucha', DATE '1976-03-08', 4, 59, 35.20, 'Agnieszka', 'Grabowska', NULL, 'Extra Ciemne'),
  ('1-969-09254-8', 'Co komu pisane piekła nie ma', DATE '1921-11-04', 3, 52, 26.60, 'Kornel', 'Johansen', NULL, 'ASCT'),
  ('2-756-28719-9', 'Co komu pisane piekło gore', DATE '2004-07-25', 2, 47, 173.60, 'Jacek', 'Piotrowski', NULL, 'Januszex'),
  ('6-059-30808-2', 'Co komu pisane tym bardziej nosa zadziera', DATE '1954-07-23', 1, 31, 94.20, 'Łukasz', 'Neumann', NULL, 'Extra Ciemne'),
  ('3-162-05286-6', 'Co komu pisane tym wyżej głowę nosi', DATE '1992-06-30', 1, 31, 83.60, 'Bartłomiej', 'Dura', NULL, 'ASCT'),
  ('3-492-34327-9', 'Co komu pisane tym więcej chce', DATE '2015-06-23', 2, 51, 111.80, 'Wiktor', 'Lewandowski', NULL, 'Babunia'),
  ('4-513-56968-9', 'Co komu pisane tym spokojniej śpisz', DATE '1935-03-17', 2, 49, 136.0, 'Iwona', 'Dostojewska', NULL, 'Kruca Fix'),
  ('9-726-86319-8', 'Co komu pisane tym bardziej gryzie', DATE '1933-04-08', 4, 42, 10.30, 'Alicja', 'Bobak', NULL, 'WSSP'),
  ('2-309-49868-8', 'Co komu pisane tak cię cenią', DATE '2003-04-12', 1, 52, 45.10, 'Paweł', 'Schneider', NULL, 'Podziemie'),
  ('8-480-50371-8', 'Co komu pisane kij się znajdzie', DATE '1884-12-11', 1, 41, 158.0, 'Jan', 'Filtz', NULL, 'GGWP'),
  ('7-375-36938-0', 'Co komu pisane to się diabeł cieszy', DATE '1949-11-25', 1, 72, 106.20, 'Rafał', 'Cebulski', NULL, 'Gambit Kaczmarkowski'),
  ('7-514-58853-1', 'Co komu pisane tak się koniec grudnia nosi', DATE '2011-02-17', 1, 23, 103.70, 'Michał', 'Dębska', NULL, 'GGWP'),
  ('7-743-43070-7', 'Co komu pisane to się lubi co się ma', DATE '1983-03-10', 1, 29, 113.80, 'Szymon', 'Kazimierczak', NULL, 'GGWP'),
  ('6-851-84849-X', 'Co komu pisane pora powiedzieć „b”', DATE '1915-06-13', 1, 44, 71.0, 'Łukasz', 'Monarek', NULL, 'Kruti'),
  ('4-116-27670-7', 'Co komu pisane to z dobrego konia', DATE '1991-03-28', 1, 30, 136.90, 'Franciszek', 'Schneider', NULL, 'Gambit Kaczmarkowski'),
  ('0-387-94001-4', 'Co komu pisane to z dobrego konia', DATE '1925-08-27', 1, 81, 115.70, 'Kamila', 'Kucharczyk', NULL, 'Kruca Fix'),
  ('3-324-94793-6', 'Co komu pisane temu czas', DATE '1943-04-11', 4, 35, 30.0, 'Rafał', 'Kamiński', NULL, 'Extra Ciemne'),
  ('9-871-72416-0', 'Co komu pisane za przewodnika', DATE '1925-11-15', 1, 51, 42.90, 'Michał', 'Filtz', NULL, 'Babunia'),
  ('3-284-57248-1', 'Co komu pisane cygana powiesili', DATE '1978-11-13', 4, 59, 11.90, 'Katarzyna', 'Gradek', NULL, 'ASCT'),
  ('8-304-25701-7', 'Co komu pisane oka nie wykole', DATE '1959-12-09', 1, 45, 75.20, 'Janusz', 'Krysicki', NULL, 'Atakałke'),
  ('0-706-89105-8', 'Co komu pisane mało mleka daje', DATE '1993-01-07', 1, 55, 138.50, 'Łukasz', 'Sejko', NULL, 'Podziemie'),
  ('9-560-17835-0', 'Co komu pisane trochę zimy, trochę lata', DATE '1996-10-23', 1, 28, 101.30, 'Katarzyna', 'Homoncik', NULL, 'Kruti'),
  ('6-551-66627-2', 'Co komu pisane nie wart i kołacza', DATE '1826-08-13', 1, 24, 107.70, 'Karolina', 'Wojciechowska', NULL, 'Pentakill'),
  ('4-956-21474-X', 'Co komu pisane ponieśli i wilka', DATE '1923-12-26', 1, 39, 133.50, 'Michał', 'Górski', NULL, 'NGU'),
  ('2-008-25993-5', 'Co komu pisane nikt nie wie', DATE '1906-06-13', 1, 12, 164.20, 'Maciek', 'Jachowicz', NULL, 'Kruca Fix'),
  ('0-838-26036-5', 'Co lato odkłada nie ma chatki', DATE '1982-12-17', 3, 53, 31.20, 'Rafał', 'Tyminśka', NULL, 'Afro'),
  ('3-491-71939-9', 'Co lato odkłada że przymarznie cap do kozy', DATE '2005-03-24', 1, 31, 17.40, 'Kornel', 'Gradek', NULL, 'Kruca Fix'),
  ('6-011-74585-7', 'Co lato odkłada ale na całe życie', DATE '2002-10-29', 1, 29, 20.0, 'Maciek', 'Grabowski', NULL, 'Pentakill'),
  ('1-251-91324-5', 'Co lato odkłada póki jeszcze czas', DATE '2000-03-03', 1, 53, 120.60, 'Dariusz', 'Kazimierczak', NULL, 'Kruca Fix'),
  ('0-446-57020-6', 'Co lato odkłada byk się ocieli', DATE '1979-01-21', 3, 39, 162.70, 'Grzegorz', 'Schneider', NULL, 'Siedmiu Krasnoludków'),
  ('9-507-62430-9', 'Co lato odkłada to drugiemu niewola', DATE '1932-03-12', 1, 12, 102.70, 'Szymon', 'Dostojewski', NULL, 'ASCT'),
  ('4-141-95713-5', 'Co lato odkłada to go nie minie', DATE '1967-04-01', 1, 53, 14.50, 'Rafał', 'Kazimierczak', NULL, 'Wesoła Szkoła'),
  ('4-130-79130-3', 'Co lato odkłada to zima przejada', DATE '1977-02-11', 1, 32, 140.30, 'Szymon', 'Monarek', NULL, 'GGWP'),
  ('5-818-76128-2', 'Co lato odkłada dom wesołym czyni', DATE '2003-04-17', 1, 43, 67.20, 'Kamila', 'Gołąbek', NULL, 'NGU'),
  ('9-945-40660-4', 'Co lato odkłada wrócić ziarno na śniadanie', DATE '1952-06-08', 1, 60, 10.80, 'Paweł', 'Dura', NULL, 'Podziemie'),
  ('8-441-04041-9', 'Co lato odkłada jak się kto przepości', DATE '1503-08-07', 1, 63, 90.20, 'Michał', 'Kaczmarek', NULL, 'Pies Filemon'),
  ('9-914-51012-4', 'Co lato odkłada pada aż do Zuzanny', DATE '1931-05-20', 1, 35, 108.90, NULL, NULL, 'TCS WPROST', 'WSSP'),
  ('8-279-00011-9', 'Co lato odkłada znać jabłuszko na jabłoni', DATE '1978-11-15', 2, 12, 30.30, NULL, NULL, 'Współczesne rozwój', 'Loki'),
  ('5-792-12032-3', 'Co lato odkłada jesień krótka, szybko mija', DATE '1917-01-03', 1, 42, 73.20, NULL, NULL, 'Uniwersytet Koloni Krężnej', 'Loki'),
  ('9-223-49148-7', 'Co lato odkłada to się diabeł cieszy', DATE '1903-06-08', 1, 58, 99.70, 'Franciszek', 'Sejko', NULL, 'Wesoła Szkoła'),
  ('9-322-73519-8', 'Co lato odkłada zwykle nastaje posucha', DATE '1115-03-12', 1, 47, 85.30, 'Andrzej', 'Gołąbek', NULL, 'Kot Reksio'),
  ('1-143-05857-7', 'Co lato odkłada piekła nie ma', DATE '2010-03-30', 1, 43, 125.60, 'Janusz', 'Sienkiewicz', NULL, 'GGWP'),
  ('3-180-59114-5', 'Co lato odkłada piekło gore', DATE '1982-01-16', 1, 49, 98.60, 'Filip', 'Gradek', NULL, 'Wesoła Szkoła'),
  ('4-909-63246-8', 'Co lato odkłada tym bardziej nosa zadziera', DATE '1949-02-13', 1, 51, 134.20, 'Filip', 'Homoncik', NULL, 'ASCT'),
  ('7-536-18839-0', 'Co lato odkłada tym wyżej głowę nosi', DATE '1963-02-09', 1, 52, 59.60, 'Grzegorz', 'Kazimierczak', NULL, 'Babunia'),
  ('5-036-01149-X', 'Co lato odkłada tym więcej chce', DATE '1912-08-12', 1, 28, 31.40, 'Brygida', 'Głowacka', NULL, 'Siedmiu Krasnoludków'),
  ('3-374-12479-8', 'Co lato odkłada tym spokojniej śpisz', DATE '1968-07-22', 1, 13, 134.0, 'Piotr', 'Mełech', NULL, 'Gambit Kaczmarkowski'),
  ('4-437-08093-9', 'Co lato odkłada tym bardziej gryzie', DATE '1506-10-08', 4, 61, 45.0, NULL, NULL, 'Wsród Matematyki', 'GGWP'),
  ('7-217-28463-5', 'Co lato odkłada tak cię cenią', DATE '1970-12-31', 4, 74, 32.70, 'Małgorzata', 'Malinowska', NULL, 'GGWP'),
  ('4-845-82911-8', 'Co lato odkłada kij się znajdzie', DATE '2001-02-05', 1, 42, 68.20, 'Agnieszka', 'Tyminśka', NULL, 'ASCT'),
  ('2-872-71226-7', 'Co lato odkłada to się diabeł cieszy', DATE '1598-02-06', 4, 65, 24.10, 'Brygida', 'Mełech', NULL, 'Kot Reksio'),
  ('9-616-00327-5', 'Co lato odkłada tak się koniec grudnia nosi', DATE '1955-02-12', 1, 39, 59.70, 'Mateusz', 'Nowicki', NULL, 'Kruca Fix'),
  ('4-777-56562-9', 'Co lato odkłada to się lubi co się ma', DATE '1960-10-29', 1, 18, 138.10, 'Elżbieta', 'Jachowicz', NULL, 'Babunia'),
  ('4-439-58737-2', 'Co lato odkłada pora powiedzieć „b”', DATE '1987-12-25', 1, 42, 123.70, 'Andrzej', 'Dębska', NULL, 'NGU'),
  ('4-354-72033-7', 'Co lato odkłada to z dobrego konia', DATE '1929-01-04', 1, 40, 50.80, 'Jakub', 'Lewandowski', NULL, 'Extra Ciemne'),
  ('3-617-05081-6', 'Co lato odkłada to z dobrego konia', DATE '1922-11-24', 1, 27, 76.40, 'Małgorzata', 'Stępień', NULL, 'Kruti'),
  ('0-861-70789-3', 'Co lato odkłada temu czas', DATE '1994-04-21', 1, 53, 78.30, 'Bożydar', 'Tanenbaum', NULL, 'Gambit Kaczmarkowski'),
  ('3-727-32615-8', 'Co lato odkłada za przewodnika', DATE '1963-10-13', 1, 21, 61.50, 'Anna', 'Monarek', NULL, 'Pentakill'),
  ('0-114-54394-1', 'Co lato odkłada cygana powiesili', DATE '1939-05-08', 3, 66, 18.80, 'Zuzanna', 'Mełech', NULL, 'WSSP'),
  ('8-310-81397-X', 'Co lato odkłada oka nie wykole', DATE '2010-09-20', 1, 39, 71.90, 'Adam', 'Tanenbaum', NULL, 'Babunia'),
  ('2-214-11944-2', 'Co lato odkłada mało mleka daje', DATE '1867-10-12', 3, 46, 101.70, 'Paweł', 'Adamczyk', NULL, 'Kot Reksio'),
  ('9-976-40976-1', 'Co lato odkłada trochę zimy, trochę lata', DATE '1965-12-29', 1, 35, 58.20, 'Joanna', 'Kazimierczak', NULL, 'WSSP'),
  ('7-535-64741-3', 'Co lato odkłada nie wart i kołacza', DATE '1840-11-09', 3, 24, 57.0, 'Rafał', 'Grabowski', NULL, 'Podziemie'),
  ('3-778-56404-8', 'Co lato odkłada ponieśli i wilka', DATE '1973-06-19', 1, 61, 15.60, 'Jakub', 'Kostrikin', NULL, 'GGWP'),
  ('7-351-20829-8', 'Co lato odkłada nikt nie wie', DATE '2000-02-07', 1, 31, 40.90, 'Filip', 'Nowicki', NULL, 'Kruca Fix'),
  ('3-169-24295-4', 'Dobra gospodyni nie ma chatki', DATE '1958-12-11', 1, 59, 109.30, 'Szymon', 'Witkowski', NULL, 'Afro'),
  ('4-956-78937-8', 'Dobra gospodyni że przymarznie cap do kozy', DATE '1951-09-12', 1, 50, 132.10, 'Mateusz', 'Dębska', NULL, 'Afro'),
  ('7-320-18966-6', 'Dobra gospodyni ale na całe życie', DATE '1934-09-22', 1, 41, 25.70, 'Jakub', 'Hoser', NULL, 'Wesoła Szkoła'),
  ('8-220-39571-0', 'Dobra gospodyni póki jeszcze czas', DATE '1904-01-02', 1, 29, 60.0, NULL, NULL, 'Poczta Polska', 'GGWP'),
  ('3-344-62214-5', 'Dobra gospodyni byk się ocieli', DATE '1970-06-23', 1, 33, 129.0, 'Agnieszka', 'Kowalska', NULL, 'Extra Ciemne'),
  ('0-254-90835-7', 'Dobra gospodyni to drugiemu niewola', DATE '1994-08-30', 1, 20, 99.60, 'Felicyta', 'Kostrikin', NULL, 'Januszex'),
  ('4-558-36380-X', 'Dobra gospodyni to go nie minie', DATE '1947-03-13', 4, 26, 83.10, 'Wiktor', 'Malinowski', NULL, 'ASCT'),
  ('0-203-36896-7', 'Dobra gospodyni to zima przejada', DATE '1963-06-13', 1, 26, 8.70, 'Sandra', 'Wiśniewska', NULL, 'Siedmiu Krasnoludków'),
  ('9-962-09602-2', 'Dobra gospodyni dom wesołym czyni', DATE '1994-07-21', 1, 35, 166.60, 'Felicyta', 'Adamczyk', NULL, 'Pentakill'),
  ('8-968-57821-4', 'Dobra gospodyni wrócić ziarno na śniadanie', DATE '1999-04-11', 3, 54, 96.90, 'Zuzanna', 'Piotrowska', NULL, 'Januszex'),
  ('7-201-89079-4', 'Dobra gospodyni jak się kto przepości', DATE '2000-08-27', 1, 36, 100.60, 'Wiktor', 'Cebulski', NULL, 'Afro'),
  ('0-435-32933-2', 'Dobra gospodyni pada aż do Zuzanny', DATE '2006-04-28', 2, 59, 140.70, 'Piotr', 'Goldberg', NULL, 'Drux'),
  ('4-321-24571-0', 'Dobra gospodyni znać jabłuszko na jabłoni', DATE '1965-10-14', 2, 5, 28.50, 'Joanna', 'Lewandowska', NULL, 'Atakałke'),
  ('4-107-14357-0', 'Dobra gospodyni jesień krótka, szybko mija', DATE '2012-09-06', 3, 63, 35.70, 'Zuzanna', 'Neumann', NULL, 'Kruti'),
  ('0-723-96695-8', 'Dobra gospodyni to się diabeł cieszy', DATE '2001-01-15', 1, 48, 117.30, 'Sandra', 'Goldberg', NULL, 'Wesoła Szkoła'),
  ('9-888-50573-4', 'Dobra gospodyni zwykle nastaje posucha', DATE '1911-10-30', 1, 59, 12.10, 'Piotr', 'Zieliński', NULL, 'Gambit Kaczmarkowski'),
  ('9-108-32830-7', 'Dobra gospodyni piekła nie ma', DATE '1971-12-08', 1, 60, 23.0, NULL, NULL, 'Dreamteam', 'WSSP'),
  ('6-514-03316-4', 'Dobra gospodyni piekło gore', DATE '1962-11-02', 1, 74, 126.0, 'Paulina', 'Gołąbek', NULL, 'NGU'),
  ('7-703-49163-2', 'Dobra gospodyni tym bardziej nosa zadziera', DATE '1983-01-18', 1, 20, 34.90, 'Łukasz', 'Słowacki', NULL, 'Siedmiu Krasnoludków'),
  ('7-639-10616-8', 'Dobra gospodyni tym wyżej głowę nosi', DATE '1932-08-14', 4, 44, 43.0, 'Mikołaj', 'Schmidt', NULL, 'GGWP'),
  ('4-889-45586-8', 'Dobra gospodyni tym więcej chce', DATE '1962-01-17', 4, 48, 102.0, NULL, NULL, 'Panowie Z Drugiej Ławki', 'Atakałke'),
  ('9-850-78658-2', 'Dobra gospodyni tym spokojniej śpisz', DATE '1952-06-02', 1, 19, 35.90, 'Adam', 'Totenbach', NULL, 'Afro'),
  ('6-199-99841-3', 'Dobra gospodyni tym bardziej gryzie', DATE '1986-01-05', 1, 29, 66.60, 'Mateusz', 'Mełech', NULL, 'Loki'),
  ('1-385-35744-4', 'Dobra gospodyni tak cię cenią', DATE '1993-09-24', 1, 35, 84.0, 'Henryk', 'Wojciechowski', NULL, 'Gambit Kaczmarkowski'),
  ('4-823-14891-6', 'Dobra gospodyni kij się znajdzie', DATE '1819-07-18', 1, 49, 15.10, 'Katarzyna', 'Kowalska', NULL, 'Afro'),
  ('5-631-10945-X', 'Dobra gospodyni to się diabeł cieszy', DATE '1964-08-12', 1, 39, 163.10, 'Agnieszka', 'Sienkiewicz', NULL, 'Drux'),
  ('5-423-19162-9', 'Dobra gospodyni tak się koniec grudnia nosi', DATE '1960-12-12', 2, 30, 90.60, 'Joanna', 'Tyminśka', NULL, 'Gambit Kaczmarkowski'),
  ('2-830-18453-X', 'Dobra gospodyni to się lubi co się ma', DATE '2014-10-29', 1, 15, 70.60, 'Weronika', 'Neumann', NULL, 'Babunia'),
  ('5-340-78900-4', 'Dobra gospodyni pora powiedzieć „b”', DATE '1901-08-27', 1, 34, 54.10, 'Weronika', 'Jachowicz', NULL, 'Januszex'),
  ('9-418-18180-0', 'Dobra gospodyni to z dobrego konia', DATE '1998-10-24', 4, 64, 96.40, 'Anna', 'Sienkiewicz', NULL, 'WSSP'),
  ('8-476-58187-4', 'Dobra gospodyni to z dobrego konia', DATE '1966-01-28', 1, 33, 72.50, 'Zuzanna', 'Dąbrowkska', NULL, 'Wesoła Szkoła'),
  ('7-149-94583-X', 'Dobra gospodyni temu czas', DATE '1931-05-07', 4, 33, 83.20, 'Jacek', 'Schneider', NULL, 'GGWP'),
  ('6-618-28089-3', 'Dobra gospodyni za przewodnika', DATE '1930-11-23', 2, 17, 7.60, 'Kornel', 'Kucharczyk', NULL, 'GGWP'),
  ('2-270-93903-4', 'Dobra gospodyni cygana powiesili', DATE '1998-04-22', 3, 18, 129.40, 'Franciszek', 'Głowacka', NULL, 'ASCT'),
  ('8-134-87877-6', 'Dobra gospodyni oka nie wykole', DATE '1996-05-13', 1, 48, 18.20, 'Anna', 'Dębska', NULL, 'Drux'),
  ('3-200-29155-9', 'Dobra gospodyni mało mleka daje', DATE '1984-04-22', 1, 43, 131.80, 'Adam', 'Nowakowski', NULL, 'Loki'),
  ('8-713-17717-6', 'Dobra gospodyni trochę zimy, trochę lata', DATE '1912-11-18', 1, 66, 70.80, 'Paweł', 'Dura', NULL, 'Kruca Fix'),
  ('7-319-19954-8', 'Dobra gospodyni nie wart i kołacza', DATE '1952-11-16', 2, 52, 21.80, 'Hans', 'Słowacki', NULL, 'WSSP'),
  ('0-922-19521-8', 'Dobra gospodyni ponieśli i wilka', DATE '1934-03-09', 1, 63, 104.60, 'Mikołaj', 'Mazur', NULL, 'Afro'),
  ('5-670-07929-9', 'Dobra gospodyni nikt nie wie', DATE '1980-06-28', 1, 42, 12.50, 'Kamila', 'Kamińska', NULL, 'ASCT'),
  ('7-098-24614-X', 'Dobre wychowanie nie ma chatki', DATE '1972-06-22', 2, 29, 48.20, 'Paweł', 'Mełech', NULL, 'Babunia'),
  ('7-570-37225-5', 'Dobre wychowanie że przymarznie cap do kozy', DATE '1673-04-10', 1, 45, 5.80, 'Grzegorz', 'Totenbach', NULL, 'Afro'),
  ('7-856-14306-1', 'Dobre wychowanie ale na całe życie', DATE '1903-06-13', 1, 34, 91.0, 'Karolina', 'Sienkiewicz', NULL, 'Drux'),
  ('3-807-39705-1', 'Dobre wychowanie póki jeszcze czas', DATE '1995-09-12', 1, 29, 84.20, 'Iwona', 'Bobak', NULL, 'NGU'),
  ('2-855-68567-2', 'Dobre wychowanie byk się ocieli', DATE '1993-11-12', 1, 74, 30.40, 'Zuzanna', 'Kostrikin', NULL, 'ASCT'),
  ('2-986-00677-9', 'Dobre wychowanie to drugiemu niewola', DATE '2003-03-17', 1, 18, 70.80, 'Wiktor', 'Gołąbek', NULL, 'GGWP'),
  ('5-663-80268-1', 'Dobre wychowanie to go nie minie', DATE '1980-05-17', 1, 64, 10.30, 'Alicja', 'Schneider', NULL, 'Drux'),
  ('6-338-00784-4', 'Dobre wychowanie to zima przejada', DATE '1980-11-22', 1, 55, 32.60, 'Anna', 'Filtz', NULL, 'Loki'),
  ('8-775-85134-2', 'Dobre wychowanie dom wesołym czyni', DATE '1904-04-20', 1, 26, 82.0, 'Jacek', 'Filtz', NULL, 'Kot Reksio'),
  ('4-041-74040-1', 'Dobre wychowanie wrócić ziarno na śniadanie', DATE '1816-10-04', 1, 72, 110.0, 'Paweł', 'Schmidt', NULL, 'Siedmiu Krasnoludków'),
  ('3-765-10753-0', 'Dobre wychowanie jak się kto przepości', DATE '1904-05-26', 3, 65, 49.90, 'Łukasz', 'Lewandowski', NULL, 'Gambit Kaczmarkowski'),
  ('7-876-60327-0', 'Dobre wychowanie pada aż do Zuzanny', DATE '1990-04-23', 3, 38, 111.80, 'Anna', 'Kondratek', NULL, 'Loki'),
  ('9-884-08486-6', 'Dobre wychowanie znać jabłuszko na jabłoni', DATE '1900-05-09', 1, 32, 63.40, 'Michał', 'Monarek', NULL, 'Loki'),
  ('9-123-13129-2', 'Dobre wychowanie jesień krótka, szybko mija', DATE '1992-04-23', 1, 75, 51.70, 'Wiktor', 'Woźniak', NULL, 'WSSP'),
  ('4-227-72115-6', 'Dobre wychowanie to się diabeł cieszy', DATE '1972-12-18', 1, 50, 104.70, 'Szymon', 'Pupa', NULL, 'Wesoła Szkoła'),
  ('9-233-09626-2', 'Dobre wychowanie zwykle nastaje posucha', DATE '1946-04-07', 1, 23, 27.60, 'Bartłomiej', 'Sienkiewicz', NULL, 'NGU'),
  ('1-724-12645-8', 'Dobre wychowanie piekła nie ma', DATE '1983-02-01', 1, 65, 24.50, 'Jacek', 'Jachowicz', NULL, 'Afro'),
  ('9-358-58882-9', 'Dobre wychowanie piekło gore', DATE '2012-03-05', 1, 63, 123.10, 'Weronika', 'Dębska', NULL, 'Drux'),
  ('7-069-96466-8', 'Dobre wychowanie tym bardziej nosa zadziera', DATE '1905-11-20', 3, 52, 12.80, 'Aleksandra', 'Kamińska', NULL, 'Podziemie'),
  ('6-584-45716-8', 'Dobre wychowanie tym wyżej głowę nosi', DATE '2015-01-30', 1, 61, 85.80, 'Janusz', 'Helik', NULL, 'NGU'),
  ('2-161-12997-X', 'Dobre wychowanie tym więcej chce', DATE '2013-03-28', 1, 60, 45.80, 'Elżbieta', 'Kazimierczak', NULL, 'NGU'),
  ('0-104-24898-X', 'Dobre wychowanie tym spokojniej śpisz', DATE '1983-02-27', 1, 52, 120.10, 'Grzegorz', 'Krysicki', NULL, 'Gambit Kaczmarkowski'),
  ('0-839-35050-3', 'Dobre wychowanie tym bardziej gryzie', DATE '1986-09-05', 1, 19, 142.10, 'Anna', 'Wojciechowska', NULL, 'Januszex'),
  ('5-226-83634-1', 'Dobre wychowanie tak cię cenią', DATE '1924-12-17', 1, 24, 98.90, 'Paulina', 'Tyminśka', NULL, 'Pies Filemon'),
  ('4-043-11757-4', 'Dobre wychowanie kij się znajdzie', DATE '1982-06-21', 1, 57, 42.20, 'Franciszek', 'Gradek', NULL, 'NGU'),
  ('4-015-25568-2', 'Dobre wychowanie to się diabeł cieszy', DATE '1181-05-26', 3, 33, 72.90, 'Piotr', 'Malinowski', NULL, 'Kruti'),
  ('8-520-18243-7', 'Dobre wychowanie tak się koniec grudnia nosi', DATE '1858-08-25', 1, 60, 50.30, 'Andrzej', 'Dudek', NULL, 'Extra Ciemne'),
  ('1-946-93235-3', 'Dobre wychowanie to się lubi co się ma', DATE '1890-06-30', 1, 49, 50.70, 'Jacek', 'Bobak', NULL, 'Januszex'),
  ('8-322-15452-6', 'Dobre wychowanie pora powiedzieć „b”', DATE '1968-09-28', 4, 52, 132.70, 'Łukasz', 'Piotrowski', NULL, 'Gambit Kaczmarkowski'),
  ('8-690-97331-1', 'Dobre wychowanie to z dobrego konia', DATE '2015-06-23', 1, 62, 46.0, 'Zuzanna', 'Kondratek', NULL, 'Babunia'),
  ('1-234-84076-6', 'Dobre wychowanie to z dobrego konia', DATE '1942-05-18', 1, 23, 8.80, 'Alicja', 'Neumann', NULL, 'Kruti'),
  ('4-058-46091-1', 'Dobre wychowanie temu czas', DATE '1909-04-11', 1, 47, 94.0, 'Piotr', 'Gołąbek', NULL, 'Kruca Fix'),
  ('9-157-89959-2', 'Dobre wychowanie za przewodnika', DATE '1910-07-05', 1, 65, 62.10, 'Wiktor', 'Sienkiewicz', NULL, 'Kot Reksio'),
  ('4-967-97846-0', 'Dobre wychowanie cygana powiesili', DATE '1919-06-17', 1, 65, 47.0, 'Michał', 'Bobak', NULL, 'Kruti'),
  ('3-591-03392-8', 'Dobre wychowanie oka nie wykole', DATE '1938-08-30', 1, 35, 58.10, 'Jakub', 'Pupa', NULL, 'Afro'),
  ('8-624-67950-8', 'Dobre wychowanie mało mleka daje', DATE '1961-08-07', 1, 66, 46.20, 'Sandra', 'Klemens', NULL, 'WSSP'),
  ('1-702-29865-5', 'Dobre wychowanie trochę zimy, trochę lata', DATE '1959-03-08', 1, 73, 103.90, 'Jarosław', 'Sienkiewicz', NULL, 'NGU'),
  ('9-259-66880-8', 'Dobre wychowanie nie wart i kołacza', DATE '1921-11-10', 2, 21, 178.80, 'Sandra', 'Dudek', NULL, 'Babunia'),
  ('3-262-45416-8', 'Dobre wychowanie ponieśli i wilka', DATE '1990-04-11', 1, 62, 47.50, 'Henryk', 'Schneider', NULL, 'Kot Reksio'),
  ('8-582-01483-X', 'Dobre wychowanie nikt nie wie', DATE '1993-12-28', 1, 60, 7.70, 'Zuzanna', 'Homoncik', NULL, 'Siedmiu Krasnoludków'),
  ('3-968-14316-7', 'Dobry chleb i z ości nie ma chatki', DATE '1957-04-24', 1, 70, 57.30, 'Jakub', 'Totenbach', NULL, 'Podziemie'),
  ('6-521-87256-7', 'Dobry chleb i z ości że przymarznie cap do kozy', DATE '1907-02-18', 1, 25, 115.70, 'Łukasz', 'Monarek', NULL, 'NGU'),
  ('6-347-50394-8', 'Dobry chleb i z ości ale na całe życie', DATE '1938-11-09', 2, 39, 75.50, 'Elżbieta', 'Sejko', NULL, 'Afro'),
  ('2-738-42189-X', 'Dobry chleb i z ości póki jeszcze czas', DATE '1973-01-30', 1, 49, 129.30, 'Paulina', 'Kaczmarek', NULL, 'ASCT'),
  ('3-331-27955-2', 'Dobry chleb i z ości byk się ocieli', DATE '1985-09-06', 4, 53, 78.30, 'Anna', 'Homoncik', NULL, 'Drux'),
  ('3-337-68212-X', 'Dobry chleb i z ości to drugiemu niewola', DATE '1934-06-22', 1, 16, 148.90, 'Hans', 'Kowalski', NULL, 'Gambit Kaczmarkowski'),
  ('0-731-78625-4', 'Dobry chleb i z ości to go nie minie', DATE '1937-10-27', 2, 48, 159.40, 'Andrzej', 'Neumann', NULL, 'Drux'),
  ('3-038-63796-3', 'Dobry chleb i z ości to zima przejada', DATE '2006-01-11', 1, 37, 87.20, 'Anna', 'Nowak', NULL, 'Januszex'),
  ('3-530-47197-6', 'Dobry chleb i z ości dom wesołym czyni', DATE '1985-06-30', 1, 10, 112.30, 'Grzegorz', 'Kowalski', NULL, 'Siedmiu Krasnoludków'),
  ('1-196-14165-7', 'Dobry chleb i z ości wrócić ziarno na śniadanie', DATE '1935-01-19', 1, 27, 70.60, 'Łukasz', 'Tanenbaum', NULL, 'Afro'),
  ('7-737-66952-3', 'Dobry chleb i z ości jak się kto przepości', DATE '1908-11-11', 1, 33, 99.20, 'Janusz', 'Kostrikin', NULL, 'Drux'),
  ('0-829-20679-5', 'Dobry chleb i z ości pada aż do Zuzanny', DATE '1993-05-16', 1, 61, 142.90, NULL, NULL, 'TCS times', 'WSSP'),
  ('3-319-24906-1', 'Dobry chleb i z ości znać jabłuszko na jabłoni', DATE '1970-09-27', 1, 17, 79.80, 'Hans', 'Sienkiewicz', NULL, 'Pentakill'),
  ('7-127-05216-6', 'Dobry chleb i z ości jesień krótka, szybko mija', DATE '1935-10-03', 1, 62, 159.80, NULL, NULL, 'Panowie Z Drugiej Ławki', 'Extra Ciemne'),
  ('2-048-61573-2', 'Dobry chleb i z ości to się diabeł cieszy', DATE '1981-11-29', 4, 48, 15.60, 'Agnieszka', 'Zielińska', NULL, 'Babunia'),
  ('3-741-86126-X', 'Dobry chleb i z ości zwykle nastaje posucha', DATE '1625-02-08', 1, 48, 102.80, 'Zuzanna', 'Dura', NULL, 'WSSP'),
  ('5-543-99250-5', 'Dobry chleb i z ości piekła nie ma', DATE '1930-10-09', 4, 78, 45.10, 'Dariusz', 'Tyminśka', NULL, 'Loki'),
  ('8-502-96839-4', 'Dobry chleb i z ości piekło gore', DATE '1924-07-25', 1, 38, 62.50, 'Hans', 'Sejko', NULL, 'Loki'),
  ('9-510-81784-8', 'Dobry chleb i z ości tym bardziej nosa zadziera', DATE '2000-01-02', 1, 33, 35.20, 'Szymon', 'Witkowski', NULL, 'Loki'),
  ('8-552-55087-3', 'Dobry chleb i z ości tym wyżej głowę nosi', DATE '2010-06-29', 1, 72, 57.30, 'Michał', 'Krysicki', NULL, 'Januszex'),
  ('0-953-85850-2', 'Dobry chleb i z ości tym więcej chce', DATE '1970-11-05', 1, 29, 83.50, 'Bartłomiej', 'Nowakowski', NULL, 'Podziemie'),
  ('5-543-46411-8', 'Dobry chleb i z ości tym spokojniej śpisz', DATE '1961-03-02', 1, 26, 46.90, 'Tomasz', 'Pawlak', NULL, 'Afro'),
  ('1-814-79034-9', 'Dobry chleb i z ości tym bardziej gryzie', DATE '1985-09-20', 4, 49, 79.40, 'Filip', 'Schmidt', NULL, 'Kruti'),
  ('3-134-24431-4', 'Dobry chleb i z ości tak cię cenią', DATE '1966-12-04', 1, 62, 125.20, 'Mateusz', 'Filtz', NULL, 'Januszex'),
  ('5-824-98524-3', 'Dobry chleb i z ości kij się znajdzie', DATE '1983-11-24', 2, 41, 80.20, 'Adam', 'Mickiewicz', NULL, 'Drux'),
  ('4-402-67211-2', 'Dobry chleb i z ości to się diabeł cieszy', DATE '1039-06-07', 2, 74, 161.60, 'Janusz', 'Wojciechowski', NULL, 'Pentakill'),
  ('8-107-25149-0', 'Dobry chleb i z ości tak się koniec grudnia nosi', DATE '1935-01-14', 1, 48, 65.20, 'Sandra', 'Cebulska', NULL, 'GGWP'),
  ('4-800-68167-7', 'Dobry chleb i z ości to się lubi co się ma', DATE '1967-03-18', 1, 12, 72.90, NULL, NULL, 'Dreamteam', 'NGU'),
  ('9-371-58750-4', 'Dobry chleb i z ości pora powiedzieć „b”', DATE '1975-05-05', 1, 35, 119.10, NULL, NULL, 'Koło Taniego Czyszczenia i Sprzątania', 'Loki'),
  ('8-236-05762-3', 'Dobry chleb i z ości to z dobrego konia', DATE '1961-12-30', 1, 53, 71.20, 'Filip', 'Głowacka', NULL, 'Januszex'),
  ('6-079-88146-2', 'Dobry chleb i z ości to z dobrego konia', DATE '2015-10-01', 1, 53, 70.50, NULL, NULL, 'Dreamteam', 'Loki'),
  ('9-578-81680-4', 'Dobry chleb i z ości temu czas', DATE '1972-03-19', 1, 49, 70.30, 'Małgorzata', 'Gołąbek', NULL, 'Loki'),
  ('8-354-47237-X', 'Dobry chleb i z ości za przewodnika', DATE '1954-07-21', 1, 32, 82.60, 'Bożydar', 'Sejko', NULL, 'Pentakill'),
  ('8-512-01568-3', 'Dobry chleb i z ości cygana powiesili', DATE '2003-05-06', 3, 37, 96.20, NULL, NULL, 'FAKTCS', 'Extra Ciemne'),
  ('8-880-52905-6', 'Dobry chleb i z ości oka nie wykole', DATE '1941-08-02', 1, 44, 45.80, 'Szymon', 'Jachowicz', NULL, 'Pentakill'),
  ('1-057-03506-8', 'Dobry chleb i z ości mało mleka daje', DATE '1994-10-02', 1, 19, 26.80, 'Michał', 'Stępień', NULL, 'WSSP'),
  ('2-070-18377-7', 'Dobry chleb i z ości trochę zimy, trochę lata', DATE '1936-11-17', 1, 46, 123.10, 'Maciek', 'Woźniak', NULL, 'Loki'),
  ('8-251-27497-4', 'Dobry chleb i z ości nie wart i kołacza', DATE '2000-05-30', 1, 62, 60.90, 'Agnieszka', 'Gross', NULL, 'ASCT'),
  ('8-204-38889-6', 'Dobry chleb i z ości ponieśli i wilka', DATE '1949-06-23', 3, 20, 126.50, 'Filip', 'Woźniak', NULL, 'Extra Ciemne'),
  ('9-605-31737-0', 'Dobry chleb i z ości nikt nie wie', DATE '1947-12-23', 1, 50, 76.70, 'Janusz', 'Gołąbek', NULL, 'Atakałke'),
  ('5-912-82017-3', 'Gdy pada w dniu świętej Anny nie ma chatki', DATE '1750-06-07', 1, 50, 95.90, 'Karolina', 'Totenbach', NULL, 'Afro'),
  ('6-174-64379-4', 'Gdy pada w dniu świętej Anny że przymarznie cap do kozy', DATE '1987-08-25', 3, 33, 106.50, 'Szymon', 'Tyminśka', NULL, 'Pentakill'),
  ('7-506-37923-6', 'Gdy pada w dniu świętej Anny ale na całe życie', DATE '1982-10-26', 1, 13, 53.0, 'Maciek', 'Gross', NULL, 'Pentakill'),
  ('9-513-28846-3', 'Gdy pada w dniu świętej Anny póki jeszcze czas', DATE '2007-07-18', 1, 50, 68.10, 'Jakub', 'Zieliński', NULL, 'Extra Ciemne'),
  ('6-492-08923-5', 'Gdy pada w dniu świętej Anny byk się ocieli', DATE '1916-05-01', 1, 66, 88.70, 'Łukasz', 'Wiśniewski', NULL, 'Pentakill'),
  ('3-613-08792-8', 'Gdy pada w dniu świętej Anny to drugiemu niewola', DATE '1997-04-11', 1, 35, 27.60, 'Alicja', 'Tanenbaum', NULL, 'Loki'),
  ('0-013-74987-0', 'Gdy pada w dniu świętej Anny to go nie minie', DATE '2010-10-22', 1, 61, 106.90, 'Franciszek', 'Pawlak', NULL, 'Afro'),
  ('9-807-42758-4', 'Gdy pada w dniu świętej Anny to zima przejada', DATE '1915-10-03', 1, 22, 28.90, 'Adam', 'Mełech', NULL, 'Atakałke'),
  ('8-383-50177-3', 'Gdy pada w dniu świętej Anny dom wesołym czyni', DATE '1931-07-14', 1, 38, 87.0, 'Grzegorz', 'Helik', NULL, 'WSSP'),
  ('2-232-84867-1', 'Gdy pada w dniu świętej Anny wrócić ziarno na śniadanie', DATE '1950-07-05', 1, 49, 160.10, 'Mateusz', 'Głowacka', NULL, 'NGU'),
  ('4-922-04569-4', 'Gdy pada w dniu świętej Anny jak się kto przepości', DATE '1930-08-29', 1, 55, 36.60, 'Michał', 'Monarek', NULL, 'NGU'),
  ('4-080-42087-0', 'Gdy pada w dniu świętej Anny pada aż do Zuzanny', DATE '1905-01-12', 1, 49, 30.70, 'Filip', 'Bobak', NULL, 'GGWP'),
  ('5-815-07688-0', 'Gdy pada w dniu świętej Anny znać jabłuszko na jabłoni', DATE '1903-03-18', 1, 46, 39.30, 'Elżbieta', 'Wiśniewska', NULL, 'WSSP'),
  ('3-884-13240-7', 'Gdy pada w dniu świętej Anny jesień krótka, szybko mija', DATE '1995-07-04', 1, 40, 26.60, 'Elżbieta', 'Schmidt', NULL, 'ASCT'),
  ('8-612-67043-8', 'Gdy pada w dniu świętej Anny to się diabeł cieszy', DATE '1921-09-08', 1, 41, 82.10, 'Iwona', 'Totenbach', NULL, 'Kruti'),
  ('3-964-97319-X', 'Gdy pada w dniu świętej Anny zwykle nastaje posucha', DATE '2006-10-19', 1, 54, 179.40, 'Anna', 'Gołąbek', NULL, 'Pies Filemon'),
  ('2-566-50524-1', 'Gdy pada w dniu świętej Anny piekła nie ma', DATE '1410-08-25', 1, 82, 108.60, 'Karolina', 'Grabowska', NULL, 'GGWP'),
  ('4-209-12478-8', 'Gdy pada w dniu świętej Anny piekło gore', DATE '1995-08-11', 1, 49, 50.20, 'Agnieszka', 'Kondratek', NULL, 'Pentakill'),
  ('0-583-04503-0', 'Gdy pada w dniu świętej Anny tym bardziej nosa zadziera', DATE '1969-10-24', 1, 36, 100.30, 'Weronika', 'Gołąbek', NULL, 'GGWP'),
  ('9-233-66149-0', 'Gdy pada w dniu świętej Anny tym wyżej głowę nosi', DATE '1936-07-22', 1, 61, 150.30, 'Elżbieta', 'Malinowska', NULL, 'GGWP'),
  ('4-247-25959-8', 'Gdy pada w dniu świętej Anny tym więcej chce', DATE '1672-01-10', 1, 59, 157.40, NULL, NULL, 'Piąta Ściana', 'Babunia'),
  ('6-234-08825-2', 'Gdy pada w dniu świętej Anny tym spokojniej śpisz', DATE '1970-05-29', 2, 75, 67.20, 'Piotr', 'Pupa', NULL, 'Siedmiu Krasnoludków'),
  ('0-593-75709-2', 'Gdy pada w dniu świętej Anny tym bardziej gryzie', DATE '1907-04-20', 3, 72, 106.80, 'Kamila', 'Nowakowska', NULL, 'Pentakill'),
  ('4-673-19802-6', 'Gdy pada w dniu świętej Anny tak cię cenią', DATE '1937-12-27', 1, 28, 93.30, 'Bartłomiej', 'Tyminśka', NULL, 'Kruti'),
  ('3-344-18001-0', 'Gdy pada w dniu świętej Anny kij się znajdzie', DATE '1834-09-24', 1, 15, 38.0, 'Aleksandra', 'Klemens', NULL, 'Kot Reksio'),
  ('5-137-56390-0', 'Gdy pada w dniu świętej Anny to się diabeł cieszy', DATE '1058-04-28', 1, 35, 110.50, 'Alicja', 'Górska', NULL, 'NGU'),
  ('1-113-86616-0', 'Gdy pada w dniu świętej Anny tak się koniec grudnia nosi', DATE '1907-04-23', 1, 24, 118.30, 'Andrzej', 'Tanenbaum', NULL, 'Podziemie'),
  ('9-058-27132-3', 'Gdy pada w dniu świętej Anny to się lubi co się ma', DATE '1903-07-12', 1, 40, 142.20, 'Grzegorz', 'Kucharczyk', NULL, 'Gambit Kaczmarkowski'),
  ('3-106-32990-4', 'Gdy pada w dniu świętej Anny pora powiedzieć „b”', DATE '2002-09-07', 1, 46, 107.40, 'Agnieszka', 'Witkowska', NULL, 'Extra Ciemne'),
  ('9-895-72801-8', 'Gdy pada w dniu świętej Anny to z dobrego konia', DATE '1990-03-08', 4, 23, 100.40, 'Zuzanna', 'Schmidt', NULL, 'Gambit Kaczmarkowski'),
  ('7-044-43450-9', 'Gdy pada w dniu świętej Anny to z dobrego konia', DATE '2005-01-15', 1, 66, 19.40, NULL, NULL, 'Poczta Polska', 'Atakałke'),
  ('9-232-82986-X', 'Gdy pada w dniu świętej Anny temu czas', DATE '1938-12-12', 1, 57, 109.10, 'Paweł', 'Kondratek', NULL, 'Kot Reksio'),
  ('6-887-79031-9', 'Gdy pada w dniu świętej Anny za przewodnika', DATE '1913-12-22', 1, 44, 68.60, 'Brygida', 'Głowacka', NULL, 'Kruca Fix'),
  ('3-366-44442-8', 'Gdy pada w dniu świętej Anny cygana powiesili', DATE '1997-01-02', 1, 62, 67.90, 'Weronika', 'Gross', NULL, 'NGU'),
  ('7-296-64920-8', 'Gdy pada w dniu świętej Anny oka nie wykole', DATE '1907-07-21', 1, 17, 108.30, 'Szymon', 'Nowakowski', NULL, 'Podziemie'),
  ('7-652-12729-7', 'Gdy pada w dniu świętej Anny mało mleka daje', DATE '1922-11-06', 1, 64, 79.70, 'Felicyta', 'Neumann', NULL, 'Wesoła Szkoła'),
  ('9-197-68310-8', 'Gdy pada w dniu świętej Anny trochę zimy, trochę lata', DATE '1971-08-02', 2, 52, 171.70, 'Iwona', 'Kondratek', NULL, 'Siedmiu Krasnoludków'),
  ('8-518-62959-4', 'Gdy pada w dniu świętej Anny nie wart i kołacza', DATE '2011-12-10', 1, 45, 37.60, 'Kornel', 'Wiśniewski', NULL, 'Babunia'),
  ('1-769-65783-5', 'Gdy pada w dniu świętej Anny ponieśli i wilka', DATE '1900-05-11', 4, 29, 100.20, 'Maciek', 'Mazur', NULL, 'Siedmiu Krasnoludków'),
  ('7-488-61731-2', 'Gdy pada w dniu świętej Anny nikt nie wie', DATE '1972-09-24', 1, 75, 52.60, 'Joanna', 'Kostrikin', NULL, 'Pentakill'),
  ('3-481-97595-3', 'Gdy przejdzie święt Antoni nie ma chatki', DATE '1944-03-09', 1, 26, 160.90, 'Michał', 'Jaworski', NULL, 'Afro'),
  ('4-222-57631-X', 'Gdy przejdzie święt Antoni że przymarznie cap do kozy', DATE '1925-07-27', 1, 40, 60.90, 'Weronika', 'Górska', NULL, 'ASCT'),
  ('7-432-20662-7', 'Gdy przejdzie święt Antoni ale na całe życie', DATE '1992-11-28', 3, 34, 44.60, 'Karolina', 'Monarek', NULL, 'Pies Filemon'),
  ('1-521-90754-4', 'Gdy przejdzie święt Antoni póki jeszcze czas', DATE '1981-04-09', 1, 35, 62.60, 'Adam', 'Pupa', NULL, 'Afro'),
  ('4-489-09632-1', 'Gdy przejdzie święt Antoni byk się ocieli', DATE '1967-01-14', 3, 42, 120.50, 'Grzegorz', 'Słowacki', NULL, 'Januszex'),
  ('1-950-71552-3', 'Gdy przejdzie święt Antoni to drugiemu niewola', DATE '1998-11-21', 1, 60, 38.50, 'Hans', 'Jachowicz', NULL, 'Afro'),
  ('0-718-04975-6', 'Gdy przejdzie święt Antoni to go nie minie', DATE '1996-09-15', 4, 31, 128.10, 'Łukasz', 'Kowalski', NULL, 'Afro'),
  ('8-141-05835-5', 'Gdy przejdzie święt Antoni to zima przejada', DATE '1917-12-08', 1, 30, 45.80, 'Jacek', 'Wojciechowski', NULL, 'Januszex'),
  ('6-908-30271-7', 'Gdy przejdzie święt Antoni dom wesołym czyni', DATE '1928-06-28', 2, 51, 80.90, 'Kornel', 'Homoncik', NULL, 'Wesoła Szkoła'),
  ('5-322-51171-7', 'Gdy przejdzie święt Antoni wrócić ziarno na śniadanie', DATE '1743-10-19', 4, 69, 22.60, NULL, NULL, 'Encylopedia Informatyki', 'Kot Reksio'),
  ('9-919-32485-X', 'Gdy przejdzie święt Antoni jak się kto przepości', DATE '2003-11-30', 2, 33, 124.30, 'Jan', 'Dudek', NULL, 'Gambit Kaczmarkowski'),
  ('8-684-07336-3', 'Gdy przejdzie święt Antoni pada aż do Zuzanny', DATE '1918-08-11', 3, 40, 81.20, 'Tomasz', 'Lewandowski', NULL, 'Siedmiu Krasnoludków'),
  ('8-051-73757-1', 'Gdy przejdzie święt Antoni znać jabłuszko na jabłoni', DATE '1839-03-13', 1, 39, 165.40, 'Piotr', 'Klemens', NULL, 'GGWP'),
  ('0-916-71623-6', 'Gdy przejdzie święt Antoni jesień krótka, szybko mija', DATE '1921-09-22', 1, 56, 71.10, 'Rafał', 'Nowakowski', NULL, 'Loki'),
  ('1-134-05311-8', 'Gdy przejdzie święt Antoni to się diabeł cieszy', DATE '1919-05-02', 1, 69, 116.20, 'Katarzyna', 'Kazimierczak', NULL, 'Kruca Fix'),
  ('4-390-72307-3', 'Gdy przejdzie święt Antoni zwykle nastaje posucha', DATE '1942-03-25', 1, 54, 164.70, 'Dariusz', 'Woźniak', NULL, 'NGU'),
  ('2-424-06918-2', 'Gdy przejdzie święt Antoni piekła nie ma', DATE '1950-08-09', 4, 75, 182.80, 'Hans', 'Stępień', NULL, 'Atakałke'),
  ('8-253-20746-8', 'Gdy przejdzie święt Antoni piekło gore', DATE '1992-12-07', 1, 69, 102.10, 'Anna', 'Gołąbek', NULL, 'Babunia'),
  ('7-484-76821-9', 'Gdy przejdzie święt Antoni tym bardziej nosa zadziera', DATE '1940-01-28', 1, 11, 79.60, 'Rafał', 'Majewski', NULL, 'Gambit Kaczmarkowski'),
  ('7-981-25721-2', 'Gdy przejdzie święt Antoni tym wyżej głowę nosi', DATE '1976-10-24', 3, 46, 111.10, 'Bożydar', 'Dębska', NULL, 'Pentakill'),
  ('6-861-84267-2', 'Gdy przejdzie święt Antoni tym więcej chce', DATE '1993-12-15', 1, 42, 30.80, 'Karolina', 'Słowacka', NULL, 'Kot Reksio'),
  ('5-963-33104-8', 'Gdy przejdzie święt Antoni tym spokojniej śpisz', DATE '1916-11-16', 1, 73, 60.0, 'Filip', 'Filtz', NULL, 'GGWP'),
  ('6-801-78251-7', 'Gdy przejdzie święt Antoni tym bardziej gryzie', DATE '2004-04-18', 4, 11, 52.80, 'Jakub', 'Kazimierczak', NULL, 'Pentakill'),
  ('5-816-29452-0', 'Gdy przejdzie święt Antoni tak cię cenią', DATE '1987-03-25', 1, 25, 44.0, 'Elżbieta', 'Witkowska', NULL, 'Kruti'),
  ('9-029-79905-6', 'Gdy przejdzie święt Antoni kij się znajdzie', DATE '1932-06-19', 1, 12, 114.10, 'Weronika', 'Wiśniewska', NULL, 'GGWP'),
  ('6-994-61602-9', 'Gdy przejdzie święt Antoni to się diabeł cieszy', DATE '1809-04-25', 4, 22, 15.50, 'Rafał', 'Mazur', NULL, 'Loki'),
  ('6-321-10324-1', 'Gdy przejdzie święt Antoni tak się koniec grudnia nosi', DATE '1965-06-21', 1, 62, 83.30, 'Wiktor', 'Woźniak', NULL, 'Extra Ciemne'),
  ('1-854-33776-9', 'Gdy przejdzie święt Antoni to się lubi co się ma', DATE '1907-12-18', 1, 66, 60.30, 'Piotr', 'Słowacki', NULL, 'Kruti'),
  ('1-909-63937-0', 'Gdy przejdzie święt Antoni pora powiedzieć „b”', DATE '1994-11-10', 2, 72, 49.70, 'Dariusz', 'Sejko', NULL, 'Siedmiu Krasnoludków'),
  ('9-952-66287-4', 'Gdy przejdzie święt Antoni to z dobrego konia', DATE '1953-11-01', 1, 41, 133.10, 'Kornel', 'Sienkiewicz', NULL, 'WSSP'),
  ('0-427-53389-9', 'Gdy przejdzie święt Antoni to z dobrego konia', DATE '1114-06-22', 2, 54, 120.0, 'Grzegorz', 'Bobak', NULL, 'GGWP'),
  ('9-191-30877-1', 'Gdy przejdzie święt Antoni temu czas', DATE '1976-05-11', 1, 60, 95.20, 'Rafał', 'Głowacka', NULL, 'Kruti'),
  ('1-699-78062-5', 'Gdy przejdzie święt Antoni za przewodnika', DATE '1892-05-08', 1, 54, 32.40, 'Dariusz', 'Kaczmarek', NULL, 'Siedmiu Krasnoludków'),
  ('2-573-20939-3', 'Gdy przejdzie święt Antoni cygana powiesili', DATE '1999-10-27', 1, 44, 64.30, 'Joanna', 'Kamińska', NULL, 'Podziemie'),
  ('4-327-27290-6', 'Gdy przejdzie święt Antoni oka nie wykole', DATE '1943-10-06', 1, 35, 114.10, 'Filip', 'Dostojewski', NULL, 'Siedmiu Krasnoludków'),
  ('7-079-92231-3', 'Gdy przejdzie święt Antoni mało mleka daje', DATE '1982-06-06', 1, 8, 19.20, 'Kornel', 'Kondratek', NULL, 'Kot Reksio'),
  ('4-762-83572-2', 'Gdy przejdzie święt Antoni trochę zimy, trochę lata', DATE '1921-05-20', 1, 37, 145.0, 'Wiktor', 'Pawlak', NULL, 'NGU'),
  ('1-494-73136-3', 'Gdy przejdzie święt Antoni nie wart i kołacza', DATE '1934-10-08', 1, 19, 98.10, 'Kornel', 'Schneider', NULL, 'Kot Reksio'),
  ('1-947-88482-4', 'Gdy przejdzie święt Antoni ponieśli i wilka', DATE '2009-11-17', 4, 48, 47.10, 'Zuzanna', 'Homoncik', NULL, 'Januszex'),
  ('6-239-56116-9', 'Gdy przejdzie święt Antoni nikt nie wie', DATE '1927-07-20', 1, 78, 20.50, 'Filip', 'Kucharczyk', NULL, 'Podziemie'),
  ('7-079-53185-3', 'Gdy sierpień wrzos rozwija nie ma chatki', DATE '1987-03-15', 1, 34, 136.60, 'Jan', 'Klemens', NULL, 'Siedmiu Krasnoludków'),
  ('7-138-40030-6', 'Gdy sierpień wrzos rozwija że przymarznie cap do kozy', DATE '2014-10-09', 1, 55, 51.90, 'Rafał', 'Wiśniewski', NULL, 'Kruti'),
  ('4-643-04454-3', 'Gdy sierpień wrzos rozwija ale na całe życie', DATE '1973-09-14', 1, 57, 96.50, 'Weronika', 'Woźniak', NULL, 'WSSP'),
  ('0-057-60325-1', 'Gdy sierpień wrzos rozwija póki jeszcze czas', DATE '1934-03-18', 4, 56, 107.70, NULL, NULL, 'Koło Taniego Czyszczenia i Sprzątania', 'Afro'),
  ('0-669-62188-9', 'Gdy sierpień wrzos rozwija byk się ocieli', DATE '1986-09-14', 2, 55, 171.80, 'Karolina', 'Majewska', NULL, 'GGWP'),
  ('2-071-77058-7', 'Gdy sierpień wrzos rozwija to drugiemu niewola', DATE '1988-10-10', 1, 24, 25.50, 'Karolina', 'Nowicka', NULL, 'Loki'),
  ('1-192-93464-4', 'Gdy sierpień wrzos rozwija to go nie minie', DATE '1915-01-19', 1, 74, 25.70, NULL, NULL, 'Gazeta WMiI', 'Atakałke'),
  ('7-807-49850-1', 'Gdy sierpień wrzos rozwija to zima przejada', DATE '1970-06-28', 1, 35, 62.40, 'Jan', 'Kowalski', NULL, 'Afro'),
  ('4-568-03820-0', 'Gdy sierpień wrzos rozwija dom wesołym czyni', DATE '1959-09-18', 1, 25, 113.50, 'Szymon', 'Kazimierczak', NULL, 'NGU'),
  ('7-215-78236-0', 'Gdy sierpień wrzos rozwija wrócić ziarno na śniadanie', DATE '1954-08-11', 1, 57, 80.60, 'Katarzyna', 'Tyminśka', NULL, 'Kot Reksio'),
  ('0-583-56591-3', 'Gdy sierpień wrzos rozwija jak się kto przepości', DATE '1975-12-27', 1, 45, 143.20, 'Andrzej', 'Gradek', NULL, 'ASCT'),
  ('6-679-98683-4', 'Gdy sierpień wrzos rozwija pada aż do Zuzanny', DATE '1980-01-17', 1, 49, 32.10, 'Brygida', 'Helik', NULL, 'NGU'),
  ('7-125-60461-7', 'Gdy sierpień wrzos rozwija znać jabłuszko na jabłoni', DATE '1970-09-02', 2, 32, 70.30, 'Grzegorz', 'Mełech', NULL, 'Pentakill'),
  ('8-768-33971-2', 'Gdy sierpień wrzos rozwija jesień krótka, szybko mija', DATE '1933-04-27', 1, 33, 114.30, 'Aleksandra', 'Helik', NULL, 'Podziemie'),
  ('8-498-68538-9', 'Gdy sierpień wrzos rozwija to się diabeł cieszy', DATE '1686-09-29', 3, 43, 106.30, 'Alicja', 'Homoncik', NULL, 'Drux'),
  ('3-581-27717-4', 'Gdy sierpień wrzos rozwija zwykle nastaje posucha', DATE '1743-01-01', 2, 15, 48.80, 'Anna', 'Tyminśka', NULL, 'GGWP'),
  ('9-532-28901-1', 'Gdy sierpień wrzos rozwija piekła nie ma', DATE '1925-06-15', 1, 45, 140.80, 'Jarosław', 'Mazur', NULL, 'Atakałke'),
  ('2-250-46878-8', 'Gdy sierpień wrzos rozwija piekło gore', DATE '1831-12-20', 2, 41, 42.50, 'Kamila', 'Sienkiewicz', NULL, 'Pentakill'),
  ('9-479-91161-2', 'Gdy sierpień wrzos rozwija tym bardziej nosa zadziera', DATE '2009-12-30', 1, 34, 67.10, 'Adam', 'Kazimierczak', NULL, 'ASCT'),
  ('8-408-71260-8', 'Gdy sierpień wrzos rozwija tym wyżej głowę nosi', DATE '1955-08-30', 1, 50, 159.50, 'Mikołaj', 'Jaworski', NULL, 'Extra Ciemne'),
  ('9-360-34734-5', 'Gdy sierpień wrzos rozwija tym więcej chce', DATE '1959-03-10', 4, 61, 122.30, 'Michał', 'Tyminśka', NULL, 'Wesoła Szkoła'),
  ('3-080-89540-1', 'Gdy sierpień wrzos rozwija tym spokojniej śpisz', DATE '1964-10-08', 2, 45, 92.0, 'Joanna', 'Kamińska', NULL, 'Babunia'),
  ('3-172-52232-6', 'Gdy sierpień wrzos rozwija tym bardziej gryzie', DATE '1969-12-27', 1, 33, 93.10, 'Kamila', 'Nowak', NULL, 'Wesoła Szkoła'),
  ('5-674-30702-4', 'Gdy sierpień wrzos rozwija tak cię cenią', DATE '1952-12-15', 4, 50, 70.80, 'Zuzanna', 'Lewandowska', NULL, 'Kruca Fix'),
  ('6-821-69943-7', 'Gdy sierpień wrzos rozwija kij się znajdzie', DATE '1956-09-26', 4, 38, 138.10, 'Małgorzata', 'Górska', NULL, 'ASCT'),
  ('3-614-19240-7', 'Gdy sierpień wrzos rozwija to się diabeł cieszy', DATE '1073-05-17', 1, 47, 43.80, 'Kornel', 'Wiśniewski', NULL, 'Extra Ciemne'),
  ('3-968-90426-5', 'Gdy sierpień wrzos rozwija tak się koniec grudnia nosi', DATE '1951-11-23', 1, 36, 79.30, 'Mateusz', 'Witkowski', NULL, 'Kot Reksio'),
  ('1-457-20898-9', 'Gdy sierpień wrzos rozwija to się lubi co się ma', DATE '1925-06-25', 1, 38, 16.90, 'Dariusz', 'Nowakowski', NULL, 'Loki'),
  ('9-001-63530-X', 'Gdy sierpień wrzos rozwija pora powiedzieć „b”', DATE '1944-03-10', 1, 44, 39.20, 'Agnieszka', 'Tyminśka', NULL, 'Pies Filemon'),
  ('7-852-24447-5', 'Gdy sierpień wrzos rozwija to z dobrego konia', DATE '1945-01-17', 1, 45, 72.0, 'Łukasz', 'Tanenbaum', NULL, 'Atakałke'),
  ('2-071-86938-9', 'Gdy sierpień wrzos rozwija to z dobrego konia', DATE '1927-03-11', 1, 16, 95.80, 'Łukasz', 'Nowakowski', NULL, 'Drux'),
  ('4-655-67730-9', 'Gdy sierpień wrzos rozwija temu czas', DATE '1975-09-12', 4, 18, 25.10, 'Maciek', 'Dudek', NULL, 'Pies Filemon'),
  ('8-217-15390-6', 'Gdy sierpień wrzos rozwija za przewodnika', DATE '1930-08-24', 2, 21, 118.80, 'Jan', 'Gołąbek', NULL, 'ASCT'),
  ('9-927-52181-2', 'Gdy sierpień wrzos rozwija cygana powiesili', DATE '1913-07-25', 1, 28, 124.40, 'Zuzanna', 'Tanenbaum', NULL, 'Kot Reksio'),
  ('3-028-32779-1', 'Gdy sierpień wrzos rozwija oka nie wykole', DATE '1957-04-03', 1, 39, 165.90, 'Kamila', 'Wojciechowska', NULL, 'Siedmiu Krasnoludków'),
  ('0-005-16854-6', 'Gdy sierpień wrzos rozwija mało mleka daje', DATE '1973-02-02', 1, 54, 103.80, 'Grzegorz', 'Sienkiewicz', NULL, 'Extra Ciemne'),
  ('3-728-85000-4', 'Gdy sierpień wrzos rozwija trochę zimy, trochę lata', DATE '1986-07-10', 1, 61, 90.20, 'Hans', 'Homoncik', NULL, 'WSSP'),
  ('8-999-44683-2', 'Gdy sierpień wrzos rozwija nie wart i kołacza', DATE '1977-10-22', 1, 46, 66.40, 'Mateusz', 'Cebulski', NULL, 'Siedmiu Krasnoludków'),
  ('9-837-31622-5', 'Gdy sierpień wrzos rozwija ponieśli i wilka', DATE '1904-08-21', 4, 47, 93.80, 'Franciszek', 'Nowakowski', NULL, 'Gambit Kaczmarkowski'),
  ('8-942-26055-1', 'Gdy sierpień wrzos rozwija nikt nie wie', DATE '1991-04-10', 1, 49, 193.10, NULL, NULL, 'Współczesne rozwój', 'GGWP'),
  ('0-168-81897-3', 'Gdy się człowiek spieszy nie ma chatki', DATE '1979-04-04', 1, 34, 109.30, 'Felicyta', 'Majewska', NULL, 'Drux'),
  ('4-204-21711-7', 'Gdy się człowiek spieszy że przymarznie cap do kozy', DATE '1938-07-08', 1, 52, 138.30, 'Michał', 'Hoser', NULL, 'Gambit Kaczmarkowski'),
  ('0-363-51767-7', 'Gdy się człowiek spieszy ale na całe życie', DATE '1967-02-02', 1, 55, 40.90, 'Łukasz', 'Johansen', NULL, 'Atakałke'),
  ('9-405-22086-1', 'Gdy się człowiek spieszy póki jeszcze czas', DATE '1817-10-07', 1, 36, 52.30, 'Szymon', 'Dębska', NULL, 'Atakałke'),
  ('5-722-84789-5', 'Gdy się człowiek spieszy byk się ocieli', DATE '1927-04-20', 1, 62, 50.20, 'Kornel', 'Klemens', NULL, 'GGWP'),
  ('8-049-59684-2', 'Gdy się człowiek spieszy to drugiemu niewola', DATE '1958-12-09', 3, 50, 45.20, 'Iwona', 'Bobak', NULL, 'Kruca Fix'),
  ('4-245-44883-0', 'Gdy się człowiek spieszy to go nie minie', DATE '1959-10-05', 1, 52, 171.20, 'Sandra', 'Krysicka', NULL, 'Kruti'),
  ('1-291-03561-3', 'Gdy się człowiek spieszy to zima przejada', DATE '1930-12-17', 1, 22, 103.70, 'Agnieszka', 'Słowacka', NULL, 'Atakałke'),
  ('5-336-74065-9', 'Gdy się człowiek spieszy dom wesołym czyni', DATE '1920-07-30', 1, 57, 53.80, 'Maciek', 'Woźniak', NULL, 'Afro'),
  ('5-902-87713-X', 'Gdy się człowiek spieszy wrócić ziarno na śniadanie', DATE '1906-02-20', 4, 32, 17.10, 'Alicja', 'Głowacka', NULL, 'Drux'),
  ('4-941-31156-6', 'Gdy się człowiek spieszy jak się kto przepości', DATE '1982-08-28', 2, 17, 23.0, NULL, NULL, 'Gazeta WMiI', 'Kruti'),
  ('7-245-55151-0', 'Gdy się człowiek spieszy pada aż do Zuzanny', DATE '1942-07-16', 1, 76, 32.40, 'Hans', 'Mickiewicz', NULL, 'Siedmiu Krasnoludków'),
  ('8-806-09046-1', 'Gdy się człowiek spieszy znać jabłuszko na jabłoni', DATE '1913-06-22', 1, 76, 22.70, 'Felicyta', 'Dębska', NULL, 'ASCT'),
  ('7-567-36554-5', 'Gdy się człowiek spieszy jesień krótka, szybko mija', DATE '1929-11-22', 1, 48, 8.30, 'Małgorzata', 'Helik', NULL, 'Podziemie'),
  ('2-234-21900-0', 'Gdy się człowiek spieszy to się diabeł cieszy', DATE '1966-10-08', 3, 25, 145.70, 'Elżbieta', 'Głowacka', NULL, 'Podziemie'),
  ('5-167-40985-3', 'Gdy się człowiek spieszy zwykle nastaje posucha', DATE '1931-01-29', 1, 30, 56.0, 'Dariusz', 'Gradek', NULL, 'WSSP'),
  ('2-979-92379-6', 'Gdy się człowiek spieszy piekła nie ma', DATE '1869-10-10', 2, 57, 52.40, 'Janusz', 'Stępień', NULL, 'Januszex'),
  ('1-228-87758-0', 'Gdy się człowiek spieszy piekło gore', DATE '1934-10-26', 1, 29, 85.70, 'Adam', 'Mełech', NULL, 'Pies Filemon'),
  ('0-779-98446-3', 'Gdy się człowiek spieszy tym bardziej nosa zadziera', DATE '1921-11-09', 1, 26, 52.60, 'Rafał', 'Słowacki', NULL, 'Januszex'),
  ('5-626-04383-7', 'Gdy się człowiek spieszy tym wyżej głowę nosi', DATE '2002-02-26', 1, 55, 88.70, 'Weronika', 'Neumann', NULL, 'Babunia'),
  ('1-550-22668-1', 'Gdy się człowiek spieszy tym więcej chce', DATE '1936-06-10', 1, 36, 66.50, 'Janusz', 'Wojciechowski', NULL, 'Podziemie'),
  ('9-650-16567-3', 'Gdy się człowiek spieszy tym spokojniej śpisz', DATE '1926-10-01', 1, 49, 121.40, 'Alicja', 'Piotrowska', NULL, 'WSSP'),
  ('3-306-81453-9', 'Gdy się człowiek spieszy tym bardziej gryzie', DATE '1936-11-24', 1, 55, 139.30, 'Elżbieta', 'Cebulska', NULL, 'Loki'),
  ('1-096-52970-X', 'Gdy się człowiek spieszy tak cię cenią', DATE '2003-07-16', 1, 22, 75.50, 'Elżbieta', 'Witkowska', NULL, 'Januszex'),
  ('1-644-07796-5', 'Gdy się człowiek spieszy kij się znajdzie', DATE '1979-12-27', 1, 45, 50.90, 'Jarosław', 'Kucharczyk', NULL, 'Kruca Fix'),
  ('0-408-82648-7', 'Gdy się człowiek spieszy to się diabeł cieszy', DATE '1936-06-06', 1, 24, 30.50, 'Jacek', 'Słowacki', NULL, 'Januszex'),
  ('1-552-37745-8', 'Gdy się człowiek spieszy tak się koniec grudnia nosi', DATE '1904-05-11', 1, 36, 33.70, NULL, NULL, 'TCS WPROST', 'Gambit Kaczmarkowski'),
  ('7-525-58834-1', 'Gdy się człowiek spieszy to się lubi co się ma', DATE '1920-06-21', 1, 75, 149.30, 'Jan', 'Mickiewicz', NULL, 'Pentakill'),
  ('4-070-24761-0', 'Gdy się człowiek spieszy pora powiedzieć „b”', DATE '2009-03-13', 1, 79, 20.50, 'Bożydar', 'Mazur', NULL, 'Extra Ciemne'),
  ('8-916-05897-X', 'Gdy się człowiek spieszy to z dobrego konia', DATE '1991-05-11', 1, 51, 56.90, 'Katarzyna', 'Dostojewska', NULL, 'ASCT'),
  ('6-854-25531-7', 'Gdy się człowiek spieszy to z dobrego konia', DATE '1973-07-17', 1, 32, 67.60, 'Łukasz', 'Kamiński', NULL, 'WSSP'),
  ('4-444-82458-1', 'Gdy się człowiek spieszy temu czas', DATE '1993-02-16', 1, 51, 64.10, 'Michał', 'Pawlak', NULL, 'NGU'),
  ('0-270-72438-9', 'Gdy się człowiek spieszy za przewodnika', DATE '1999-07-11', 1, 40, 23.20, 'Paulina', 'Kucharczyk', NULL, 'ASCT'),
  ('9-785-60740-2', 'Gdy się człowiek spieszy cygana powiesili', DATE '1980-01-11', 1, 48, 153.20, 'Szymon', 'Monarek', NULL, 'Babunia'),
  ('7-541-03808-3', 'Gdy się człowiek spieszy oka nie wykole', DATE '1977-05-27', 4, 40, 89.30, 'Joanna', 'Gołąbek', NULL, 'NGU'),
  ('1-651-23864-2', 'Gdy się człowiek spieszy mało mleka daje', DATE '1968-01-20', 1, 61, 23.90, 'Wiktor', 'Kaczmarek', NULL, 'WSSP'),
  ('3-594-12164-X', 'Gdy się człowiek spieszy trochę zimy, trochę lata', DATE '2013-07-02', 1, 51, 58.50, 'Maciek', 'Nowicki', NULL, 'Pentakill'),
  ('5-984-73998-4', 'Gdy się człowiek spieszy nie wart i kołacza', DATE '1997-08-29', 1, 54, 58.70, 'Felicyta', 'Nowak', NULL, 'Januszex'),
  ('1-119-39033-8', 'Gdy się człowiek spieszy ponieśli i wilka', DATE '1916-04-10', 1, 48, 165.90, 'Anna', 'Sienkiewicz', NULL, 'Podziemie'),
  ('3-814-82692-2', 'Gdy się człowiek spieszy nikt nie wie', DATE '1990-09-15', 1, 43, 136.40, 'Grzegorz', 'Sienkiewicz', NULL, 'Drux'),
  ('4-197-92708-8', 'Gdy w sierpniu z północy dmucha nie ma chatki', DATE '1904-09-08', 1, 38, 55.70, 'Wiktor', 'Jaworski', NULL, 'Kruca Fix'),
  ('5-299-25214-5', 'Gdy w sierpniu z północy dmucha że przymarznie cap do kozy', DATE '1989-05-03', 1, 75, 99.70, 'Andrzej', 'Bobak', NULL, 'Drux'),
  ('6-267-11923-8', 'Gdy w sierpniu z północy dmucha ale na całe życie', DATE '1939-02-13', 1, 27, 101.10, 'Katarzyna', 'Gołąbek', NULL, 'Extra Ciemne'),
  ('8-137-61940-2', 'Gdy w sierpniu z północy dmucha póki jeszcze czas', DATE '1923-02-25', 1, 27, 78.70, 'Jacek', 'Jachowicz', NULL, 'NGU'),
  ('6-976-87737-1', 'Gdy w sierpniu z północy dmucha byk się ocieli', DATE '2008-05-18', 1, 46, 143.90, 'Wiktor', 'Piotrowski', NULL, 'Januszex'),
  ('6-744-70368-4', 'Gdy w sierpniu z północy dmucha to drugiemu niewola', DATE '2010-08-13', 2, 24, 153.60, 'Kamila', 'Jachowicz', NULL, 'WSSP'),
  ('3-611-79113-X', 'Gdy w sierpniu z północy dmucha to go nie minie', DATE '1917-09-08', 4, 28, 44.0, 'Paulina', 'Dudek', NULL, 'Gambit Kaczmarkowski'),
  ('8-011-74988-9', 'Gdy w sierpniu z północy dmucha to zima przejada', DATE '1913-12-20', 1, 18, 112.70, 'Dariusz', 'Helik', NULL, 'Pentakill'),
  ('5-897-59762-6', 'Gdy w sierpniu z północy dmucha dom wesołym czyni', DATE '1928-01-05', 1, 54, 21.90, 'Jacek', 'Dudek', NULL, 'Babunia'),
  ('5-429-77784-6', 'Gdy w sierpniu z północy dmucha wrócić ziarno na śniadanie', DATE '2006-02-21', 1, 57, 28.30, 'Mateusz', 'Dudek', NULL, 'Afro'),
  ('3-195-07938-0', 'Gdy w sierpniu z północy dmucha jak się kto przepości', DATE '1910-08-18', 1, 20, 118.20, 'Bartłomiej', 'Słowacki', NULL, 'Podziemie'),
  ('8-782-53368-7', 'Gdy w sierpniu z północy dmucha pada aż do Zuzanny', DATE '1989-12-08', 4, 49, 97.10, 'Maciek', 'Dudek', NULL, 'Siedmiu Krasnoludków'),
  ('3-881-76970-6', 'Gdy w sierpniu z północy dmucha znać jabłuszko na jabłoni', DATE '1984-09-14', 1, 40, 43.60, 'Alicja', 'Dura', NULL, 'Drux'),
  ('9-884-17446-6', 'Gdy w sierpniu z północy dmucha jesień krótka, szybko mija', DATE '1935-06-13', 1, 61, 34.80, 'Kornel', 'Dąbrowkski', NULL, 'Pentakill'),
  ('3-873-78162-X', 'Gdy w sierpniu z północy dmucha to się diabeł cieszy', DATE '1915-11-20', 1, 24, 69.70, 'Michał', 'Malinowski', NULL, 'Drux'),
  ('8-188-73876-X', 'Gdy w sierpniu z północy dmucha zwykle nastaje posucha', DATE '1921-03-01', 1, 54, 63.70, 'Jakub', 'Bobak', NULL, 'GGWP'),
  ('2-948-83981-5', 'Gdy w sierpniu z północy dmucha piekła nie ma', DATE '1925-08-20', 2, 30, 66.0, 'Weronika', 'Mełech', NULL, 'Extra Ciemne'),
  ('5-096-83521-9', 'Gdy w sierpniu z północy dmucha piekło gore', DATE '1931-09-09', 1, 35, 54.50, 'Paweł', 'Kamiński', NULL, 'Afro'),
  ('1-402-20408-6', 'Gdy w sierpniu z północy dmucha tym bardziej nosa zadziera', DATE '1902-02-06', 1, 73, 52.30, 'Paweł', 'Pawlak', NULL, 'Extra Ciemne'),
  ('0-261-97790-3', 'Gdy w sierpniu z północy dmucha tym wyżej głowę nosi', DATE '1964-11-13', 1, 41, 46.0, 'Jarosław', 'Monarek', NULL, 'Siedmiu Krasnoludków'),
  ('2-924-44617-1', 'Gdy w sierpniu z północy dmucha tym więcej chce', DATE '1990-02-28', 1, 36, 53.0, 'Kamila', 'Witkowska', NULL, 'Gambit Kaczmarkowski'),
  ('6-612-06440-4', 'Gdy w sierpniu z północy dmucha tym spokojniej śpisz', DATE '1952-11-12', 1, 72, 117.10, 'Mikołaj', 'Nowak', NULL, 'Kruti'),
  ('1-986-07549-4', 'Gdy w sierpniu z północy dmucha tym bardziej gryzie', DATE '1992-10-21', 1, 53, 137.90, 'Iwona', 'Kamińska', NULL, 'Afro'),
  ('5-208-61779-X', 'Gdy w sierpniu z północy dmucha tak cię cenią', DATE '1940-05-13', 1, 50, 27.90, 'Maciek', 'Bobak', NULL, 'Loki'),
  ('0-028-37037-6', 'Gdy w sierpniu z północy dmucha kij się znajdzie', DATE '1920-03-04', 2, 73, 84.70, 'Paweł', 'Cebulski', NULL, 'GGWP'),
  ('1-358-37157-1', 'Gdy w sierpniu z północy dmucha to się diabeł cieszy', DATE '1033-12-01', 4, 53, 70.40, 'Alicja', 'Gołąbek', NULL, 'Pies Filemon'),
  ('0-085-09079-4', 'Gdy w sierpniu z północy dmucha tak się koniec grudnia nosi', DATE '1971-11-10', 1, 56, 134.60, 'Bartłomiej', 'Dostojewski', NULL, 'Siedmiu Krasnoludków'),
  ('9-327-64941-9', 'Gdy w sierpniu z północy dmucha to się lubi co się ma', DATE '1983-07-10', 1, 69, 62.20, 'Agnieszka', 'Górska', NULL, 'Kruti'),
  ('2-456-24174-6', 'Gdy w sierpniu z północy dmucha pora powiedzieć „b”', DATE '1995-08-27', 1, 35, 104.50, 'Zuzanna', 'Monarek', NULL, 'Kruca Fix'),
  ('1-679-21570-1', 'Gdy w sierpniu z północy dmucha to z dobrego konia', DATE '1957-12-08', 1, 24, 53.60, 'Filip', 'Słowacki', NULL, 'ASCT'),
  ('7-484-69251-4', 'Gdy w sierpniu z północy dmucha to z dobrego konia', DATE '1946-09-02', 1, 70, 108.10, 'Henryk', 'Dostojewski', NULL, 'Kot Reksio'),
  ('8-727-70356-8', 'Gdy w sierpniu z północy dmucha temu czas', DATE '2005-05-30', 1, 62, 136.30, 'Kamila', 'Kazimierczak', NULL, 'Pentakill'),
  ('4-689-48685-9', 'Gdy w sierpniu z północy dmucha za przewodnika', DATE '1904-10-04', 1, 28, 54.60, 'Weronika', 'Piotrowska', NULL, 'Kot Reksio'),
  ('9-026-07206-6', 'Gdy w sierpniu z północy dmucha cygana powiesili', DATE '1882-10-30', 1, 44, 38.70, 'Hans', 'Krysicki', NULL, 'WSSP'),
  ('8-649-13941-8', 'Gdy w sierpniu z północy dmucha oka nie wykole', DATE '1963-04-13', 1, 48, 127.50, 'Rafał', 'Nowicki', NULL, 'GGWP'),
  ('3-018-89649-1', 'Gdy w sierpniu z północy dmucha mało mleka daje', DATE '1943-07-15', 3, 32, 77.20, 'Sandra', 'Krysicka', NULL, 'Babunia'),
  ('1-484-41481-0', 'Gdy w sierpniu z północy dmucha trochę zimy, trochę lata', DATE '1913-08-08', 2, 52, 155.10, NULL, NULL, 'Koło Taniego Czyszczenia i Sprzątania', 'NGU'),
  ('8-885-60608-3', 'Gdy w sierpniu z północy dmucha nie wart i kołacza', DATE '1768-06-28', 1, 51, 120.30, 'Janusz', 'Tanenbaum', NULL, 'Januszex'),
  ('3-400-70868-2', 'Gdy w sierpniu z północy dmucha ponieśli i wilka', DATE '1972-11-07', 1, 59, 38.30, 'Kornel', 'Johansen', NULL, 'Pentakill'),
  ('0-487-51351-7', 'Gdy w sierpniu z północy dmucha nikt nie wie', DATE '1962-10-05', 1, 30, 24.20, 'Bożydar', 'Sejko', NULL, 'Januszex'),
  ('8-388-80269-0', 'Hulaj dusza nie ma chatki', DATE '1967-07-16', 1, 45, 97.80, 'Wiktor', 'Goldberg', NULL, 'ASCT'),
  ('0-760-95595-6', 'Hulaj dusza że przymarznie cap do kozy', DATE '1994-07-03', 1, 22, 12.50, 'Aleksandra', 'Helik', NULL, 'Pentakill'),
  ('8-074-77347-7', 'Hulaj dusza ale na całe życie', DATE '1979-12-02', 1, 77, 30.60, 'Katarzyna', 'Dostojewska', NULL, 'Afro'),
  ('2-118-40116-7', 'Hulaj dusza póki jeszcze czas', DATE '1988-07-15', 4, 36, 31.50, 'Maciek', 'Jaworski', NULL, 'Drux'),
  ('0-567-40059-X', 'Hulaj dusza byk się ocieli', DATE '1931-11-08', 1, 63, 95.10, 'Sandra', 'Jachowicz', NULL, 'Kruca Fix'),
  ('3-206-42331-7', 'Hulaj dusza to drugiemu niewola', DATE '1963-11-23', 1, 69, 95.90, 'Michał', 'Tanenbaum', NULL, 'Kruti'),
  ('8-537-68184-9', 'Hulaj dusza to go nie minie', DATE '2011-04-11', 1, 47, 101.70, 'Jakub', 'Mazur', NULL, 'Gambit Kaczmarkowski'),
  ('0-875-07154-6', 'Hulaj dusza to zima przejada', DATE '2013-12-28', 1, 60, 119.20, 'Agnieszka', 'Górska', NULL, 'Pentakill'),
  ('4-744-06492-2', 'Hulaj dusza dom wesołym czyni', DATE '1920-12-04', 1, 16, 123.10, 'Jacek', 'Dostojewski', NULL, 'Drux'),
  ('4-735-37274-1', 'Hulaj dusza wrócić ziarno na śniadanie', DATE '1963-01-19', 1, 76, 52.40, 'Katarzyna', 'Klemens', NULL, 'Kruca Fix'),
  ('1-458-49594-9', 'Hulaj dusza jak się kto przepości', DATE '1906-06-30', 1, 62, 82.80, 'Filip', 'Głowacka', NULL, 'Gambit Kaczmarkowski'),
  ('0-328-75523-0', 'Hulaj dusza pada aż do Zuzanny', DATE '1910-04-09', 1, 75, 97.90, 'Jan', 'Stępień', NULL, 'ASCT'),
  ('5-365-59079-1', 'Hulaj dusza znać jabłuszko na jabłoni', DATE '1955-11-11', 1, 47, 185.10, 'Filip', 'Kaczmarek', NULL, 'Gambit Kaczmarkowski'),
  ('5-109-26403-1', 'Hulaj dusza jesień krótka, szybko mija', DATE '1969-04-20', 1, 47, 98.90, 'Piotr', 'Kondratek', NULL, 'Drux'),
  ('4-957-12944-4', 'Hulaj dusza to się diabeł cieszy', DATE '1928-09-14', 3, 37, 98.40, 'Henryk', 'Dudek', NULL, 'Siedmiu Krasnoludków'),
  ('2-129-56935-8', 'Hulaj dusza zwykle nastaje posucha', DATE '1957-11-07', 1, 47, 16.80, 'Katarzyna', 'Słowacka', NULL, 'Loki'),
  ('1-822-66588-4', 'Hulaj dusza piekła nie ma', DATE '1918-02-06', 1, 22, 35.80, 'Piotr', 'Hoser', NULL, 'Babunia'),
  ('0-910-24076-0', 'Hulaj dusza piekło gore', DATE '1985-08-15', 1, 64, 57.40, 'Mikołaj', 'Mickiewicz', NULL, 'Kot Reksio'),
  ('5-164-26458-7', 'Hulaj dusza tym bardziej nosa zadziera', DATE '1858-01-29', 2, 57, 139.70, 'Łukasz', 'Kazimierczak', NULL, 'Podziemie'),
  ('1-141-32208-0', 'Hulaj dusza tym wyżej głowę nosi', DATE '1910-05-04', 1, 44, 60.80, 'Jarosław', 'Majewski', NULL, 'Kruti'),
  ('5-052-26389-9', 'Hulaj dusza tym więcej chce', DATE '1944-08-15', 3, 68, 39.80, 'Joanna', 'Tyminśka', NULL, 'GGWP'),
  ('7-440-29373-8', 'Hulaj dusza tym spokojniej śpisz', DATE '1927-09-16', 1, 60, 69.60, 'Tomasz', 'Bobak', NULL, 'Gambit Kaczmarkowski'),
  ('8-846-63213-3', 'Hulaj dusza tym bardziej gryzie', DATE '1988-03-08', 3, 75, 156.50, 'Jarosław', 'Sienkiewicz', NULL, 'WSSP'),
  ('6-303-48106-X', 'Hulaj dusza tak cię cenią', DATE '1905-05-20', 1, 57, 48.0, 'Bożydar', 'Wojciechowski', NULL, 'Kruca Fix'),
  ('0-887-85080-4', 'Hulaj dusza kij się znajdzie', DATE '1944-09-07', 1, 28, 92.20, 'Sandra', 'Kamińska', NULL, 'Loki'),
  ('8-229-95072-5', 'Hulaj dusza to się diabeł cieszy', DATE '1954-03-27', 1, 51, 99.50, 'Małgorzata', 'Piotrowska', NULL, 'WSSP'),
  ('9-648-62214-0', 'Hulaj dusza tak się koniec grudnia nosi', DATE '1902-05-04', 3, 21, 55.0, 'Jakub', 'Tyminśka', NULL, 'Siedmiu Krasnoludków'),
  ('0-013-30170-5', 'Hulaj dusza to się lubi co się ma', DATE '1930-12-11', 3, 53, 28.20, 'Iwona', 'Kowalska', NULL, 'WSSP'),
  ('9-143-26451-4', 'Hulaj dusza pora powiedzieć „b”', DATE '1982-10-16', 1, 68, 141.0, 'Łukasz', 'Schneider', NULL, 'NGU'),
  ('1-644-23588-9', 'Hulaj dusza to z dobrego konia', DATE '1977-09-25', 1, 43, 88.80, 'Katarzyna', 'Tanenbaum', NULL, 'GGWP'),
  ('1-410-82846-8', 'Hulaj dusza to z dobrego konia', DATE '1999-08-04', 1, 64, 146.40, 'Kamila', 'Stępień', NULL, 'Pies Filemon'),
  ('5-957-37367-2', 'Hulaj dusza temu czas', DATE '1927-06-19', 1, 30, 125.40, NULL, NULL, 'Uniwersytet Koloni Krężnej', 'Wesoła Szkoła'),
  ('2-086-91306-0', 'Hulaj dusza za przewodnika', DATE '1971-06-07', 4, 24, 102.0, 'Sandra', 'Sienkiewicz', NULL, 'Loki'),
  ('1-932-25424-2', 'Hulaj dusza cygana powiesili', DATE '1953-12-22', 1, 32, 67.80, 'Henryk', 'Gradek', NULL, 'Podziemie'),
  ('3-276-50692-0', 'Hulaj dusza oka nie wykole', DATE '1970-04-03', 1, 32, 43.80, 'Sandra', 'Słowacka', NULL, 'Extra Ciemne'),
  ('0-117-47933-0', 'Hulaj dusza mało mleka daje', DATE '1927-10-14', 4, 48, 75.90, 'Bożydar', 'Malinowski', NULL, 'Loki'),
  ('3-179-67096-7', 'Hulaj dusza trochę zimy, trochę lata', DATE '1964-02-18', 1, 66, 27.70, 'Bartłomiej', 'Zieliński', NULL, 'Wesoła Szkoła'),
  ('9-994-02573-2', 'Hulaj dusza nie wart i kołacza', DATE '1998-07-04', 1, 66, 122.60, 'Elżbieta', 'Dębska', NULL, 'Babunia'),
  ('1-528-83977-3', 'Hulaj dusza ponieśli i wilka', DATE '1999-06-10', 1, 33, 24.30, 'Jacek', 'Sejko', NULL, 'Pies Filemon'),
  ('1-881-81820-9', 'Hulaj dusza nikt nie wie', DATE '1907-08-30', 4, 79, 132.60, 'Jan', 'Gołąbek', NULL, 'Pies Filemon'),
  ('6-815-62566-4', 'Hulaj duszo nie ma chatki', DATE '1978-05-01', 1, 72, 71.70, 'Joanna', 'Helik', NULL, 'Januszex'),
  ('8-109-66973-5', 'Hulaj duszo że przymarznie cap do kozy', DATE '1967-05-03', 1, 66, 63.10, 'Dariusz', 'Kazimierczak', NULL, 'ASCT'),
  ('1-065-77878-3', 'Hulaj duszo ale na całe życie', DATE '1984-06-24', 1, 79, 128.70, 'Mikołaj', 'Wojciechowski', NULL, 'Wesoła Szkoła'),
  ('5-733-04581-7', 'Hulaj duszo póki jeszcze czas', DATE '1931-11-01', 1, 63, 18.0, 'Janusz', 'Bobak', NULL, 'Afro'),
  ('0-375-35278-3', 'Hulaj duszo byk się ocieli', DATE '1915-07-04', 1, 37, 100.30, 'Weronika', 'Majewska', NULL, 'Drux'),
  ('3-926-24119-5', 'Hulaj duszo to drugiemu niewola', DATE '1978-03-02', 1, 45, 96.30, 'Paulina', 'Dąbrowkska', NULL, 'Siedmiu Krasnoludków'),
  ('2-267-90638-4', 'Hulaj duszo to go nie minie', DATE '1907-01-27', 2, 24, 109.30, 'Jarosław', 'Dura', NULL, 'Kruca Fix'),
  ('8-423-07694-6', 'Hulaj duszo to zima przejada', DATE '1935-12-30', 1, 70, 39.40, 'Karolina', 'Gołąbek', NULL, 'Loki'),
  ('0-998-27263-9', 'Hulaj duszo dom wesołym czyni', DATE '1949-08-13', 4, 54, 69.40, 'Jakub', 'Kaczmarek', NULL, 'NGU'),
  ('2-737-93783-3', 'Hulaj duszo wrócić ziarno na śniadanie', DATE '1968-02-16', 1, 25, 143.80, 'Rafał', 'Dębska', NULL, 'GGWP'),
  ('3-295-04361-2', 'Hulaj duszo jak się kto przepości', DATE '1937-05-19', 1, 45, 42.40, 'Łukasz', 'Kazimierczak', NULL, 'Siedmiu Krasnoludków'),
  ('1-823-77683-3', 'Hulaj duszo pada aż do Zuzanny', DATE '2010-01-04', 1, 45, 35.0, 'Aleksandra', 'Kostrikin', NULL, 'Babunia'),
  ('2-026-65688-6', 'Hulaj duszo znać jabłuszko na jabłoni', DATE '1927-05-18', 1, 57, 20.10, 'Katarzyna', 'Dura', NULL, 'Pentakill'),
  ('0-810-54072-X', 'Hulaj duszo jesień krótka, szybko mija', DATE '2006-02-13', 1, 58, 70.0, 'Bartłomiej', 'Cebulski', NULL, 'Wesoła Szkoła'),
  ('2-419-31941-9', 'Hulaj duszo to się diabeł cieszy', DATE '2000-04-24', 3, 26, 132.40, 'Filip', 'Jaworski', NULL, 'Wesoła Szkoła'),
  ('9-837-56397-4', 'Hulaj duszo zwykle nastaje posucha', DATE '1996-04-13', 1, 35, 23.30, 'Piotr', 'Goldberg', NULL, 'ASCT'),
  ('3-968-76713-6', 'Hulaj duszo piekła nie ma', DATE '1989-07-14', 1, 45, 98.0, NULL, NULL, 'Dreamteam', 'Kruti'),
  ('2-513-64851-X', 'Hulaj duszo piekło gore', DATE '2003-04-25', 1, 31, 123.70, 'Sandra', 'Bobak', NULL, 'Loki'),
  ('6-187-82317-6', 'Hulaj duszo tym bardziej nosa zadziera', DATE '1979-03-23', 4, 41, 135.90, NULL, NULL, 'TCS WPROST', 'Januszex'),
  ('7-132-37057-X', 'Hulaj duszo tym wyżej głowę nosi', DATE '1919-08-16', 1, 34, 51.0, NULL, NULL, 'FAKTCS', 'GGWP'),
  ('9-292-65098-X', 'Hulaj duszo tym więcej chce', DATE '1935-04-07', 3, 36, 70.30, 'Weronika', 'Johansen', NULL, 'Atakałke'),
  ('4-307-61155-1', 'Hulaj duszo tym spokojniej śpisz', DATE '1993-10-29', 1, 56, 109.50, 'Wiktor', 'Pupa', NULL, 'Atakałke'),
  ('4-428-58377-X', 'Hulaj duszo tym bardziej gryzie', DATE '1950-08-13', 1, 30, 63.40, 'Mikołaj', 'Witkowski', NULL, 'Pentakill'),
  ('0-546-58108-0', 'Hulaj duszo tak cię cenią', DATE '1918-02-02', 1, 38, 76.90, 'Sandra', 'Krysicka', NULL, 'Drux'),
  ('7-821-92831-3', 'Hulaj duszo kij się znajdzie', DATE '2009-01-21', 4, 56, 64.60, 'Jacek', 'Słowacki', NULL, 'ASCT'),
  ('8-970-44067-4', 'Hulaj duszo to się diabeł cieszy', DATE '1914-08-28', 1, 50, 9.70, 'Jan', 'Totenbach', NULL, 'Drux'),
  ('9-270-75147-3', 'Hulaj duszo tak się koniec grudnia nosi', DATE '1983-04-24', 3, 41, 28.90, 'Iwona', 'Kaczmarek', NULL, 'Kruti'),
  ('0-189-78340-0', 'Hulaj duszo to się lubi co się ma', DATE '1907-06-18', 2, 72, 95.50, 'Jarosław', 'Piotrowski', NULL, 'Gambit Kaczmarkowski'),
  ('1-363-38619-0', 'Hulaj duszo pora powiedzieć „b”', DATE '2005-07-21', 1, 78, 90.40, 'Elżbieta', 'Malinowska', NULL, 'Pentakill'),
  ('4-710-44527-3', 'Hulaj duszo to z dobrego konia', DATE '1982-03-26', 1, 9, 79.10, 'Kamila', 'Goldberg', NULL, 'ASCT'),
  ('1-868-13725-2', 'Hulaj duszo to z dobrego konia', DATE '1964-07-16', 1, 29, 24.30, 'Rafał', 'Tyminśka', NULL, 'Loki'),
  ('6-454-08299-7', 'Hulaj duszo temu czas', DATE '1950-03-29', 1, 55, 100.90, 'Sandra', 'Wiśniewska', NULL, 'Podziemie'),
  ('9-340-02676-4', 'Hulaj duszo za przewodnika', DATE '1918-01-30', 2, 29, 59.50, 'Brygida', 'Kazimierczak', NULL, 'Wesoła Szkoła'),
  ('0-937-04364-8', 'Hulaj duszo cygana powiesili', DATE '1944-07-13', 4, 68, 78.30, 'Bożydar', 'Schneider', NULL, 'ASCT'),
  ('6-110-33970-9', 'Hulaj duszo oka nie wykole', DATE '1999-06-16', 2, 30, 51.30, 'Kamila', 'Kaczmarek', NULL, 'Pentakill'),
  ('4-942-40453-3', 'Hulaj duszo mało mleka daje', DATE '2008-04-09', 1, 56, 53.70, 'Alicja', 'Homoncik', NULL, 'Gambit Kaczmarkowski'),
  ('2-226-81205-9', 'Hulaj duszo trochę zimy, trochę lata', DATE '1900-11-09', 1, 51, 40.40, 'Jakub', 'Woźniak', NULL, 'NGU'),
  ('7-050-19455-7', 'Hulaj duszo nie wart i kołacza', DATE '1947-09-11', 1, 42, 123.50, 'Łukasz', 'Grabowski', NULL, 'NGU'),
  ('6-355-05008-6', 'Hulaj duszo ponieśli i wilka', DATE '1988-04-17', 1, 59, 70.30, 'Hans', 'Stępień', NULL, 'Drux'),
  ('4-187-76022-9', 'Hulaj duszo nikt nie wie', DATE '2013-03-28', 1, 33, 82.70, 'Alicja', 'Nowak', NULL, 'Kruca Fix'),
  ('0-190-95393-4', 'Im bucik starszy nie ma chatki', DATE '1929-02-21', 1, 64, 105.20, 'Michał', 'Mełech', NULL, 'Atakałke'),
  ('6-463-08418-2', 'Im bucik starszy że przymarznie cap do kozy', DATE '1911-06-25', 1, 56, 22.50, 'Michał', 'Filtz', NULL, 'ASCT'),
  ('3-501-49522-6', 'Im bucik starszy ale na całe życie', DATE '1966-01-14', 1, 41, 23.60, 'Filip', 'Dostojewski', NULL, 'Babunia'),
  ('4-597-22544-7', 'Im bucik starszy póki jeszcze czas', DATE '1987-10-27', 1, 12, 104.20, 'Karolina', 'Kondratek', NULL, 'Kruca Fix'),
  ('1-196-66353-X', 'Im bucik starszy byk się ocieli', DATE '1933-03-09', 1, 25, 63.40, 'Jacek', 'Wojciechowski', NULL, 'Kot Reksio'),
  ('4-049-45144-1', 'Im bucik starszy to drugiemu niewola', DATE '1710-12-18', 2, 27, 73.80, 'Dariusz', 'Johansen', NULL, 'Drux'),
  ('0-689-62102-7', 'Im bucik starszy to go nie minie', DATE '1977-10-30', 3, 39, 63.80, 'Agnieszka', 'Helik', NULL, 'Wesoła Szkoła'),
  ('8-332-45826-9', 'Im bucik starszy to zima przejada', DATE '2000-08-16', 1, 23, 127.90, 'Filip', 'Dostojewski', NULL, 'NGU'),
  ('8-796-78902-6', 'Im bucik starszy dom wesołym czyni', DATE '1905-08-23', 1, 73, 41.80, 'Zuzanna', 'Helik', NULL, 'Siedmiu Krasnoludków'),
  ('4-162-06212-9', 'Im bucik starszy wrócić ziarno na śniadanie', DATE '1923-07-12', 4, 45, 45.60, 'Filip', 'Nowakowski', NULL, 'Januszex'),
  ('9-129-46200-2', 'Im bucik starszy jak się kto przepości', DATE '1914-07-24', 1, 11, 161.40, 'Adam', 'Mełech', NULL, 'Kruca Fix'),
  ('7-728-53974-4', 'Im bucik starszy pada aż do Zuzanny', DATE '1909-05-07', 1, 77, 180.40, 'Jacek', 'Homoncik', NULL, 'Pentakill'),
  ('6-008-07528-5', 'Im bucik starszy znać jabłuszko na jabłoni', DATE '1908-06-01', 1, 65, 21.90, 'Bożydar', 'Malinowski', NULL, 'Extra Ciemne'),
  ('3-782-44265-2', 'Im bucik starszy jesień krótka, szybko mija', DATE '2002-11-08', 1, 56, 44.80, 'Kornel', 'Wojciechowski', NULL, 'GGWP'),
  ('4-731-46040-9', 'Im bucik starszy to się diabeł cieszy', DATE '1827-11-23', 1, 34, 159.60, 'Kornel', 'Piotrowski', NULL, 'Atakałke'),
  ('7-107-56607-5', 'Im bucik starszy zwykle nastaje posucha', DATE '1980-04-08', 1, 40, 87.60, 'Tomasz', 'Bobak', NULL, 'Drux'),
  ('9-487-25944-9', 'Im bucik starszy piekła nie ma', DATE '1995-09-29', 4, 35, 76.50, 'Karolina', 'Mazur', NULL, 'Drux'),
  ('8-871-98795-0', 'Im bucik starszy piekło gore', DATE '1998-11-07', 1, 76, 106.20, 'Rafał', 'Tyminśka', NULL, 'Januszex'),
  ('3-767-14707-6', 'Im bucik starszy tym bardziej nosa zadziera', DATE '2000-04-19', 1, 12, 114.30, NULL, NULL, 'TCS times', 'Drux'),
  ('2-900-04670-X', 'Im bucik starszy tym wyżej głowę nosi', DATE '1648-07-23', 1, 13, 144.80, 'Grzegorz', 'Sejko', NULL, 'Drux'),
  ('6-835-65486-4', 'Im bucik starszy tym więcej chce', DATE '1926-07-05', 2, 32, 113.60, 'Joanna', 'Mickiewicz', NULL, 'WSSP'),
  ('1-017-27763-X', 'Im bucik starszy tym spokojniej śpisz', DATE '1941-08-02', 1, 78, 25.20, 'Grzegorz', 'Dąbrowkski', NULL, 'GGWP'),
  ('1-779-50169-2', 'Im bucik starszy tym bardziej gryzie', DATE '1524-07-21', 2, 51, 43.0, 'Karolina', 'Dębska', NULL, 'Wesoła Szkoła'),
  ('9-619-32724-1', 'Im bucik starszy tak cię cenią', DATE '1952-06-03', 1, 24, 28.0, 'Dariusz', 'Totenbach', NULL, 'Kruti'),
  ('4-297-39448-0', 'Im bucik starszy kij się znajdzie', DATE '1937-08-03', 1, 76, 16.20, 'Piotr', 'Schmidt', NULL, 'Kruti'),
  ('1-087-25114-1', 'Im bucik starszy to się diabeł cieszy', DATE '1980-09-12', 1, 28, 162.40, 'Aleksandra', 'Majewska', NULL, 'Siedmiu Krasnoludków'),
  ('4-550-88088-0', 'Im bucik starszy tak się koniec grudnia nosi', DATE '1907-04-29', 3, 43, 149.80, 'Sandra', 'Tanenbaum', NULL, 'GGWP'),
  ('6-578-61313-7', 'Im bucik starszy to się lubi co się ma', DATE '2006-05-13', 1, 54, 50.40, 'Aleksandra', 'Dąbrowkska', NULL, 'Pies Filemon'),
  ('8-162-02070-5', 'Im bucik starszy pora powiedzieć „b”', DATE '1967-01-07', 1, 28, 95.10, 'Dariusz', 'Hoser', NULL, 'Januszex'),
  ('2-999-77040-5', 'Im bucik starszy to z dobrego konia', DATE '1992-11-20', 1, 67, 135.80, 'Paweł', 'Sienkiewicz', NULL, 'Afro'),
  ('7-292-04395-X', 'Im bucik starszy to z dobrego konia', DATE '1704-08-17', 2, 76, 100.40, NULL, NULL, 'Wsród Matematyki', 'Januszex'),
  ('7-546-47386-1', 'Im bucik starszy temu czas', DATE '2002-05-25', 2, 30, 4.20, 'Tomasz', 'Tanenbaum', NULL, 'Pentakill'),
  ('5-143-32070-4', 'Im bucik starszy za przewodnika', DATE '1980-08-15', 1, 60, 95.0, 'Dariusz', 'Wojciechowski', NULL, 'Atakałke'),
  ('8-125-77632-X', 'Im bucik starszy cygana powiesili', DATE '1341-02-05', 1, 59, 112.20, 'Brygida', 'Pawlak', NULL, 'Kruti'),
  ('8-786-86703-2', 'Im bucik starszy oka nie wykole', DATE '1942-11-30', 1, 20, 40.60, NULL, NULL, 'Piąta Ściana', 'Januszex'),
  ('2-398-64854-0', 'Im bucik starszy mało mleka daje', DATE '2015-03-26', 1, 28, 17.80, 'Agnieszka', 'Klemens', NULL, 'Januszex'),
  ('8-721-96514-5', 'Im bucik starszy trochę zimy, trochę lata', DATE '2011-11-19', 1, 79, 140.80, 'Jakub', 'Sienkiewicz', NULL, 'GGWP'),
  ('6-016-71313-9', 'Im bucik starszy nie wart i kołacza', DATE '2003-07-17', 1, 70, 58.10, 'Franciszek', 'Wiśniewski', NULL, 'Podziemie'),
  ('9-914-79407-6', 'Im bucik starszy ponieśli i wilka', DATE '1994-07-16', 1, 22, 122.40, 'Dariusz', 'Kucharczyk', NULL, 'Wesoła Szkoła'),
  ('4-825-64678-6', 'Im bucik starszy nikt nie wie', DATE '1984-09-16', 1, 63, 57.30, 'Michał', 'Klemens', NULL, 'Afro'),
  ('9-705-25562-8', 'Im kto mniej wart nie ma chatki', DATE '2000-11-02', 1, 66, 58.70, 'Mateusz', 'Gradek', NULL, 'GGWP'),
  ('6-705-31246-7', 'Im kto mniej wart że przymarznie cap do kozy', DATE '2005-02-26', 1, 40, 159.0, 'Piotr', 'Mełech', NULL, 'Kruti'),
  ('1-612-09924-6', 'Im kto mniej wart ale na całe życie', DATE '1954-12-07', 1, 58, 136.90, 'Anna', 'Pawlak', NULL, 'Kruca Fix'),
  ('7-879-38760-9', 'Im kto mniej wart póki jeszcze czas', DATE '1845-07-01', 1, 46, 83.20, 'Jan', 'Nowakowski', NULL, 'Kruca Fix'),
  ('9-765-95367-4', 'Im kto mniej wart byk się ocieli', DATE '1983-09-15', 1, 65, 19.80, 'Grzegorz', 'Nowicki', NULL, 'NGU'),
  ('5-477-86473-7', 'Im kto mniej wart to drugiemu niewola', DATE '1897-12-04', 1, 19, 32.20, 'Filip', 'Totenbach', NULL, 'Pies Filemon'),
  ('6-979-43532-9', 'Im kto mniej wart to go nie minie', DATE '1964-12-27', 1, 25, 55.0, 'Tomasz', 'Krysicki', NULL, 'Wesoła Szkoła'),
  ('6-345-82753-3', 'Im kto mniej wart to zima przejada', DATE '1998-06-19', 1, 51, 77.70, 'Jarosław', 'Dura', NULL, 'Wesoła Szkoła'),
  ('7-619-68425-5', 'Im kto mniej wart dom wesołym czyni', DATE '1906-11-10', 1, 49, 17.50, 'Łukasz', 'Monarek', NULL, 'Drux'),
  ('7-411-09810-8', 'Im kto mniej wart wrócić ziarno na śniadanie', DATE '2007-11-19', 1, 52, 55.90, 'Weronika', 'Kondratek', NULL, 'Pentakill'),
  ('5-525-89090-9', 'Im kto mniej wart jak się kto przepości', DATE '1880-05-06', 1, 52, 33.20, 'Hans', 'Kowalski', NULL, 'Extra Ciemne'),
  ('0-321-99615-1', 'Im kto mniej wart pada aż do Zuzanny', DATE '2004-02-17', 1, 40, 188.30, 'Piotr', 'Dostojewski', NULL, 'WSSP'),
  ('1-889-38372-4', 'Im kto mniej wart znać jabłuszko na jabłoni', DATE '1981-07-28', 1, 53, 45.60, 'Joanna', 'Tyminśka', NULL, 'WSSP'),
  ('2-018-22832-3', 'Im kto mniej wart jesień krótka, szybko mija', DATE '1911-09-08', 1, 60, 78.10, 'Jacek', 'Dostojewski', NULL, 'NGU'),
  ('9-099-29323-2', 'Im kto mniej wart to się diabeł cieszy', DATE '1938-07-10', 1, 7, 40.10, NULL, NULL, 'Encylopedia Informatyki', 'Loki'),
  ('5-416-62681-X', 'Im kto mniej wart zwykle nastaje posucha', DATE '1934-07-01', 3, 19, 117.10, 'Anna', 'Bobak', NULL, 'Siedmiu Krasnoludków'),
  ('3-179-52481-2', 'Im kto mniej wart piekła nie ma', DATE '1616-08-02', 4, 46, 173.10, 'Paulina', 'Malinowska', NULL, 'Januszex'),
  ('6-588-21113-9', 'Im kto mniej wart piekło gore', DATE '1901-12-08', 1, 21, 36.40, 'Jarosław', 'Gołąbek', NULL, 'Wesoła Szkoła'),
  ('3-420-51869-2', 'Im kto mniej wart tym bardziej nosa zadziera', DATE '2009-03-01', 1, 66, 65.20, 'Mikołaj', 'Słowacki', NULL, 'Pentakill'),
  ('0-330-76629-5', 'Im kto mniej wart tym wyżej głowę nosi', DATE '1947-10-14', 1, 39, 45.20, 'Andrzej', 'Jaworski', NULL, 'Kruca Fix'),
  ('6-534-25055-1', 'Im kto mniej wart tym więcej chce', DATE '1940-03-02', 2, 75, 113.10, 'Agnieszka', 'Dostojewska', NULL, 'Pies Filemon'),
  ('9-557-61297-5', 'Im kto mniej wart tym spokojniej śpisz', DATE '1906-08-14', 3, 66, 68.20, 'Kornel', 'Homoncik', NULL, 'Januszex'),
  ('6-353-66833-3', 'Im kto mniej wart tym bardziej gryzie', DATE '1916-12-03', 1, 75, 134.20, 'Paweł', 'Dębska', NULL, 'ASCT'),
  ('0-158-31306-2', 'Im kto mniej wart tak cię cenią', DATE '1992-04-02', 1, 65, 100.10, 'Brygida', 'Monarek', NULL, 'Afro'),
  ('0-956-17492-2', 'Im kto mniej wart kij się znajdzie', DATE '1932-05-26', 1, 61, 127.0, 'Alicja', 'Nowak', NULL, 'NGU'),
  ('4-227-23671-1', 'Im kto mniej wart to się diabeł cieszy', DATE '1962-08-24', 2, 19, 23.40, 'Adam', 'Lewandowski', NULL, 'Januszex'),
  ('5-718-67014-5', 'Im kto mniej wart tak się koniec grudnia nosi', DATE '1914-08-16', 1, 27, 12.60, 'Tomasz', 'Górski', NULL, 'Siedmiu Krasnoludków'),
  ('1-573-64094-8', 'Im kto mniej wart to się lubi co się ma', DATE '1971-02-27', 1, 60, 89.50, 'Andrzej', 'Piotrowski', NULL, 'Kruca Fix'),
  ('6-394-82275-2', 'Im kto mniej wart pora powiedzieć „b”', DATE '2007-05-10', 1, 50, 74.60, 'Piotr', 'Tyminśka', NULL, 'Afro'),
  ('7-285-77983-0', 'Im kto mniej wart to z dobrego konia', DATE '1932-08-13', 1, 63, 49.70, 'Grzegorz', 'Dębska', NULL, 'Podziemie'),
  ('4-059-64360-2', 'Im kto mniej wart to z dobrego konia', DATE '2015-08-25', 1, 41, 72.40, 'Janusz', 'Cebulski', NULL, 'Afro'),
  ('2-811-77446-7', 'Im kto mniej wart temu czas', DATE '1943-07-29', 1, 45, 18.0, 'Aleksandra', 'Zielińska', NULL, 'Extra Ciemne'),
  ('4-084-41252-X', 'Im kto mniej wart za przewodnika', DATE '1942-11-06', 3, 61, 16.70, 'Jakub', 'Neumann', NULL, 'Pentakill'),
  ('9-977-81097-4', 'Im kto mniej wart cygana powiesili', DATE '1918-04-22', 1, 26, 77.10, 'Rafał', 'Kucharczyk', NULL, 'Kruca Fix'),
  ('9-199-61850-8', 'Im kto mniej wart oka nie wykole', DATE '2011-05-09', 1, 15, 124.80, 'Felicyta', 'Sienkiewicz', NULL, 'NGU'),
  ('1-350-74383-6', 'Im kto mniej wart mało mleka daje', DATE '1981-11-18', 4, 19, 101.10, 'Karolina', 'Homoncik', NULL, 'NGU'),
  ('9-972-40590-7', 'Im kto mniej wart trochę zimy, trochę lata', DATE '1970-10-29', 1, 62, 172.0, 'Bożydar', 'Helik', NULL, 'Extra Ciemne'),
  ('5-206-01793-0', 'Im kto mniej wart nie wart i kołacza', DATE '1911-07-24', 1, 54, 134.90, 'Piotr', 'Gradek', NULL, 'Gambit Kaczmarkowski'),
  ('6-468-53059-8', 'Im kto mniej wart ponieśli i wilka', DATE '1984-11-22', 4, 37, 146.10, NULL, NULL, 'Poczta Polska', 'Babunia'),
  ('9-798-80428-7', 'Im kto mniej wart nikt nie wie', DATE '2007-12-22', 1, 59, 22.50, 'Grzegorz', 'Jachowicz', NULL, 'NGU'),
  ('7-067-67655-X', 'Im kto więcej ma nie ma chatki', DATE '1923-04-20', 1, 20, 11.20, 'Maciek', 'Bobak', NULL, 'Babunia'),
  ('2-608-79956-6', 'Im kto więcej ma że przymarznie cap do kozy', DATE '2010-04-15', 3, 47, 38.50, 'Anna', 'Wiśniewska', NULL, 'Pentakill'),
  ('9-266-20449-8', 'Im kto więcej ma ale na całe życie', DATE '1961-07-18', 2, 36, 40.80, 'Anna', 'Helik', NULL, 'ASCT'),
  ('3-000-61248-3', 'Im kto więcej ma póki jeszcze czas', DATE '1901-03-26', 1, 28, 67.30, 'Grzegorz', 'Kostrikin', NULL, 'Extra Ciemne'),
  ('1-745-97519-5', 'Im kto więcej ma byk się ocieli', DATE '1972-08-08', 1, 67, 163.50, 'Hans', 'Kucharczyk', NULL, 'WSSP'),
  ('9-697-20497-7', 'Im kto więcej ma to drugiemu niewola', DATE '1814-12-25', 1, 52, 106.10, 'Alicja', 'Tyminśka', NULL, 'Podziemie'),
  ('1-901-31949-0', 'Im kto więcej ma to go nie minie', DATE '1906-12-01', 1, 75, 56.90, NULL, NULL, 'Piąta Ściana', 'Kruti'),
  ('1-810-49141-X', 'Im kto więcej ma to zima przejada', DATE '1935-01-12', 1, 57, 69.70, 'Andrzej', 'Dura', NULL, 'GGWP'),
  ('8-768-47657-4', 'Im kto więcej ma dom wesołym czyni', DATE '1994-08-11', 1, 57, 104.70, 'Sandra', 'Sejko', NULL, 'Atakałke'),
  ('5-094-49107-5', 'Im kto więcej ma wrócić ziarno na śniadanie', DATE '1938-05-16', 2, 31, 135.80, 'Karolina', 'Schmidt', NULL, 'ASCT'),
  ('5-089-06210-2', 'Im kto więcej ma jak się kto przepości', DATE '1991-02-06', 1, 72, 10.70, 'Mateusz', 'Kamiński', NULL, 'Loki'),
  ('8-248-22013-3', 'Im kto więcej ma pada aż do Zuzanny', DATE '1997-12-02', 1, 71, 15.70, 'Małgorzata', 'Wojciechowska', NULL, 'ASCT'),
  ('7-167-67935-6', 'Im kto więcej ma znać jabłuszko na jabłoni', DATE '1991-07-28', 1, 29, 108.20, 'Agnieszka', 'Dostojewska', NULL, 'NGU'),
  ('1-836-11990-9', 'Im kto więcej ma jesień krótka, szybko mija', DATE '1936-12-25', 1, 45, 125.20, 'Andrzej', 'Kostrikin', NULL, 'Babunia'),
  ('5-798-22869-X', 'Im kto więcej ma to się diabeł cieszy', DATE '1979-11-01', 1, 71, 16.10, NULL, NULL, 'Piąta Ściana', 'Babunia'),
  ('3-082-15786-6', 'Im kto więcej ma zwykle nastaje posucha', DATE '1957-06-08', 2, 39, 152.30, 'Sandra', 'Słowacka', NULL, 'Afro'),
  ('6-682-51445-X', 'Im kto więcej ma piekła nie ma', DATE '1917-04-15', 1, 35, 27.80, 'Kamila', 'Jachowicz', NULL, 'Drux'),
  ('9-882-64846-0', 'Im kto więcej ma piekło gore', DATE '2005-08-23', 1, 28, 80.0, NULL, NULL, 'Gazeta WMiI', 'Extra Ciemne'),
  ('0-922-42333-4', 'Im kto więcej ma tym bardziej nosa zadziera', DATE '1927-04-05', 1, 48, 74.80, 'Weronika', 'Nowak', NULL, 'Januszex'),
  ('5-907-00834-2', 'Im kto więcej ma tym wyżej głowę nosi', DATE '1933-01-23', 1, 15, 121.80, 'Felicyta', 'Filtz', NULL, 'Pentakill'),
  ('3-041-00209-4', 'Im kto więcej ma tym więcej chce', DATE '1866-06-28', 1, 73, 132.10, 'Jakub', 'Mełech', NULL, 'Afro'),
  ('9-602-73416-7', 'Im kto więcej ma tym spokojniej śpisz', DATE '1969-11-20', 1, 20, 9.20, 'Adam', 'Lewandowski', NULL, 'Kruti'),
  ('0-548-05409-6', 'Im kto więcej ma tym bardziej gryzie', DATE '1916-09-04', 4, 58, 98.60, 'Brygida', 'Stępień', NULL, 'Podziemie'),
  ('0-073-97837-X', 'Im kto więcej ma tak cię cenią', DATE '1936-09-10', 1, 51, 92.90, 'Karolina', 'Jaworska', NULL, 'Atakałke'),
  ('7-792-12505-X', 'Im kto więcej ma kij się znajdzie', DATE '1929-11-30', 1, 59, 47.90, NULL, NULL, 'TCS times', 'Kot Reksio'),
  ('6-602-70962-3', 'Im kto więcej ma to się diabeł cieszy', DATE '1929-07-29', 1, 43, 150.70, 'Bożydar', 'Sienkiewicz', NULL, 'Drux'),
  ('6-068-84686-5', 'Im kto więcej ma tak się koniec grudnia nosi', DATE '1989-04-20', 2, 40, 95.80, 'Bartłomiej', 'Monarek', NULL, 'Kruti'),
  ('2-076-53611-6', 'Im kto więcej ma to się lubi co się ma', DATE '1975-09-18', 1, 29, 108.20, 'Wiktor', 'Piotrowski', NULL, 'Atakałke'),
  ('9-380-52028-X', 'Im kto więcej ma pora powiedzieć „b”', DATE '1954-02-07', 2, 61, 90.50, 'Elżbieta', 'Goldberg', NULL, 'Kot Reksio'),
  ('4-423-53654-4', 'Im kto więcej ma to z dobrego konia', DATE '1933-09-18', 1, 41, 25.10, 'Alicja', 'Adamczyk', NULL, 'Babunia'),
  ('7-328-18453-1', 'Im kto więcej ma to z dobrego konia', DATE '1971-10-30', 3, 46, 89.30, 'Henryk', 'Jaworski', NULL, 'Afro'),
  ('6-940-81501-5', 'Im kto więcej ma temu czas', DATE '1902-09-23', 3, 9, 70.0, 'Paulina', 'Kowalska', NULL, 'Kruca Fix'),
  ('1-926-71611-6', 'Im kto więcej ma za przewodnika', DATE '1959-09-17', 1, 9, 95.20, 'Wiktor', 'Sejko', NULL, 'Drux'),
  ('1-262-97136-5', 'Im kto więcej ma cygana powiesili', DATE '1976-05-29', 2, 69, 80.10, 'Sandra', 'Mickiewicz', NULL, 'Siedmiu Krasnoludków'),
  ('4-443-95758-8', 'Im kto więcej ma oka nie wykole', DATE '2004-08-02', 1, 47, 173.40, 'Bartłomiej', 'Słowacki', NULL, 'Pentakill'),
  ('6-551-31594-1', 'Im kto więcej ma mało mleka daje', DATE '1964-07-12', 4, 45, 53.0, 'Agnieszka', 'Bobak', NULL, 'Wesoła Szkoła'),
  ('1-476-24385-9', 'Im kto więcej ma trochę zimy, trochę lata', DATE '1771-04-05', 1, 32, 34.0, 'Filip', 'Woźniak', NULL, 'Extra Ciemne'),
  ('8-917-07460-X', 'Im kto więcej ma nie wart i kołacza', DATE '1921-07-18', 2, 15, 112.70, NULL, NULL, 'Dreamteam', 'Januszex'),
  ('1-913-11122-9', 'Im kto więcej ma ponieśli i wilka', DATE '2012-07-16', 1, 55, 18.0, 'Hans', 'Jaworski', NULL, 'Januszex'),
  ('4-110-32148-4', 'Im kto więcej ma nikt nie wie', DATE '1993-10-12', 2, 35, 35.60, 'Felicyta', 'Piotrowska', NULL, 'ASCT'),
  ('8-562-53665-2', 'Im mniej wiesz nie ma chatki', DATE '1994-08-07', 1, 17, 124.40, 'Tomasz', 'Cebulski', NULL, 'ASCT'),
  ('6-776-75358-X', 'Im mniej wiesz że przymarznie cap do kozy', DATE '2002-03-08', 1, 25, 115.40, 'Karolina', 'Krysicka', NULL, 'Kruti'),
  ('4-863-24190-9', 'Im mniej wiesz ale na całe życie', DATE '1948-09-06', 1, 31, 108.60, 'Aleksandra', 'Stępień', NULL, 'Kot Reksio'),
  ('9-492-53338-3', 'Im mniej wiesz póki jeszcze czas', DATE '1985-08-02', 1, 51, 45.40, 'Jan', 'Schneider', NULL, 'Atakałke'),
  ('6-537-14308-X', 'Im mniej wiesz byk się ocieli', DATE '1947-08-14', 4, 48, 138.90, 'Grzegorz', 'Wiśniewski', NULL, 'Atakałke'),
  ('3-741-20879-5', 'Im mniej wiesz to drugiemu niewola', DATE '2015-02-27', 1, 49, 107.40, 'Zuzanna', 'Dąbrowkska', NULL, 'GGWP'),
  ('0-499-95856-X', 'Im mniej wiesz to go nie minie', DATE '1953-01-03', 1, 76, 179.40, NULL, NULL, 'Encylopedia Informatyki', 'Atakałke'),
  ('8-127-97959-7', 'Im mniej wiesz to zima przejada', DATE '1918-09-18', 4, 40, 112.50, 'Agnieszka', 'Górska', NULL, 'Pies Filemon'),
  ('4-678-17256-4', 'Im mniej wiesz dom wesołym czyni', DATE '1929-10-16', 1, 71, 68.40, 'Elżbieta', 'Dudek', NULL, 'Pies Filemon'),
  ('4-980-22823-2', 'Im mniej wiesz wrócić ziarno na śniadanie', DATE '1876-04-28', 3, 49, 41.0, NULL, NULL, 'Uniwersytet Koloni Krężnej', 'WSSP'),
  ('1-585-86974-0', 'Im mniej wiesz jak się kto przepości', DATE '1911-02-07', 1, 51, 129.10, 'Michał', 'Neumann', NULL, 'Atakałke'),
  ('4-184-70967-2', 'Im mniej wiesz pada aż do Zuzanny', DATE '1916-09-25', 1, 7, 145.10, 'Adam', 'Dostojewski', NULL, 'Kruti'),
  ('7-417-67841-6', 'Im mniej wiesz znać jabłuszko na jabłoni', DATE '2002-09-25', 1, 56, 133.60, NULL, NULL, 'Poczta Polska', 'WSSP'),
  ('0-601-28069-5', 'Im mniej wiesz jesień krótka, szybko mija', DATE '1954-09-27', 2, 30, 72.20, 'Tomasz', 'Neumann', NULL, 'Pies Filemon'),
  ('4-218-23544-9', 'Im mniej wiesz to się diabeł cieszy', DATE '1954-03-19', 3, 46, 8.0, 'Rafał', 'Klemens', NULL, 'Siedmiu Krasnoludków'),
  ('0-974-83792-X', 'Im mniej wiesz zwykle nastaje posucha', DATE '2003-08-11', 1, 65, 136.0, 'Paweł', 'Grabowski', NULL, 'Babunia'),
  ('2-007-70666-0', 'Im mniej wiesz piekła nie ma', DATE '1900-10-01', 1, 24, 57.30, 'Iwona', 'Helik', NULL, 'Babunia'),
  ('7-214-03520-0', 'Im mniej wiesz piekło gore', DATE '1920-07-24', 3, 71, 92.0, 'Elżbieta', 'Dąbrowkska', NULL, 'ASCT'),
  ('0-130-12427-3', 'Im mniej wiesz tym bardziej nosa zadziera', DATE '1920-11-19', 3, 16, 17.50, 'Agnieszka', 'Zielińska', NULL, 'Babunia'),
  ('5-386-49791-X', 'Im mniej wiesz tym wyżej głowę nosi', DATE '1803-03-20', 1, 40, 139.70, 'Jakub', 'Wiśniewski', NULL, 'Januszex'),
  ('7-149-92488-3', 'Im mniej wiesz tym więcej chce', DATE '1999-07-20', 1, 63, 55.10, 'Sandra', 'Wiśniewska', NULL, 'Loki'),
  ('6-346-81032-4', 'Im mniej wiesz tym spokojniej śpisz', DATE '2013-12-17', 1, 32, 39.40, 'Jan', 'Sejko', NULL, 'Kot Reksio'),
  ('1-604-46805-X', 'Im mniej wiesz tym bardziej gryzie', DATE '1953-06-22', 1, 52, 141.0, 'Iwona', 'Stępień', NULL, 'Loki'),
  ('5-353-18233-2', 'Im mniej wiesz tak cię cenią', DATE '1903-12-08', 3, 28, 96.0, 'Kornel', 'Nowicki', NULL, 'Afro'),
  ('3-246-89134-6', 'Im mniej wiesz kij się znajdzie', DATE '2013-01-23', 1, 14, 18.10, 'Michał', 'Totenbach', NULL, 'Babunia'),
  ('4-917-74112-2', 'Im mniej wiesz to się diabeł cieszy', DATE '1932-05-05', 2, 22, 123.60, NULL, NULL, 'Drużyna Pierścienia', 'Kruca Fix'),
  ('8-554-62075-5', 'Im mniej wiesz tak się koniec grudnia nosi', DATE '1975-08-20', 1, 59, 13.20, 'Paweł', 'Helik', NULL, 'Gambit Kaczmarkowski'),
  ('7-364-46990-7', 'Im mniej wiesz to się lubi co się ma', DATE '1917-05-29', 3, 32, 78.80, 'Filip', 'Zieliński', NULL, 'ASCT'),
  ('1-996-57111-7', 'Im mniej wiesz pora powiedzieć „b”', DATE '1953-05-20', 2, 69, 103.80, 'Michał', 'Tyminśka', NULL, 'Kruca Fix'),
  ('1-423-55543-0', 'Im mniej wiesz to z dobrego konia', DATE '1981-11-22', 2, 63, 40.90, 'Zuzanna', 'Sejko', NULL, 'Podziemie'),
  ('4-590-51676-4', 'Im mniej wiesz to z dobrego konia', DATE '1947-06-06', 1, 67, 39.20, 'Joanna', 'Klemens', NULL, 'NGU'),
  ('0-765-53075-9', 'Im mniej wiesz temu czas', DATE '1948-06-16', 1, 37, 130.90, 'Jakub', 'Monarek', NULL, 'Kot Reksio'),
  ('4-642-57232-5', 'Im mniej wiesz za przewodnika', DATE '1944-06-27', 1, 21, 156.50, NULL, NULL, 'Związek Rybaków i Płetwonurków', 'Gambit Kaczmarkowski'),
  ('4-502-31998-8', 'Im mniej wiesz cygana powiesili', DATE '1246-04-24', 1, 36, 18.20, 'Katarzyna', 'Dudek', NULL, 'Januszex'),
  ('2-014-65190-6', 'Im mniej wiesz oka nie wykole', DATE '1970-02-17', 3, 18, 46.10, 'Grzegorz', 'Dudek', NULL, 'Pentakill'),
  ('2-499-53187-8', 'Im mniej wiesz mało mleka daje', DATE '2007-11-22', 1, 36, 3.10, 'Katarzyna', 'Cebulska', NULL, 'Atakałke'),
  ('9-045-09110-0', 'Im mniej wiesz trochę zimy, trochę lata', DATE '1950-03-05', 1, 58, 117.70, 'Jacek', 'Hoser', NULL, 'Extra Ciemne'),
  ('8-740-96263-6', 'Im mniej wiesz nie wart i kołacza', DATE '1993-07-05', 4, 63, 21.50, 'Jakub', 'Hoser', NULL, 'NGU'),
  ('2-712-61022-9', 'Im mniej wiesz ponieśli i wilka', DATE '1966-05-09', 4, 73, 93.20, NULL, NULL, 'Dreamteam', 'Atakałke'),
  ('3-019-84176-3', 'Im mniej wiesz nikt nie wie', DATE '1967-10-17', 1, 62, 134.0, 'Anna', 'Totenbach', NULL, 'Wesoła Szkoła'),
  ('2-384-41653-7', 'Im pies mniej szczeka nie ma chatki', DATE '1960-03-20', 1, 63, 20.70, 'Paweł', 'Jachowicz', NULL, 'Gambit Kaczmarkowski'),
  ('2-580-40526-7', 'Im pies mniej szczeka że przymarznie cap do kozy', DATE '1978-07-07', 1, 67, 121.0, 'Henryk', 'Górski', NULL, 'Januszex'),
  ('3-897-24206-0', 'Im pies mniej szczeka ale na całe życie', DATE '1953-10-18', 2, 15, 136.20, 'Małgorzata', 'Sejko', NULL, 'Kruti'),
  ('7-970-23830-0', 'Im pies mniej szczeka póki jeszcze czas', DATE '1991-03-14', 1, 11, 93.80, NULL, NULL, 'Związek Rybaków i Płetwonurków', 'ASCT'),
  ('2-135-28326-6', 'Im pies mniej szczeka byk się ocieli', DATE '1974-06-15', 4, 40, 74.40, 'Franciszek', 'Mełech', NULL, 'Afro'),
  ('6-941-78404-0', 'Im pies mniej szczeka to drugiemu niewola', DATE '1846-08-22', 1, 29, 69.10, 'Sandra', 'Grabowska', NULL, 'Kruti'),
  ('5-922-81352-8', 'Im pies mniej szczeka to go nie minie', DATE '1921-05-27', 1, 56, 51.50, 'Andrzej', 'Woźniak', NULL, 'Podziemie'),
  ('9-495-36450-7', 'Im pies mniej szczeka to zima przejada', DATE '1852-06-11', 1, 65, 147.60, 'Karolina', 'Gross', NULL, 'Kot Reksio'),
  ('6-820-92409-7', 'Im pies mniej szczeka dom wesołym czyni', DATE '1922-05-13', 3, 39, 68.20, 'Joanna', 'Wiśniewska', NULL, 'Gambit Kaczmarkowski'),
  ('3-035-59390-6', 'Im pies mniej szczeka wrócić ziarno na śniadanie', DATE '1901-11-07', 1, 65, 140.40, 'Kamila', 'Kondratek', NULL, 'Siedmiu Krasnoludków'),
  ('7-791-42379-0', 'Im pies mniej szczeka jak się kto przepości', DATE '1903-02-07', 3, 37, 25.90, 'Joanna', 'Wiśniewska', NULL, 'Kruca Fix'),
  ('0-654-83176-9', 'Im pies mniej szczeka pada aż do Zuzanny', DATE '1959-04-16', 1, 31, 176.90, 'Paulina', 'Zielińska', NULL, 'NGU'),
  ('3-329-05579-0', 'Im pies mniej szczeka znać jabłuszko na jabłoni', DATE '1962-08-22', 1, 74, 99.60, NULL, NULL, 'Wsród Matematyki', 'Extra Ciemne'),
  ('3-517-85119-1', 'Im pies mniej szczeka jesień krótka, szybko mija', DATE '2001-11-18', 1, 24, 111.10, 'Janusz', 'Cebulski', NULL, 'Drux'),
  ('3-638-19346-2', 'Im pies mniej szczeka to się diabeł cieszy', DATE '2011-12-12', 1, 58, 180.10, 'Wiktor', 'Gołąbek', NULL, 'Kruca Fix'),
  ('6-859-18876-6', 'Im pies mniej szczeka zwykle nastaje posucha', DATE '2002-09-26', 1, 25, 174.30, 'Tomasz', 'Głowacka', NULL, 'WSSP'),
  ('2-929-00750-8', 'Im pies mniej szczeka piekła nie ma', DATE '1987-11-28', 1, 81, 12.50, 'Anna', 'Kucharczyk', NULL, 'Pentakill'),
  ('5-422-27366-4', 'Im pies mniej szczeka piekło gore', DATE '1681-10-20', 1, 59, 84.60, 'Andrzej', 'Słowacki', NULL, 'Drux'),
  ('4-534-68002-3', 'Im pies mniej szczeka tym bardziej nosa zadziera', DATE '1929-09-22', 1, 68, 121.80, 'Jarosław', 'Monarek', NULL, 'Siedmiu Krasnoludków'),
  ('8-623-26862-8', 'Im pies mniej szczeka tym wyżej głowę nosi', DATE '1908-03-18', 1, 47, 41.20, 'Joanna', 'Dostojewska', NULL, 'Kot Reksio'),
  ('9-705-18352-X', 'Im pies mniej szczeka tym więcej chce', DATE '1959-11-05', 3, 62, 128.90, 'Mateusz', 'Pawlak', NULL, 'Siedmiu Krasnoludków'),
  ('5-569-07902-5', 'Im pies mniej szczeka tym spokojniej śpisz', DATE '1977-04-10', 1, 48, 140.20, 'Aleksandra', 'Gołąbek', NULL, 'Afro'),
  ('4-779-23845-5', 'Im pies mniej szczeka tym bardziej gryzie', DATE '1929-06-21', 2, 64, 112.80, 'Janusz', 'Sejko', NULL, 'Pentakill'),
  ('4-285-32402-4', 'Im pies mniej szczeka tak cię cenią', DATE '1963-09-06', 1, 47, 69.60, 'Wiktor', 'Pawlak', NULL, 'Podziemie'),
  ('3-400-26213-7', 'Im pies mniej szczeka kij się znajdzie', DATE '1965-01-15', 1, 25, 89.90, 'Karolina', 'Gross', NULL, 'Siedmiu Krasnoludków'),
  ('6-813-15847-3', 'Im pies mniej szczeka to się diabeł cieszy', DATE '1924-04-22', 1, 41, 82.10, 'Franciszek', 'Wojciechowski', NULL, 'Kruca Fix'),
  ('4-581-54179-4', 'Im pies mniej szczeka tak się koniec grudnia nosi', DATE '2010-02-20', 3, 59, 175.10, 'Weronika', 'Tyminśka', NULL, 'Kot Reksio'),
  ('5-510-86769-8', 'Im pies mniej szczeka to się lubi co się ma', DATE '1984-04-13', 1, 51, 21.30, NULL, NULL, 'Gazeta WMiI', 'GGWP'),
  ('7-507-25547-6', 'Im pies mniej szczeka pora powiedzieć „b”', DATE '1960-02-11', 1, 65, 65.50, 'Aleksandra', 'Neumann', NULL, 'Kruca Fix'),
  ('8-413-68987-2', 'Im pies mniej szczeka to z dobrego konia', DATE '1914-03-05', 1, 81, 155.40, 'Weronika', 'Wojciechowska', NULL, 'Siedmiu Krasnoludków'),
  ('5-490-80513-7', 'Im pies mniej szczeka to z dobrego konia', DATE '1945-07-02', 4, 43, 76.90, 'Paulina', 'Mickiewicz', NULL, 'Pies Filemon'),
  ('9-066-71384-4', 'Im pies mniej szczeka temu czas', DATE '1996-08-22', 2, 40, 147.30, NULL, NULL, 'Wsród Matematyki', 'ASCT'),
  ('5-346-30868-7', 'Im pies mniej szczeka za przewodnika', DATE '1909-01-30', 1, 46, 163.0, 'Felicyta', 'Pupa', NULL, 'Pentakill'),
  ('3-793-54992-5', 'Im pies mniej szczeka cygana powiesili', DATE '1995-01-11', 1, 51, 62.0, 'Mateusz', 'Wojciechowski', NULL, 'Kruti'),
  ('1-962-62155-3', 'Im pies mniej szczeka oka nie wykole', DATE '1949-01-28', 1, 78, 103.50, 'Kornel', 'Grabowski', NULL, 'Pies Filemon'),
  ('7-068-87971-3', 'Im pies mniej szczeka mało mleka daje', DATE '1919-04-12', 1, 44, 71.40, 'Jarosław', 'Kazimierczak', NULL, 'Afro'),
  ('4-707-09069-9', 'Im pies mniej szczeka trochę zimy, trochę lata', DATE '1966-06-18', 1, 33, 72.40, 'Filip', 'Bobak', NULL, 'Pies Filemon'),
  ('8-539-07804-X', 'Im pies mniej szczeka nie wart i kołacza', DATE '2014-03-21', 1, 42, 107.10, 'Karolina', 'Lewandowska', NULL, 'Kruti'),
  ('2-608-80511-6', 'Im pies mniej szczeka ponieśli i wilka', DATE '1882-02-01', 2, 43, 122.80, 'Bożydar', 'Schneider', NULL, 'Gambit Kaczmarkowski'),
  ('0-143-96916-1', 'Im pies mniej szczeka nikt nie wie', DATE '2009-06-24', 1, 54, 118.60, 'Franciszek', 'Klemens', NULL, 'Januszex'),
  ('2-972-10353-X', 'Jak się cenisz nie ma chatki', DATE '1905-01-23', 4, 30, 7.40, NULL, NULL, 'Panowie Z Drugiej Ławki', 'GGWP'),
  ('2-416-74964-1', 'Jak się cenisz że przymarznie cap do kozy', DATE '1871-07-17', 1, 59, 85.80, NULL, NULL, 'Piąta Ściana', 'Drux'),
  ('5-398-38089-3', 'Jak się cenisz ale na całe życie', DATE '1985-07-29', 1, 58, 88.10, 'Henryk', 'Kamiński', NULL, 'Januszex'),
  ('8-249-99200-8', 'Jak się cenisz póki jeszcze czas', DATE '1999-05-03', 1, 31, 124.0, 'Adam', 'Adamczyk', NULL, 'Extra Ciemne'),
  ('0-971-96537-4', 'Jak się cenisz byk się ocieli', DATE '1915-05-30', 1, 66, 67.10, 'Alicja', 'Bobak', NULL, 'Kruti'),
  ('3-232-45117-9', 'Jak się cenisz to drugiemu niewola', DATE '1847-09-27', 1, 64, 92.90, 'Mateusz', 'Kucharczyk', NULL, 'Podziemie'),
  ('8-310-87439-1', 'Jak się cenisz to go nie minie', DATE '2001-12-30', 1, 68, 149.20, 'Paweł', 'Grabowski', NULL, 'ASCT'),
  ('8-779-37579-0', 'Jak się cenisz to zima przejada', DATE '1902-02-06', 1, 30, 58.80, NULL, NULL, 'Wsród Matematyki', 'Extra Ciemne'),
  ('9-355-44413-3', 'Jak się cenisz dom wesołym czyni', DATE '2005-03-24', 1, 80, 11.30, 'Kornel', 'Sienkiewicz', NULL, 'Extra Ciemne'),
  ('4-150-64512-4', 'Jak się cenisz wrócić ziarno na śniadanie', DATE '1979-03-16', 1, 22, 37.50, 'Łukasz', 'Monarek', NULL, 'Gambit Kaczmarkowski'),
  ('2-133-47499-4', 'Jak się cenisz jak się kto przepości', DATE '1986-06-11', 1, 21, 82.30, 'Mateusz', 'Monarek', NULL, 'Siedmiu Krasnoludków'),
  ('6-860-28352-1', 'Jak się cenisz pada aż do Zuzanny', DATE '1940-08-10', 1, 60, 68.80, 'Andrzej', 'Bobak', NULL, 'Pentakill'),
  ('6-186-84647-4', 'Jak się cenisz znać jabłuszko na jabłoni', DATE '1996-03-13', 4, 69, 96.10, 'Andrzej', 'Schmidt', NULL, 'ASCT'),
  ('1-173-86662-0', 'Jak się cenisz jesień krótka, szybko mija', DATE '1933-07-20', 1, 28, 174.70, 'Jan', 'Dudek', NULL, 'Siedmiu Krasnoludków'),
  ('1-890-70446-6', 'Jak się cenisz to się diabeł cieszy', DATE '1970-07-19', 1, 7, 99.0, 'Wiktor', 'Dębska', NULL, 'Kruti'),
  ('5-901-41934-0', 'Jak się cenisz zwykle nastaje posucha', DATE '1971-03-19', 1, 59, 109.10, 'Hans', 'Kucharczyk', NULL, 'Kruca Fix'),
  ('3-047-11832-9', 'Jak się cenisz piekła nie ma', DATE '1927-07-30', 1, 29, 63.10, 'Jacek', 'Johansen', NULL, 'Afro'),
  ('8-659-50919-6', 'Jak się cenisz piekło gore', DATE '1922-11-07', 1, 43, 108.40, NULL, NULL, 'Dreamteam', 'Pies Filemon'),
  ('6-493-77164-1', 'Jak się cenisz tym bardziej nosa zadziera', DATE '1844-01-30', 1, 32, 111.30, 'Małgorzata', 'Górska', NULL, 'Gambit Kaczmarkowski'),
  ('5-079-85580-0', 'Jak się cenisz tym wyżej głowę nosi', DATE '1917-12-03', 4, 21, 111.50, 'Adam', 'Kucharczyk', NULL, 'GGWP'),
  ('0-665-64853-7', 'Jak się cenisz tym więcej chce', DATE '2004-11-19', 1, 52, 50.60, 'Mikołaj', 'Gross', NULL, 'Babunia'),
  ('2-903-30998-1', 'Jak się cenisz tym spokojniej śpisz', DATE '1947-01-23', 4, 24, 62.30, 'Felicyta', 'Stępień', NULL, 'Kot Reksio'),
  ('5-662-88382-3', 'Jak się cenisz tym bardziej gryzie', DATE '1931-04-19', 3, 22, 71.40, NULL, NULL, 'Współczesne rozwój', 'Kruti'),
  ('5-670-26702-8', 'Jak się cenisz tak cię cenią', DATE '1926-10-23', 1, 56, 98.20, 'Jan', 'Gradek', NULL, 'Pies Filemon'),
  ('5-191-96786-0', 'Jak się cenisz kij się znajdzie', DATE '2008-02-22', 1, 67, 22.70, 'Tomasz', 'Kucharczyk', NULL, 'Afro'),
  ('4-963-81484-6', 'Jak się cenisz to się diabeł cieszy', DATE '1940-05-09', 1, 48, 79.30, 'Wiktor', 'Sejko', NULL, 'Kruca Fix'),
  ('4-864-30513-7', 'Jak się cenisz tak się koniec grudnia nosi', DATE '1900-02-05', 1, 37, 147.0, 'Anna', 'Sienkiewicz', NULL, 'WSSP'),
  ('0-169-80946-3', 'Jak się cenisz to się lubi co się ma', DATE '1936-08-15', 1, 76, 49.50, 'Jan', 'Tyminśka', NULL, 'Loki'),
  ('7-735-43804-4', 'Jak się cenisz pora powiedzieć „b”', DATE '1994-08-02', 1, 51, 22.10, 'Tomasz', 'Nowakowski', NULL, 'NGU'),
  ('7-361-54089-9', 'Jak się cenisz to z dobrego konia', DATE '1974-10-05', 1, 25, 118.30, 'Kornel', 'Krysicki', NULL, 'Kruti'),
  ('3-688-95488-2', 'Jak się cenisz to z dobrego konia', DATE '1928-03-08', 1, 51, 77.90, 'Wiktor', 'Kaczmarek', NULL, 'Wesoła Szkoła'),
  ('5-495-92301-4', 'Jak się cenisz temu czas', DATE '1927-10-13', 1, 64, 95.10, 'Michał', 'Johansen', NULL, 'Kruca Fix'),
  ('1-785-24111-7', 'Jak się cenisz za przewodnika', DATE '1945-11-16', 1, 60, 39.20, 'Anna', 'Tanenbaum', NULL, 'Pentakill'),
  ('3-284-59337-3', 'Jak się cenisz cygana powiesili', DATE '1939-01-17', 1, 47, 99.60, 'Brygida', 'Zielińska', NULL, 'Atakałke'),
  ('2-083-91776-6', 'Jak się cenisz oka nie wykole', DATE '1933-08-21', 1, 21, 69.60, 'Brygida', 'Johansen', NULL, 'Pentakill'),
  ('2-290-83268-5', 'Jak się cenisz mało mleka daje', DATE '1990-04-02', 1, 22, 78.60, 'Zuzanna', 'Woźniak', NULL, 'Siedmiu Krasnoludków'),
  ('2-533-15707-4', 'Jak się cenisz trochę zimy, trochę lata', DATE '1987-05-12', 3, 27, 112.20, NULL, NULL, 'Współczesne rozwój', 'NGU'),
  ('6-347-23109-3', 'Jak się cenisz nie wart i kołacza', DATE '1945-07-04', 1, 27, 42.40, 'Hans', 'Klemens', NULL, 'ASCT'),
  ('7-050-03542-4', 'Jak się cenisz ponieśli i wilka', DATE '1902-03-12', 1, 29, 93.30, 'Henryk', 'Klemens', NULL, 'Januszex'),
  ('3-972-24276-X', 'Jak się cenisz nikt nie wie', DATE '1946-11-30', 1, 33, 37.50, 'Bartłomiej', 'Witkowski', NULL, 'Kruti'),
  ('5-946-09571-4', 'Jak się chce psa uderzyć nie ma chatki', DATE '1984-04-09', 1, 53, 60.80, 'Jakub', 'Monarek', NULL, 'Pentakill'),
  ('4-707-36872-7', 'Jak się chce psa uderzyć że przymarznie cap do kozy', DATE '2012-11-27', 1, 22, 30.50, 'Maciek', 'Woźniak', NULL, 'Gambit Kaczmarkowski'),
  ('9-433-47346-9', 'Jak się chce psa uderzyć ale na całe życie', DATE '1948-08-24', 1, 45, 151.80, 'Hans', 'Pawlak', NULL, 'Wesoła Szkoła'),
  ('3-023-11845-0', 'Jak się chce psa uderzyć póki jeszcze czas', DATE '1999-09-09', 2, 64, 143.60, 'Michał', 'Gradek', NULL, 'Pies Filemon'),
  ('4-428-55071-5', 'Jak się chce psa uderzyć byk się ocieli', DATE '1949-12-08', 1, 39, 14.20, 'Piotr', 'Pawlak', NULL, 'GGWP'),
  ('3-459-41381-6', 'Jak się chce psa uderzyć to drugiemu niewola', DATE '1935-01-10', 2, 19, 55.60, NULL, NULL, 'Encylopedia Informatyki', 'Gambit Kaczmarkowski'),
  ('8-049-34471-1', 'Jak się chce psa uderzyć to go nie minie', DATE '1985-03-26', 1, 35, 34.50, 'Katarzyna', 'Homoncik', NULL, 'Atakałke'),
  ('9-115-09740-4', 'Jak się chce psa uderzyć to zima przejada', DATE '1970-10-08', 2, 51, 22.90, 'Henryk', 'Helik', NULL, 'Wesoła Szkoła'),
  ('2-379-07214-0', 'Jak się chce psa uderzyć dom wesołym czyni', DATE '1922-12-11', 4, 21, 95.40, 'Karolina', 'Majewska', NULL, 'Siedmiu Krasnoludków'),
  ('6-887-42213-1', 'Jak się chce psa uderzyć wrócić ziarno na śniadanie', DATE '1998-05-03', 1, 36, 95.0, 'Anna', 'Filtz', NULL, 'Gambit Kaczmarkowski'),
  ('1-819-30727-1', 'Jak się chce psa uderzyć jak się kto przepości', DATE '1954-04-06', 4, 48, 101.40, NULL, NULL, 'Poczta Polska', 'Afro'),
  ('2-606-91782-0', 'Jak się chce psa uderzyć pada aż do Zuzanny', DATE '1969-05-06', 1, 40, 30.60, 'Adam', 'Grabowski', NULL, 'Pentakill'),
  ('9-187-70378-5', 'Jak się chce psa uderzyć znać jabłuszko na jabłoni', DATE '1633-02-10', 1, 58, 26.10, 'Andrzej', 'Bobak', NULL, 'Gambit Kaczmarkowski'),
  ('9-649-55034-8', 'Jak się chce psa uderzyć jesień krótka, szybko mija', DATE '1922-07-19', 4, 29, 53.30, 'Dariusz', 'Grabowski', NULL, 'Gambit Kaczmarkowski'),
  ('8-228-12671-9', 'Jak się chce psa uderzyć to się diabeł cieszy', DATE '1975-02-24', 1, 20, 82.40, 'Sandra', 'Goldberg', NULL, 'Pies Filemon'),
  ('1-955-64784-4', 'Jak się chce psa uderzyć zwykle nastaje posucha', DATE '1948-02-21', 1, 72, 58.40, NULL, NULL, 'TCS times', 'Siedmiu Krasnoludków'),
  ('4-152-64569-5', 'Jak się chce psa uderzyć piekła nie ma', DATE '1974-10-30', 3, 60, 150.0, 'Felicyta', 'Nowak', NULL, 'NGU'),
  ('7-667-41915-9', 'Jak się chce psa uderzyć piekło gore', DATE '1983-03-11', 1, 66, 135.0, 'Alicja', 'Krysicka', NULL, 'Kruti'),
  ('5-827-69527-0', 'Jak się chce psa uderzyć tym bardziej nosa zadziera', DATE '1927-01-06', 1, 23, 103.70, 'Adam', 'Słowacki', NULL, 'Gambit Kaczmarkowski'),
  ('9-069-71990-8', 'Jak się chce psa uderzyć tym wyżej głowę nosi', DATE '1910-02-07', 2, 58, 100.50, 'Iwona', 'Mickiewicz', NULL, 'Gambit Kaczmarkowski'),
  ('3-392-90451-1', 'Jak się chce psa uderzyć tym więcej chce', DATE '1934-02-05', 1, 73, 52.40, 'Agnieszka', 'Sienkiewicz', NULL, 'Drux'),
  ('4-256-18922-X', 'Jak się chce psa uderzyć tym spokojniej śpisz', DATE '1942-11-17', 1, 63, 98.70, 'Bożydar', 'Stępień', NULL, 'Drux'),
  ('3-200-94440-4', 'Jak się chce psa uderzyć tym bardziej gryzie', DATE '1929-06-18', 4, 50, 89.70, 'Rafał', 'Tanenbaum', NULL, 'ASCT'),
  ('8-636-66068-8', 'Jak się chce psa uderzyć tak cię cenią', DATE '1949-12-09', 1, 47, 36.30, NULL, NULL, 'Gazeta WMiI', 'Pentakill'),
  ('1-137-96561-4', 'Jak się chce psa uderzyć kij się znajdzie', DATE '1954-11-15', 1, 57, 77.40, NULL, NULL, 'Gazeta WMiI', 'WSSP'),
  ('1-446-66892-4', 'Jak się chce psa uderzyć to się diabeł cieszy', DATE '1966-07-13', 1, 49, 68.40, 'Paweł', 'Dąbrowkski', NULL, 'Extra Ciemne'),
  ('4-246-57014-1', 'Jak się chce psa uderzyć tak się koniec grudnia nosi', DATE '1911-03-18', 1, 24, 94.40, NULL, NULL, 'Wsród Matematyki', 'Kruca Fix'),
  ('6-158-50476-9', 'Jak się chce psa uderzyć to się lubi co się ma', DATE '1922-05-21', 1, 58, 22.60, 'Hans', 'Nowak', NULL, 'Kruti'),
  ('8-082-55625-0', 'Jak się chce psa uderzyć pora powiedzieć „b”', DATE '1437-05-03', 1, 43, 13.90, 'Iwona', 'Adamczyk', NULL, 'Pies Filemon'),
  ('0-303-58563-3', 'Jak się chce psa uderzyć to z dobrego konia', DATE '1913-08-29', 1, 47, 159.90, 'Paweł', 'Stępień', NULL, 'WSSP'),
  ('2-046-26129-1', 'Jak się chce psa uderzyć to z dobrego konia', DATE '2009-07-16', 1, 20, 12.90, 'Paweł', 'Sejko', NULL, 'Januszex'),
  ('7-202-32580-2', 'Jak się chce psa uderzyć temu czas', DATE '1940-01-28', 1, 27, 31.10, 'Kornel', 'Dąbrowkski', NULL, 'Babunia'),
  ('3-631-20522-8', 'Jak się chce psa uderzyć za przewodnika', DATE '1791-10-09', 1, 60, 133.40, 'Bożydar', 'Mełech', NULL, 'Babunia'),
  ('3-024-58389-0', 'Jak się chce psa uderzyć cygana powiesili', DATE '1902-08-15', 1, 24, 38.30, NULL, NULL, 'Gazeta WMiI', 'Pies Filemon'),
  ('4-467-12035-1', 'Jak się chce psa uderzyć oka nie wykole', DATE '1902-06-30', 1, 31, 22.30, 'Aleksandra', 'Gross', NULL, 'Pies Filemon'),
  ('7-305-64941-4', 'Jak się chce psa uderzyć mało mleka daje', DATE '2001-04-08', 1, 26, 141.80, NULL, NULL, 'Współczesne rozwój', 'Atakałke'),
  ('2-835-57497-2', 'Jak się chce psa uderzyć trochę zimy, trochę lata', DATE '1977-04-01', 1, 32, 131.40, 'Grzegorz', 'Helik', NULL, 'Extra Ciemne'),
  ('3-728-16743-6', 'Jak się chce psa uderzyć nie wart i kołacza', DATE '1973-12-31', 1, 32, 131.10, 'Elżbieta', 'Schneider', NULL, 'Kot Reksio'),
  ('5-683-73212-3', 'Jak się chce psa uderzyć ponieśli i wilka', DATE '1906-10-10', 1, 53, 112.90, 'Joanna', 'Pawlak', NULL, 'NGU'),
  ('2-403-96991-5', 'Jak się chce psa uderzyć nikt nie wie', DATE '1988-11-01', 1, 25, 94.70, 'Katarzyna', 'Sienkiewicz', NULL, 'WSSP'),
  ('7-210-93696-3', 'Jak się człowiek śpieszy nie ma chatki', DATE '1945-08-07', 1, 49, 109.0, 'Jakub', 'Hoser', NULL, 'Afro'),
  ('6-699-98300-8', 'Jak się człowiek śpieszy że przymarznie cap do kozy', DATE '2013-04-13', 1, 34, 88.90, 'Felicyta', 'Totenbach', NULL, 'Loki'),
  ('4-310-68879-9', 'Jak się człowiek śpieszy ale na całe życie', DATE '1960-03-27', 1, 35, 37.20, 'Andrzej', 'Kondratek', NULL, 'Kot Reksio'),
  ('2-006-07049-5', 'Jak się człowiek śpieszy póki jeszcze czas', DATE '1910-03-29', 4, 23, 134.80, 'Alicja', 'Zielińska', NULL, 'Gambit Kaczmarkowski'),
  ('2-354-87704-8', 'Jak się człowiek śpieszy byk się ocieli', DATE '2009-09-22', 1, 53, 65.30, 'Henryk', 'Krysicki', NULL, 'Kruca Fix'),
  ('9-045-48013-1', 'Jak się człowiek śpieszy to drugiemu niewola', DATE '1900-09-11', 1, 62, 95.50, 'Kornel', 'Bobak', NULL, 'Gambit Kaczmarkowski'),
  ('5-615-02747-9', 'Jak się człowiek śpieszy to go nie minie', DATE '1909-02-25', 1, 37, 29.90, 'Dariusz', 'Kazimierczak', NULL, 'Podziemie'),
  ('8-087-25650-6', 'Jak się człowiek śpieszy to zima przejada', DATE '1868-01-15', 1, 38, 68.60, NULL, NULL, 'Gazeta WMiI', 'Kruca Fix'),
  ('1-428-97627-2', 'Jak się człowiek śpieszy dom wesołym czyni', DATE '1950-11-23', 2, 49, 56.80, 'Jacek', 'Schmidt', NULL, 'Extra Ciemne'),
  ('3-347-37255-7', 'Jak się człowiek śpieszy wrócić ziarno na śniadanie', DATE '1926-03-06', 3, 31, 121.90, 'Rafał', 'Malinowski', NULL, 'Extra Ciemne'),
  ('3-381-53690-7', 'Jak się człowiek śpieszy jak się kto przepości', DATE '1920-05-17', 1, 63, 97.0, 'Henryk', 'Sienkiewicz', NULL, 'WSSP'),
  ('7-806-66147-6', 'Jak się człowiek śpieszy pada aż do Zuzanny', DATE '2009-06-18', 2, 75, 66.60, 'Brygida', 'Dostojewska', NULL, 'Babunia'),
  ('2-444-83490-9', 'Jak się człowiek śpieszy znać jabłuszko na jabłoni', DATE '1921-12-11', 1, 34, 44.0, 'Paulina', 'Krysicka', NULL, 'Pies Filemon'),
  ('5-677-31177-4', 'Jak się człowiek śpieszy jesień krótka, szybko mija', DATE '1937-06-14', 1, 40, 108.80, 'Szymon', 'Monarek', NULL, 'Extra Ciemne'),
  ('7-670-24814-9', 'Jak się człowiek śpieszy to się diabeł cieszy', DATE '1919-12-13', 1, 52, 55.10, 'Kornel', 'Dudek', NULL, 'Kruca Fix'),
  ('0-382-56848-6', 'Jak się człowiek śpieszy zwykle nastaje posucha', DATE '1950-01-28', 1, 22, 107.10, 'Filip', 'Homoncik', NULL, 'Kruti'),
  ('0-158-15117-8', 'Jak się człowiek śpieszy piekła nie ma', DATE '1935-02-07', 1, 47, 55.40, 'Filip', 'Goldberg', NULL, 'NGU'),
  ('9-145-57905-9', 'Jak się człowiek śpieszy piekło gore', DATE '1951-07-24', 1, 66, 88.40, 'Franciszek', 'Goldberg', NULL, 'Kruca Fix'),
  ('5-680-77324-4', 'Jak się człowiek śpieszy tym bardziej nosa zadziera', DATE '1971-06-20', 1, 29, 127.30, 'Jarosław', 'Wojciechowski', NULL, 'Babunia'),
  ('8-431-01981-6', 'Jak się człowiek śpieszy tym wyżej głowę nosi', DATE '1683-10-05', 1, 48, 95.20, NULL, NULL, 'FAKTCS', 'Januszex'),
  ('0-970-28192-7', 'Jak się człowiek śpieszy tym więcej chce', DATE '1453-12-17', 1, 48, 63.30, 'Rafał', 'Kaczmarek', NULL, 'Afro'),
  ('9-469-88850-2', 'Jak się człowiek śpieszy tym spokojniej śpisz', DATE '1602-02-03', 4, 43, 97.10, 'Bożydar', 'Gross', NULL, 'Pentakill'),
  ('6-994-30012-9', 'Jak się człowiek śpieszy tym bardziej gryzie', DATE '1953-01-29', 1, 58, 70.50, 'Szymon', 'Bobak', NULL, 'Wesoła Szkoła'),
  ('5-820-21935-X', 'Jak się człowiek śpieszy tak cię cenią', DATE '1993-06-27', 1, 44, 49.50, 'Anna', 'Sejko', NULL, 'Babunia'),
  ('1-424-88400-4', 'Jak się człowiek śpieszy kij się znajdzie', DATE '1901-02-04', 1, 62, 84.80, 'Henryk', 'Gołąbek', NULL, 'Pies Filemon'),
  ('4-971-58575-3', 'Jak się człowiek śpieszy to się diabeł cieszy', DATE '1931-04-07', 1, 48, 12.90, 'Aleksandra', 'Gradek', NULL, 'Drux'),
  ('1-443-31432-3', 'Jak się człowiek śpieszy tak się koniec grudnia nosi', DATE '1915-04-20', 1, 24, 50.0, 'Kornel', 'Bobak', NULL, 'Siedmiu Krasnoludków'),
  ('0-576-48014-2', 'Jak się człowiek śpieszy to się lubi co się ma', DATE '1270-01-30', 2, 15, 35.60, 'Kamila', 'Lewandowska', NULL, 'WSSP'),
  ('2-405-62238-6', 'Jak się człowiek śpieszy pora powiedzieć „b”', DATE '1944-08-20', 4, 30, 35.0, 'Adam', 'Mełech', NULL, 'Drux'),
  ('2-345-19236-4', 'Jak się człowiek śpieszy to z dobrego konia', DATE '1834-03-30', 1, 40, 65.40, 'Jacek', 'Kostrikin', NULL, 'Wesoła Szkoła'),
  ('0-803-15882-3', 'Jak się człowiek śpieszy to z dobrego konia', DATE '1965-07-14', 4, 57, 105.30, 'Franciszek', 'Gradek', NULL, 'Kruti'),
  ('7-464-56359-X', 'Jak się człowiek śpieszy temu czas', DATE '1978-05-13', 1, 60, 73.20, 'Jarosław', 'Mełech', NULL, 'NGU'),
  ('8-471-77531-X', 'Jak się człowiek śpieszy za przewodnika', DATE '1951-07-29', 4, 70, 25.0, 'Jan', 'Bobak', NULL, 'Atakałke'),
  ('3-774-57859-1', 'Jak się człowiek śpieszy cygana powiesili', DATE '1998-11-20', 1, 39, 80.50, 'Franciszek', 'Kowalski', NULL, 'Wesoła Szkoła'),
  ('4-851-50044-0', 'Jak się człowiek śpieszy oka nie wykole', DATE '1928-01-01', 1, 22, 51.20, 'Małgorzata', 'Adamczyk', NULL, 'Atakałke'),
  ('4-209-16887-4', 'Jak się człowiek śpieszy mało mleka daje', DATE '1912-09-02', 1, 22, 60.90, 'Grzegorz', 'Wojciechowski', NULL, 'Siedmiu Krasnoludków'),
  ('9-076-11813-2', 'Jak się człowiek śpieszy trochę zimy, trochę lata', DATE '1963-02-13', 1, 86, 169.60, 'Paulina', 'Gradek', NULL, 'Januszex'),
  ('9-788-87053-8', 'Jak się człowiek śpieszy nie wart i kołacza', DATE '1959-05-28', 4, 32, 146.50, 'Agnieszka', 'Goldberg', NULL, 'Atakałke'),
  ('5-611-70170-1', 'Jak się człowiek śpieszy ponieśli i wilka', DATE '2002-11-27', 4, 29, 154.90, NULL, NULL, 'Gazeta WMiI', 'Extra Ciemne'),
  ('4-807-69240-2', 'Jak się człowiek śpieszy nikt nie wie', DATE '1956-02-06', 1, 21, 21.20, 'Katarzyna', 'Nowakowska', NULL, 'Pies Filemon'),
  ('7-883-12311-4', 'Jak się matka z córką zgłosi nie ma chatki', DATE '1572-11-27', 1, 74, 104.40, 'Iwona', 'Nowak', NULL, 'Kruti'),
  ('1-403-48123-7', 'Jak się matka z córką zgłosi że przymarznie cap do kozy', DATE '1941-06-07', 1, 73, 33.80, 'Andrzej', 'Totenbach', NULL, 'Drux'),
  ('6-342-87890-0', 'Jak się matka z córką zgłosi ale na całe życie', DATE '1983-04-09', 1, 24, 45.20, 'Hans', 'Jachowicz', NULL, 'Podziemie'),
  ('8-029-50214-1', 'Jak się matka z córką zgłosi póki jeszcze czas', DATE '1914-03-19', 1, 66, 16.60, 'Agnieszka', 'Dudek', NULL, 'Kruca Fix'),
  ('6-151-15237-9', 'Jak się matka z córką zgłosi byk się ocieli', DATE '1989-04-01', 1, 47, 187.90, 'Małgorzata', 'Majewska', NULL, 'Pentakill'),
  ('8-921-00372-X', 'Jak się matka z córką zgłosi to drugiemu niewola', DATE '1973-01-27', 2, 62, 53.60, 'Joanna', 'Mickiewicz', NULL, 'Atakałke'),
  ('9-673-65406-9', 'Jak się matka z córką zgłosi to go nie minie', DATE '1982-02-25', 1, 61, 106.30, 'Agnieszka', 'Totenbach', NULL, 'Pentakill'),
  ('1-991-78741-3', 'Jak się matka z córką zgłosi to zima przejada', DATE '1939-03-18', 1, 9, 108.30, 'Anna', 'Jachowicz', NULL, 'Pies Filemon'),
  ('3-818-82073-2', 'Jak się matka z córką zgłosi dom wesołym czyni', DATE '1255-03-22', 1, 30, 68.40, 'Adam', 'Jachowicz', NULL, 'Siedmiu Krasnoludków'),
  ('0-856-90701-4', 'Jak się matka z córką zgłosi wrócić ziarno na śniadanie', DATE '1993-12-08', 1, 54, 185.70, NULL, NULL, 'Poczta Polska', 'GGWP'),
  ('7-065-16593-0', 'Jak się matka z córką zgłosi jak się kto przepości', DATE '1912-07-22', 1, 79, 108.60, 'Piotr', 'Nowakowski', NULL, 'Gambit Kaczmarkowski'),
  ('5-840-81366-4', 'Jak się matka z córką zgłosi pada aż do Zuzanny', DATE '1993-03-03', 1, 74, 57.10, 'Małgorzata', 'Adamczyk', NULL, 'Wesoła Szkoła'),
  ('1-832-18080-8', 'Jak się matka z córką zgłosi znać jabłuszko na jabłoni', DATE '1949-04-28', 1, 63, 62.20, 'Piotr', 'Pawlak', NULL, 'Podziemie'),
  ('8-439-84917-6', 'Jak się matka z córką zgłosi jesień krótka, szybko mija', DATE '1939-04-21', 2, 50, 149.50, 'Weronika', 'Dura', NULL, 'Kot Reksio'),
  ('5-368-76215-1', 'Jak się matka z córką zgłosi to się diabeł cieszy', DATE '1991-09-15', 1, 42, 83.80, NULL, NULL, 'Współczesne rozwój', 'Drux'),
  ('1-728-71507-5', 'Jak się matka z córką zgłosi zwykle nastaje posucha', DATE '1953-10-18', 1, 39, 172.0, 'Kamila', 'Dębska', NULL, 'GGWP'),
  ('0-153-36057-7', 'Jak się matka z córką zgłosi piekła nie ma', DATE '1956-03-04', 1, 29, 111.0, 'Jacek', 'Kamiński', NULL, 'Pentakill'),
  ('6-601-33496-0', 'Jak się matka z córką zgłosi piekło gore', DATE '2001-02-14', 1, 63, 140.70, 'Paulina', 'Kostrikin', NULL, 'WSSP'),
  ('4-782-66880-5', 'Jak się matka z córką zgłosi tym bardziej nosa zadziera', DATE '1983-05-10', 2, 16, 100.10, 'Elżbieta', 'Dura', NULL, 'Gambit Kaczmarkowski'),
  ('3-012-05909-1', 'Jak się matka z córką zgłosi tym wyżej głowę nosi', DATE '1907-12-14', 1, 79, 20.0, 'Tomasz', 'Hoser', NULL, 'Atakałke'),
  ('6-931-37141-X', 'Jak się matka z córką zgłosi tym więcej chce', DATE '2009-05-18', 1, 37, 134.10, 'Bożydar', 'Woźniak', NULL, 'Podziemie'),
  ('6-354-13346-8', 'Jak się matka z córką zgłosi tym spokojniej śpisz', DATE '1921-12-04', 1, 56, 71.50, 'Alicja', 'Malinowska', NULL, 'Drux'),
  ('6-403-96662-6', 'Jak się matka z córką zgłosi tym bardziej gryzie', DATE '2001-08-07', 4, 57, 136.80, 'Agnieszka', 'Jachowicz', NULL, 'NGU'),
  ('5-632-70875-6', 'Jak się matka z córką zgłosi tak cię cenią', DATE '1910-11-15', 1, 23, 122.30, NULL, NULL, 'Piąta Ściana', 'GGWP'),
  ('2-923-38814-3', 'Jak się matka z córką zgłosi kij się znajdzie', DATE '2011-04-11', 1, 30, 78.70, 'Joanna', 'Stępień', NULL, 'Pentakill'),
  ('5-805-20855-5', 'Jak się matka z córką zgłosi to się diabeł cieszy', DATE '2010-09-03', 1, 23, 113.70, 'Paweł', 'Kowalski', NULL, 'NGU'),
  ('7-408-18970-X', 'Jak się matka z córką zgłosi tak się koniec grudnia nosi', DATE '1905-09-25', 1, 46, 92.80, 'Rafał', 'Wiśniewski', NULL, 'ASCT'),
  ('6-766-85284-4', 'Jak się matka z córką zgłosi to się lubi co się ma', DATE '2012-04-06', 1, 74, 62.40, 'Paulina', 'Pupa', NULL, 'ASCT'),
  ('3-074-44332-4', 'Jak się matka z córką zgłosi pora powiedzieć „b”', DATE '1932-03-05', 1, 49, 147.50, 'Alicja', 'Tyminśka', NULL, 'Atakałke'),
  ('8-450-39105-9', 'Jak się matka z córką zgłosi to z dobrego konia', DATE '1964-06-03', 1, 50, 112.70, NULL, NULL, 'Związek Rybaków i Płetwonurków', 'NGU'),
  ('0-007-54810-9', 'Jak się matka z córką zgłosi to z dobrego konia', DATE '1628-02-04', 1, 36, 30.30, NULL, NULL, 'TCS WPROST', 'Pies Filemon'),
  ('6-711-75196-5', 'Jak się matka z córką zgłosi temu czas', DATE '2000-09-10', 1, 34, 41.50, 'Sandra', 'Tyminśka', NULL, 'Drux'),
  ('1-641-00933-0', 'Jak się matka z córką zgłosi za przewodnika', DATE '1956-12-06', 2, 17, 81.70, 'Weronika', 'Wiśniewska', NULL, 'Extra Ciemne'),
  ('9-521-74715-3', 'Jak się matka z córką zgłosi cygana powiesili', DATE '1982-05-21', 3, 29, 44.40, 'Paulina', 'Woźniak', NULL, 'Drux'),
  ('7-034-53984-7', 'Jak się matka z córką zgłosi oka nie wykole', DATE '1996-04-10', 1, 42, 77.20, 'Jacek', 'Kazimierczak', NULL, 'GGWP'),
  ('9-153-92336-7', 'Jak się matka z córką zgłosi mało mleka daje', DATE '2012-02-24', 3, 45, 105.30, 'Maciek', 'Cebulski', NULL, 'Babunia'),
  ('3-599-10283-X', 'Jak się matka z córką zgłosi trochę zimy, trochę lata', DATE '1971-06-20', 1, 46, 105.40, 'Rafał', 'Gradek', NULL, 'GGWP'),
  ('7-032-38749-7', 'Jak się matka z córką zgłosi nie wart i kołacza', DATE '1987-05-01', 1, 60, 129.90, 'Iwona', 'Kaczmarek', NULL, 'Loki'),
  ('5-092-28282-7', 'Jak się matka z córką zgłosi ponieśli i wilka', DATE '2006-02-19', 4, 65, 169.80, 'Joanna', 'Totenbach', NULL, 'Loki'),
  ('8-329-57269-2', 'Jak się matka z córką zgłosi nikt nie wie', DATE '1968-02-07', 3, 33, 107.10, 'Janusz', 'Gradek', NULL, 'Kruti'),
  ('0-282-38770-6', 'Jak się nie ma co się lubi nie ma chatki', DATE '1986-01-22', 2, 55, 106.0, 'Sandra', 'Sejko', NULL, 'GGWP'),
  ('8-295-61766-4', 'Jak się nie ma co się lubi że przymarznie cap do kozy', DATE '1953-12-17', 1, 37, 182.0, NULL, NULL, 'Drużyna Pierścienia', 'Kruti'),
  ('0-091-72923-8', 'Jak się nie ma co się lubi ale na całe życie', DATE '1956-04-24', 1, 47, 143.70, 'Bożydar', 'Jaworski', NULL, 'Wesoła Szkoła'),
  ('1-327-64076-7', 'Jak się nie ma co się lubi póki jeszcze czas', DATE '2005-10-10', 4, 19, 27.30, 'Iwona', 'Helik', NULL, 'Podziemie'),
  ('7-670-18658-5', 'Jak się nie ma co się lubi byk się ocieli', DATE '2000-11-02', 1, 47, 50.90, 'Szymon', 'Goldberg', NULL, 'Wesoła Szkoła'),
  ('7-237-92363-3', 'Jak się nie ma co się lubi to drugiemu niewola', DATE '1989-10-04', 3, 51, 88.80, 'Zuzanna', 'Helik', NULL, 'Pentakill'),
  ('9-062-85532-6', 'Jak się nie ma co się lubi to go nie minie', DATE '1984-02-05', 4, 65, 149.90, 'Jacek', 'Kowalski', NULL, 'Babunia'),
  ('5-144-24406-8', 'Jak się nie ma co się lubi to zima przejada', DATE '1920-02-11', 1, 52, 114.20, 'Piotr', 'Kaczmarek', NULL, 'Kruti'),
  ('3-149-41396-6', 'Jak się nie ma co się lubi dom wesołym czyni', DATE '1915-09-18', 1, 66, 25.60, 'Tomasz', 'Jachowicz', NULL, 'Pentakill'),
  ('9-641-27289-6', 'Jak się nie ma co się lubi wrócić ziarno na śniadanie', DATE '2005-01-27', 1, 18, 101.50, 'Szymon', 'Gross', NULL, 'Loki'),
  ('2-212-02043-0', 'Jak się nie ma co się lubi jak się kto przepości', DATE '1972-06-21', 1, 46, 34.70, NULL, NULL, 'Gazeta WMiI', 'Kot Reksio'),
  ('8-724-95628-7', 'Jak się nie ma co się lubi pada aż do Zuzanny', DATE '1930-03-15', 1, 46, 71.20, 'Łukasz', 'Helik', NULL, 'NGU'),
  ('7-019-22866-6', 'Jak się nie ma co się lubi znać jabłuszko na jabłoni', DATE '1973-09-06', 1, 66, 68.80, 'Paulina', 'Wiśniewska', NULL, 'Siedmiu Krasnoludków'),
  ('3-964-66670-X', 'Jak się nie ma co się lubi jesień krótka, szybko mija', DATE '1786-07-07', 1, 53, 85.20, 'Tomasz', 'Klemens', NULL, 'Januszex'),
  ('1-689-72836-1', 'Jak się nie ma co się lubi to się diabeł cieszy', DATE '2005-07-14', 1, 58, 87.20, 'Janusz', 'Piotrowski', NULL, 'Siedmiu Krasnoludków'),
  ('4-386-50231-9', 'Jak się nie ma co się lubi zwykle nastaje posucha', DATE '1961-06-16', 3, 64, 181.90, 'Tomasz', 'Wojciechowski', NULL, 'Extra Ciemne'),
  ('8-703-64850-8', 'Jak się nie ma co się lubi piekła nie ma', DATE '2013-04-20', 1, 28, 111.60, 'Piotr', 'Górski', NULL, 'Pentakill'),
  ('4-252-05900-3', 'Jak się nie ma co się lubi piekło gore', DATE '1913-02-10', 4, 52, 171.90, 'Małgorzata', 'Bobak', NULL, 'GGWP'),
  ('7-177-13168-X', 'Jak się nie ma co się lubi tym bardziej nosa zadziera', DATE '1945-06-05', 1, 38, 88.70, 'Bożydar', 'Kamiński', NULL, 'Siedmiu Krasnoludków'),
  ('7-110-61360-7', 'Jak się nie ma co się lubi tym wyżej głowę nosi', DATE '1931-04-10', 1, 35, 19.40, 'Anna', 'Jachowicz', NULL, 'Loki'),
  ('4-699-52369-2', 'Jak się nie ma co się lubi tym więcej chce', DATE '2009-04-17', 1, 77, 117.70, 'Mikołaj', 'Schmidt', NULL, 'Wesoła Szkoła'),
  ('8-094-46067-9', 'Jak się nie ma co się lubi tym spokojniej śpisz', DATE '2004-07-14', 1, 46, 95.50, 'Kamila', 'Adamczyk', NULL, 'Atakałke'),
  ('1-814-42666-3', 'Jak się nie ma co się lubi tym bardziej gryzie', DATE '1998-01-23', 4, 72, 78.0, 'Andrzej', 'Adamczyk', NULL, 'Loki'),
  ('3-533-76200-9', 'Jak się nie ma co się lubi tak cię cenią', DATE '1970-07-07', 1, 58, 39.20, 'Mikołaj', 'Monarek', NULL, 'GGWP'),
  ('1-601-93847-0', 'Jak się nie ma co się lubi kij się znajdzie', DATE '1952-08-18', 1, 40, 124.80, 'Jan', 'Helik', NULL, 'Extra Ciemne'),
  ('2-803-93927-4', 'Jak się nie ma co się lubi to się diabeł cieszy', DATE '1927-12-29', 2, 57, 32.90, 'Szymon', 'Mazur', NULL, 'Kruti'),
  ('2-467-38853-0', 'Jak się nie ma co się lubi tak się koniec grudnia nosi', DATE '1909-03-05', 1, 29, 57.60, 'Elżbieta', 'Tyminśka', NULL, 'Loki'),
  ('2-591-41529-3', 'Jak się nie ma co się lubi to się lubi co się ma', DATE '1991-06-27', 1, 21, 130.50, 'Kamila', 'Mełech', NULL, 'Pentakill'),
  ('3-619-55456-0', 'Jak się nie ma co się lubi pora powiedzieć „b”', DATE '1968-10-24', 1, 57, 32.50, 'Hans', 'Dostojewski', NULL, 'Atakałke'),
  ('4-989-62871-3', 'Jak się nie ma co się lubi to z dobrego konia', DATE '1912-05-18', 1, 18, 13.80, NULL, NULL, 'FAKTCS', 'Drux'),
  ('3-011-31859-X', 'Jak się nie ma co się lubi to z dobrego konia', DATE '1959-08-05', 1, 26, 23.70, 'Mateusz', 'Cebulski', NULL, 'Siedmiu Krasnoludków'),
  ('1-097-42756-0', 'Jak się nie ma co się lubi temu czas', DATE '1952-05-18', 1, 31, 111.10, NULL, NULL, 'Gazeta WMiI', 'Babunia'),
  ('9-679-99118-0', 'Jak się nie ma co się lubi za przewodnika', DATE '1937-04-29', 1, 31, 120.90, NULL, NULL, 'Związek Rybaków i Płetwonurków', 'NGU'),
  ('2-927-17696-5', 'Jak się nie ma co się lubi cygana powiesili', DATE '1904-09-20', 1, 19, 52.80, 'Hans', 'Gołąbek', NULL, 'ASCT'),
  ('8-169-40170-4', 'Jak się nie ma co się lubi oka nie wykole', DATE '2012-01-14', 1, 37, 127.70, 'Jakub', 'Wiśniewski', NULL, 'Kruti'),
  ('1-810-91252-0', 'Jak się nie ma co się lubi mało mleka daje', DATE '1932-12-27', 3, 37, 98.30, 'Tomasz', 'Stępień', NULL, 'Kruti'),
  ('5-689-09731-4', 'Jak się nie ma co się lubi trochę zimy, trochę lata', DATE '1998-08-18', 1, 51, 118.10, 'Sandra', 'Malinowska', NULL, 'Pentakill'),
  ('6-638-20600-1', 'Jak się nie ma co się lubi nie wart i kołacza', DATE '1997-04-12', 1, 34, 26.60, 'Janusz', 'Jachowicz', NULL, 'Wesoła Szkoła'),
  ('3-551-74724-5', 'Jak się nie ma co się lubi ponieśli i wilka', DATE '1587-05-07', 1, 42, 109.0, 'Jan', 'Zieliński', NULL, 'Kot Reksio'),
  ('0-833-38119-9', 'Jak się nie ma co się lubi nikt nie wie', DATE '1939-07-21', 1, 52, 95.40, 'Jacek', 'Kondratek', NULL, 'GGWP'),
  ('4-733-85338-6', 'Jak się powiedziało „a” nie ma chatki', DATE '2005-04-09', 1, 53, 71.60, NULL, NULL, 'Wsród Matematyki', 'Siedmiu Krasnoludków'),
  ('4-857-10183-1', 'Jak się powiedziało „a” że przymarznie cap do kozy', DATE '1902-11-18', 1, 23, 97.80, 'Jakub', 'Kostrikin', NULL, 'Januszex'),
  ('5-992-53022-3', 'Jak się powiedziało „a” ale na całe życie', DATE '1984-06-13', 1, 28, 26.50, 'Anna', 'Sienkiewicz', NULL, 'Atakałke'),
  ('3-663-33235-7', 'Jak się powiedziało „a” póki jeszcze czas', DATE '1984-08-10', 1, 60, 63.80, 'Kamila', 'Adamczyk', NULL, 'Pies Filemon'),
  ('1-284-74037-4', 'Jak się powiedziało „a” byk się ocieli', DATE '1968-12-27', 1, 26, 74.60, 'Elżbieta', 'Witkowska', NULL, 'ASCT'),
  ('9-695-22719-8', 'Jak się powiedziało „a” to drugiemu niewola', DATE '1850-12-05', 1, 35, 122.0, NULL, NULL, 'Koło Taniego Czyszczenia i Sprzątania', 'Kruti'),
  ('4-126-02583-9', 'Jak się powiedziało „a” to go nie minie', DATE '1949-12-13', 1, 56, 42.70, 'Michał', 'Schmidt', NULL, 'NGU'),
  ('2-874-33879-6', 'Jak się powiedziało „a” to zima przejada', DATE '1933-03-24', 2, 45, 27.60, 'Weronika', 'Zielińska', NULL, 'Pentakill'),
  ('8-828-96762-5', 'Jak się powiedziało „a” dom wesołym czyni', DATE '1979-04-09', 3, 68, 158.0, 'Joanna', 'Górska', NULL, 'Gambit Kaczmarkowski'),
  ('1-531-53342-6', 'Jak się powiedziało „a” wrócić ziarno na śniadanie', DATE '1909-07-04', 2, 34, 37.90, 'Jarosław', 'Nowakowski', NULL, 'Januszex'),
  ('0-174-08951-1', 'Jak się powiedziało „a” jak się kto przepości', DATE '1998-09-12', 1, 20, 15.10, 'Franciszek', 'Kondratek', NULL, 'Wesoła Szkoła'),
  ('5-922-85559-X', 'Jak się powiedziało „a” pada aż do Zuzanny', DATE '1958-02-19', 1, 34, 80.30, 'Grzegorz', 'Tanenbaum', NULL, 'NGU'),
  ('3-115-68402-9', 'Jak się powiedziało „a” znać jabłuszko na jabłoni', DATE '1953-04-01', 4, 26, 48.40, 'Sandra', 'Schmidt', NULL, 'Kot Reksio'),
  ('2-329-98203-8', 'Jak się powiedziało „a” jesień krótka, szybko mija', DATE '1987-05-13', 1, 17, 28.70, 'Małgorzata', 'Stępień', NULL, 'Kot Reksio'),
  ('3-272-09631-0', 'Jak się powiedziało „a” to się diabeł cieszy', DATE '1917-08-13', 1, 77, 118.10, 'Sandra', 'Górska', NULL, 'Pies Filemon'),
  ('2-002-13486-3', 'Jak się powiedziało „a” zwykle nastaje posucha', DATE '1979-11-11', 1, 24, 40.20, 'Katarzyna', 'Wiśniewska', NULL, 'Januszex'),
  ('8-850-80182-3', 'Jak się powiedziało „a” piekła nie ma', DATE '1960-05-22', 1, 32, 27.50, 'Wiktor', 'Kucharczyk', NULL, 'ASCT'),
  ('0-953-53336-0', 'Jak się powiedziało „a” piekło gore', DATE '1937-08-13', 1, 48, 42.70, 'Piotr', 'Neumann', NULL, 'Kot Reksio'),
  ('6-918-31716-4', 'Jak się powiedziało „a” tym bardziej nosa zadziera', DATE '1960-10-03', 1, 71, 105.40, 'Zuzanna', 'Klemens', NULL, 'Babunia'),
  ('5-361-45253-X', 'Jak się powiedziało „a” tym wyżej głowę nosi', DATE '1978-04-09', 1, 48, 66.90, 'Weronika', 'Głowacka', NULL, 'Pentakill'),
  ('2-785-36899-1', 'Jak się powiedziało „a” tym więcej chce', DATE '2000-06-28', 4, 39, 23.50, 'Hans', 'Wojciechowski', NULL, 'Kruca Fix'),
  ('2-276-89384-2', 'Jak się powiedziało „a” tym spokojniej śpisz', DATE '2000-11-28', 1, 41, 104.90, 'Paulina', 'Neumann', NULL, 'GGWP'),
  ('8-377-92088-3', 'Jak się powiedziało „a” tym bardziej gryzie', DATE '1959-02-21', 4, 30, 37.70, 'Joanna', 'Goldberg', NULL, 'Kruca Fix'),
  ('5-663-24812-9', 'Jak się powiedziało „a” tak cię cenią', DATE '1915-03-13', 1, 81, 121.50, 'Michał', 'Gołąbek', NULL, 'Wesoła Szkoła'),
  ('5-533-68122-1', 'Jak się powiedziało „a” kij się znajdzie', DATE '1929-09-07', 1, 40, 67.10, 'Kamila', 'Helik', NULL, 'Loki'),
  ('3-595-64019-5', 'Jak się powiedziało „a” to się diabeł cieszy', DATE '1941-07-12', 1, 50, 57.80, 'Mateusz', 'Schneider', NULL, 'Atakałke'),
  ('5-676-72288-6', 'Jak się powiedziało „a” tak się koniec grudnia nosi', DATE '1964-09-22', 1, 53, 7.0, 'Bożydar', 'Schneider', NULL, 'Kot Reksio'),
  ('7-120-99696-7', 'Jak się powiedziało „a” to się lubi co się ma', DATE '2015-01-16', 1, 57, 71.10, 'Paulina', 'Witkowska', NULL, 'Atakałke'),
  ('5-627-89929-8', 'Jak się powiedziało „a” pora powiedzieć „b”', DATE '1988-04-10', 1, 37, 59.0, 'Franciszek', 'Klemens', NULL, 'Januszex'),
  ('5-848-39477-6', 'Jak się powiedziało „a” to z dobrego konia', DATE '1978-11-18', 1, 27, 14.90, NULL, NULL, 'Gazeta WMiI', 'Drux'),
  ('7-243-96800-7', 'Jak się powiedziało „a” to z dobrego konia', DATE '1943-07-04', 1, 57, 160.90, 'Dariusz', 'Mickiewicz', NULL, 'Januszex'),
  ('4-352-22687-4', 'Jak się powiedziało „a” temu czas', DATE '1800-07-08', 1, 69, 74.20, 'Jacek', 'Dudek', NULL, 'WSSP'),
  ('5-669-11565-1', 'Jak się powiedziało „a” za przewodnika', DATE '1916-10-01', 1, 58, 98.80, 'Elżbieta', 'Jaworska', NULL, 'NGU'),
  ('2-803-35917-0', 'Jak się powiedziało „a” cygana powiesili', DATE '1928-07-01', 1, 53, 85.10, 'Dariusz', 'Kazimierczak', NULL, 'Drux'),
  ('5-379-89794-0', 'Jak się powiedziało „a” oka nie wykole', DATE '1978-01-01', 1, 56, 73.90, 'Paulina', 'Schmidt', NULL, 'Siedmiu Krasnoludków'),
  ('6-669-21590-8', 'Jak się powiedziało „a” mało mleka daje', DATE '1931-05-29', 1, 31, 90.40, 'Aleksandra', 'Klemens', NULL, 'Januszex'),
  ('1-729-88767-8', 'Jak się powiedziało „a” trochę zimy, trochę lata', DATE '1921-03-06', 1, 55, 115.60, 'Michał', 'Majewski', NULL, 'NGU'),
  ('8-235-36457-3', 'Jak się powiedziało „a” nie wart i kołacza', DATE '1917-10-09', 1, 67, 136.50, NULL, NULL, 'Poczta Polska', 'Kruti'),
  ('3-007-64789-4', 'Jak się powiedziało „a” ponieśli i wilka', DATE '1998-07-30', 4, 55, 112.0, 'Joanna', 'Kondratek', NULL, 'Kruti'),
  ('3-652-20228-7', 'Jak się powiedziało „a” nikt nie wie', DATE '1494-08-27', 1, 17, 73.20, 'Bartłomiej', 'Dąbrowkski', NULL, 'Podziemie'),
  ('9-746-47519-3', 'Jak sobie pościelesz nie ma chatki', DATE '1953-08-23', 1, 56, 26.90, NULL, NULL, 'Związek Rybaków i Płetwonurków', 'Pentakill'),
  ('1-407-10684-8', 'Jak sobie pościelesz że przymarznie cap do kozy', DATE '1972-08-10', 1, 24, 38.80, 'Mikołaj', 'Jachowicz', NULL, 'Januszex'),
  ('4-543-55775-1', 'Jak sobie pościelesz ale na całe życie', DATE '1979-02-10', 3, 50, 139.20, 'Iwona', 'Dudek', NULL, 'Atakałke'),
  ('7-839-00655-8', 'Jak sobie pościelesz póki jeszcze czas', DATE '1976-07-19', 4, 60, 116.70, 'Hans', 'Gołąbek', NULL, 'WSSP'),
  ('0-498-38887-5', 'Jak sobie pościelesz byk się ocieli', DATE '1914-09-07', 1, 58, 85.40, 'Jan', 'Schneider', NULL, 'Kruti'),
  ('2-647-04395-7', 'Jak sobie pościelesz to drugiemu niewola', DATE '1970-02-15', 1, 43, 106.20, NULL, NULL, 'FAKTCS', 'Pentakill'),
  ('4-474-20794-7', 'Jak sobie pościelesz to go nie minie', DATE '1973-10-23', 1, 54, 162.0, 'Grzegorz', 'Grabowski', NULL, 'Extra Ciemne'),
  ('7-930-70644-3', 'Jak sobie pościelesz to zima przejada', DATE '1960-12-04', 1, 58, 34.20, 'Katarzyna', 'Klemens', NULL, 'Pies Filemon'),
  ('5-302-27150-8', 'Jak sobie pościelesz dom wesołym czyni', DATE '1617-07-26', 2, 29, 52.10, 'Jarosław', 'Hoser', NULL, 'Kot Reksio'),
  ('6-606-35138-3', 'Jak sobie pościelesz wrócić ziarno na śniadanie', DATE '1907-06-02', 1, 43, 122.90, 'Hans', 'Bobak', NULL, 'Babunia'),
  ('1-614-77273-8', 'Jak sobie pościelesz jak się kto przepości', DATE '1937-03-22', 1, 46, 69.40, 'Iwona', 'Neumann', NULL, 'Afro'),
  ('4-057-38542-8', 'Jak sobie pościelesz pada aż do Zuzanny', DATE '1995-07-03', 1, 57, 6.20, 'Weronika', 'Mełech', NULL, 'Januszex'),
  ('0-590-75042-9', 'Jak sobie pościelesz znać jabłuszko na jabłoni', DATE '1922-06-10', 1, 75, 76.70, 'Janusz', 'Malinowski', NULL, 'GGWP'),
  ('0-453-16828-0', 'Jak sobie pościelesz jesień krótka, szybko mija', DATE '1915-11-12', 1, 42, 47.10, 'Tomasz', 'Pupa', NULL, 'Extra Ciemne'),
  ('6-067-86431-2', 'Jak sobie pościelesz to się diabeł cieszy', DATE '2005-03-24', 2, 21, 115.40, 'Jan', 'Krysicki', NULL, 'Atakałke'),
  ('8-024-31710-9', 'Jak sobie pościelesz zwykle nastaje posucha', DATE '1985-01-17', 1, 28, 104.0, 'Jakub', 'Sienkiewicz', NULL, 'NGU'),
  ('2-486-46893-5', 'Jak sobie pościelesz piekła nie ma', DATE '1996-11-25', 1, 39, 139.50, 'Wiktor', 'Kucharczyk', NULL, 'Podziemie'),
  ('6-799-53359-4', 'Jak sobie pościelesz piekło gore', DATE '1953-08-19', 1, 48, 83.50, 'Bartłomiej', 'Nowicki', NULL, 'Afro'),
  ('9-215-77489-0', 'Jak sobie pościelesz tym bardziej nosa zadziera', DATE '2013-07-27', 1, 47, 171.70, 'Weronika', 'Gradek', NULL, 'Kruca Fix'),
  ('6-308-51276-1', 'Jak sobie pościelesz tym wyżej głowę nosi', DATE '1996-11-08', 4, 62, 72.40, 'Jarosław', 'Hoser', NULL, 'Gambit Kaczmarkowski'),
  ('1-369-03403-2', 'Jak sobie pościelesz tym więcej chce', DATE '1917-12-30', 1, 48, 26.60, 'Jan', 'Krysicki', NULL, 'Podziemie'),
  ('6-183-59820-8', 'Jak sobie pościelesz tym spokojniej śpisz', DATE '1993-09-21', 1, 50, 54.60, 'Franciszek', 'Kamiński', NULL, 'Pies Filemon'),
  ('4-207-46849-8', 'Jak sobie pościelesz tym bardziej gryzie', DATE '1981-05-02', 3, 77, 82.80, 'Sandra', 'Kaczmarek', NULL, 'Kot Reksio'),
  ('2-996-65062-X', 'Jak sobie pościelesz tak cię cenią', DATE '1902-07-01', 3, 33, 94.40, 'Katarzyna', 'Wojciechowska', NULL, 'Afro'),
  ('4-440-69277-X', 'Jak sobie pościelesz kij się znajdzie', DATE '1912-02-27', 4, 27, 51.70, 'Paulina', 'Schmidt', NULL, 'Siedmiu Krasnoludków'),
  ('0-000-96668-1', 'Jak sobie pościelesz to się diabeł cieszy', DATE '1977-05-10', 2, 30, 23.90, 'Jacek', 'Kazimierczak', NULL, 'Loki'),
  ('3-148-34854-0', 'Jak sobie pościelesz tak się koniec grudnia nosi', DATE '1967-08-22', 1, 13, 86.70, 'Anna', 'Lewandowska', NULL, 'Extra Ciemne'),
  ('1-780-91261-7', 'Jak sobie pościelesz to się lubi co się ma', DATE '1974-06-06', 1, 79, 97.30, 'Iwona', 'Sejko', NULL, 'Babunia'),
  ('5-556-16499-1', 'Jak sobie pościelesz pora powiedzieć „b”', DATE '1928-10-11', 3, 38, 10.50, 'Małgorzata', 'Lewandowska', NULL, 'Siedmiu Krasnoludków'),
  ('7-767-03350-3', 'Jak sobie pościelesz to z dobrego konia', DATE '1901-11-07', 1, 59, 51.60, 'Kornel', 'Górski', NULL, 'Wesoła Szkoła'),
  ('9-483-67025-X', 'Jak sobie pościelesz to z dobrego konia', DATE '1974-09-18', 4, 24, 92.90, 'Jacek', 'Kowalski', NULL, 'WSSP'),
  ('1-015-00104-1', 'Jak sobie pościelesz temu czas', DATE '1927-07-03', 1, 41, 103.10, 'Dariusz', 'Woźniak', NULL, 'Wesoła Szkoła'),
  ('4-491-53370-9', 'Jak sobie pościelesz za przewodnika', DATE '1971-04-26', 3, 19, 65.10, 'Mateusz', 'Głowacka', NULL, 'Podziemie'),
  ('9-020-76489-6', 'Jak sobie pościelesz cygana powiesili', DATE '2005-11-30', 1, 17, 97.80, 'Grzegorz', 'Schmidt', NULL, 'Extra Ciemne'),
  ('6-815-72792-0', 'Jak sobie pościelesz oka nie wykole', DATE '1941-04-14', 1, 24, 27.90, 'Jan', 'Pupa', NULL, 'Loki'),
  ('8-897-87612-9', 'Jak sobie pościelesz mało mleka daje', DATE '1915-12-01', 1, 46, 95.30, 'Janusz', 'Woźniak', NULL, 'Kruti'),
  ('2-527-41538-5', 'Jak sobie pościelesz trochę zimy, trochę lata', DATE '1944-11-07', 4, 14, 169.20, 'Elżbieta', 'Gradek', NULL, 'Afro'),
  ('0-649-88716-6', 'Jak sobie pościelesz nie wart i kołacza', DATE '1904-10-13', 1, 62, 46.90, 'Brygida', 'Gradek', NULL, 'Kruti'),
  ('3-588-58790-X', 'Jak sobie pościelesz ponieśli i wilka', DATE '1697-10-03', 4, 45, 127.60, 'Rafał', 'Górski', NULL, 'Afro'),
  ('7-731-66647-6', 'Jak sobie pościelesz nikt nie wie', DATE '1937-09-26', 1, 30, 38.0, 'Zuzanna', 'Goldberg', NULL, 'Babunia'),
  ('1-380-25976-2', 'Jak spadać nie ma chatki', DATE '1951-01-14', 2, 25, 149.0, 'Adam', 'Gradek', NULL, 'Podziemie'),
  ('9-188-41144-3', 'Jak spadać że przymarznie cap do kozy', DATE '1623-10-03', 1, 58, 49.0, 'Brygida', 'Wojciechowska', NULL, 'Atakałke'),
  ('0-831-74274-7', 'Jak spadać ale na całe życie', DATE '1928-02-25', 1, 72, 67.90, 'Sandra', 'Hoser', NULL, 'Atakałke'),
  ('8-778-97929-3', 'Jak spadać póki jeszcze czas', DATE '1928-12-06', 1, 74, 61.10, 'Paulina', 'Gross', NULL, 'Babunia'),
  ('2-544-84155-9', 'Jak spadać byk się ocieli', DATE '1998-09-18', 3, 43, 72.30, 'Rafał', 'Gross', NULL, 'Babunia'),
  ('8-288-90566-8', 'Jak spadać to drugiemu niewola', DATE '1930-12-22', 1, 58, 65.70, 'Jan', 'Pupa', NULL, 'ASCT'),
  ('5-378-56134-5', 'Jak spadać to go nie minie', DATE '2015-12-22', 1, 29, 23.50, 'Hans', 'Totenbach', NULL, 'Babunia'),
  ('1-627-59328-4', 'Jak spadać to zima przejada', DATE '1926-04-14', 1, 71, 86.90, 'Bożydar', 'Sienkiewicz', NULL, 'Pies Filemon'),
  ('9-267-80527-4', 'Jak spadać dom wesołym czyni', DATE '1819-09-27', 1, 71, 67.60, 'Aleksandra', 'Gołąbek', NULL, 'Atakałke'),
  ('7-652-04483-9', 'Jak spadać wrócić ziarno na śniadanie', DATE '1942-05-29', 1, 40, 81.30, 'Grzegorz', 'Jaworski', NULL, 'Loki'),
  ('8-149-72524-5', 'Jak spadać jak się kto przepości', DATE '1740-11-08', 3, 50, 81.70, 'Filip', 'Nowakowski', NULL, 'Drux'),
  ('2-053-46707-X', 'Jak spadać pada aż do Zuzanny', DATE '1922-09-29', 1, 51, 65.20, 'Dariusz', 'Stępień', NULL, 'Babunia'),
  ('3-404-04470-3', 'Jak spadać znać jabłuszko na jabłoni', DATE '1995-12-02', 1, 29, 86.30, 'Maciek', 'Krysicki', NULL, 'Afro'),
  ('1-537-98192-7', 'Jak spadać jesień krótka, szybko mija', DATE '1943-06-03', 1, 56, 32.70, 'Zuzanna', 'Słowacka', NULL, 'Kruca Fix'),
  ('3-846-55104-X', 'Jak spadać to się diabeł cieszy', DATE '1902-12-17', 1, 43, 79.50, 'Henryk', 'Jaworski', NULL, 'Kruca Fix'),
  ('6-716-94533-4', 'Jak spadać zwykle nastaje posucha', DATE '1902-03-13', 1, 60, 103.30, 'Anna', 'Dura', NULL, 'Januszex'),
  ('3-431-49855-8', 'Jak spadać piekła nie ma', DATE '1910-05-04', 3, 38, 128.0, 'Mikołaj', 'Pupa', NULL, 'Babunia'),
  ('1-604-03055-0', 'Jak spadać piekło gore', DATE '2008-10-15', 1, 49, 61.0, 'Wiktor', 'Stępień', NULL, 'Kot Reksio'),
  ('6-224-65071-3', 'Jak spadać tym bardziej nosa zadziera', DATE '1879-11-16', 1, 43, 135.80, 'Agnieszka', 'Nowicka', NULL, 'GGWP'),
  ('2-241-22366-2', 'Jak spadać tym wyżej głowę nosi', DATE '1958-10-16', 1, 57, 107.20, 'Jarosław', 'Dębska', NULL, 'Babunia'),
  ('6-380-42405-9', 'Jak spadać tym więcej chce', DATE '1910-01-27', 1, 42, 121.70, 'Małgorzata', 'Klemens', NULL, 'WSSP'),
  ('7-405-57869-1', 'Jak spadać tym spokojniej śpisz', DATE '1998-10-14', 4, 27, 119.60, 'Jacek', 'Tyminśka', NULL, 'GGWP'),
  ('2-026-52167-0', 'Jak spadać tym bardziej gryzie', DATE '1967-02-13', 1, 37, 82.10, 'Bożydar', 'Jachowicz', NULL, 'Extra Ciemne'),
  ('5-571-59106-4', 'Jak spadać tak cię cenią', DATE '1948-04-06', 1, 41, 18.30, 'Tomasz', 'Majewski', NULL, 'Pies Filemon'),
  ('7-125-69252-4', 'Jak spadać kij się znajdzie', DATE '1988-03-25', 1, 15, 126.10, 'Bożydar', 'Malinowski', NULL, 'Extra Ciemne'),
  ('9-608-27075-8', 'Jak spadać to się diabeł cieszy', DATE '1360-02-28', 3, 28, 71.0, NULL, NULL, 'Współczesne rozwój', 'GGWP'),
  ('0-536-05767-2', 'Jak spadać tak się koniec grudnia nosi', DATE '1875-06-07', 1, 13, 19.90, 'Bartłomiej', 'Mazur', NULL, 'Podziemie'),
  ('2-400-02868-0', 'Jak spadać to się lubi co się ma', DATE '1935-11-17', 1, 57, 82.20, 'Grzegorz', 'Jaworski', NULL, 'Babunia'),
  ('7-258-29259-4', 'Jak spadać pora powiedzieć „b”', DATE '1997-08-20', 1, 47, 50.20, 'Kornel', 'Nowakowski', NULL, 'Januszex'),
  ('3-838-30008-4', 'Jak spadać to z dobrego konia', DATE '1919-03-13', 1, 79, 29.50, 'Karolina', 'Krysicka', NULL, 'Januszex'),
  ('7-388-71701-3', 'Jak spadać to z dobrego konia', DATE '1792-05-17', 1, 31, 56.50, 'Jan', 'Głowacka', NULL, 'Drux'),
  ('3-041-12492-0', 'Jak spadać temu czas', DATE '1948-06-25', 1, 54, 73.70, 'Katarzyna', 'Jachowicz', NULL, 'Kruca Fix'),
  ('7-068-60133-2', 'Jak spadać za przewodnika', DATE '1909-08-09', 1, 43, 140.80, 'Mateusz', 'Mazur', NULL, 'Januszex'),
  ('9-941-02262-3', 'Jak spadać cygana powiesili', DATE '1887-08-05', 1, 58, 117.60, 'Janusz', 'Tanenbaum', NULL, 'Gambit Kaczmarkowski'),
  ('7-589-08041-1', 'Jak spadać oka nie wykole', DATE '1964-04-28', 4, 42, 31.60, 'Elżbieta', 'Jaworska', NULL, 'Siedmiu Krasnoludków'),
  ('7-742-31030-9', 'Jak spadać mało mleka daje', DATE '1921-10-17', 1, 22, 57.60, 'Bożydar', 'Wojciechowski', NULL, 'Extra Ciemne'),
  ('5-563-63007-2', 'Jak spadać trochę zimy, trochę lata', DATE '1437-04-10', 1, 72, 42.30, 'Bożydar', 'Sienkiewicz', NULL, 'NGU'),
  ('3-680-23809-6', 'Jak spadać nie wart i kołacza', DATE '1953-10-14', 1, 24, 99.40, 'Karolina', 'Hoser', NULL, 'Drux'),
  ('6-982-73176-6', 'Jak spadać ponieśli i wilka', DATE '1985-07-17', 3, 61, 76.0, 'Alicja', 'Cebulska', NULL, 'Extra Ciemne'),
  ('7-171-65069-3', 'Jak spadać nikt nie wie', DATE '1951-09-16', 1, 54, 83.40, 'Henryk', 'Słowacki', NULL, 'Afro'),
  ('5-644-71762-3', 'Jak suka nie da nie ma chatki', DATE '1941-01-25', 1, 60, 26.10, 'Hans', 'Sienkiewicz', NULL, 'Afro'),
  ('6-396-94330-1', 'Jak suka nie da że przymarznie cap do kozy', DATE '1926-12-30', 1, 45, 37.60, 'Grzegorz', 'Schneider', NULL, 'Atakałke'),
  ('3-074-96982-2', 'Jak suka nie da ale na całe życie', DATE '1956-08-18', 1, 75, 135.30, 'Bartłomiej', 'Wojciechowski', NULL, 'Januszex'),
  ('2-634-28422-5', 'Jak suka nie da póki jeszcze czas', DATE '1830-07-12', 1, 66, 78.80, 'Hans', 'Goldberg', NULL, 'Pies Filemon'),
  ('3-133-77102-7', 'Jak suka nie da byk się ocieli', DATE '1952-11-29', 1, 26, 74.90, 'Jacek', 'Stępień', NULL, 'Januszex'),
  ('7-312-44470-9', 'Jak suka nie da to drugiemu niewola', DATE '1947-04-24', 1, 51, 19.70, 'Andrzej', 'Johansen', NULL, 'NGU'),
  ('6-283-25648-1', 'Jak suka nie da to go nie minie', DATE '1958-11-11', 1, 41, 27.30, 'Anna', 'Jaworska', NULL, 'Wesoła Szkoła'),
  ('2-441-43326-1', 'Jak suka nie da to zima przejada', DATE '1960-09-05', 1, 38, 37.30, 'Piotr', 'Malinowski', NULL, 'Loki'),
  ('7-720-25466-X', 'Jak suka nie da dom wesołym czyni', DATE '1963-09-14', 1, 36, 119.50, NULL, NULL, 'Związek Rybaków i Płetwonurków', 'Pies Filemon'),
  ('0-236-99561-8', 'Jak suka nie da wrócić ziarno na śniadanie', DATE '1982-07-03', 4, 41, 110.80, NULL, NULL, 'Związek Rybaków i Płetwonurków', 'Extra Ciemne'),
  ('9-153-31556-1', 'Jak suka nie da jak się kto przepości', DATE '1948-06-19', 3, 39, 173.20, 'Elżbieta', 'Nowakowska', NULL, 'Kruca Fix'),
  ('8-199-50203-7', 'Jak suka nie da pada aż do Zuzanny', DATE '1949-03-12', 1, 67, 81.40, NULL, NULL, 'Gazeta WMiI', 'Kot Reksio'),
  ('3-978-72801-X', 'Jak suka nie da znać jabłuszko na jabłoni', DATE '1999-06-13', 1, 68, 75.70, 'Hans', 'Gołąbek', NULL, 'NGU'),
  ('9-832-38329-3', 'Jak suka nie da jesień krótka, szybko mija', DATE '1987-10-01', 1, 35, 92.80, 'Piotr', 'Gradek', NULL, 'Extra Ciemne'),
  ('5-495-78422-7', 'Jak suka nie da to się diabeł cieszy', DATE '1957-10-14', 1, 60, 75.20, 'Andrzej', 'Nowak', NULL, 'Extra Ciemne'),
  ('0-091-36741-7', 'Jak suka nie da zwykle nastaje posucha', DATE '1981-09-14', 1, 71, 102.20, 'Weronika', 'Mełech', NULL, 'Extra Ciemne'),
  ('8-384-30375-4', 'Jak suka nie da piekła nie ma', DATE '1952-05-04', 1, 29, 131.70, 'Katarzyna', 'Schmidt', NULL, 'WSSP'),
  ('2-820-50354-3', 'Jak suka nie da piekło gore', DATE '1957-02-07', 2, 54, 10.0, 'Iwona', 'Neumann', NULL, 'Afro'),
  ('8-863-68390-5', 'Jak suka nie da tym bardziej nosa zadziera', DATE '1638-01-11', 1, 52, 49.40, 'Zuzanna', 'Kucharczyk', NULL, 'Pentakill'),
  ('2-515-59314-3', 'Jak suka nie da tym wyżej głowę nosi', DATE '1953-01-28', 1, 44, 121.20, NULL, NULL, 'TCS times', 'Kruti'),
  ('1-833-77540-6', 'Jak suka nie da tym więcej chce', DATE '1990-01-02', 1, 43, 68.50, 'Felicyta', 'Majewska', NULL, 'WSSP'),
  ('4-403-23176-4', 'Jak suka nie da tym spokojniej śpisz', DATE '1942-07-03', 1, 26, 51.70, 'Alicja', 'Kondratek', NULL, 'Kruca Fix'),
  ('7-391-33758-7', 'Jak suka nie da tym bardziej gryzie', DATE '1908-06-29', 1, 47, 97.10, 'Kornel', 'Dostojewski', NULL, 'Babunia'),
  ('5-703-69872-3', 'Jak suka nie da tak cię cenią', DATE '1967-06-29', 1, 54, 145.0, 'Sandra', 'Grabowska', NULL, 'Gambit Kaczmarkowski'),
  ('7-099-37752-3', 'Jak suka nie da kij się znajdzie', DATE '1952-12-20', 3, 37, 93.50, 'Kamila', 'Głowacka', NULL, 'Kot Reksio'),
  ('1-335-81670-4', 'Jak suka nie da to się diabeł cieszy', DATE '1974-06-07', 1, 61, 132.40, 'Aleksandra', 'Monarek', NULL, 'Loki'),
  ('1-592-40798-6', 'Jak suka nie da tak się koniec grudnia nosi', DATE '1920-05-08', 1, 46, 88.10, 'Maciek', 'Kowalski', NULL, 'Pies Filemon'),
  ('6-422-53755-7', 'Jak suka nie da to się lubi co się ma', DATE '1935-07-13', 4, 39, 49.80, 'Katarzyna', 'Dąbrowkska', NULL, 'Kruti'),
  ('9-997-85107-2', 'Jak suka nie da pora powiedzieć „b”', DATE '1963-07-25', 1, 54, 92.50, 'Joanna', 'Klemens', NULL, 'Pentakill'),
  ('9-059-74861-1', 'Jak suka nie da to z dobrego konia', DATE '1996-10-21', 1, 28, 76.90, 'Elżbieta', 'Malinowska', NULL, 'NGU'),
  ('5-816-61610-2', 'Jak suka nie da to z dobrego konia', DATE '1979-11-23', 2, 46, 184.40, 'Tomasz', 'Mazur', NULL, 'Pentakill'),
  ('1-400-37943-1', 'Jak suka nie da temu czas', DATE '1855-02-02', 1, 64, 59.10, 'Mateusz', 'Piotrowski', NULL, 'Atakałke'),
  ('2-921-75796-6', 'Jak suka nie da za przewodnika', DATE '2012-08-04', 1, 47, 65.90, 'Weronika', 'Zielińska', NULL, 'ASCT'),
  ('1-726-94847-1', 'Jak suka nie da cygana powiesili', DATE '1993-01-09', 1, 56, 38.90, 'Anna', 'Malinowska', NULL, 'ASCT'),
  ('8-147-95513-8', 'Jak suka nie da oka nie wykole', DATE '1919-04-11', 1, 37, 104.70, 'Jacek', 'Nowak', NULL, 'GGWP'),
  ('9-900-41308-3', 'Jak suka nie da mało mleka daje', DATE '2001-06-04', 1, 64, 43.40, 'Felicyta', 'Dura', NULL, 'Siedmiu Krasnoludków'),
  ('4-637-64666-9', 'Jak suka nie da trochę zimy, trochę lata', DATE '2001-10-09', 3, 50, 167.50, 'Agnieszka', 'Kowalska', NULL, 'Babunia'),
  ('3-582-14861-0', 'Jak suka nie da nie wart i kołacza', DATE '1932-07-13', 4, 48, 143.90, 'Sandra', 'Tanenbaum', NULL, 'Kot Reksio'),
  ('6-311-97809-1', 'Jak suka nie da ponieśli i wilka', DATE '1974-02-12', 1, 62, 33.60, 'Mateusz', 'Witkowski', NULL, 'NGU'),
  ('1-384-05928-8', 'Jak suka nie da nikt nie wie', DATE '1907-07-13', 1, 37, 76.60, 'Weronika', 'Filtz', NULL, 'Afro'),
  ('3-382-59535-4', 'Komu w drogę nie ma chatki', DATE '1902-11-11', 1, 39, 41.10, 'Jan', 'Kowalski', NULL, 'Extra Ciemne'),
  ('8-106-25917-X', 'Komu w drogę że przymarznie cap do kozy', DATE '1974-04-10', 2, 23, 3.70, 'Bożydar', 'Lewandowski', NULL, 'Siedmiu Krasnoludków'),
  ('3-515-61667-5', 'Komu w drogę ale na całe życie', DATE '1848-05-29', 4, 58, 99.70, 'Grzegorz', 'Słowacki', NULL, 'Babunia'),
  ('4-118-34361-4', 'Komu w drogę póki jeszcze czas', DATE '1907-07-21', 1, 45, 74.20, 'Tomasz', 'Zieliński', NULL, 'Podziemie'),
  ('1-001-54385-8', 'Komu w drogę byk się ocieli', DATE '2007-09-15', 1, 47, 26.10, 'Jacek', 'Wiśniewski', NULL, 'Januszex'),
  ('0-202-21422-2', 'Komu w drogę to drugiemu niewola', DATE '1933-02-07', 1, 35, 137.90, 'Zuzanna', 'Mełech', NULL, 'Wesoła Szkoła'),
  ('1-415-61765-1', 'Komu w drogę to go nie minie', DATE '1848-02-25', 2, 70, 22.60, 'Anna', 'Klemens', NULL, 'GGWP'),
  ('7-683-00915-6', 'Komu w drogę to zima przejada', DATE '1932-08-28', 1, 32, 107.50, 'Hans', 'Dura', NULL, 'Pies Filemon'),
  ('4-306-29302-5', 'Komu w drogę dom wesołym czyni', DATE '2000-02-05', 1, 22, 19.30, 'Paulina', 'Tanenbaum', NULL, 'Afro'),
  ('9-522-06724-5', 'Komu w drogę wrócić ziarno na śniadanie', DATE '1983-08-04', 1, 49, 5.80, 'Michał', 'Zieliński', NULL, 'Siedmiu Krasnoludków'),
  ('3-346-23168-2', 'Komu w drogę jak się kto przepości', DATE '1962-06-08', 1, 46, 29.50, 'Filip', 'Goldberg', NULL, 'Atakałke'),
  ('3-010-16354-1', 'Komu w drogę pada aż do Zuzanny', DATE '1956-07-27', 4, 34, 104.50, 'Andrzej', 'Klemens', NULL, 'Kruca Fix'),
  ('9-952-31263-6', 'Komu w drogę znać jabłuszko na jabłoni', DATE '1903-08-12', 2, 51, 95.90, 'Tomasz', 'Majewski', NULL, 'Drux'),
  ('5-454-74356-9', 'Komu w drogę jesień krótka, szybko mija', DATE '1988-05-17', 1, 30, 67.10, 'Brygida', 'Majewska', NULL, 'Drux'),
  ('0-088-85239-3', 'Komu w drogę to się diabeł cieszy', DATE '1913-04-27', 1, 69, 41.40, 'Dariusz', 'Pupa', NULL, 'Extra Ciemne'),
  ('9-189-80968-8', 'Komu w drogę zwykle nastaje posucha', DATE '1927-11-23', 1, 35, 132.30, 'Sandra', 'Kowalska', NULL, 'Podziemie'),
  ('3-387-59838-6', 'Komu w drogę piekła nie ma', DATE '2012-10-28', 1, 32, 139.30, 'Kamila', 'Grabowska', NULL, 'Loki'),
  ('5-159-81568-6', 'Komu w drogę piekło gore', DATE '1924-08-28', 1, 76, 36.40, 'Paweł', 'Klemens', NULL, 'Gambit Kaczmarkowski'),
  ('8-506-88759-3', 'Komu w drogę tym bardziej nosa zadziera', DATE '1976-01-29', 1, 71, 23.40, 'Aleksandra', 'Tanenbaum', NULL, 'Podziemie'),
  ('6-848-33451-0', 'Komu w drogę tym wyżej głowę nosi', DATE '2015-11-30', 1, 71, 26.0, 'Janusz', 'Nowak', NULL, 'Loki'),
  ('1-812-87036-1', 'Komu w drogę tym więcej chce', DATE '1956-11-03', 1, 37, 48.10, 'Aleksandra', 'Nowak', NULL, 'Podziemie'),
  ('5-406-81593-8', 'Komu w drogę tym spokojniej śpisz', DATE '1978-08-09', 4, 74, 104.40, 'Małgorzata', 'Mazur', NULL, 'Kruca Fix'),
  ('0-800-15714-1', 'Komu w drogę tym bardziej gryzie', DATE '1990-06-07', 3, 72, 63.60, 'Janusz', 'Kondratek', NULL, 'Pies Filemon'),
  ('2-616-93413-2', 'Komu w drogę tak cię cenią', DATE '1981-01-08', 4, 35, 80.50, NULL, NULL, 'TCS times', 'Kot Reksio'),
  ('3-896-29000-2', 'Komu w drogę kij się znajdzie', DATE '1972-02-06', 1, 49, 2.90, 'Paweł', 'Kamiński', NULL, 'Drux'),
  ('8-699-22948-8', 'Komu w drogę to się diabeł cieszy', DATE '1905-05-05', 1, 60, 157.40, 'Mateusz', 'Mazur', NULL, 'Januszex'),
  ('2-748-92691-9', 'Komu w drogę tak się koniec grudnia nosi', DATE '1719-09-13', 2, 32, 121.10, 'Małgorzata', 'Głowacka', NULL, 'WSSP'),
  ('6-866-68508-7', 'Komu w drogę to się lubi co się ma', DATE '1964-11-07', 1, 52, 41.60, 'Rafał', 'Hoser', NULL, 'Kruca Fix'),
  ('3-386-54712-5', 'Komu w drogę pora powiedzieć „b”', DATE '1870-11-17', 1, 52, 102.20, 'Zuzanna', 'Majewska', NULL, 'Kruca Fix'),
  ('2-645-90098-4', 'Komu w drogę to z dobrego konia', DATE '1936-04-30', 1, 43, 139.30, 'Bożydar', 'Dudek', NULL, 'Pentakill'),
  ('7-132-05072-9', 'Komu w drogę to z dobrego konia', DATE '1941-06-21', 3, 44, 14.60, 'Piotr', 'Stępień', NULL, 'Podziemie'),
  ('8-388-65999-5', 'Komu w drogę temu czas', DATE '1922-02-25', 1, 43, 172.70, 'Grzegorz', 'Dąbrowkski', NULL, 'Pentakill'),
  ('2-139-93471-7', 'Komu w drogę za przewodnika', DATE '1961-01-22', 1, 61, 102.40, 'Łukasz', 'Grabowski', NULL, 'Januszex'),
  ('0-696-51702-7', 'Komu w drogę cygana powiesili', DATE '1903-08-23', 1, 75, 61.40, 'Michał', 'Totenbach', NULL, 'WSSP'),
  ('9-424-52141-3', 'Komu w drogę oka nie wykole', DATE '1904-05-29', 1, 51, 8.90, 'Piotr', 'Kaczmarek', NULL, 'Kruti'),
  ('7-790-78493-5', 'Komu w drogę mało mleka daje', DATE '1991-05-02', 1, 44, 128.20, 'Kamila', 'Adamczyk', NULL, 'Loki'),
  ('4-134-61353-1', 'Komu w drogę trochę zimy, trochę lata', DATE '1946-06-22', 1, 20, 73.70, 'Jakub', 'Głowacka', NULL, 'Kruti'),
  ('0-769-30076-6', 'Komu w drogę nie wart i kołacza', DATE '1996-09-03', 1, 35, 58.40, 'Elżbieta', 'Sejko', NULL, 'WSSP'),
  ('9-130-86965-X', 'Komu w drogę ponieśli i wilka', DATE '1928-11-21', 1, 66, 173.10, 'Wiktor', 'Schneider', NULL, 'Drux'),
  ('4-656-76928-2', 'Komu w drogę nikt nie wie', DATE '1970-10-25', 2, 32, 95.70, 'Iwona', 'Cebulska', NULL, 'Kruca Fix'),
  ('0-263-52200-8', 'Koniec języka nie ma chatki', DATE '1480-08-17', 1, 24, 114.80, 'Felicyta', 'Woźniak', NULL, 'Gambit Kaczmarkowski'),
  ('0-785-61844-9', 'Koniec języka że przymarznie cap do kozy', DATE '1920-09-06', 1, 62, 101.70, 'Anna', 'Kazimierczak', NULL, 'Wesoła Szkoła'),
  ('9-758-68763-8', 'Koniec języka ale na całe życie', DATE '2013-10-30', 4, 30, 33.20, 'Agnieszka', 'Głowacka', NULL, 'Babunia'),
  ('6-130-62932-X', 'Koniec języka póki jeszcze czas', DATE '1999-06-03', 1, 33, 122.10, 'Mateusz', 'Grabowski', NULL, 'Drux'),
  ('2-549-12363-8', 'Koniec języka byk się ocieli', DATE '1930-05-03', 1, 28, 32.60, 'Janusz', 'Nowak', NULL, 'Pentakill'),
  ('1-301-84824-7', 'Koniec języka to drugiemu niewola', DATE '1973-04-08', 4, 36, 86.40, 'Felicyta', 'Wojciechowska', NULL, 'ASCT'),
  ('1-297-32053-0', 'Koniec języka to go nie minie', DATE '1968-10-07', 3, 40, 171.50, 'Mikołaj', 'Nowak', NULL, 'Drux'),
  ('1-152-58446-4', 'Koniec języka to zima przejada', DATE '1966-01-01', 1, 50, 114.60, 'Łukasz', 'Dąbrowkski', NULL, 'Extra Ciemne'),
  ('0-843-86768-X', 'Koniec języka dom wesołym czyni', DATE '2008-10-04', 1, 42, 27.80, 'Janusz', 'Johansen', NULL, 'Babunia'),
  ('1-746-54710-3', 'Koniec języka wrócić ziarno na śniadanie', DATE '1941-12-26', 1, 73, 37.30, 'Jan', 'Nowak', NULL, 'Loki'),
  ('6-376-58697-X', 'Koniec języka jak się kto przepości', DATE '1902-07-27', 1, 58, 34.60, 'Joanna', 'Kostrikin', NULL, 'Afro'),
  ('1-104-76045-2', 'Koniec języka pada aż do Zuzanny', DATE '1934-06-28', 4, 31, 60.90, 'Henryk', 'Kazimierczak', NULL, 'Drux'),
  ('9-348-85102-0', 'Koniec języka znać jabłuszko na jabłoni', DATE '1977-03-24', 1, 49, 20.50, 'Zuzanna', 'Filtz', NULL, 'Pentakill'),
  ('0-367-48086-7', 'Koniec języka jesień krótka, szybko mija', DATE '1912-06-12', 2, 37, 112.90, 'Michał', 'Tanenbaum', NULL, 'NGU'),
  ('0-227-04281-6', 'Koniec języka to się diabeł cieszy', DATE '1940-05-27', 1, 53, 114.20, 'Mateusz', 'Sienkiewicz', NULL, 'Pies Filemon'),
  ('7-869-76113-3', 'Koniec języka zwykle nastaje posucha', DATE '1996-04-03', 1, 76, 38.80, 'Wiktor', 'Piotrowski', NULL, 'Extra Ciemne'),
  ('3-935-10572-X', 'Koniec języka piekła nie ma', DATE '1921-12-29', 1, 22, 123.80, 'Szymon', 'Woźniak', NULL, 'Pentakill'),
  ('5-206-43880-4', 'Koniec języka piekło gore', DATE '1635-06-28', 4, 58, 16.70, 'Elżbieta', 'Nowak', NULL, 'Loki'),
  ('0-324-37656-1', 'Koniec języka tym bardziej nosa zadziera', DATE '1999-09-24', 1, 64, 60.0, NULL, NULL, 'Panowie Z Drugiej Ławki', 'Podziemie'),
  ('1-298-74126-2', 'Koniec języka tym wyżej głowę nosi', DATE '1945-11-04', 2, 22, 12.90, 'Michał', 'Sejko', NULL, 'Kruti'),
  ('5-901-83374-0', 'Koniec języka tym więcej chce', DATE '1931-09-11', 1, 31, 78.60, 'Franciszek', 'Majewski', NULL, 'Siedmiu Krasnoludków'),
  ('4-371-86494-5', 'Koniec języka tym spokojniej śpisz', DATE '2003-10-05', 2, 37, 16.40, 'Andrzej', 'Dura', NULL, 'Pentakill'),
  ('5-940-08471-0', 'Koniec języka tym bardziej gryzie', DATE '1926-08-25', 1, 61, 54.70, 'Franciszek', 'Dębska', NULL, 'Pentakill'),
  ('7-927-89949-X', 'Koniec języka tak cię cenią', DATE '1906-04-29', 2, 64, 138.80, 'Aleksandra', 'Kaczmarek', NULL, 'WSSP'),
  ('0-657-94934-5', 'Koniec języka kij się znajdzie', DATE '1976-08-17', 1, 61, 38.10, 'Iwona', 'Krysicka', NULL, 'Januszex'),
  ('5-221-34904-3', 'Koniec języka to się diabeł cieszy', DATE '1810-02-04', 1, 36, 173.80, 'Agnieszka', 'Jachowicz', NULL, 'Siedmiu Krasnoludków'),
  ('2-195-34977-8', 'Koniec języka tak się koniec grudnia nosi', DATE '1922-07-16', 3, 47, 13.90, 'Sandra', 'Helik', NULL, 'Drux'),
  ('8-009-14212-3', 'Koniec języka to się lubi co się ma', DATE '1997-02-18', 1, 18, 116.40, 'Bartłomiej', 'Hoser', NULL, 'Drux'),
  ('1-371-75106-4', 'Koniec języka pora powiedzieć „b”', DATE '1978-08-14', 1, 60, 51.80, 'Joanna', 'Krysicka', NULL, 'Drux'),
  ('8-355-98969-4', 'Koniec języka to z dobrego konia', DATE '2005-11-21', 1, 34, 98.70, NULL, NULL, 'Koło Taniego Czyszczenia i Sprzątania', 'Kruca Fix'),
  ('0-922-45072-2', 'Koniec języka to z dobrego konia', DATE '1942-12-13', 1, 18, 95.40, 'Kamila', 'Mickiewicz', NULL, 'Siedmiu Krasnoludków'),
  ('4-533-54488-6', 'Koniec języka temu czas', DATE '1991-05-07', 4, 70, 103.70, NULL, NULL, 'Związek Rybaków i Płetwonurków', 'NGU'),
  ('2-523-33987-0', 'Koniec języka za przewodnika', DATE '1904-08-29', 1, 52, 37.40, NULL, NULL, 'Uniwersytet Koloni Krężnej', 'WSSP'),
  ('6-144-88930-2', 'Koniec języka cygana powiesili', DATE '1900-09-04', 1, 54, 87.80, 'Franciszek', 'Wojciechowski', NULL, 'Pentakill'),
  ('6-443-72446-1', 'Koniec języka oka nie wykole', DATE '1944-10-14', 1, 74, 27.70, 'Andrzej', 'Głowacka', NULL, 'GGWP'),
  ('7-566-83046-5', 'Koniec języka mało mleka daje', DATE '1920-09-15', 1, 74, 54.20, 'Łukasz', 'Dostojewski', NULL, 'GGWP'),
  ('2-037-02498-3', 'Koniec języka trochę zimy, trochę lata', DATE '2000-09-08', 4, 31, 24.30, 'Jacek', 'Kaczmarek', NULL, 'Extra Ciemne'),
  ('0-022-04454-X', 'Koniec języka nie wart i kołacza', DATE '1947-05-26', 1, 73, 80.60, 'Dariusz', 'Dura', NULL, 'Wesoła Szkoła'),
  ('9-403-00523-8', 'Koniec języka ponieśli i wilka', DATE '1998-08-30', 1, 47, 28.40, 'Bartłomiej', 'Malinowski', NULL, 'GGWP'),
  ('1-123-72777-5', 'Koniec języka nikt nie wie', DATE '2014-11-12', 1, 57, 37.10, 'Jarosław', 'Kamiński', NULL, 'Atakałke'),
  ('1-961-37562-1', 'Kowal zawinił nie ma chatki', DATE '1962-02-28', 2, 41, 111.40, 'Kamila', 'Kowalska', NULL, 'Kruti'),
  ('8-191-30003-6', 'Kowal zawinił że przymarznie cap do kozy', DATE '1963-04-05', 1, 10, 5.70, 'Henryk', 'Głowacka', NULL, 'Kruca Fix'),
  ('5-777-70694-0', 'Kowal zawinił ale na całe życie', DATE '2003-03-12', 1, 62, 111.30, 'Brygida', 'Tanenbaum', NULL, 'Atakałke'),
  ('4-613-78266-X', 'Kowal zawinił póki jeszcze czas', DATE '1919-09-10', 1, 34, 141.60, NULL, NULL, 'Encylopedia Informatyki', 'Kruca Fix'),
  ('9-994-02083-8', 'Kowal zawinił byk się ocieli', DATE '1978-10-20', 4, 59, 78.70, NULL, NULL, 'Wsród Matematyki', 'Loki'),
  ('8-354-48339-8', 'Kowal zawinił to drugiemu niewola', DATE '1963-02-10', 1, 29, 49.80, 'Małgorzata', 'Wiśniewska', NULL, 'Januszex'),
  ('8-740-34688-9', 'Kowal zawinił to go nie minie', DATE '1972-02-12', 2, 52, 135.50, 'Jacek', 'Nowicki', NULL, 'ASCT'),
  ('0-120-23863-2', 'Kowal zawinił to zima przejada', DATE '1964-04-14', 2, 72, 66.70, 'Mateusz', 'Hoser', NULL, 'Loki'),
  ('4-283-99729-3', 'Kowal zawinił dom wesołym czyni', DATE '1973-08-05', 1, 18, 41.10, 'Sandra', 'Witkowska', NULL, 'Loki'),
  ('8-775-63077-X', 'Kowal zawinił wrócić ziarno na śniadanie', DATE '1914-03-10', 1, 19, 150.10, 'Karolina', 'Schneider', NULL, 'Kruti'),
  ('6-143-75272-9', 'Kowal zawinił jak się kto przepości', DATE '1960-01-22', 1, 38, 168.0, 'Janusz', 'Górski', NULL, 'Drux'),
  ('2-998-67130-6', 'Kowal zawinił pada aż do Zuzanny', DATE '2012-10-17', 1, 25, 64.90, 'Bartłomiej', 'Mazur', NULL, 'Siedmiu Krasnoludków'),
  ('2-254-47338-7', 'Kowal zawinił znać jabłuszko na jabłoni', DATE '1777-02-21', 1, 76, 179.60, 'Grzegorz', 'Dostojewski', NULL, 'Pies Filemon'),
  ('4-540-28372-3', 'Kowal zawinił jesień krótka, szybko mija', DATE '1941-12-16', 1, 48, 89.50, 'Henryk', 'Adamczyk', NULL, 'Kruti'),
  ('6-695-76136-1', 'Kowal zawinił to się diabeł cieszy', DATE '1959-12-04', 1, 32, 161.0, 'Alicja', 'Grabowska', NULL, 'Gambit Kaczmarkowski'),
  ('5-117-08395-4', 'Kowal zawinił zwykle nastaje posucha', DATE '1901-03-26', 2, 25, 12.60, 'Anna', 'Sienkiewicz', NULL, 'Wesoła Szkoła'),
  ('7-735-20647-X', 'Kowal zawinił piekła nie ma', DATE '1978-05-17', 4, 71, 20.10, 'Filip', 'Mickiewicz', NULL, 'Podziemie'),
  ('2-410-58985-5', 'Kowal zawinił piekło gore', DATE '1944-08-10', 1, 46, 90.90, 'Weronika', 'Woźniak', NULL, 'Januszex'),
  ('2-697-51183-0', 'Kowal zawinił tym bardziej nosa zadziera', DATE '1924-11-08', 2, 37, 166.90, 'Kamila', 'Gołąbek', NULL, 'Drux'),
  ('5-552-09196-5', 'Kowal zawinił tym wyżej głowę nosi', DATE '1616-12-02', 3, 64, 15.40, 'Elżbieta', 'Wiśniewska', NULL, 'ASCT'),
  ('2-812-26801-8', 'Kowal zawinił tym więcej chce', DATE '1999-09-12', 1, 48, 108.70, 'Paulina', 'Kucharczyk', NULL, 'Wesoła Szkoła'),
  ('0-087-93705-0', 'Kowal zawinił tym spokojniej śpisz', DATE '1956-02-12', 1, 36, 69.10, NULL, NULL, 'Związek Rybaków i Płetwonurków', 'Gambit Kaczmarkowski'),
  ('4-180-23242-1', 'Kowal zawinił tym bardziej gryzie', DATE '1935-06-19', 1, 55, 186.50, 'Bartłomiej', 'Nowak', NULL, 'Afro'),
  ('5-249-49021-2', 'Kowal zawinił tak cię cenią', DATE '1918-03-25', 1, 40, 29.30, 'Zuzanna', 'Nowakowska', NULL, 'Siedmiu Krasnoludków'),
  ('6-495-34905-X', 'Kowal zawinił kij się znajdzie', DATE '2001-08-30', 1, 40, 92.20, 'Jacek', 'Nowakowski', NULL, 'NGU'),
  ('9-095-95101-4', 'Kowal zawinił to się diabeł cieszy', DATE '1912-07-08', 1, 75, 103.10, 'Alicja', 'Piotrowska', NULL, 'Kot Reksio'),
  ('1-995-99506-1', 'Kowal zawinił tak się koniec grudnia nosi', DATE '1986-08-18', 1, 37, 31.70, 'Rafał', 'Dudek', NULL, 'Afro'),
  ('3-076-28524-6', 'Kowal zawinił to się lubi co się ma', DATE '1196-12-27', 2, 34, 97.90, 'Sandra', 'Malinowska', NULL, 'Afro'),
  ('7-663-31517-0', 'Kowal zawinił pora powiedzieć „b”', DATE '1989-07-21', 1, 33, 27.70, 'Alicja', 'Cebulska', NULL, 'Atakałke'),
  ('3-098-46601-4', 'Kowal zawinił to z dobrego konia', DATE '1975-12-19', 1, 47, 161.0, 'Jarosław', 'Helik', NULL, 'Gambit Kaczmarkowski'),
  ('8-748-29819-0', 'Kowal zawinił to z dobrego konia', DATE '1992-12-09', 1, 42, 127.50, 'Andrzej', 'Jaworski', NULL, 'Pentakill'),
  ('7-761-57015-9', 'Kowal zawinił temu czas', DATE '1922-10-15', 1, 65, 147.40, 'Franciszek', 'Gross', NULL, 'Extra Ciemne'),
  ('8-987-46629-9', 'Kowal zawinił za przewodnika', DATE '1981-08-07', 1, 29, 43.20, 'Brygida', 'Mickiewicz', NULL, 'ASCT'),
  ('6-983-66375-6', 'Kowal zawinił cygana powiesili', DATE '2011-01-23', 1, 60, 70.60, 'Maciek', 'Gross', NULL, 'Atakałke'),
  ('4-999-66059-8', 'Kowal zawinił oka nie wykole', DATE '1858-03-17', 1, 44, 122.60, 'Katarzyna', 'Kamińska', NULL, 'Siedmiu Krasnoludków'),
  ('8-492-76185-7', 'Kowal zawinił mało mleka daje', DATE '1980-03-14', 1, 66, 51.60, 'Katarzyna', 'Dostojewska', NULL, 'GGWP'),
  ('9-127-43145-2', 'Kowal zawinił trochę zimy, trochę lata', DATE '1990-07-30', 2, 28, 32.20, 'Brygida', 'Głowacka', NULL, 'Drux'),
  ('3-189-27064-3', 'Kowal zawinił nie wart i kołacza', DATE '1995-07-24', 1, 38, 65.0, 'Michał', 'Gross', NULL, 'Kruti'),
  ('6-850-78189-8', 'Kowal zawinił ponieśli i wilka', DATE '1927-03-22', 1, 32, 48.80, 'Dariusz', 'Nowicki', NULL, 'Wesoła Szkoła'),
  ('1-256-22674-2', 'Kowal zawinił nikt nie wie', DATE '1404-01-02', 1, 37, 55.0, 'Bożydar', 'Grabowski', NULL, 'Januszex'),
  ('1-364-00866-1', 'Kruk krukowi nie ma chatki', DATE '1950-01-25', 1, 31, 46.90, NULL, NULL, 'Koło Taniego Czyszczenia i Sprzątania', 'Siedmiu Krasnoludków'),
  ('2-081-53599-8', 'Kruk krukowi że przymarznie cap do kozy', DATE '1951-12-28', 1, 51, 83.20, 'Anna', 'Tanenbaum', NULL, 'Januszex'),
  ('6-443-66560-0', 'Kruk krukowi ale na całe życie', DATE '1995-08-05', 1, 65, 64.70, 'Bartłomiej', 'Nowicki', NULL, 'Drux'),
  ('6-620-90655-9', 'Kruk krukowi póki jeszcze czas', DATE '2001-05-20', 4, 31, 50.40, 'Agnieszka', 'Totenbach', NULL, 'Kruti'),
  ('3-615-69401-5', 'Kruk krukowi byk się ocieli', DATE '1972-04-21', 1, 37, 80.70, 'Zuzanna', 'Klemens', NULL, 'Kot Reksio'),
  ('3-242-27035-5', 'Kruk krukowi to drugiemu niewola', DATE '1922-08-01', 1, 60, 64.50, NULL, NULL, 'Uniwersytet Koloni Krężnej', 'Atakałke'),
  ('0-253-43667-2', 'Kruk krukowi to go nie minie', DATE '1908-04-11', 4, 63, 52.60, 'Henryk', 'Piotrowski', NULL, 'WSSP'),
  ('8-937-13986-3', 'Kruk krukowi to zima przejada', DATE '1945-08-04', 1, 73, 149.40, 'Andrzej', 'Dudek', NULL, 'Loki'),
  ('3-399-89816-9', 'Kruk krukowi dom wesołym czyni', DATE '1976-10-25', 1, 35, 46.90, 'Jakub', 'Głowacka', NULL, 'Extra Ciemne'),
  ('7-522-76587-0', 'Kruk krukowi wrócić ziarno na śniadanie', DATE '2005-10-20', 2, 70, 152.10, NULL, NULL, 'Piąta Ściana', 'Babunia'),
  ('8-706-38680-6', 'Kruk krukowi jak się kto przepości', DATE '1991-07-05', 4, 28, 132.30, 'Dariusz', 'Kowalski', NULL, 'Babunia'),
  ('0-249-32960-3', 'Kruk krukowi pada aż do Zuzanny', DATE '1928-05-21', 1, 49, 71.0, 'Filip', 'Nowak', NULL, 'GGWP'),
  ('1-688-50299-8', 'Kruk krukowi znać jabłuszko na jabłoni', DATE '1997-07-05', 4, 69, 44.50, 'Brygida', 'Schmidt', NULL, 'Drux'),
  ('3-933-74054-1', 'Kruk krukowi jesień krótka, szybko mija', DATE '2007-04-07', 1, 22, 26.0, 'Franciszek', 'Grabowski', NULL, 'Afro'),
  ('5-357-40674-X', 'Kruk krukowi to się diabeł cieszy', DATE '1983-09-21', 1, 6, 34.50, 'Wiktor', 'Adamczyk', NULL, 'Extra Ciemne'),
  ('7-734-38805-1', 'Kruk krukowi zwykle nastaje posucha', DATE '1772-10-19', 1, 13, 38.50, NULL, NULL, 'FAKTCS', 'Babunia'),
  ('1-863-93266-6', 'Kruk krukowi piekła nie ma', DATE '2003-05-16', 1, 48, 24.0, 'Kornel', 'Klemens', NULL, 'Babunia'),
  ('6-927-13798-X', 'Kruk krukowi piekło gore', DATE '1942-10-02', 1, 39, 79.30, 'Michał', 'Malinowski', NULL, 'Drux'),
  ('2-817-10957-0', 'Kruk krukowi tym bardziej nosa zadziera', DATE '1940-04-12', 3, 61, 117.30, 'Franciszek', 'Krysicki', NULL, 'Gambit Kaczmarkowski'),
  ('9-942-36046-8', 'Kruk krukowi tym wyżej głowę nosi', DATE '1926-10-18', 1, 49, 89.60, 'Wiktor', 'Sienkiewicz', NULL, 'Pentakill'),
  ('4-021-01275-3', 'Kruk krukowi tym więcej chce', DATE '1917-12-27', 1, 30, 102.10, 'Paweł', 'Górski', NULL, 'Babunia'),
  ('3-212-67210-2', 'Kruk krukowi tym spokojniej śpisz', DATE '1966-11-03', 4, 61, 82.60, 'Brygida', 'Mickiewicz', NULL, 'Gambit Kaczmarkowski'),
  ('7-265-11743-3', 'Kruk krukowi tym bardziej gryzie', DATE '1907-03-09', 1, 62, 23.40, 'Jan', 'Kucharczyk', NULL, 'Siedmiu Krasnoludków'),
  ('9-346-03088-7', 'Kruk krukowi tak cię cenią', DATE '1989-08-08', 1, 64, 41.70, 'Dariusz', 'Tanenbaum', NULL, 'Loki'),
  ('0-648-65303-X', 'Kruk krukowi kij się znajdzie', DATE '1931-05-03', 1, 55, 40.80, 'Elżbieta', 'Kaczmarek', NULL, 'Kot Reksio'),
  ('5-506-42510-4', 'Kruk krukowi to się diabeł cieszy', DATE '1938-01-24', 1, 64, 148.0, 'Tomasz', 'Piotrowski', NULL, 'Wesoła Szkoła'),
  ('4-457-52478-6', 'Kruk krukowi tak się koniec grudnia nosi', DATE '1823-04-15', 1, 40, 159.90, 'Alicja', 'Pupa', NULL, 'Gambit Kaczmarkowski'),
  ('6-127-68117-0', 'Kruk krukowi to się lubi co się ma', DATE '1931-10-14', 1, 27, 33.70, 'Małgorzata', 'Bobak', NULL, 'Atakałke'),
  ('4-254-62789-0', 'Kruk krukowi pora powiedzieć „b”', DATE '1968-05-14', 1, 20, 146.50, 'Brygida', 'Klemens', NULL, 'Podziemie'),
  ('0-461-30394-9', 'Kruk krukowi to z dobrego konia', DATE '1973-07-10', 1, 36, 5.60, NULL, NULL, 'Związek Rybaków i Płetwonurków', 'Podziemie'),
  ('7-278-80826-X', 'Kruk krukowi to z dobrego konia', DATE '1984-07-16', 3, 59, 75.40, 'Aleksandra', 'Schmidt', NULL, 'Loki'),
  ('9-384-57845-2', 'Kruk krukowi temu czas', DATE '1978-04-12', 1, 77, 57.50, 'Łukasz', 'Kowalski', NULL, 'GGWP'),
  ('2-810-01307-1', 'Kruk krukowi za przewodnika', DATE '1939-12-07', 4, 39, 59.70, 'Aleksandra', 'Głowacka', NULL, 'Babunia'),
  ('2-080-02034-X', 'Kruk krukowi cygana powiesili', DATE '1980-02-08', 1, 47, 71.50, 'Katarzyna', 'Filtz', NULL, 'GGWP'),
  ('4-321-96396-6', 'Kruk krukowi oka nie wykole', DATE '1917-01-23', 2, 39, 87.70, 'Maciek', 'Kazimierczak', NULL, 'Kot Reksio'),
  ('9-931-37570-1', 'Kruk krukowi mało mleka daje', DATE '1997-08-24', 1, 67, 110.90, 'Szymon', 'Schneider', NULL, 'NGU'),
  ('2-817-70804-0', 'Kruk krukowi trochę zimy, trochę lata', DATE '1957-06-19', 3, 69, 75.40, 'Kornel', 'Nowicki', NULL, 'Kruca Fix'),
  ('6-720-36846-X', 'Kruk krukowi nie wart i kołacza', DATE '1935-01-10', 1, 64, 90.90, 'Elżbieta', 'Bobak', NULL, 'Extra Ciemne'),
  ('8-203-28068-4', 'Kruk krukowi ponieśli i wilka', DATE '1801-05-20', 2, 28, 34.10, 'Jacek', 'Jachowicz', NULL, 'Atakałke'),
  ('9-629-52456-2', 'Kruk krukowi nikt nie wie', DATE '2013-07-05', 1, 39, 66.0, 'Bartłomiej', 'Piotrowski', NULL, 'Pentakill'),
  ('3-466-47289-X', 'Krowa, która dużo ryczy nie ma chatki', DATE '1988-08-23', 1, 24, 85.10, 'Piotr', 'Klemens', NULL, 'Kruti'),
  ('8-213-46034-0', 'Krowa, która dużo ryczy że przymarznie cap do kozy', DATE '2000-11-13', 1, 60, 150.70, 'Łukasz', 'Pupa', NULL, 'Siedmiu Krasnoludków'),
  ('7-263-25530-8', 'Krowa, która dużo ryczy ale na całe życie', DATE '1969-03-25', 1, 54, 60.0, 'Rafał', 'Gołąbek', NULL, 'Atakałke'),
  ('0-995-16909-8', 'Krowa, która dużo ryczy póki jeszcze czas', DATE '1801-12-08', 3, 34, 140.0, 'Piotr', 'Mickiewicz', NULL, 'NGU'),
  ('0-845-56463-3', 'Krowa, która dużo ryczy byk się ocieli', DATE '1992-11-11', 1, 40, 56.20, 'Katarzyna', 'Jaworska', NULL, 'Drux'),
  ('9-266-88643-2', 'Krowa, która dużo ryczy to drugiemu niewola', DATE '1950-04-12', 1, 42, 64.40, 'Jan', 'Adamczyk', NULL, 'ASCT'),
  ('5-876-28006-2', 'Krowa, która dużo ryczy to go nie minie', DATE '1958-09-07', 1, 49, 28.0, 'Mateusz', 'Bobak', NULL, 'Kruti'),
  ('3-714-46415-8', 'Krowa, która dużo ryczy to zima przejada', DATE '2013-12-06', 1, 76, 81.0, 'Małgorzata', 'Pupa', NULL, 'Atakałke'),
  ('9-771-52168-3', 'Krowa, która dużo ryczy dom wesołym czyni', DATE '2003-12-14', 1, 41, 116.0, NULL, NULL, 'Dreamteam', 'Podziemie'),
  ('9-281-06095-7', 'Krowa, która dużo ryczy wrócić ziarno na śniadanie', DATE '1931-07-26', 2, 32, 47.0, 'Agnieszka', 'Majewska', NULL, 'Pentakill'),
  ('3-717-30924-2', 'Krowa, która dużo ryczy jak się kto przepości', DATE '2008-07-22', 1, 42, 101.40, 'Janusz', 'Majewski', NULL, 'Babunia'),
  ('1-605-65373-X', 'Krowa, która dużo ryczy pada aż do Zuzanny', DATE '1984-11-21', 3, 24, 105.30, 'Małgorzata', 'Kowalska', NULL, 'Afro'),
  ('8-905-03321-0', 'Krowa, która dużo ryczy znać jabłuszko na jabłoni', DATE '1363-09-30', 1, 59, 143.50, 'Agnieszka', 'Grabowska', NULL, 'Babunia'),
  ('4-165-96711-4', 'Krowa, która dużo ryczy jesień krótka, szybko mija', DATE '1943-10-04', 1, 83, 113.60, 'Hans', 'Dura', NULL, 'ASCT'),
  ('9-489-84060-2', 'Krowa, która dużo ryczy to się diabeł cieszy', DATE '1974-08-27', 1, 19, 108.60, NULL, NULL, 'Piąta Ściana', 'Afro'),
  ('1-005-22462-5', 'Krowa, która dużo ryczy zwykle nastaje posucha', DATE '1777-10-24', 1, 33, 120.30, 'Maciek', 'Górski', NULL, 'Siedmiu Krasnoludków'),
  ('1-127-06701-X', 'Krowa, która dużo ryczy piekła nie ma', DATE '2010-06-08', 1, 48, 52.80, NULL, NULL, 'Panowie Z Drugiej Ławki', 'Podziemie'),
  ('1-264-42676-3', 'Krowa, która dużo ryczy piekło gore', DATE '1911-05-09', 2, 64, 26.50, 'Brygida', 'Goldberg', NULL, 'WSSP'),
  ('6-296-33899-6', 'Krowa, która dużo ryczy tym bardziej nosa zadziera', DATE '1662-08-05', 1, 20, 54.80, 'Sandra', 'Grabowska', NULL, 'Afro'),
  ('6-131-59675-1', 'Krowa, która dużo ryczy tym wyżej głowę nosi', DATE '1996-08-26', 2, 41, 86.10, 'Adam', 'Kondratek', NULL, 'Kruti'),
  ('6-174-46579-9', 'Krowa, która dużo ryczy tym więcej chce', DATE '1948-02-12', 1, 73, 99.40, 'Felicyta', 'Kamińska', NULL, 'Pentakill'),
  ('1-314-17503-3', 'Krowa, która dużo ryczy tym spokojniej śpisz', DATE '1908-03-19', 1, 82, 132.0, 'Joanna', 'Tyminśka', NULL, 'ASCT'),
  ('3-998-32246-9', 'Krowa, która dużo ryczy tym bardziej gryzie', DATE '1934-04-16', 1, 14, 133.10, 'Piotr', 'Lewandowski', NULL, 'WSSP'),
  ('8-229-27036-8', 'Krowa, która dużo ryczy tak cię cenią', DATE '1934-05-27', 4, 15, 44.70, 'Karolina', 'Nowakowska', NULL, 'Siedmiu Krasnoludków'),
  ('2-059-43282-0', 'Krowa, która dużo ryczy kij się znajdzie', DATE '1920-06-11', 1, 48, 103.10, 'Szymon', 'Homoncik', NULL, 'Gambit Kaczmarkowski'),
  ('8-485-12762-5', 'Krowa, która dużo ryczy to się diabeł cieszy', DATE '1937-07-01', 1, 39, 75.20, NULL, NULL, 'TCS times', 'WSSP'),
  ('5-361-78137-1', 'Krowa, która dużo ryczy tak się koniec grudnia nosi', DATE '1920-06-14', 1, 44, 64.90, 'Piotr', 'Gołąbek', NULL, 'Kot Reksio'),
  ('7-948-01382-2', 'Krowa, która dużo ryczy to się lubi co się ma', DATE '1923-04-27', 1, 57, 76.10, 'Filip', 'Kaczmarek', NULL, 'NGU'),
  ('9-110-28988-7', 'Krowa, która dużo ryczy pora powiedzieć „b”', DATE '2005-06-21', 1, 72, 24.70, 'Sandra', 'Witkowska', NULL, 'ASCT'),
  ('0-693-09431-1', 'Krowa, która dużo ryczy to z dobrego konia', DATE '1949-10-28', 4, 58, 25.70, 'Felicyta', 'Krysicka', NULL, 'Pies Filemon'),
  ('5-132-85878-3', 'Krowa, która dużo ryczy to z dobrego konia', DATE '2004-02-27', 1, 72, 90.50, 'Jarosław', 'Piotrowski', NULL, 'Pentakill'),
  ('0-208-05957-1', 'Krowa, która dużo ryczy temu czas', DATE '2008-01-13', 1, 78, 67.10, 'Zuzanna', 'Mickiewicz', NULL, 'Podziemie'),
  ('3-105-13911-7', 'Krowa, która dużo ryczy za przewodnika', DATE '2008-07-15', 1, 55, 15.80, 'Kornel', 'Dostojewski', NULL, 'Drux'),
  ('9-241-10415-5', 'Krowa, która dużo ryczy cygana powiesili', DATE '1924-07-17', 1, 53, 83.20, 'Kamila', 'Kostrikin', NULL, 'Afro'),
  ('4-004-71642-X', 'Krowa, która dużo ryczy oka nie wykole', DATE '1974-08-09', 1, 40, 175.30, 'Jacek', 'Adamczyk', NULL, 'Afro'),
  ('7-371-51175-1', 'Krowa, która dużo ryczy mało mleka daje', DATE '1927-09-05', 1, 44, 71.70, 'Adam', 'Słowacki', NULL, 'Kruca Fix'),
  ('3-872-76547-7', 'Krowa, która dużo ryczy trochę zimy, trochę lata', DATE '1934-07-11', 1, 19, 63.70, 'Sandra', 'Kowalska', NULL, 'Atakałke'),
  ('6-888-24918-2', 'Krowa, która dużo ryczy nie wart i kołacza', DATE '1939-01-10', 1, 55, 50.0, 'Karolina', 'Kucharczyk', NULL, 'Pies Filemon'),
  ('7-646-62462-4', 'Krowa, która dużo ryczy ponieśli i wilka', DATE '1922-08-19', 1, 54, 34.80, 'Elżbieta', 'Schmidt', NULL, 'Gambit Kaczmarkowski'),
  ('2-623-30096-8', 'Krowa, która dużo ryczy nikt nie wie', DATE '1957-05-16', 1, 22, 115.90, 'Karolina', 'Mickiewicz', NULL, 'WSSP'),
  ('2-891-31957-5', 'Kto chleba nie chce nie ma chatki', DATE '1933-04-25', 4, 49, 116.60, NULL, NULL, 'Koło Taniego Czyszczenia i Sprzątania', 'Pentakill'),
  ('6-134-02811-8', 'Kto chleba nie chce że przymarznie cap do kozy', DATE '1908-11-29', 1, 46, 94.40, 'Wiktor', 'Kazimierczak', NULL, 'WSSP'),
  ('7-192-85541-3', 'Kto chleba nie chce ale na całe życie', DATE '1920-02-04', 1, 26, 66.90, 'Alicja', 'Kucharczyk', NULL, 'Siedmiu Krasnoludków'),
  ('8-004-67871-8', 'Kto chleba nie chce póki jeszcze czas', DATE '2008-02-21', 1, 14, 142.90, NULL, NULL, 'Encylopedia Informatyki', 'Drux'),
  ('5-574-10230-7', 'Kto chleba nie chce byk się ocieli', DATE '1959-09-30', 1, 15, 9.30, 'Wiktor', 'Jachowicz', NULL, 'Kruti'),
  ('8-910-39523-0', 'Kto chleba nie chce to drugiemu niewola', DATE '1943-06-22', 1, 58, 83.30, NULL, NULL, 'Współczesne rozwój', 'WSSP'),
  ('9-760-18900-3', 'Kto chleba nie chce to go nie minie', DATE '1961-10-02', 1, 68, 173.80, 'Kamila', 'Zielińska', NULL, 'Gambit Kaczmarkowski'),
  ('0-847-43706-X', 'Kto chleba nie chce to zima przejada', DATE '1928-12-23', 1, 46, 13.70, 'Małgorzata', 'Dostojewska', NULL, 'ASCT'),
  ('6-862-99036-5', 'Kto chleba nie chce dom wesołym czyni', DATE '1935-12-07', 1, 24, 167.0, 'Paulina', 'Gradek', NULL, 'Pies Filemon'),
  ('9-157-21595-2', 'Kto chleba nie chce wrócić ziarno na śniadanie', DATE '1912-03-02', 1, 68, 72.0, 'Weronika', 'Kowalska', NULL, 'GGWP'),
  ('8-841-84253-9', 'Kto chleba nie chce jak się kto przepości', DATE '1961-04-27', 1, 49, 54.50, 'Dariusz', 'Dostojewski', NULL, 'Kot Reksio'),
  ('6-952-44085-2', 'Kto chleba nie chce pada aż do Zuzanny', DATE '1944-12-26', 1, 62, 70.60, 'Rafał', 'Dudek', NULL, 'Gambit Kaczmarkowski'),
  ('7-578-73926-3', 'Kto chleba nie chce znać jabłuszko na jabłoni', DATE '2010-07-25', 1, 31, 169.90, 'Karolina', 'Schmidt', NULL, 'GGWP'),
  ('9-416-69337-5', 'Kto chleba nie chce jesień krótka, szybko mija', DATE '1840-03-09', 1, 19, 95.70, NULL, NULL, 'Związek Rybaków i Płetwonurków', 'ASCT'),
  ('5-257-80641-X', 'Kto chleba nie chce to się diabeł cieszy', DATE '1806-11-29', 4, 58, 31.40, 'Brygida', 'Klemens', NULL, 'GGWP'),
  ('8-045-29076-5', 'Kto chleba nie chce zwykle nastaje posucha', DATE '1837-06-26', 4, 22, 47.30, 'Hans', 'Schmidt', NULL, 'Pentakill'),
  ('1-499-39095-5', 'Kto chleba nie chce piekła nie ma', DATE '1960-04-12', 1, 35, 83.80, 'Karolina', 'Kamińska', NULL, 'GGWP'),
  ('5-335-04294-X', 'Kto chleba nie chce piekło gore', DATE '1901-06-09', 1, 48, 34.20, 'Weronika', 'Dudek', NULL, 'WSSP'),
  ('0-622-36718-8', 'Kto chleba nie chce tym bardziej nosa zadziera', DATE '1933-09-29', 1, 19, 34.20, 'Jan', 'Pupa', NULL, 'GGWP'),
  ('9-419-81715-6', 'Kto chleba nie chce tym wyżej głowę nosi', DATE '2009-05-26', 1, 59, 28.0, 'Rafał', 'Johansen', NULL, 'Drux'),
  ('0-700-11620-6', 'Kto chleba nie chce tym więcej chce', DATE '1973-07-07', 4, 57, 8.10, 'Anna', 'Krysicka', NULL, 'Gambit Kaczmarkowski'),
  ('0-887-30730-2', 'Kto chleba nie chce tym spokojniej śpisz', DATE '1977-06-21', 1, 64, 144.60, 'Iwona', 'Gołąbek', NULL, 'Afro'),
  ('1-460-28826-2', 'Kto chleba nie chce tym bardziej gryzie', DATE '1979-10-16', 1, 27, 23.60, 'Karolina', 'Stępień', NULL, 'GGWP'),
  ('8-935-04194-7', 'Kto chleba nie chce tak cię cenią', DATE '1999-11-18', 3, 36, 99.30, 'Iwona', 'Monarek', NULL, 'Atakałke'),
  ('1-571-56083-1', 'Kto chleba nie chce kij się znajdzie', DATE '1954-09-22', 3, 59, 22.70, 'Mateusz', 'Totenbach', NULL, 'Afro'),
  ('5-362-77850-1', 'Kto chleba nie chce to się diabeł cieszy', DATE '1925-01-15', 1, 56, 92.30, 'Anna', 'Witkowska', NULL, 'Atakałke'),
  ('9-471-93655-1', 'Kto chleba nie chce tak się koniec grudnia nosi', DATE '2005-06-02', 1, 18, 85.50, 'Małgorzata', 'Neumann', NULL, 'Afro'),
  ('3-211-52745-1', 'Kto chleba nie chce to się lubi co się ma', DATE '1989-01-08', 1, 29, 13.50, 'Iwona', 'Klemens', NULL, 'Atakałke'),
  ('5-976-80813-1', 'Kto chleba nie chce pora powiedzieć „b”', DATE '1943-01-15', 4, 60, 20.80, 'Andrzej', 'Tyminśka', NULL, 'Loki'),
  ('5-210-88974-2', 'Kto chleba nie chce to z dobrego konia', DATE '1909-02-13', 1, 46, 127.40, 'Iwona', 'Adamczyk', NULL, 'Siedmiu Krasnoludków'),
  ('3-829-39461-6', 'Kto chleba nie chce to z dobrego konia', DATE '1959-08-20', 4, 55, 64.70, 'Aleksandra', 'Schmidt', NULL, 'Kot Reksio'),
  ('7-388-01643-0', 'Kto chleba nie chce temu czas', DATE '1993-10-21', 1, 76, 87.20, 'Piotr', 'Wiśniewski', NULL, 'Kot Reksio'),
  ('5-920-59559-0', 'Kto chleba nie chce za przewodnika', DATE '1988-07-23', 1, 80, 53.10, 'Łukasz', 'Nowakowski', NULL, 'ASCT'),
  ('0-748-99711-3', 'Kto chleba nie chce cygana powiesili', DATE '1945-02-22', 1, 32, 109.60, 'Wiktor', 'Słowacki', NULL, 'NGU'),
  ('1-979-79817-6', 'Kto chleba nie chce oka nie wykole', DATE '1952-03-05', 1, 43, 61.70, 'Wiktor', 'Mełech', NULL, 'Drux'),
  ('2-897-62853-7', 'Kto chleba nie chce mało mleka daje', DATE '1938-08-27', 4, 49, 36.60, NULL, NULL, 'Encylopedia Informatyki', 'Extra Ciemne'),
  ('1-153-97778-8', 'Kto chleba nie chce trochę zimy, trochę lata', DATE '1917-10-17', 4, 10, 105.90, 'Paulina', 'Kowalska', NULL, 'Drux'),
  ('0-220-26199-7', 'Kto chleba nie chce nie wart i kołacza', DATE '1981-02-25', 1, 39, 116.60, NULL, NULL, 'Wsród Matematyki', 'Wesoła Szkoła'),
  ('3-055-29561-7', 'Kto chleba nie chce ponieśli i wilka', DATE '1943-10-29', 1, 27, 79.50, 'Adam', 'Sienkiewicz', NULL, 'ASCT'),
  ('2-078-61848-9', 'Kto chleba nie chce nikt nie wie', DATE '1939-08-17', 1, 37, 39.70, 'Małgorzata', 'Witkowska', NULL, 'WSSP'),
  ('8-823-04584-3', 'Kwiecień – plecień, co przeplata nie ma chatki', DATE '2013-11-19', 1, 33, 71.80, 'Paulina', 'Dębska', NULL, 'Babunia'),
  ('6-378-88833-7', 'Kwiecień – plecień, co przeplata że przymarznie cap do kozy', DATE '1929-06-30', 1, 45, 81.70, 'Jan', 'Pawlak', NULL, 'GGWP'),
  ('7-331-99569-3', 'Kwiecień – plecień, co przeplata ale na całe życie', DATE '1964-01-30', 4, 71, 140.40, NULL, NULL, 'Uniwersytet Koloni Krężnej', 'GGWP'),
  ('7-050-30775-0', 'Kwiecień – plecień, co przeplata póki jeszcze czas', DATE '1924-03-15', 1, 64, 113.30, 'Jarosław', 'Kucharczyk', NULL, 'Drux'),
  ('4-233-42512-1', 'Kwiecień – plecień, co przeplata byk się ocieli', DATE '1979-11-19', 1, 46, 96.20, 'Karolina', 'Stępień', NULL, 'Drux'),
  ('8-608-45390-8', 'Kwiecień – plecień, co przeplata to drugiemu niewola', DATE '1981-09-01', 1, 57, 146.50, 'Jarosław', 'Kostrikin', NULL, 'NGU'),
  ('3-655-65274-7', 'Kwiecień – plecień, co przeplata to go nie minie', DATE '1958-12-13', 1, 57, 52.10, 'Grzegorz', 'Klemens', NULL, 'Drux'),
  ('8-413-56101-9', 'Kwiecień – plecień, co przeplata to zima przejada', DATE '1973-06-06', 2, 42, 24.0, 'Felicyta', 'Tyminśka', NULL, 'Kruti'),
  ('4-069-34549-3', 'Kwiecień – plecień, co przeplata dom wesołym czyni', DATE '1972-04-01', 1, 36, 24.30, 'Karolina', 'Sejko', NULL, 'Atakałke'),
  ('0-300-54215-1', 'Kwiecień – plecień, co przeplata wrócić ziarno na śniadanie', DATE '1187-04-23', 1, 33, 195.10, 'Mateusz', 'Lewandowski', NULL, 'Siedmiu Krasnoludków'),
  ('5-178-87389-0', 'Kwiecień – plecień, co przeplata jak się kto przepości', DATE '1066-10-06', 1, 30, 81.40, 'Jan', 'Schneider', NULL, 'Kruti'),
  ('2-305-95885-4', 'Kwiecień – plecień, co przeplata pada aż do Zuzanny', DATE '1920-12-09', 1, 20, 127.0, 'Bożydar', 'Kowalski', NULL, 'WSSP'),
  ('3-328-94192-4', 'Kwiecień – plecień, co przeplata znać jabłuszko na jabłoni', DATE '1957-09-20', 1, 39, 8.10, 'Katarzyna', 'Jaworska', NULL, 'Loki'),
  ('3-196-94922-2', 'Kwiecień – plecień, co przeplata jesień krótka, szybko mija', DATE '1744-09-21', 3, 25, 164.20, 'Wiktor', 'Mickiewicz', NULL, 'Loki'),
  ('1-671-23439-1', 'Kwiecień – plecień, co przeplata to się diabeł cieszy', DATE '1917-11-18', 1, 22, 149.70, 'Paulina', 'Słowacka', NULL, 'Podziemie'),
  ('0-762-59042-4', 'Kwiecień – plecień, co przeplata zwykle nastaje posucha', DATE '1947-05-23', 1, 42, 127.10, 'Jakub', 'Górski', NULL, 'Januszex'),
  ('1-409-00664-6', 'Kwiecień – plecień, co przeplata piekła nie ma', DATE '1920-03-20', 1, 58, 100.50, 'Kornel', 'Mickiewicz', NULL, 'Extra Ciemne'),
  ('6-605-93194-7', 'Kwiecień – plecień, co przeplata piekło gore', DATE '1929-03-10', 1, 30, 119.10, 'Wiktor', 'Monarek', NULL, 'Kot Reksio'),
  ('1-974-93310-5', 'Kwiecień – plecień, co przeplata tym bardziej nosa zadziera', DATE '1954-01-13', 1, 42, 136.70, 'Jarosław', 'Johansen', NULL, 'Afro'),
  ('7-030-37131-3', 'Kwiecień – plecień, co przeplata tym wyżej głowę nosi', DATE '1930-05-28', 1, 39, 31.80, 'Franciszek', 'Gradek', NULL, 'Gambit Kaczmarkowski'),
  ('8-317-71921-9', 'Kwiecień – plecień, co przeplata tym więcej chce', DATE '1905-03-01', 1, 70, 29.80, 'Aleksandra', 'Kostrikin', NULL, 'Gambit Kaczmarkowski'),
  ('5-678-48175-4', 'Kwiecień – plecień, co przeplata tym spokojniej śpisz', DATE '2014-09-13', 1, 71, 71.90, 'Janusz', 'Malinowski', NULL, 'Babunia'),
  ('1-027-49647-4', 'Kwiecień – plecień, co przeplata tym bardziej gryzie', DATE '1908-09-10', 1, 48, 12.90, 'Paweł', 'Nowak', NULL, 'Gambit Kaczmarkowski'),
  ('0-927-03943-5', 'Kwiecień – plecień, co przeplata tak cię cenią', DATE '1999-02-11', 1, 35, 23.30, NULL, NULL, 'Drużyna Pierścienia', 'Loki'),
  ('3-334-94409-3', 'Kwiecień – plecień, co przeplata kij się znajdzie', DATE '1958-05-18', 1, 52, 106.10, NULL, NULL, 'TCS times', 'Pies Filemon'),
  ('5-028-63198-0', 'Kwiecień – plecień, co przeplata to się diabeł cieszy', DATE '1991-06-03', 1, 32, 87.0, 'Sandra', 'Głowacka', NULL, 'ASCT'),
  ('0-978-92030-9', 'Kwiecień – plecień, co przeplata tak się koniec grudnia nosi', DATE '1738-06-09', 1, 32, 91.80, 'Filip', 'Gradek', NULL, 'ASCT'),
  ('8-131-95065-4', 'Kwiecień – plecień, co przeplata to się lubi co się ma', DATE '1998-03-14', 1, 51, 48.50, 'Mateusz', 'Stępień', NULL, 'Atakałke'),
  ('7-846-54085-8', 'Kwiecień – plecień, co przeplata pora powiedzieć „b”', DATE '1810-11-28', 1, 58, 39.40, 'Iwona', 'Jaworska', NULL, 'Loki'),
  ('4-155-82520-1', 'Kwiecień – plecień, co przeplata to z dobrego konia', DATE '1986-11-02', 1, 55, 38.0, NULL, NULL, 'Współczesne rozwój', 'Loki'),
  ('3-747-09416-3', 'Kwiecień – plecień, co przeplata to z dobrego konia', DATE '1971-11-08', 1, 37, 37.50, 'Katarzyna', 'Filtz', NULL, 'Pies Filemon'),
  ('1-054-60110-0', 'Kwiecień – plecień, co przeplata temu czas', DATE '1968-03-22', 1, 26, 83.0, 'Piotr', 'Wiśniewski', NULL, 'Loki'),
  ('8-900-84258-7', 'Kwiecień – plecień, co przeplata za przewodnika', DATE '1972-12-20', 4, 22, 96.10, 'Andrzej', 'Homoncik', NULL, 'NGU'),
  ('3-521-22044-3', 'Kwiecień – plecień, co przeplata cygana powiesili', DATE '1986-01-05', 1, 60, 145.50, 'Franciszek', 'Woźniak', NULL, 'ASCT'),
  ('4-537-96247-X', 'Kwiecień – plecień, co przeplata oka nie wykole', DATE '1950-04-21', 1, 52, 28.80, 'Rafał', 'Totenbach', NULL, 'Loki'),
  ('2-137-29356-0', 'Kwiecień – plecień, co przeplata mało mleka daje', DATE '1990-05-22', 1, 45, 63.20, NULL, NULL, 'FAKTCS', 'WSSP'),
  ('3-631-30343-2', 'Kwiecień – plecień, co przeplata trochę zimy, trochę lata', DATE '1924-03-19', 1, 39, 108.10, 'Rafał', 'Woźniak', NULL, 'Loki'),
  ('0-125-37488-7', 'Kwiecień – plecień, co przeplata nie wart i kołacza', DATE '2012-02-12', 1, 56, 61.90, 'Michał', 'Filtz', NULL, 'Atakałke'),
  ('3-111-93231-1', 'Kwiecień – plecień, co przeplata ponieśli i wilka', DATE '1107-12-27', 1, 38, 47.10, 'Henryk', 'Dudek', NULL, 'Loki'),
  ('9-846-87010-8', 'Kwiecień – plecień, co przeplata nikt nie wie', DATE '1969-09-17', 1, 41, 124.30, 'Brygida', 'Witkowska', NULL, 'GGWP'),
  ('9-706-10758-4', 'Kto chleba nie chce nie ma chatki', DATE '2011-11-28', 1, 45, 78.10, 'Mateusz', 'Pawlak', NULL, 'Januszex'),
  ('2-455-25531-X', 'Kto chleba nie chce że przymarznie cap do kozy', DATE '1987-05-23', 3, 63, 132.50, 'Jakub', 'Kowalski', NULL, 'Podziemie'),
  ('8-472-82859-X', 'Kto chleba nie chce ale na całe życie', DATE '2014-01-16', 1, 42, 14.0, 'Szymon', 'Monarek', NULL, 'Kot Reksio'),
  ('5-319-89571-2', 'Kto chleba nie chce póki jeszcze czas', DATE '1951-10-12', 4, 30, 163.20, 'Henryk', 'Kamiński', NULL, 'Kot Reksio'),
  ('0-927-47258-9', 'Kto chleba nie chce byk się ocieli', DATE '1949-08-01', 1, 34, 23.60, 'Bartłomiej', 'Klemens', NULL, 'Pentakill'),
  ('0-274-17335-2', 'Kto chleba nie chce to drugiemu niewola', DATE '1994-02-20', 4, 15, 105.30, 'Elżbieta', 'Kondratek', NULL, 'Kruti'),
  ('4-082-98474-7', 'Kto chleba nie chce to go nie minie', DATE '2008-04-12', 1, 44, 68.30, 'Szymon', 'Zieliński', NULL, 'Gambit Kaczmarkowski'),
  ('1-925-98571-7', 'Kto chleba nie chce to zima przejada', DATE '1995-02-19', 1, 56, 39.10, 'Zuzanna', 'Górska', NULL, 'WSSP'),
  ('9-745-97622-9', 'Kto chleba nie chce dom wesołym czyni', DATE '1994-05-11', 1, 64, 110.60, 'Katarzyna', 'Goldberg', NULL, 'WSSP'),
  ('0-860-97734-X', 'Kto chleba nie chce wrócić ziarno na śniadanie', DATE '1992-02-18', 1, 14, 26.40, 'Hans', 'Johansen', NULL, 'Kot Reksio'),
  ('8-620-24005-6', 'Kto chleba nie chce jak się kto przepości', DATE '1830-11-14', 1, 13, 118.80, 'Filip', 'Dostojewski', NULL, 'GGWP'),
  ('5-905-70111-3', 'Kto chleba nie chce pada aż do Zuzanny', DATE '2004-04-09', 1, 22, 163.10, 'Joanna', 'Piotrowska', NULL, 'NGU'),
  ('8-902-97315-8', 'Kto chleba nie chce znać jabłuszko na jabłoni', DATE '2006-11-05', 2, 48, 117.0, 'Agnieszka', 'Dura', NULL, 'NGU'),
  ('9-929-80914-7', 'Kto chleba nie chce jesień krótka, szybko mija', DATE '1960-02-16', 3, 63, 138.80, 'Andrzej', 'Gołąbek', NULL, 'Kruti'),
  ('9-250-66186-X', 'Kto chleba nie chce to się diabeł cieszy', DATE '1974-08-11', 1, 19, 88.60, 'Wiktor', 'Hoser', NULL, 'GGWP'),
  ('7-700-61231-5', 'Kto chleba nie chce zwykle nastaje posucha', DATE '1918-02-03', 1, 51, 127.80, 'Anna', 'Nowakowska', NULL, 'Pentakill'),
  ('1-615-78479-9', 'Kto chleba nie chce piekła nie ma', DATE '1806-04-26', 1, 45, 79.40, 'Kamila', 'Krysicka', NULL, 'Januszex'),
  ('1-765-17324-8', 'Kto chleba nie chce piekło gore', DATE '2001-07-19', 1, 58, 76.10, 'Aleksandra', 'Schmidt', NULL, 'Atakałke'),
  ('9-704-31196-6', 'Kto chleba nie chce tym bardziej nosa zadziera', DATE '2006-02-10', 1, 38, 56.40, 'Michał', 'Monarek', NULL, 'Extra Ciemne'),
  ('2-168-86782-8', 'Kto chleba nie chce tym wyżej głowę nosi', DATE '1816-04-02', 4, 65, 68.40, 'Joanna', 'Pawlak', NULL, 'ASCT'),
  ('6-013-26606-9', 'Kto chleba nie chce tym więcej chce', DATE '1982-12-07', 1, 48, 67.90, NULL, NULL, 'Współczesne rozwój', 'Pentakill'),
  ('6-938-71685-4', 'Kto chleba nie chce tym spokojniej śpisz', DATE '1924-04-08', 3, 60, 81.10, 'Zuzanna', 'Adamczyk', NULL, 'Drux'),
  ('9-458-11960-X', 'Kto chleba nie chce tym bardziej gryzie', DATE '1932-05-29', 1, 22, 65.90, 'Grzegorz', 'Schneider', NULL, 'Atakałke'),
  ('1-225-01161-2', 'Kto chleba nie chce tak cię cenią', DATE '1993-09-12', 1, 22, 109.0, 'Franciszek', 'Kazimierczak', NULL, 'Drux'),
  ('9-576-71118-5', 'Kto chleba nie chce kij się znajdzie', DATE '1968-02-06', 1, 32, 33.90, 'Elżbieta', 'Witkowska', NULL, 'NGU'),
  ('8-400-29507-2', 'Kto chleba nie chce to się diabeł cieszy', DATE '1989-05-28', 1, 18, 61.70, 'Weronika', 'Totenbach', NULL, 'Siedmiu Krasnoludków'),
  ('9-684-59859-9', 'Kto chleba nie chce tak się koniec grudnia nosi', DATE '1992-09-03', 1, 44, 23.60, NULL, NULL, 'Koło Taniego Czyszczenia i Sprzątania', 'Gambit Kaczmarkowski'),
  ('2-451-39120-0', 'Kto chleba nie chce to się lubi co się ma', DATE '2001-02-28', 4, 69, 81.70, 'Michał', 'Grabowski', NULL, 'Babunia'),
  ('5-541-19780-5', 'Kto chleba nie chce pora powiedzieć „b”', DATE '1913-04-06', 1, 76, 139.60, 'Bartłomiej', 'Helik', NULL, 'Podziemie'),
  ('2-298-15378-7', 'Kto chleba nie chce to z dobrego konia', DATE '1958-07-07', 1, 43, 160.30, 'Tomasz', 'Homoncik', NULL, 'Drux'),
  ('5-723-95615-9', 'Kto chleba nie chce to z dobrego konia', DATE '1966-12-12', 1, 49, 64.50, 'Dariusz', 'Kazimierczak', NULL, 'Kot Reksio'),
  ('1-006-15348-9', 'Kto chleba nie chce temu czas', DATE '1993-11-06', 1, 61, 8.90, 'Katarzyna', 'Goldberg', NULL, 'Afro'),
  ('7-767-90918-2', 'Kto chleba nie chce za przewodnika', DATE '1928-04-27', 4, 43, 64.30, 'Franciszek', 'Grabowski', NULL, 'Loki'),
  ('5-119-00897-6', 'Kto chleba nie chce cygana powiesili', DATE '1933-09-12', 4, 67, 146.90, 'Karolina', 'Schneider', NULL, 'Podziemie'),
  ('0-617-68079-5', 'Kto chleba nie chce oka nie wykole', DATE '1922-05-06', 1, 74, 126.70, 'Jacek', 'Dąbrowkski', NULL, 'Pentakill'),
  ('5-464-79388-7', 'Kto chleba nie chce mało mleka daje', DATE '1969-11-30', 2, 66, 142.60, 'Maciek', 'Jaworski', NULL, 'Kruca Fix'),
  ('0-600-77463-5', 'Kto chleba nie chce trochę zimy, trochę lata', DATE '1993-09-20', 1, 58, 33.90, 'Kamila', 'Piotrowska', NULL, 'Kruca Fix'),
  ('7-458-36456-4', 'Kto chleba nie chce nie wart i kołacza', DATE '1932-07-11', 1, 84, 65.20, 'Tomasz', 'Krysicki', NULL, 'Pies Filemon'),
  ('1-985-25193-0', 'Kto chleba nie chce ponieśli i wilka', DATE '1941-05-17', 1, 47, 87.60, 'Agnieszka', 'Mickiewicz',
   NULL, 'Pies Filemon'),
  ('4-585-11499-8', 'Kto chleba nie chce nikt nie wie', DATE '1964-09-28', 1, 39, 149.30, 'Tomasz', 'Adamczyk', NULL,
   'Afro');
INSERT INTO customers
(first_name, last_name, login, passwordHash, postal_code, street, building_no, flat_no, city, nip, phone_number)
VALUES
  ('Szymon', 'Kamiński', 'h4jSvWJUgac', 'ol9e4PdFDe', '56-254', 'Kajakowa', '2', '2', 'Karpacz', NULL, '356816105'),
  ('Zuzanna', 'Nowicka', 'ihKdU3NKMBr', 'AvTZh3M18TrXR', '36-350', 'Małka', '6b', NULL, 'Moszczenica', NULL, '850627645'),
  ('Tomasz', 'Totenbach', '6g4i9C6VcoL', 'Tr9hhse0QD', '90-454', 'Traczy', '6', NULL, 'Gdynia', '3312935914', '592480151'),
  ('Michał', 'Gross', 'PaVcjBeQU', 'QFWrwN9TG', '14-733', 'Korfantego', '7', NULL, 'Płock', NULL, '135396680'),
  ('Iwona', 'Jachowicz', 'pR2kPnolYR', 'YiVaUoPad5a', '22-486', 'Magnolii', '6', '28', 'Lublin', NULL, '283644177'),
  ('Agnieszka', 'Gross', '65GTREU02ah', 'UcsSRKOT0', '52-046', 'Małka', '14', '9', 'Słupsk', '1308264683', '515092418'),
  ('Michał', 'Helik', 'PfTz53kb', '22CISo5Ntn', '19-715', 'Jaskra', '33', NULL, 'Kleszczów', NULL, '239291194'),
  ('Jacek', 'Kowalski', 'pmiUXEvbyiE', 'euZWGa2pXIhf', '60-230', 'Rolna', '1', NULL, 'Białka Tatrzańska', NULL, '451052046'),
  ('Joanna', 'Kazimierczak', 'RsYKIKyUHKSpG', '8lgCSivUoJ', '82-280', 'Reja', '3b', NULL, 'Opoczno', NULL, '328768864'),
  ('Wiktor', 'Nowak', 'yosrs06hOn', 'tUxf6ua6EHlU', '61-033', 'Błotna', '6', NULL, 'Bełchatów', NULL, '187506342'),
  ('Hans', 'Lewandowski', '5Fogb2LQB', 'YCglDaCr', '44-040', 'Grota - Roweckiego', '29', NULL, 'Niebo', NULL, '956551618'),
  ('Aleksandra', 'Kamińska', '6EOX2V2Cr3', 'zWV2SkJtsMs', '57-328', 'Hleny', '1d', NULL, 'Słupsk', NULL, '982912061'),
  ('Joanna', 'Filtz', 'axA0FKGNcNX', '2Ky3ctrfYgn', '28-451', 'Wandy', '92c', NULL, 'Ręczno', '3172045148', '664158534'),
  ('Filip', 'Gołąbek', '36CSMUTK6P', 'BlSHaNNM1', '98-255', 'Łuczników', '14', NULL, 'Niebo', NULL, '076956919'),
  ('Dariusz', 'Mazur', 'VXr6XNi8K1', 'r9IonB8o0kG', '32-961', 'Jakuba', '77', NULL, 'Liszki', '9709875497', '352985849'),
  ('Piotr', 'Dura', 'wCD8WarDd', 'ywrOzQ15v6', '17-749', 'Conrada', '5', '76', 'Zgon', NULL, '314002070'),
  ('Dariusz', 'Kazimierczak', 'oxOlvJXVq1b', '7mpFAF1YPp', '32-282', 'Piekarska', '46', NULL, 'Łódź', '6500137685', '712774608'),
  ('Adam', 'Monarek', 'hxRPrwdg', '17UvLaY9EdI', '78-227', 'Polna', '3', NULL, 'Końskie', '4056107565', '098099074'),
  ('Katarzyna', 'Homoncik', '8hR1JoWNUJa', 'fc87D8DX', '50-472', 'Zimna', '53', NULL, 'Inowłódz', '9130519627', '389148319'),
  ('Zuzanna', 'Górska', 'HyIGJUNOx', 'BVDHZOZhg', '68-192', 'Bednarska', '94', NULL, 'Koniecpol', '4229472271', '529180635'),
  ('Rafał', 'Tanenbaum', 'DmP79wSGCuVO8', 'PkltUgPptG', '63-406', 'Bema', '7', NULL, 'Miechów', '4649845282', '030797714'),
  ('Michał', 'Kostrikin', 'uAB6xWzEh', 'FMGJVfNA', '59-628', 'Karabuły', '4', NULL, 'Jędczydół', NULL, '038254439'),
  ('Michał', 'Słowacki', 'JWLM243BNmIIO', 'DBEzlziLgFUTW', '04-529', 'Domowa', '57', NULL, 'Łeba', NULL, '514669512'),
  ('Jacek', 'Adamczyk', '8bHTNcJ7na', 'Cy06oal2TC', '44-045', 'Dr Jana Piltza', '4', NULL, 'Piotrków Trybunalski', NULL, '269245640'),
  ('Rafał', 'Kostrikin', 'i3NJEAM3', 'c8siHOM5TA', '33-309', 'Sodowa', '9b', NULL, 'Ostrołęka', NULL, '252491034'),
  ('Mateusz', 'Kucharczyk', 'K2vAzR78dT', 'l533fnxMM', '30-116', 'Kajakowa', '76', NULL, 'Wieruszów', NULL, '703581852'),
  ('Andrzej', 'Gross', 'RN1BtjHy2', 'ecoMGVzibc7n', '69-889', 'Kogucia', '7b', '9', 'Zelów', NULL, '825743263'),
  ('Karolina', 'Wojciechowska', 'ZVzVvSXBqNi', 'G9bCLNEQcl', '61-515', 'Orla', '82', NULL, 'Pacanów', '7991497300', '447598039'),
  ('Andrzej', 'Dura', 'VBV6RTKiLBKM', 'eB3zRyK9D', '51-582', 'Piastowka', '75c', NULL, 'Puławy', NULL, '146019227'),
  ('Franciszek', 'Zieliński', 'svtZ4lHbeJD', 'T0sT1K1dtum', '14-227', 'Siwna', '85', NULL, 'Radomsko', NULL, '111991608'),
  ('Karolina', 'Jaworska', 'LjWFUzFt', '99BxCaAvhkvb', '63-122', 'Traugutta', '4', NULL, 'Ustka', NULL, '088522643'),
  ('Zuzanna', 'Tyminśka', 'LkCcMGwo', 'Nlg02Xf5W', '92-852', 'Konopnickiej', '22', NULL, 'Zgierz', '2306147525', '768853865'),
  ('Filip', 'Goldberg', 'Eo0bMrA5xn', 'JylTF8BU4kb', '77-724', 'Zacisze', '1', NULL, 'Kolonia Krężna', NULL, '833000409'),
  ('Maciek', 'Wiśniewski', 'SsSmkYgEE9u', 'MWXYpqllOe', '09-941', 'Dymnik', '3', NULL, 'Pacanów', '3626696352', '840582903'),
  ('Michał', 'Gradek', 'KhLyrtrFd', 'aGMBq1L6wCf', '70-815', 'Boczna', '7', NULL, 'Ostrołęka', NULL, '097752465'),
  ('Grzegorz', 'Mazur', '4xi8uSCL', 'nUt7CCI2SVi', '45-579', 'Łuczników', '15', NULL, 'Dzierżawy', '7155279555', '225529094'),
  ('Zuzanna', 'Nowakowska', 'yQpK0bu61x1', 'IQVbLPcXI', '58-572', 'Inflancka', '41', NULL, 'Nowy Targ', NULL, '200139365'),
  ('Szymon', 'Gross', '8bKwwdoG3icHr', 'afSDebH8t', '85-379', 'Żytnia', '3', NULL, 'Zgon', '9980981648', '095037445'),
  ('Jacek', 'Kowalski', 'tjzelP30lZI7NU', 'JRw9QBMEADMk', '05-193', 'Domowa', '52', NULL, 'Żary', NULL, '046368380'),
  ('Elżbieta', 'Cebulska', 'MSS3NUJ7i', 'ssqoUsY8Afz', '81-704', 'Muzyków', '3f', NULL, 'Mielno', NULL, '053061141'),
  ('Filip', 'Kazimierczak', 'pJ89HvFMJJ', 'Uu4xwLIGlqe', '81-940', 'Kogucia', '9', NULL, 'Radom', NULL, '143160784'),
  ('Wiktor', 'Wiśniewski', 'gPbHLtU4', 'Dxuxlgqjj', '03-247', 'Nefrytowa', '6', NULL, 'Koszalin', NULL, '932483322'),
  ('Katarzyna', 'Dudek', 'D6X00smWHcp', '1aydNfFgIG', '94-445', 'Polna', '18', NULL, 'Poznań', NULL, '852103496'),
  ('Karolina', 'Dudek', 'daMRAKhv', 'TezARBtq4x', '33-157', 'Irysowa', '14d', '62', 'Nysa', NULL, '067991323'),
  ('Filip', 'Dura', 'TVJqDpTkrF', 'zVr5OskUAHN', '79-882', 'Pilotów', '70', NULL, 'Przedbórz', NULL, '985860509'),
  ('Filip', 'Woźniak', 'i5NRbcn23BDj', 'QGVxSaxcMMa', '05-835', 'Cicha', '1', NULL, 'Zelów', '9065372766', '434801721'),
  ('Mikołaj', 'Helik', 'VwbQOTAjSFS', 'qKrR0EK0LyJ', '64-950', 'Ryba', '21', NULL, 'Bytom', NULL, '937431480'),
  ('Sandra', 'Tyminśka', 'qdJQ2orrH', 'OxIIiqTMY8', '44-641', 'Irysowa', '18', NULL, 'Słupsk', '3298343010', '842632477'),
  ('Brygida', 'Neumann', 'JKuKRgA40', 'gHoInnc7NvLP', '24-928', 'Sądowa', '11', NULL, 'Inowrocławek', '0242415590', '671756082'),
  ('Hans', 'Nowak', '8uC4bSEh5', '54X1Fk3SiKKY', '96-833', 'Wiosenna', '71c', NULL, 'Bobry', NULL, '569270377'),
  ('Katarzyna', 'Gross', 'aI5by4LIHELVu', 'lV0i8Dqt', '01-213', 'Bednarska', '92', NULL, 'Sejny', NULL, '981528506'),
  ('Tomasz', 'Witkowski', '6dvgUlzeZs', 'LiCr4ffQ', '43-228', 'Nefrytowa', '59f', NULL, 'Dzierżawy', NULL, '957555558'),
  ('Bartłomiej', 'Majewski', 'IV8ubIKEJ', 'l4Bx7tisd', '00-970', 'Gołębia', '3b', '6', 'Bytom', NULL, '443092659'),
  ('Iwona', 'Filtz', 'M4qDkS0pd', 'G5YU1B4T', '06-916', 'Piastowka', '91', NULL, 'Mszana Dolna', '2388214474', '355536843'),
  ('Felicyta', 'Nowakowska', 'rsrE4irq53Yk', '0gTsCoeNyWW', '57-503', 'Katowicka', '4', '76', 'Liszki', NULL, '121357968'),
  ('Mateusz', 'Sejko', 'VmqMQHSRU2', 'l9RwMUglE', '62-576', 'Łojasiewicza', '16b', NULL, 'Lublin', NULL, '416564309'),
  ('Aleksandra', 'Bobak', 'la6KE2521', '5JZSiFvcPDh0', '07-946', 'Karabuły', '9c', NULL, 'Piotrków Trybunalski', NULL, '654117696'),
  ('Zuzanna', 'Lewandowska', 'CGcx7GlPzrU', '10dVVtPz', '97-458', 'Skośna', '71', NULL, 'Zawiercie', NULL, '456181338'),
  ('Felicyta', 'Wojciechowska', 'tyMn3icGqk00r', 'pJ2KugGCb', '27-395', 'Łuczników', '98', '94', 'Bydgoszcz', NULL, '538780107'),
  ('Karolina', 'Nowakowska', 'ipJTRzz758wR', 'hwnfU9z2ix9', '91-931', 'Nowickiego', '16', NULL, 'Koszalin', NULL, '585488726'),
  ('Karolina', 'Dura', 'Q981aRovnaG', 'WW6ZW43ATc', '89-924', 'Jakuba', '5', NULL, 'Nowy Sącz', '5715143704', '285052332'),
  ('Andrzej', 'Malinowski', '9rOQ0KfAm', 'CWyk1eRGTTa', '03-934', 'Polna', '26', NULL, 'Darłowo', NULL, '703822756'),
  ('Małgorzata', 'Mazur', 'FGJXwRFmc5F', 'XpQsHRxDpfI', '69-958', 'Lipińskiego', '1', NULL, 'Łańcut', NULL, '727815338'),
  ('Łukasz', 'Helik', 'kBpUkFBl', 'jliRFVGIK', '24-834', 'Żytnia', '5', '66', 'Ciechanów', NULL, '468315555'),
  ('Adam', 'Schmidt', 'c8TYgjgRAo1V', 'g8Q7EooSe', '12-205', 'Wandy', '3', NULL, 'Rozprza', '1241824973', '498654115'),
  ('Sandra', 'Stępień', 'jFs6LT3ues5', 'UbNtSGDE', '73-714', 'Konopnickiej', '1', NULL, 'Poznań', NULL, '185271930'),
  ('Sandra', 'Kazimierczak', '9e2FMDhP33', 'C64g5vVlUt', '85-570', 'Niebieska', '72', NULL, 'Słupsk', NULL, '323170923'),
  ('Alicja', 'Głowacka', 'wAZl2BfbG', 'jsEGyEA3nV', '38-705', 'Kapucyńska', '66', NULL, 'Aleksandórw Łódzki', '8797999837', '309756987'),
  ('Bartłomiej', 'Sejko', 'ExRS1W34Kek2', 'bPp8aoRZBg', '08-644', 'Zacisze', '2', NULL, 'Elbląg', NULL, '375258590'),
  ('Maciek', 'Monarek', 'FVXzeEEaQTy', 'phSJpVeN4', '42-157', 'Zawiła', '77', NULL, 'Rabka - Zdrój', NULL, '095247258'),
  ('Janusz', 'Johansen', 'Odpc8UKn', 'SCWAWNuB0lc', '83-324', 'Basztowa', '4', NULL, 'Poznań', NULL, '731212761'),
  ('Łukasz', 'Kamiński', '5dgIANglPJ', 'wwf4efYo1', '73-744', 'Północna', '5', NULL, 'Rozprza', NULL, '719428223'),
  ('Iwona', 'Adamczyk', 'iTt15HfBU', 'B2pRJBiVlp', '78-144', 'Młynowa', '73', NULL, 'Kopytkowo', NULL, '282220900'),
  ('Alicja', 'Neumann', 'ZNjA4Mb77sE', 'ym9aO7e4Ju', '16-253', 'Wandy', '44', NULL, 'Liszki', NULL, '514989849'),
  ('Andrzej', 'Zieliński', 'ownGhkzqMX', 'huxP2oceh2V', '87-897', 'Obozowa', '30', NULL, 'Lesko', NULL, '833474805'),
  ('Piotr', 'Kamiński', '2pqVhAhL3h', 'cO5U5XBlSAG', '72-735', 'Piekarska', '6f', NULL, 'Brzegi', NULL, '888521032'),
  ('Paweł', 'Lewandowski', 'fVueoFi4C0cu', 'i6HmudZGFt5f', '51-555', 'Wysoka', '2', NULL, 'Poniatów', NULL, '286420300'),
  ('Alicja', 'Pupa', 'tmyXoRjpR', '8xWXxLh0sa', '53-802', 'Nefrytowa', '71', '36', 'Leszno', NULL, '304682005'),
  ('Aleksandra', 'Adamczyk', 'Nzw9sIre', 'Wj1HPJJW4', '01-858', 'Chmieleniec', '6', NULL, 'Poznań', NULL, '031738447'),
  ('Łukasz', 'Filtz', 'AGEy9EJ7W3fGw', '7WKo1Q8PBp', '63-454', 'Łódzka', '97', NULL, 'Sejny', NULL, '096431629'),
  ('Paweł', 'Dostojewski', 'B39pn1dy7VkMM', '9blFGYRetH', '49-477', 'Czerwone Maki', '1', NULL, 'Przedbórz', NULL, '562253375'),
  ('Aleksandra', 'Pawlak', 'yLsddLEpGRL', 'dzLPhDT44', '67-285', 'Czerwone Maki', '18', NULL, 'Świnoujście', NULL, '516427710'),
  ('Jakub', 'Majewski', '7wTgdC0RkFc', '0ZvdWiul', '58-065', 'Nefrytowa', '20', NULL, 'Nienadówka', NULL, '585451259'),
  ('Paulina', 'Tyminśka', 'kmK1JYF9z', 'IwtfDDgP', '86-713', 'Katowicka', '10', NULL, 'Baby', NULL, '005790845'),
  ('Iwona', 'Witkowska', 'ymG86Ven', 'B0PmEvAihe', '00-703', 'Niebieska', '62', NULL, 'Aleksandórw Łódzki', NULL, '870876852'),
  ('Mikołaj', 'Dąbrowkski', 'P1GumNok4YmtFb', '2nxNLQUGvgG', '76-973', 'Sądowa', '3', NULL, 'Baby', '2008910725', '402198972'),
  ('Kamila', 'Kondratek', 'hX2OWZ1eTM', 'KzKVuA9WE', '97-964', 'Gołębia', '6', '37', 'Legnica', NULL, '468591901'),
  ('Jarosław', 'Tanenbaum', 'E3DyYXTTWO', 'hDlLZF6wV', '19-836', 'Lubostroń', '33f', NULL, 'Koniecpol', NULL, '271590283'),
  ('Małgorzata', 'Głowacka', 'dUx7XLLGPi', '14rWIsnMh', '77-765', 'Jachowicza', '1', NULL, 'Koniec Świata', '5349027769', '117633605'),
  ('Mikołaj', 'Sejko', 'sfkBGozNM2X', 'QyhCMtUi', '15-027', 'Lasek', '1d', '71', 'Sanok', NULL, '441216303'),
  ('Andrzej', 'Górski', 'D7NgENUHwxs', 'BRWMGgOPEIxj', '72-390', 'Bajeczna', '7', NULL, 'Kopytkowo', NULL, '940266429'),
  ('Hans', 'Kondratek', 'sFkWV3Vs0m', 'CV7Wf8xp', '80-396', 'Zawiła', '1', NULL, 'Żary', NULL, '841779057'),
  ('Rafał', 'Górski', 'UqVfM1tPnuSEN', 'OllWzWyiwHA', '38-586', 'Żytnia', '56', NULL, 'Katowice', NULL, '044867816'),
  ('Rafał', 'Goldberg', 'WvTdqTFuh', 'tbNPvYQLZU3', '34-844', 'Piekarska', '21', NULL, 'Ciechanów', NULL, '210658694'),
  ('Karolina', 'Dostojewska', '4wSOD4jge9xW', 'qmyt908R9k', '46-346', 'Konopnickiej', '65b', NULL, 'Rozprza', NULL, '667021022'),
  ('Adam', 'Krysicki', 'LdyxTqufat', 'NJebjkqEpZF', '40-456', 'Wysoka', '60', NULL, 'Koziebrody', NULL, '354673637'),
  ('Małgorzata', 'Krysicka', 'dHRsJ93aIU', '8wmfFEM51', '45-998', 'Jana Pawła II', '1', NULL, 'Iwonicz Zdrój', NULL, '683701698'),
  ('Anna', 'Sienkiewicz', 'VTWM2Uwp', 'xu0byEnrc2q', '90-720', 'Conrada', '8', NULL, 'Krynica Zdrój', '8424138367', '944067133'),
  ('Szymon', 'Wiśniewski', 'fyuWou9yAfpM', 'dmQVrTph5K', '63-318', 'Cicha', '13', NULL, 'Inowłódz', '0973622168', '160238993'),
  ('Henryk', 'Kamiński', 'eo7i4ztVcBW', 'Hq829KXl69', '46-850', 'Łódzka', '67b', NULL, 'Iwonicz Zdrój', NULL, '317290286'),
  ('Anna', 'Helik', 'KUIyPOI1Afe', '3RDS1WCgbdb', '42-713', 'Kogucia', '46', NULL, 'Szczecin', NULL, '357145451'),
  ('Mateusz', 'Lewandowski', 'uFUNnCrcH', 'cehwf35fbXe', '12-228', 'Nasza', '14', NULL, 'Kolonia Krężna', '4285779444', '811904446'),
  ('Franciszek', 'Stępień', 'YTV37Ogg8GQu', 'bj9ufOcYuc', '86-456', 'Zielona', '95', NULL, 'Przedbórz', NULL, '500298162'),
  ('Jan', 'Malinowski', 'vNnKTJLqAAi8G', 'jSPthQAoiV', '38-630', 'Chmieleniec', '44', NULL, 'Rzeszów', NULL, '147812237'),
  ('Paweł', 'Jaworski', 'cMcgqU2aqc', 'pLYHLSbEliLU', '60-362', 'Magnolii', '66', NULL, 'Chełm', NULL, '648667450'),
  ('Zuzanna', 'Grabowska', 'eDoggeFwZQoP', 'r2DWcxXByu41U', '36-590', 'Teligi', '6', '4', 'Krynica Zdrój', NULL, '628453240'),
  ('Zuzanna', 'Helik', 'Af1Wiu9zj', '9wZQRmQiQnsx', '81-384', 'Klasztorska', '5', NULL, 'Toruń', NULL, '084125910'),
  ('Aleksandra', 'Cebulska', 'IlL8dUaNhofoq', '4A44pLwHE', '73-520', 'Balicka', '56', NULL, 'Warszawa', NULL, '194115606'),
  ('Zuzanna', 'Kazimierczak', 'UoLGmWPeVGVB', 'ZBISwoqOM', '20-851', 'Basztowa', '3e', NULL, 'Frombork', NULL, '515391063'),
  ('Grzegorz', 'Neumann', 'wvkkGNsQ', 'khOjeGC67ha', '33-771', 'Miodowa', '78', NULL, 'Hrubieszów', '9157223028', '883553309'),
  ('Rafał', 'Gołąbek', 'yGnWdg5gQlZ', 'YXfkY5SL51ZY', '73-466', 'Azaliowa', '4', NULL, 'Piła', NULL, '418386125'),
  ('Rafał', 'Goldberg', 'ULZyIkQ7', 'ovhG6tsKT', '21-423', 'Boczna', '90', NULL, 'Nienadówka', NULL, '944606413'),
  ('Aleksandra', 'Głowacka', 'nkSmguK4Ebb', 'co9qdKGobq', '50-688', 'Brożka', '89d', NULL, 'Rybnik', NULL, '728226001'),
  ('Andrzej', 'Sejko', 'GAGKS7WIaZK7', 'EeqTwug4oocH0', '31-492', 'Lipińskiego', '82', '23', 'Sopot', NULL, '820423626'),
  ('Łukasz', 'Sienkiewicz', 'qAdGZfvJqb', 'y8pHKUxhyVN', '36-246', 'Zawiła', '6', NULL, 'Opole', NULL, '606189528'),
  ('Elżbieta', 'Kazimierczak', '2VvhZZ91JGPS', 'u82OR4dcicth', '24-611', 'Niebieska', '5', NULL, 'Zajączki', NULL, '529229529'),
  ('Sandra', 'Zielińska', 'DEbFkRCFDpZ', 'QMpmD2eQ', '91-187', 'Miła', '3b', NULL, 'Sławno', NULL, '989745865'),
  ('Łukasz', 'Witkowski', 'iZ65WbIGHUy', 'ayaOBVEisi', '98-283', 'Halki', '7', NULL, 'Wieruszów', NULL, '786106288'),
  ('Elżbieta', 'Totenbach', 'koN8S8FuH9f', 'D4PZhW81nC', '82-689', 'Lewkowa', '64b', NULL, 'Inowłódz', NULL, '302282705'),
  ('Bartłomiej', 'Kondratek', '1FwEEG7w', 'BP0Iy5wyz', '60-426', 'Ruczaj', '6', NULL, 'Legnica', NULL, '863980125'),
  ('Hans', 'Kondratek', 'KNwT1p7q', 'parJHwZvnje', '21-235', 'Bednarska', '90', NULL, 'Koziebrody', '6984275822', '293409430'),
  ('Hans', 'Kostrikin', 'S0MxPsEvT9Q', 'PA4qrSvj9VVN', '06-402', 'Niebieska', '7', NULL, 'Kielce', NULL, '791791879'),
  ('Dariusz', 'Schneider', '6KjsoXvXcEE', 'A3b5dAIhJ8', '81-948', 'Łódzka', '4', '7', 'Zakopane', NULL, '776599709'),
  ('Iwona', 'Kamińska', 'JrX6wk6fN', 'hhui47TD', '18-020', 'Żniwna', '7', NULL, 'Słupsk', NULL, '424657879'),
  ('Karolina', 'Goldberg', 'yWD1YuSe3', 'McJcWw2LZEl', '75-404', 'Łojasiewicza', '15', NULL, 'Poręba Wielka', NULL, '031999536'),
  ('Iwona', 'Jaworska', 'C7nEr0KFT', 'XkxSupkdYV1o', '76-973', 'Dworcowa', '92a', NULL, 'Olsztyn', NULL, '120159022'),
  ('Brygida', 'Dębska', 'pSBrhG0MOUEf', 'N75ht2hPB35', '20-374', 'Obozowa', '6', NULL, 'Lublin', '7630508318', '036995664'),
  ('Kornel', 'Sejko', 'JDFXl2j9M', 'M3y0Rls0ptGu', '08-151', 'Grota - Roweckiego', '5', '41', 'Człopa', NULL, '543995280'),
  ('Jan', 'Woźniak', 'C2PWk7aX6', 'Lwt71cfQg', '30-889', 'Asnyka', '2', NULL, 'Jelenia Góra', NULL, '846997431'),
  ('Bożydar', 'Sienkiewicz', 'qrRPwYN16hNO', 'iJaHEoUHra', '12-247', 'Karabuły', '88', NULL, 'Rozprza', NULL, '468367189'),
  ('Bartłomiej', 'Hoser', 'btHqcXc89b5', 'DVsDF46BbIrJ', '58-683', 'Halicka', '64', NULL, 'Białystok', NULL, '142685932'),
  ('Kamila', 'Adamczyk', 'Ud9aWtZE', '3SdAUT84q', '61-483', 'Lipińskiego', '38', NULL, 'Włochy', '8147313025', '909665448'),
  ('Henryk', 'Tanenbaum', 'kpY460rquiY', 'bWsWi0X7ygpIk', '22-162', 'Kogucia', '65', NULL, 'Gniezno', '7747223525', '849069501'),
  ('Bartłomiej', 'Sejko', 'ybXvTRYJ', 'AUAm1BSTO', '33-859', 'Traczy', '1', NULL, 'Leszno', NULL, '094939378'),
  ('Weronika', 'Sienkiewicz', 'U7mLMZLX9aV', '9KUyw4jUNKI', '86-566', 'Złota', '33', NULL, 'Radomsko', NULL, '908749035'),
  ('Dariusz', 'Sejko', 'H023V6Wig', 'r1xLTsiYrU2', '00-862', 'Dzielna', '24', NULL, 'Sławno', NULL, '883763496'),
  ('Henryk', 'Dudek', 'MRFBIM4hV', 'h0DhDkM7Akd', '61-801', 'Zielona', '12d', NULL, 'Poręba Wielka', NULL, '286056789'),
  ('Felicyta', 'Wiśniewska', '27YWPjlOB1', 'lmnYqfJvj', '28-916', 'Małka', '7', NULL, 'Piotrków Trybunalski', '6821973391', '519694764'),
  ('Wiktor', 'Głowacka', '5n8ME4uCf5m', 'wy4LdAR2hm', '36-953', 'Teligi', '52', NULL, 'Nienadówka', NULL, '491983280'),
  ('Alicja', 'Sejko', '50deRmClY6', '1Dv13ftL5S', '15-610', 'Wysoka', '49', NULL, 'Poręba Wielka', NULL, '695827426'),
  ('Henryk', 'Majewski', 'Li5jhQkoe', 'P8FrIAHgsY', '55-799', 'Okopowa', '28', NULL, 'Kielce', '6917780337', '944538617'),
  ('Mikołaj', 'Kowalski', 'crben4WA7', 'CnLC0VT6y2', '80-710', 'Dzielna', '8', '28', 'Lesko', NULL, '352769273'),
  ('Iwona', 'Głowacka', 'gEt91yU4', 'os4FRyRSm2', '64-236', 'Błotna', '2', NULL, 'Pacanów', NULL, '509439463'),
  ('Piotr', 'Cebulski', 'Vfm6voSPqH', '4VJ3Iy2ak7VX', '75-454', 'Wiosenna', '4', NULL, 'Frombork', NULL, '959955586'),
  ('Elżbieta', 'Dura', '9PPNh0xN7R', 'qxPhWORtoKMx', '64-057', 'Miodowa', '9', NULL, 'Bydgoszcz', '6860249156', '011792899'),
  ('Sandra', 'Dudek', 'N4p0RDkg', 'nvL1A7nTzU', '04-523', 'Lubostroń', '33', NULL, 'Rabka - Zdrój', NULL, '705460199'),
  ('Hans', 'Helik', 'wTwVp1jaaD', 'pYBa7SRF', '56-541', 'Karabuły', '21e', NULL, 'Bity Kamień', NULL, '068413838'),
  ('Grzegorz', 'Lewandowski', '06GbFs4xJG', '4qgQd0Ndti', '90-482', 'Sądowa', '4', NULL, 'Koniecpol', '4639079277', '251866184'),
  ('Janusz', 'Witkowski', 'kct50eEXo', 'xChi84GKI8', '39-683', 'Traugutta', '4', NULL, 'Zajączki', NULL, '543567709'),
  ('Łukasz', 'Mazur', 'eF09VEyHkEQ', 'M20WAvD8Q', '47-512', 'Pilotów', '2', NULL, 'Gniezno', NULL, '870896616'),
  ('Maciek', 'Neumann', 'Lo2YfXssJUX', '9NEqu5td', '04-042', 'Żytnia', '31', NULL, 'Białka Tatrzańska', NULL, '257414046'),
  ('Agnieszka', 'Kostrikin', 'rH5WY4qm1n', 'wLbH6pJwN', '12-233', 'Azaliowa', '89', NULL, 'Suwałki', NULL, '564187350'),
  ('Paweł', 'Helik', 'AMNFI1qrCTj', 'pTX9lzZkyt', '43-727', 'Skośna', '69', NULL, 'Liszki', NULL, '287592801'),
  ('Kornel', 'Kaczmarek', 'l6dVjY0Kq3', 'clLKzIjk', '74-372', 'Pilotów', '48', '55', 'Gliwice', NULL, '269215774'),
  ('Grzegorz', 'Kamiński', 'GfB7rHApdld7', '4JSDDoEYwsVR', '43-896', 'Czerwone Maki', '76', NULL, 'Tczew', '5707951973', '941432705'),
  ('Agnieszka', 'Filtz', '0JhzBkBsF', 'gi96ouuNPGtnVP', '43-592', 'Jakuba', '7', NULL, 'Bełchatów', NULL, '818634358'),
  ('Dariusz', 'Helik', 'YdZGbCuni7k', 'X8WeydcrRrtyB', '02-403', 'Pilotów', '98', NULL, 'Karpacz', '2250880233', '618625358'),
  ('Wiktor', 'Mełech', 'LnxcjD6pRV', 'fAZHsKTc00', '26-477', 'Kajakowa', '5', NULL, 'Piekło', NULL, '941874460'),
  ('Maciek', 'Gradek', 'RFxacv5Rb', 'QWSA0UV8O0rn', '51-915', 'Miła', '9e', NULL, 'Olsztyn', '7283934327', '736324881'),
  ('Mateusz', 'Tyminśka', 'I7Zot6i0MA5Q', 'uWHCqU0NMLV0u6', '59-217', 'Górna', '50', NULL, 'Sławno', '0899088035', '880974844'),
  ('Elżbieta', 'Adamczyk', 'YyMRxtkc', '29MsIUiMU', '92-260', '3 - maja', '56', NULL, 'Szczecin', NULL, '112951363'),
  ('Kornel', 'Głowacka', 'K0GQSaWVg', 'WUuJBriupL', '97-275', 'Traczy', '9', NULL, 'Kołobrzeg', '7215516190', '004117205'),
  ('Karolina', 'Grabowska', '9X0iiK6L5X', 'f2LwwTpbw3Ak', '50-561', 'Pawia', '8', NULL, 'Kędzierzyn - Koźle', NULL, '406637914'),
  ('Bartłomiej', 'Mełech', 'BmM9alnu', 'JsmvNfFNcK', '38-656', 'Mariacka', '9', '42', 'Polańczyk', NULL, '263420370'),
  ('Hans', 'Nowakowski', 'ZW15PQUuISb', 'pmsNVkSDk8', '12-842', 'Bajeczna', '60', NULL, 'Dzierżawy', NULL, '610817256'),
  ('Aleksandra', 'Sejko', 'ypwAJlUrRCnx', 'dpwMWMUBlG', '85-967', 'Kapucyńska', '90a', NULL, 'Chorzów', NULL, '907181342'),
  ('Filip', 'Pawlak', '0ClTMjmqRSbw', 'z5uT0HZIyp', '69-915', 'Balicka', '8', NULL, 'Adamów', '4895781511', '703197145'),
  ('Maciek', 'Kazimierczak', 'ypPBs7BnR', '50cxvAKXm4O7', '11-051', 'Nowaka', '8', NULL, 'Ostrów Wielkopolski', '8768887998', '291830817'),
  ('Anna', 'Tanenbaum', 'ASfAbMMUFam', 'cFj5TpiiewLD', '01-041', 'Klasztorska', '5', NULL, 'Bobry', NULL, '229771528'),
  ('Weronika', 'Klemens', 'c7PS8G7x', '8kYB2BrLVgAhh', '40-028', 'Miła', '11', NULL, 'Kołobrzeg', NULL, '062037305'),
  ('Elżbieta', 'Piotrowska', 'hj1BWMm8sSz', 'CFGDLU1it', '12-462', 'Północna', '72', NULL, 'Kraków', '6514249023', '471636660'),
  ('Joanna', 'Dąbrowkska', 'wvIFMeZrKJk', '7wGn8k2HG', '55-084', 'Tęczowa', '58a', NULL, 'Opole', NULL, '408930606'),
  ('Grzegorz', 'Bobak', '35VXTAPpb7', '3n9TFvgYB', '80-565', 'Tkacka', '2c', NULL, 'Poznań', NULL, '931708185'),
  ('Mikołaj', 'Dudek', '9vbRcHj51a', 'hcb7CuyFAP', '25-535', 'Halicka', '12', NULL, 'Tymbark', NULL, '576291397'),
  ('Weronika', 'Pupa', 'aCXiMRNcpq', 'aL86gIjqOZUg', '84-551', 'Chopina', '14', NULL, 'Warszawa', NULL, '841659668'),
  ('Jan', 'Wiśniewski', 'UruzPoyd2', 'fzlNjgtJTken', '29-666', 'Hleny', '38', '1', 'Puławy', '9077342914', '399443511'),
  ('Piotr', 'Nowakowski', 'WeNK3vGa', 'rIuzWpzA3', '46-689', 'Conrada', '41e', NULL, 'Słupsk', NULL, '135515199'),
  ('Janusz', 'Woźniak', 'ltGVvacd2Oe', '3ya1XYhsT', '29-293', 'Frycza', '95', NULL, 'Zgierz', '5192063914', '691889908'),
  ('Andrzej', 'Pawlak', 'g5yKtFhtdyw', 'mEzzScZ4EKuk', '59-687', 'Wałowa', '69b', NULL, 'Łeba', NULL, '202742629'),
  ('Franciszek', 'Jachowicz', '1g585Li5yQL', 'gEN8oh18hN4T', '18-882', 'Balicka', '1e', NULL, 'Rabka - Zdrój', NULL, '980810638'),
  ('Katarzyna', 'Grabowska', 'Hd5oFTyNYXq', 'PqyhHIb9yp', '48-459', 'Błotna', '8c', NULL, 'Kędzierzyn - Koźle', NULL, '373780963'),
  ('Wiktor', 'Klemens', 'pCklWMro9clg', 'XsOWBTyTssT', '28-879', 'Pilotów', '82f', '84', 'Rozprza', NULL, '580313761'),
  ('Zuzanna', 'Adamczyk', 'd3dJhHrx3mA3gxY', '1pFNJVGo', '93-619', 'Domowa', '99', NULL, 'Łeba', '4206867706', '301070795'),
  ('Sandra', 'Schneider', 'ZX6kDL6JKb', 'iQEio35as', '90-211', 'Siwna', '8', NULL, 'Kiełczyce', NULL, '584822604'),
  ('Bartłomiej', 'Johansen', 'ZhUf2EU23h', 'OxPMhxZti', '20-440', 'Cisowa', '46', NULL, 'Elbląg', NULL, '110734232'),
  ('Dariusz', 'Sienkiewicz', 'AXBV9jVFY8', 'P9AFu67Zc', '88-434', 'Korfantego', '5', NULL, 'Opoczno', NULL, '546041867'),
  ('Paweł', 'Piotrowski', 'OnFGS8me5m4', 'QJVk1uj42zR', '94-815', 'Dymnik', '20', NULL, 'Tarnów', NULL, '727821140'),
  ('Jacek', 'Kazimierczak', 'R71u3Oa9N', 'SGLql9mxWccU', '28-633', 'Bracka', '5', NULL, 'Koziebrody', '2760804768', '663496339'),
  ('Andrzej', 'Pupa', 'KDhpyFxIwZq', 'JWU9w5DT5', '39-315', 'Niebieska', '1f', '58', 'Nowy Targ', NULL, '241323289'),
  ('Tomasz', 'Wiśniewski', 'axgsPrvtku', 'dPKWPNub', '08-723', 'Lewkowa', '58', NULL, 'Żary', NULL, '071377386'),
  ('Adam', 'Filtz', '1DTVs4Q2X', 'CIK17br3Pd3', '13-905', 'Miodowa', '95', NULL, 'Augustów', '8426907143', '171608241'),
  ('Wiktor', 'Malinowski', '1C76xItZbs0up', 'JaCKVEJL76Uf', '90-567', 'Kolejowa', '69b', '94', 'Zgierz', NULL, '314601591'),
  ('Weronika', 'Woźniak', 'oUuy7ViqQnR6', 'J2WsiYgM', '23-867', 'Asnyka', '7', NULL, 'Baby', NULL, '404884836'),
  ('Agnieszka', 'Gross', 'hhJwfLqLW', 'zqipPKMXes', '50-981', 'Sapiechy', '60', '8', 'Szczecin', '6878536649', '724369459'),
  ('Zuzanna', 'Monarek', 'feAtTIeLGJh', 'vFo0v1JlA9', '09-735', 'Czerwone Maki', '77', NULL, 'Trzebinca', '4124843639', '074107908'),
  ('Franciszek', 'Mazur', 'bFY5uImB2mWZ', 'twTP3ZwwzQ', '83-499', 'Korfantego', '3d', '7', 'Łeba', NULL, '062833875'),
  ('Jan', 'Jachowicz', 'gigaZ5FgA', 'nDaLVkV2', '81-608', 'Młynowa', '7', '9', 'Adamów', NULL, '512469192'),
  ('Sandra', 'Majewska', '5fIB6H2sXM', 'lzryNwQH9Q', '15-285', 'Północna', '59', NULL, 'Malbork', '6283621898', '566481391'),
  ('Felicyta', 'Goldberg', 'Mc6VfMJUM', 'vUnd5RxduaRzZ', '13-787', 'Conrada', '8', '68', 'Ojców', NULL, '525853919'),
  ('Jacek', 'Hoser', 'FbgfOTqmLQMA', 'CEYMCNST', '68-630', 'Halki', '63', NULL, 'Człopa', NULL, '873480214'),
  ('Mateusz', 'Kamiński', 'D9UnvDf5i0Fj', 'vi1KxEFsT', '61-940', 'Falowa', '4f', NULL, 'Bytów', NULL, '782184630'),
  ('Michał', 'Homoncik', 'gnvP4afyvQ2Z', 'mvgj8kL57', '87-650', 'Klasztorska', '3', NULL, 'Jędczydół', NULL, '664127654'),
  ('Bartłomiej', 'Dudek', 'WNyi66MJ4LYd', 'rbemx4nxW1UQv', '09-622', 'Dworcowa', '91', '1', 'Kamieńsk', NULL, '718516070'),
  ('Tomasz', 'Głowacka', '22G5VTb4W5', '7bra4R1sw', '72-705', 'Piastowka', '1', NULL, 'Zamośc', NULL, '004389700'),
  ('Agnieszka', 'Gołąbek', 'B3416Yf1f', 'NYJ0HdZ9B', '90-486', 'Leśmiana', '28', NULL, 'Inowłódz', NULL, '687163740'),
  ('Brygida', 'Dudek', 'Y9aYr6IA1Cd', 'Znu90Ya6Z1o', '95-137', 'Jana Pawła II', '68', NULL, 'Zielona Góra', NULL, '759852664'),
  ('Franciszek', 'Wiśniewski', 'lPn9HBY9rM', 'tFx89Zd48A', '85-694', 'Rolna', '66', NULL, 'Okocim', NULL, '602452812'),
  ('Jarosław', 'Dąbrowkski', 'Jw2IodwENHqJ', 'nnevFRGa', '46-465', 'Bracka', '1c', NULL, 'Rybnik', '5150493768', '016529105'),
  ('Małgorzata', 'Neumann', 't9cCgpv3jhk8', 'qo5LlLq9waEL', '44-645', 'Rowida', '70', NULL, 'Koszalin', NULL, '490574942'),
  ('Henryk', 'Kondratek', 'ofZyJIxVH', 'ZzOjlWgV6Q', '20-846', 'Górna', '32', NULL, 'Koziebrody', NULL, '920750912'),
  ('Michał', 'Tyminśka', '0gn6yjcEq', 'JAwtOPcm', '23-927', 'Dzielna', '7d', NULL, 'Białystok', NULL, '329010682'),
  ('Wiktor', 'Dostojewski', 'nEwfflus3W', '5t5dJoZOP', '91-139', 'Obozowa', '5', NULL, 'Poręba Wielka', '4426059279', '886566174'),
  ('Elżbieta', 'Gradek', '70nruRAe', '5C5KUy2D5', '67-371', 'Traczy', '2a', NULL, 'Krynica Zdrój', NULL, '921313342'),
  ('Bożydar', 'Dura', '8IGMd7aQ0OE', 'vMogBnm4bVK', '79-111', 'Orla', '6', NULL, 'Drozdów', NULL, '672826166'),
  ('Filip', 'Dudek', 'nrqZ3WqHs', 'IO8U1pgMlek', '43-780', '3 - maja', '44', NULL, 'Łódź', '9084815727', '704764807'),
  ('Mikołaj', 'Sienkiewicz', 'XwgtegKnSdG', 'KD6m2ss2', '72-684', 'Dworcowa', '95', NULL, 'Świnoujście', NULL, '955753559'),
  ('Karolina', 'Helik', 'eoYkIkTEXG3', 'yC6IrCbG', '86-165', 'Lasek', '1', NULL, 'Żary', NULL, '683703255'),
  ('Henryk', 'Głowacka', 'Nmcoh8Wz', '2l76cuhYQSjyW', '08-221', 'Kajakowa', '19', NULL, 'Rybnik', NULL, '902266838'),
  ('Karolina', 'Witkowska', 'I36vK3ydzr', 'qivmSdj5NpF', '37-539', 'Pilotów', '20', NULL, 'Zgon', NULL, '895740225'),
  ('Dariusz', 'Głowacka', 'HtzIM8gfnbj', 'BJWrA1WB', '28-540', 'Jaskra', '95', NULL, 'Tczew', NULL, '194153971'),
  ('Jacek', 'Dudek', 'XJYwrKA2pwX6p', 'ExwnSqv37pB', '05-403', 'Okopowa', '1e', '72', 'Szczyrk', NULL, '285778683'),
  ('Jakub', 'Neumann', 'JgzCAKbHV', 'EphEw8ktQjub', '95-418', 'Dr Jana Piltza', '4', NULL, 'Sejny', '4170348827', '780962313'),
  ('Jarosław', 'Nowakowski', '8edvHx56GJ', '7JSpvlvIHMzy', '28-939', 'Hutnicka', '1', NULL, 'Polańczyk', NULL, '508641165'),
  ('Rafał', 'Helik', 'h7ES65CoBv', '5pSH8sbH5i', '55-619', 'Lewkowa', '85', NULL, 'Kołobrzeg', NULL, '875935932'),
  ('Felicyta', 'Górska', 'z0TwjNqwQoVI', 'ZZwSyBS38', '62-552', 'Conrada', '3', '66', 'Toruń', NULL, '080820296'),
  ('Felicyta', 'Sienkiewicz', 'ZtPnqxciA1u', 'Y336TcWXx1JQU5', '31-519', 'Grota - Roweckiego', '21', NULL, 'Suwałki', '8321300052', '207074807'),
  ('Kamila', 'Kucharczyk', 'DvXOGSCvtOm', 'lU2EXmiNhQUmch', '75-548', 'Wiosenna', '94', '13', 'Malbork', NULL, '158360227'),
  ('Piotr', 'Neumann', 'VTeyXTkLMu', 'ardtqPbxSMUp', '63-955', 'Jana Pawła II', '56', NULL, 'Tczew', '4797293779', '038460925'),
  ('Michał', 'Monarek', 'BVo5Qq8EFeH', 'Hvj6OmDQAYp8', '75-068', 'Rzeczna', '66e', NULL, 'Nowy Targ', NULL, '057534187'),
  ('Adam', 'Słowacki', 'vpXKPOurCE', 'QudRinscdhM', '20-564', 'Młynowa', '1', NULL, 'Pupki', NULL, '978159805'),
  ('Filip', 'Schmidt', 'OCSHUCBH', 'qQp0WTgaE4', '96-032', 'Mariacka', '90', '46', 'Trzebinca', NULL, '593054136'),
  ('Bożydar', 'Gross', 'pRVKLRr18cZ', 'IrQwwrlqWRY', '62-242', 'Grota - Roweckiego', '85', NULL, 'Chorzów', '7458357018', '226959941'),
  ('Zuzanna', 'Sejko', 'mkXeReStR', 'hTUkrIjW4', '62-052', 'Skośna', '2e', NULL, 'Gdańsk', NULL, '432434049'),
  ('Jarosław', 'Schneider', 'BmAAqZ9VNs2', 'rYPoHyPoF4S', '03-283', 'Sportowa', '8', NULL, 'Wałcz', '7893985932', '007553297'),
  ('Mateusz', 'Kondratek', 'tNAzw14LRW', 'jrKeSgvWRs5g', '39-288', 'Wałowa', '1', NULL, 'Koszalin', NULL, '011019965'),
  ('Katarzyna', 'Wojciechowska', 'meWSTRCg', 'Wa6YPwiSHLf', '53-639', 'Złota', '63e', NULL, 'Warszawa', NULL, '887621798'),
  ('Jacek', 'Majewski', 'kVyRnbk7', 'E32uGBDU6', '04-985', 'Goetla', '98', NULL, 'Ostrów Wielkopolski', '1038805872', '579025649'),
  ('Mateusz', 'Malinowski', 'yPQCjcIQQxx', 'VZJUPrAF', '64-484', 'Żytnia', '60', NULL, 'Uniejów', NULL, '340336579'),
  ('Iwona', 'Klemens', '6BWL9ce52LLu', 'hRXKfV3a08', '19-704', 'Ochocza', '2', NULL, 'Legnica', NULL, '130977313'),
  ('Aleksandra', 'Mełech', 'UJZjLmGnev', 'ETEGX5VDb', '78-007', 'Mariacka', '99b', NULL, 'Legnica', NULL, '650474648'),
  ('Maciek', 'Helik', 'oVD6mDJM', 'g2WnZxl2kKa6G', '74-712', 'Conrada', '79', NULL, 'Olsztyn', NULL, '179651295'),
  ('Elżbieta', 'Wiśniewska', 'uw4CsQzjuab', 'NBc8kmwQb', '66-526', 'Łódzka', '67', NULL, 'Rybnik', '1727702372', '495000169'),
  ('Rafał', 'Górski', 'zlJAmheB0L', 'RQsUtd1P', '64-365', 'Wysoka', '4', NULL, 'Zabrze', NULL, '507660893'),
  ('Jacek', 'Woźniak', 'AfKNPiTEz6QAZ', 'yX4SrtLTmC', '65-247', 'Domowa', '64', NULL, 'Ojców', '3657177854', '236882570'),
  ('Zuzanna', 'Kowalska', 'B1oPG7lNp36', 'FfMDvrE1KIi', '84-418', 'Korfantego', '2', NULL, 'Koniec', '7587304225', '915364025'),
  ('Aleksandra', 'Gołąbek', '1Pjw6g0x0U', 'bjkKxYn78vv', '50-694', 'Tkacka', '73', NULL, 'Krynica Zdrój', NULL, '799393008'),
  ('Dariusz', 'Pawlak', 'xYrv3AYck96', 'j68WtlLW', '71-177', 'Legionów', '8', '91', 'Nienadówka', NULL, '309605119'),
  ('Karolina', 'Stępień', 'J7snVceN8zk', 'uJsQfMLtsvTK', '75-839', 'Rolna', '82', NULL, 'Sopot', NULL, '489028398'),
  ('Bożydar', 'Mełech', 'IqcPyKZeETgi', 'tU0ROupVYHidP', '70-412', 'Irysowa', '79d', '58', 'Iwonicz Zdrój', '5601163979', '949646090'),
  ('Adam', 'Nowakowski', 'g3qCxZA8Ay', 'Rcy7F3m4B', '77-586', 'Legionów', '21', '71', 'Łomża', NULL, '495591770'),
  ('Łukasz', 'Zieliński', 'n9Udg4geU', 'yVEq48gyH', '92-336', 'Górna', '1', NULL, 'Zabrze', '3312492486', '566914118'),
  ('Filip', 'Cebulski', 'KhOfe8Lu2', 'vJJj6nPhO9', '99-118', 'Ruczaj', '17', NULL, 'Mszana Dolna', '5489807390', '581834353'),
  ('Brygida', 'Stępień', 'CX5Gh4Zjqdn', 'dn3kf5e3Of', '78-133', 'Balicka', '3', '44', 'Poniatów', NULL, '779889326'),
  ('Małgorzata', 'Jachowicz', 'bwkP2qvDieQJ', 'mpBTMTPqBe0j', '44-303', 'Rzeczna', '52', NULL, 'Sanok', NULL, '672081237'),
  ('Szymon', 'Bobak', 'mTMEekUa', 'JJTpjCeNV5g', '63-259', 'Wandy', '1', NULL, 'Nysa', NULL, '502827871'),
  ('Weronika', 'Nowak', 'hrIZjo6Plm', 'hHBnO5YQQf', '92-161', 'Fatimska', '4', NULL, 'Karpacz', '5160386844', '191703178'),
  ('Paulina', 'Filtz', 'D3ZIv7Ew', 'EoPwdddkYhf', '05-497', 'Obozowa', '9e', NULL, 'Koło', NULL, '952684319'),
  ('Iwona', 'Tyminśka', 'DMCxVtaX', '8Haut3tQm8KR', '91-243', 'Traczy', '9f', NULL, 'Legnica', NULL, '674167901'),
  ('Rafał', 'Tanenbaum', 'KTH9rU4oSg', 'Gb4Bmhw5u', '89-723', 'Sokola', '69', NULL, 'Pcim', NULL, '846187990'),
  ('Jacek', 'Grabowski', 'LhYPJxHNy4cg', 'vG1NAsJ2f', '97-350', 'Zielona', '1e', NULL, 'Ciechanów', NULL, '435780284'),
  ('Henryk', 'Dąbrowkski', 'z8YuNHSWTH', 'iSnFIsgqfFe', '99-207', '3 - maja', '66', '56', 'Trzebinca', NULL, '427475243'),
  ('Filip', 'Kowalski', 'j9FI4kOD', 'VbjM0Z9taU', '17-097', 'Paska', '15', '4', 'Żary', '1487644906', '697810739'),
  ('Anna', 'Totenbach', 'gGlwdQz2W', 'IQpGU6l0Mqf', '21-245', 'Bajeczna', '19', NULL, 'Toruń', NULL, '897036722'),
  ('Andrzej', 'Wojciechowski', '2jURpXNbQ', 'kMNAZs1cz', '18-185', 'Polna', '16e', '38', 'Koniec', NULL, '817966355'),
  ('Piotr', 'Woźniak', 'DVfQJlJb9pt', 'fppqMW2H6uX', '81-886', 'Lubicz', '6', NULL, 'Sandomierz', NULL, '824525736'),
  ('Weronika', 'Johansen', '3RhsV4LnUV', 'ul652U8uK8e', '42-429', 'Konopnickiej', '5', NULL, 'Jajkowo', NULL, '944487863'),
  ('Małgorzata', 'Schmidt', 'rCNIq3ejtM', 'PAon4nhhwi', '29-661', 'Magnolii', '2', NULL, 'Końskie', NULL, '190369278'),
  ('Jan', 'Cebulski', 'Ka8xJxkVuv', 'e9jFVphGk57', '68-791', 'Kogucia', '71', NULL, 'Wałbrzych', NULL, '372168650'),
  ('Bartłomiej', 'Homoncik', 'VU9dkRE3', 'DULhJFQlfS', '22-014', 'Frycza', '8', NULL, 'Jędczydół', NULL, '980837347'),
  ('Jan', 'Pawlak', 'rW9OKCpuJ3I', 'gyYGSsVUBHP', '19-591', 'Okopowa', '1a', NULL, 'Pcim', '4236211749', '754989140'),
  ('Małgorzata', 'Tanenbaum', '5CKdn5RT', 'hizKIuFa1f', '68-365', 'Łódzka', '3', NULL, 'Trzebinca', NULL, '939937907'),
  ('Felicyta', 'Witkowska', 'XqywYCXF', 'sm2MgJUQozK8', '19-160', 'Karabuły', '4', NULL, 'Chełm', NULL, '936029327'),
  ('Mikołaj', 'Pawlak', 'Zl08EZVAC0Y', 'vrWMGHuO9Sa', '39-175', 'Ryba', '1', '77', 'Wałcz', NULL, '064930675'),
  ('Maciek', 'Mazur', '2aMmhguxSc', 'iBy1pn0wF', '19-211', 'Jachowicza', '68', NULL, 'Rzeszów', '0599187738', '120435244'),
  ('Bartłomiej', 'Gross', 'nhKnZ04Jo2', 'WC8hQzePAp8', '20-514', 'Niebieska', '18', NULL, 'Katowice', '5418988415', '177682222'),
  ('Paweł', 'Wiśniewski', 'ClF0edCO', 'uFF4OlMSkECwm', '47-069', 'Bracka', '2e', NULL, 'Opoczno', '9703408317', '051073417'),
  ('Weronika', 'Neumann', 'Bbfuclu08Jq', 'DL14qEjOv', '88-288', 'Łojasiewicza', '5', NULL, 'Baby', NULL, '615104937'),
  ('Łukasz', 'Wiśniewski', '2cMd75D6evx', 'Clg8WE2Qng', '67-836', 'Okopowa', '38', '40', 'Okocim', '0313113578', '182585877'),
  ('Franciszek', 'Filtz', '7EDLMuIPzKwz', 'cCFWryRe', '86-855', 'Pilotów', '91', NULL, 'Iwonicz Zdrój', NULL, '886391626'),
  ('Elżbieta', 'Nowakowska', 'VlOP0sV0NK', 'jNhlx3CnaD', '02-656', 'Sportowa', '75', NULL, 'Rzeszów', NULL, '217907211'),
  ('Adam', 'Kondratek', 'ju5PzDxeXB', '59z1qP9v', '80-563', 'Żniwna', '4', NULL, 'Tymbark', NULL, '010020564'),
  ('Kornel', 'Kaczmarek', 'obInrEQITnKz', 'BaZneLrpZkO', '05-753', 'Nasza', '5', NULL, 'Poniatów', NULL, '299407360'),
  ('Filip', 'Dąbrowkski', 'aCqSwkhpY', '8ndaH4hqY0w', '58-509', 'Ziołowa', '10', '77', 'Sejny', NULL, '085945582'),
  ('Piotr', 'Johansen', '5CVMb4wHwtT', 'siAo293E8jS', '65-458', 'Błotna', '62', '19', 'Ciechanów', '9883354579', '143708176'),
  ('Łukasz', 'Stępień', 'C9RquyOjnqJp', 'kzrVvj0b8', '03-160', 'Sportowa', '82', NULL, 'Elbląg', '9625768584', '470790725'),
  ('Alicja', 'Sejko', 'eX4lT14mq', 'uJpT8fDY', '60-347', 'Frycza', '2', NULL, 'Włoszczowa', NULL, '425419324'),
  ('Elżbieta', 'Mazur', 'd2fcYWfIE', '13YIlwJBQmE9', '27-261', '3 - maja', '2', NULL, 'Żary', '7803816701', '436484879'),
  ('Mikołaj', 'Kostrikin', 'VzgkAv4TTzqj', 'U6i7Z9im', '89-030', 'Nowaka', '8c', NULL, 'Kołobrzeg', NULL, '805185784'),
  ('Sandra', 'Majewska', 'yEnSqeAdjuh', 'SPkWOnM5m', '97-976', 'Sodowa', '4', NULL, 'Przedbórz', '1229658270', '738499752'),
  ('Jan', 'Pawlak', '26f1mYZPF', 'jdc2luGPeA', '37-477', 'Halki', '45', NULL, 'Moszczenica', '2447117259', '094226574'),
  ('Bożydar', 'Dostojewski', 'zzY13Ydy', 'yGc9HlPQZif', '30-369', 'Pilotów', '92', NULL, 'Legnica', NULL, '159222942'),
  ('Szymon', 'Mełech', 'dnBUCCy9Kd', 'cMVitTBz', '41-099', 'Irysowa', '13', NULL, 'Lesko', NULL, '426238593'),
  ('Bożydar', 'Nowakowski', 'hBgchK3UQhyf', 'GkpsK8MROBI', '19-763', 'Miodowa', '19', NULL, 'Opoczno', '7651659850', '945075416'),
  ('Filip', 'Totenbach', '7VjZpkURqp', 'OMpKA1RD4s', '75-416', 'Bema', '59', NULL, 'Poniatów', '4070712908', '173664859'),
  ('Felicyta', 'Bobak', 'prj4Jp4mo7', 'wPD6djb2pkno', '25-140', 'Ryba', '1d', NULL, 'Wieluń', NULL, '783231836'),
  ('Mateusz', 'Helik', 'IxAIAiv2ZAj57', 'vFNpZ3dfDQg', '77-253', 'Zawiła', '65c', NULL, 'Wierzeje', NULL, '452729736'),
  ('Tomasz', 'Homoncik', 'HQitrKF7S8', 'D9ls7x9XFQU', '44-238', 'Ćwiklińskiej', '66', NULL, 'Rozprza', NULL, '327465560'),
  ('Dariusz', 'Hoser', 'VpaVfHsv', 'LoTiML1AvkCm', '90-167', 'Lasek', '21', NULL, 'Inowrocławek', '9668425075', '422823513'),
  ('Jakub', 'Nowak', 'PYAL1jysq', 'UE3PQIR9pdL2', '05-172', 'Jesionowa', '4', '84', 'Kleszczów', NULL, '066133793'),
  ('Sandra', 'Kaczmarek', 'Gsp8BoGIZ5', 'NFFT0Y99xodx', '96-949', 'Goetla', '13', NULL, 'Zabrze', NULL, '113105058'),
  ('Mateusz', 'Kazimierczak', 'kY9AmAg7gYh', 'cmvPCKZntnmQ', '81-014', 'Lewkowa', '85', NULL, 'Gdańsk', NULL, '028757404');
INSERT INTO discounts (name, value) VALUES
  ('Bronze Client Rank', 0.03),
  ('Silver Client Rank', 0.05),
  ('Gold Client Rank', 0.08),
  ('Platinum Client Rank', 0.12);
INSERT INTO shippers (name, phone_number) VALUES
  ('DHŁ', '134654324'), ('OutPost', '968522515'),
  ('Poczta Polska', '651115311'), ('DBD', '532225222'),
  ('UPSsss', '424111155'), ('GiLS', '110594033'),
  ('FedEXP', '500202343'), ('Pocztext', '602028199'),
  ('TNT - explosives', '110054698'), ('OPECK', '842000224'),
  ('geSCHENKER', '549282095'), ('IKS-Press', '406593928'),
  ('Amarzon', '324106532');
INSERT INTO genres (name) VALUES
  ('Biografia'), ('Kryminał'), ('Thriller'), ('Sensacja'),
  ('Historyczna'), ('Przyrodnicze'), ('Dokumentalne'), ('Horror'),
  ('Komedia'), ('Naukowa'), ('Psycholgiczna'), ('Fantasy'),
  ('Kucharskie'), ('Science-Fiction'), ('Słowniki'), ('Encyklopedie'),
  ('Romanse'), ('Ballady'), ('Wiersze'), ('Obrazkowe'),
  ('Młodzieżowe'), ('Hobbistyczne'), ('Sportowe'), ('Pamiętnik'),
  ('Autobiografia'), ('Dzienniki'), ('Ogrodnicze'), ('Dziecięce'),
  ('Detyktywistyczne'), ('Religijne'), ('Poezja współczesna'),
  ('Literatura skandynawska');
INSERT INTO books_genres
(book_id, genre_id)
VALUES
  ('978-62-82077-46-4', 18),
  ('978-66-52710-99-7', 29),
  ('978-93-09965-40-9', 20),
  ('978-79-47426-94-0', 12),
  ('978-79-47426-94-0', 10),
  ('978-79-47426-94-0', 10),
  ('978-58-79768-35-0', 12),
  ('978-58-79768-35-0', 11),
  ('978-26-16866-55-7', 22),
  ('978-51-96834-91-8', 18),
  ('978-51-96834-91-8', 30),
  ('978-51-96834-91-8', 26),
  ('978-82-94547-43-8', 20),
  ('978-90-69351-21-4', 32),
  ('978-90-69351-21-4', 24),
  ('978-90-69351-21-4', 5),
  ('978-05-68350-24-7', 1),
  ('978-10-15567-32-0', 20),
  ('978-10-15567-32-0', 2),
  ('978-10-15567-32-0', 31),
  ('978-51-33563-64-4', 9),
  ('978-51-33563-64-4', 21),
  ('978-47-29403-93-1', 31),
  ('978-03-26475-98-0', 20),
  ('978-45-43223-75-9', 6),
  ('978-20-96834-48-4', 19),
  ('978-20-96834-48-4', 2),
  ('978-05-12554-44-6', 21),
  ('978-05-12554-44-6', 21),
  ('978-20-49946-06-2', 15),
  ('978-31-75798-39-8', 22),
  ('978-53-96820-70-2', 23),
  ('978-53-96820-70-2', 20),
  ('978-32-79944-80-0', 28),
  ('978-32-79944-80-0', 31),
  ('978-27-09742-93-9', 29),
  ('978-48-31459-66-6', 17),
  ('978-34-35195-60-8', 22),
  ('978-00-56400-97-1', 8),
  ('978-79-00130-40-8', 9),
  ('978-79-00130-40-8', 20),
  ('978-79-00130-40-8', 20),
  ('978-83-39028-32-8', 2),
  ('978-83-39028-32-8', 7),
  ('978-30-79974-26-3', 28),
  ('978-30-79974-26-3', 15),
  ('978-30-79974-26-3', 14),
  ('978-73-62814-70-6', 15),
  ('978-51-93468-20-8', 25),
  ('978-50-77648-87-6', 18),
  ('978-41-36186-05-0', 15),
  ('978-36-02155-51-6', 13),
  ('978-28-75201-24-1', 13),
  ('978-05-44062-74-0', 32),
  ('978-79-31446-90-1', 12),
  ('978-71-44226-85-5', 15),
  ('978-53-46337-70-4', 30),
  ('978-53-46337-70-4', 1),
  ('978-96-00175-74-5', 16),
  ('978-96-00175-74-5', 2),
  ('978-86-65773-79-2', 27),
  ('978-86-65773-79-2', 30),
  ('978-86-65773-79-2', 25),
  ('978-86-65773-79-2', 19),
  ('978-78-60046-69-0', 20),
  ('978-30-80070-70-5', 30),
  ('978-30-80070-70-5', 23),
  ('978-30-80070-70-5', 32),
  ('978-30-80070-70-5', 6),
  ('978-66-09831-75-3', 2),
  ('978-66-09831-75-3', 6),
  ('978-86-64942-96-4', 20),
  ('978-86-64942-96-4', 25),
  ('978-00-79377-11-9', 22),
  ('978-34-67169-07-3', 11),
  ('978-34-67169-07-3', 2),
  ('978-71-88713-50-8', 9),
  ('978-71-88713-50-8', 16),
  ('978-50-79860-65-4', 2),
  ('978-05-18968-85-4', 21),
  ('978-05-18968-85-4', 11),
  ('978-05-18968-85-4', 28),
  ('978-05-18968-85-4', 18),
  ('978-58-12517-61-2', 24),
  ('978-59-93843-98-2', 25),
  ('978-59-93843-98-2', 3),
  ('978-03-19379-22-4', 22),
  ('978-03-19379-22-4', 29),
  ('978-03-19379-22-4', 8),
  ('978-48-10313-42-0', 26),
  ('978-48-10313-42-0', 6),
  ('8-379-32742-X', 27),
  ('1-435-73862-4', 10),
  ('2-342-96369-6', 11),
  ('2-265-10974-6', 32),
  ('2-265-10974-6', 3),
  ('2-265-10974-6', 6),
  ('8-207-74950-4', 1),
  ('9-181-66565-2', 26),
  ('9-330-73476-6', 30),
  ('9-330-73476-6', 22),
  ('9-330-73476-6', 25),
  ('7-131-62625-2', 10),
  ('7-131-62625-2', 11),
  ('4-502-18561-2', 7),
  ('4-502-18561-2', 18),
  ('7-648-28542-8', 20),
  ('3-613-10050-9', 23),
  ('7-674-80113-6', 2),
  ('0-358-15689-0', 7),
  ('0-358-15689-0', 12),
  ('0-358-15689-0', 25),
  ('0-097-31291-6', 25),
  ('0-097-31291-6', 1),
  ('0-097-31291-6', 19),
  ('1-929-82191-3', 9),
  ('1-929-82191-3', 20),
  ('6-563-85697-7', 29),
  ('6-563-85697-7', 1),
  ('6-563-85697-7', 28),
  ('2-957-54517-9', 13),
  ('2-957-54517-9', 20),
  ('2-957-54517-9', 32),
  ('2-957-54517-9', 1),
  ('6-254-69347-X', 23),
  ('6-254-69347-X', 2),
  ('9-366-95869-9', 29),
  ('9-366-95869-9', 6),
  ('9-366-95869-9', 31),
  ('9-366-95869-9', 8),
  ('3-204-42710-2', 27),
  ('3-204-42710-2', 23),
  ('3-204-42710-2', 5),
  ('6-026-55108-5', 2),
  ('6-026-55108-5', 22),
  ('8-367-23769-2', 27),
  ('3-491-58415-9', 22),
  ('5-640-70773-9', 3),
  ('1-310-47717-5', 3),
  ('1-310-47717-5', 5),
  ('1-310-47717-5', 26),
  ('7-938-45157-6', 10),
  ('8-615-98526-X', 15),
  ('0-996-48453-1', 13),
  ('0-996-48453-1', 19),
  ('3-586-18506-5', 24),
  ('3-586-18506-5', 17),
  ('3-586-18506-5', 21),
  ('3-586-18506-5', 25),
  ('5-513-44050-4', 17),
  ('5-513-44050-4', 32),
  ('2-334-00114-7', 22),
  ('2-334-00114-7', 7),
  ('8-011-13440-X', 6),
  ('8-011-13440-X', 6),
  ('8-011-13440-X', 26),
  ('8-011-13440-X', 11),
  ('0-001-60391-4', 16),
  ('0-001-60391-4', 8),
  ('8-488-29842-0', 23),
  ('8-488-29842-0', 16),
  ('0-845-14093-0', 3),
  ('0-845-14093-0', 30),
  ('0-845-14093-0', 6),
  ('8-760-86031-6', 27),
  ('1-179-65828-0', 20),
  ('1-179-65828-0', 2),
  ('4-593-63554-3', 10),
  ('4-593-63554-3', 9),
  ('1-485-02226-6', 32),
  ('2-604-11818-1', 25),
  ('2-824-94000-X', 10),
  ('8-129-54778-3', 12),
  ('8-129-54778-3', 4),
  ('9-817-11951-3', 30),
  ('3-915-70380-X', 27),
  ('7-865-31646-1', 9),
  ('7-865-31646-1', 20),
  ('9-887-75632-6', 7),
  ('3-426-31630-7', 20),
  ('6-343-23885-9', 7),
  ('6-343-23885-9', 3),
  ('6-343-23885-9', 23),
  ('6-241-72416-9', 15),
  ('1-267-84125-7', 24),
  ('3-528-33212-3', 3),
  ('3-528-33212-3', 23),
  ('3-528-33212-3', 26),
  ('3-528-33212-3', 30),
  ('1-866-69289-5', 26),
  ('1-866-69289-5', 15),
  ('0-418-20126-9', 23),
  ('0-418-20126-9', 27),
  ('0-418-20126-9', 23),
  ('4-703-20760-5', 31),
  ('4-703-20760-5', 2),
  ('8-858-19512-4', 25),
  ('7-100-38088-X', 15),
  ('7-100-38088-X', 26),
  ('7-100-38088-X', 12),
  ('2-365-45965-X', 24),
  ('1-304-44821-5', 31),
  ('6-457-56071-7', 24),
  ('6-457-56071-7', 20),
  ('2-816-08255-5', 14),
  ('5-718-03731-0', 29),
  ('5-718-03731-0', 30),
  ('5-718-03731-0', 6),
  ('8-781-83004-1', 6),
  ('8-781-83004-1', 17),
  ('6-778-26509-4', 2),
  ('6-778-26509-4', 10),
  ('2-494-25105-2', 25),
  ('6-864-60177-3', 21),
  ('6-864-60177-3', 9),
  ('3-180-55049-X', 24),
  ('3-180-55049-X', 21),
  ('0-639-68248-0', 13),
  ('1-585-68119-9', 17),
  ('1-585-68119-9', 32),
  ('1-585-68119-9', 28),
  ('9-243-88163-9', 25),
  ('9-243-88163-9', 1),
  ('9-243-88163-9', 14),
  ('9-243-88163-9', 8),
  ('4-543-45809-5', 25),
  ('4-543-45809-5', 32),
  ('3-976-53317-3', 20),
  ('3-976-53317-3', 20),
  ('3-976-53317-3', 27),
  ('9-661-59057-5', 15),
  ('3-661-55918-4', 24),
  ('5-822-57810-1', 23),
  ('6-350-20962-1', 9),
  ('4-185-66817-1', 9),
  ('4-185-66817-1', 13),
  ('4-644-38515-8', 5),
  ('2-291-74938-2', 12),
  ('2-291-74938-2', 28),
  ('8-813-93597-8', 27),
  ('8-356-15420-0', 15),
  ('9-797-40016-6', 16),
  ('2-056-24331-8', 25),
  ('2-056-24331-8', 28),
  ('2-056-24331-8', 6),
  ('3-710-96352-4', 28),
  ('3-710-96352-4', 22),
  ('3-762-71203-4', 7),
  ('5-884-22306-4', 19),
  ('1-860-53069-9', 23),
  ('1-860-53069-9', 3),
  ('5-430-45037-5', 30),
  ('7-226-69099-3', 25),
  ('7-226-69099-3', 30),
  ('7-226-69099-3', 13),
  ('0-074-26643-8', 13),
  ('0-074-26643-8', 22),
  ('0-074-26643-8', 18),
  ('8-590-31005-1', 13),
  ('8-590-31005-1', 1),
  ('8-590-31005-1', 7),
  ('8-310-49550-1', 29),
  ('1-202-78880-7', 3),
  ('7-872-88403-8', 22),
  ('7-872-88403-8', 11),
  ('1-589-75840-4', 14),
  ('1-589-75840-4', 28),
  ('1-589-75840-4', 14),
  ('1-589-75840-4', 11),
  ('1-005-74373-8', 3),
  ('1-005-74373-8', 9),
  ('1-005-74373-8', 32),
  ('1-005-74373-8', 9),
  ('3-965-47765-X', 30),
  ('3-965-47765-X', 25),
  ('3-965-47765-X', 7),
  ('3-965-47765-X', 12),
  ('0-471-52219-8', 18),
  ('0-531-95869-8', 14),
  ('0-531-95869-8', 14),
  ('7-857-57200-4', 11),
  ('0-606-09656-6', 21),
  ('0-498-02608-6', 2),
  ('5-342-94612-3', 13),
  ('5-342-94612-3', 15),
  ('5-342-94612-3', 18),
  ('6-560-14566-2', 18),
  ('6-560-14566-2', 24),
  ('8-921-80742-X', 21),
  ('2-540-82106-5', 32),
  ('2-540-82106-5', 28),
  ('2-540-82106-5', 9),
  ('6-492-73023-2', 11),
  ('4-613-07912-8', 12),
  ('4-613-07912-8', 15),
  ('4-613-07912-8', 28),
  ('0-921-18921-4', 16),
  ('0-921-18921-4', 32),
  ('0-921-18921-4', 5),
  ('0-921-18921-4', 18),
  ('4-502-60483-6', 30),
  ('4-502-60483-6', 17),
  ('4-502-60483-6', 20),
  ('3-068-90395-5', 5),
  ('3-068-90395-5', 3),
  ('3-068-90395-5', 5),
  ('0-905-36794-4', 27),
  ('0-905-36794-4', 4),
  ('1-129-14019-9', 13),
  ('5-727-25866-9', 23),
  ('5-727-25866-9', 7),
  ('1-443-01228-9', 21),
  ('1-443-01228-9', 6),
  ('8-429-56499-3', 21),
  ('2-440-82434-8', 6),
  ('5-529-96352-8', 3),
  ('2-561-41862-6', 15),
  ('2-561-41862-6', 17),
  ('0-247-29380-6', 21),
  ('0-247-29380-6', 8),
  ('0-247-29380-6', 8),
  ('1-491-09448-6', 31),
  ('9-019-02594-5', 6),
  ('9-019-02594-5', 29),
  ('9-019-02594-5', 13),
  ('9-684-29658-4', 14),
  ('9-684-29658-4', 1),
  ('9-684-29658-4', 12),
  ('4-078-08505-9', 32),
  ('8-698-73872-9', 6),
  ('7-315-42130-0', 8),
  ('7-315-42130-0', 1),
  ('7-315-42130-0', 4),
  ('6-233-90818-3', 10),
  ('2-640-51494-6', 17),
  ('4-501-42704-3', 28),
  ('9-998-73376-6', 18),
  ('9-998-73376-6', 18),
  ('5-019-10811-1', 29),
  ('1-051-00131-5', 29),
  ('1-051-00131-5', 3),
  ('1-051-00131-5', 18),
  ('1-051-00131-5', 5),
  ('5-579-10961-X', 25),
  ('5-579-10961-X', 8),
  ('8-398-07496-5', 15),
  ('4-154-15003-0', 5),
  ('0-243-90644-7', 11),
  ('0-243-90644-7', 28),
  ('0-243-90644-7', 25),
  ('0-243-90644-7', 24),
  ('8-024-04847-7', 4),
  ('8-024-04847-7', 4),
  ('8-749-82108-3', 22),
  ('6-348-64505-3', 13),
  ('6-348-64505-3', 15),
  ('2-945-90048-3', 32),
  ('2-945-90048-3', 18),
  ('1-368-01948-X', 11),
  ('1-114-43713-1', 5),
  ('6-788-81106-7', 3),
  ('2-404-58158-9', 11),
  ('2-404-58158-9', 21),
  ('8-671-61785-8', 13),
  ('1-296-27687-2', 16),
  ('1-296-27687-2', 32),
  ('9-250-07293-7', 21),
  ('9-250-07293-7', 29),
  ('5-700-11283-3', 11),
  ('7-424-50470-3', 10),
  ('5-063-13740-7', 25),
  ('5-063-13740-7', 29),
  ('5-063-13740-7', 25),
  ('6-600-16291-0', 32),
  ('3-237-69571-8', 10),
  ('3-237-69571-8', 26),
  ('3-237-69571-8', 14),
  ('3-237-69571-8', 31),
  ('0-728-75203-4', 11),
  ('0-728-75203-4', 3),
  ('0-728-75203-4', 5),
  ('0-728-75203-4', 26),
  ('3-332-25156-2', 29),
  ('3-332-25156-2', 22),
  ('9-500-65417-2', 23),
  ('9-500-65417-2', 4),
  ('3-267-85487-3', 14),
  ('6-757-28185-6', 6),
  ('1-948-52629-8', 18),
  ('7-721-65323-1', 26),
  ('7-721-65323-1', 2),
  ('3-997-36670-5', 15),
  ('3-997-36670-5', 6),
  ('3-997-36670-5', 26),
  ('3-393-02801-4', 29),
  ('3-393-02801-4', 2),
  ('4-603-15620-0', 32),
  ('5-535-57372-8', 25),
  ('9-477-62220-6', 29),
  ('9-477-62220-6', 4),
  ('0-151-86773-9', 6),
  ('0-151-86773-9', 21),
  ('4-647-10747-7', 20),
  ('4-647-10747-7', 32),
  ('4-647-10747-7', 3),
  ('8-437-39377-9', 4),
  ('3-328-82449-9', 19),
  ('3-328-82449-9', 29),
  ('3-328-82449-9', 5),
  ('3-328-82449-9', 16),
  ('0-840-27567-6', 18),
  ('5-717-74834-5', 17),
  ('5-717-74834-5', 24),
  ('5-717-74834-5', 18),
  ('4-555-57229-7', 27),
  ('4-537-27372-0', 9),
  ('9-451-20959-X', 30),
  ('9-508-01453-9', 17),
  ('9-508-01453-9', 28),
  ('9-508-01453-9', 26),
  ('9-508-01453-9', 1),
  ('1-698-88519-9', 25),
  ('1-698-88519-9', 31),
  ('7-844-13513-1', 4),
  ('2-199-56993-4', 4),
  ('2-199-56993-4', 16),
  ('8-181-02593-8', 32),
  ('8-181-02593-8', 12),
  ('4-863-44648-9', 23),
  ('1-249-10975-2', 5),
  ('1-451-28587-6', 25),
  ('4-272-70641-1', 17),
  ('4-272-70641-1', 3),
  ('4-272-70641-1', 17),
  ('7-650-22496-1', 5),
  ('9-365-61449-X', 3),
  ('6-771-86453-7', 6),
  ('6-771-86453-7', 21),
  ('5-536-49411-2', 4),
  ('5-536-49411-2', 3),
  ('9-852-02739-5', 14),
  ('5-048-14534-8', 4),
  ('5-048-14534-8', 10),
  ('8-251-62321-9', 31),
  ('7-469-94165-7', 17),
  ('3-412-28989-2', 19),
  ('7-838-48473-1', 22),
  ('7-838-48473-1', 28),
  ('7-838-48473-1', 1),
  ('8-709-17967-4', 23),
  ('8-709-17967-4', 31),
  ('8-709-17967-4', 4),
  ('3-329-40842-1', 13),
  ('1-007-95036-6', 24),
  ('1-365-47566-2', 21),
  ('4-069-79234-1', 30),
  ('4-069-79234-1', 20),
  ('6-534-99459-3', 5),
  ('2-605-18352-1', 12),
  ('1-286-42377-5', 4),
  ('1-286-42377-5', 21),
  ('6-216-74894-7', 21),
  ('3-355-51969-3', 11),
  ('2-699-44319-0', 21),
  ('2-699-44319-0', 16),
  ('9-272-11911-1', 32),
  ('9-839-44237-6', 30),
  ('9-839-44237-6', 24),
  ('9-839-44237-6', 15),
  ('9-864-45496-X', 2),
  ('0-840-06914-6', 6),
  ('0-840-06914-6', 17),
  ('9-594-91254-5', 11),
  ('9-594-91254-5', 29),
  ('0-820-44196-1', 17),
  ('7-617-13556-4', 21),
  ('7-617-13556-4', 16),
  ('9-013-60977-5', 16),
  ('4-905-30643-4', 28),
  ('5-464-91508-7', 32),
  ('4-476-85071-5', 23),
  ('4-476-85071-5', 21),
  ('4-476-85071-5', 1),
  ('5-369-30628-1', 8),
  ('5-369-30628-1', 29),
  ('7-609-45407-9', 27),
  ('7-609-45407-9', 13),
  ('7-609-45407-9', 3),
  ('7-609-45407-9', 23),
  ('7-722-79870-5', 8),
  ('6-628-50772-6', 28),
  ('8-445-42162-X', 18),
  ('8-445-42162-X', 17),
  ('4-827-70336-1', 13),
  ('4-827-70336-1', 24),
  ('4-827-70336-1', 28),
  ('8-492-06235-5', 30),
  ('8-492-06235-5', 2),
  ('6-055-35159-5', 14),
  ('1-914-39484-4', 10),
  ('4-624-45371-9', 4),
  ('4-624-45371-9', 15),
  ('4-624-45371-9', 31),
  ('9-285-55949-2', 31),
  ('9-285-55949-2', 2),
  ('9-285-55949-2', 2),
  ('1-052-57444-0', 3),
  ('1-052-57444-0', 4),
  ('1-052-57444-0', 14),
  ('6-198-61943-5', 4),
  ('6-198-61943-5', 32),
  ('6-198-61943-5', 30),
  ('9-366-64952-1', 27),
  ('9-366-64952-1', 29),
  ('9-366-64952-1', 12),
  ('4-169-16394-X', 25),
  ('2-056-29901-1', 3),
  ('2-108-54002-4', 6),
  ('2-108-54002-4', 6),
  ('4-992-61382-9', 20),
  ('3-545-22241-1', 21),
  ('1-691-63800-5', 24),
  ('8-533-25938-7', 11),
  ('1-066-46271-2', 10),
  ('1-066-46271-2', 16),
  ('1-066-46271-2', 13),
  ('9-622-03389-X', 9),
  ('9-622-03389-X', 31),
  ('4-145-84308-8', 24),
  ('3-102-56391-0', 26),
  ('3-102-56391-0', 1),
  ('3-102-56391-0', 28),
  ('5-003-46548-3', 21),
  ('4-338-02513-1', 12),
  ('4-338-02513-1', 31),
  ('4-606-64125-8', 28),
  ('1-373-61169-3', 5),
  ('9-998-23396-8', 18),
  ('9-998-23396-8', 24),
  ('9-998-23396-8', 2),
  ('1-127-42732-6', 11),
  ('2-649-32346-9', 1),
  ('2-649-32346-9', 9),
  ('7-626-64304-6', 10),
  ('6-792-98025-0', 6),
  ('6-792-98025-0', 24),
  ('8-020-30744-3', 22),
  ('7-849-44985-1', 21),
  ('9-305-20205-5', 16),
  ('5-563-57653-1', 20),
  ('5-198-84377-6', 6),
  ('5-198-84377-6', 2),
  ('5-198-84377-6', 12),
  ('0-024-30160-4', 22),
  ('0-024-30160-4', 9),
  ('0-024-30160-4', 22),
  ('3-316-73710-3', 22),
  ('3-316-73710-3', 1),
  ('1-769-42278-1', 12),
  ('3-353-06286-6', 29),
  ('3-353-06286-6', 25),
  ('1-969-09254-8', 29),
  ('1-969-09254-8', 16),
  ('2-756-28719-9', 31),
  ('6-059-30808-2', 18),
  ('3-162-05286-6', 23),
  ('3-492-34327-9', 26),
  ('3-492-34327-9', 16),
  ('4-513-56968-9', 5),
  ('4-513-56968-9', 14),
  ('9-726-86319-8', 14),
  ('2-309-49868-8', 26),
  ('2-309-49868-8', 13),
  ('8-480-50371-8', 6),
  ('8-480-50371-8', 9),
  ('7-375-36938-0', 24),
  ('7-375-36938-0', 24),
  ('7-514-58853-1', 16),
  ('7-743-43070-7', 18),
  ('7-743-43070-7', 26),
  ('6-851-84849-X', 27),
  ('4-116-27670-7', 18),
  ('0-387-94001-4', 31),
  ('3-324-94793-6', 13),
  ('3-324-94793-6', 24),
  ('9-871-72416-0', 4),
  ('9-871-72416-0', 23),
  ('3-284-57248-1', 31),
  ('3-284-57248-1', 21),
  ('3-284-57248-1', 11),
  ('8-304-25701-7', 1),
  ('8-304-25701-7', 11),
  ('0-706-89105-8', 18),
  ('0-706-89105-8', 12),
  ('0-706-89105-8', 28),
  ('9-560-17835-0', 23),
  ('9-560-17835-0', 5),
  ('6-551-66627-2', 28),
  ('4-956-21474-X', 6),
  ('2-008-25993-5', 29),
  ('2-008-25993-5', 25),
  ('0-838-26036-5', 15),
  ('3-491-71939-9', 14),
  ('6-011-74585-7', 3),
  ('1-251-91324-5', 14),
  ('0-446-57020-6', 31),
  ('0-446-57020-6', 24),
  ('9-507-62430-9', 24),
  ('4-141-95713-5', 28),
  ('4-130-79130-3', 8),
  ('4-130-79130-3', 21),
  ('4-130-79130-3', 18),
  ('5-818-76128-2', 14),
  ('5-818-76128-2', 15),
  ('5-818-76128-2', 30),
  ('9-945-40660-4', 15),
  ('8-441-04041-9', 20),
  ('8-441-04041-9', 9),
  ('8-441-04041-9', 13),
  ('9-914-51012-4', 26),
  ('8-279-00011-9', 24),
  ('5-792-12032-3', 4),
  ('9-223-49148-7', 20),
  ('9-223-49148-7', 26),
  ('9-322-73519-8', 1),
  ('1-143-05857-7', 23),
  ('1-143-05857-7', 16),
  ('3-180-59114-5', 13),
  ('4-909-63246-8', 27),
  ('4-909-63246-8', 1),
  ('4-909-63246-8', 11),
  ('7-536-18839-0', 23),
  ('7-536-18839-0', 19),
  ('5-036-01149-X', 3),
  ('3-374-12479-8', 10),
  ('4-437-08093-9', 8),
  ('7-217-28463-5', 1),
  ('4-845-82911-8', 1),
  ('2-872-71226-7', 24),
  ('9-616-00327-5', 28),
  ('4-777-56562-9', 29),
  ('4-439-58737-2', 8),
  ('4-354-72033-7', 30),
  ('3-617-05081-6', 14),
  ('3-617-05081-6', 17),
  ('0-861-70789-3', 26),
  ('0-861-70789-3', 9),
  ('0-861-70789-3', 30),
  ('0-861-70789-3', 1),
  ('3-727-32615-8', 1),
  ('3-727-32615-8', 21),
  ('0-114-54394-1', 14),
  ('8-310-81397-X', 23),
  ('8-310-81397-X', 7),
  ('8-310-81397-X', 20),
  ('8-310-81397-X', 11),
  ('2-214-11944-2', 26),
  ('9-976-40976-1', 22),
  ('9-976-40976-1', 7),
  ('9-976-40976-1', 21),
  ('7-535-64741-3', 2),
  ('7-535-64741-3', 20),
  ('7-535-64741-3', 26),
  ('3-778-56404-8', 2),
  ('7-351-20829-8', 6),
  ('3-169-24295-4', 26),
  ('4-956-78937-8', 7),
  ('7-320-18966-6', 29),
  ('7-320-18966-6', 6),
  ('8-220-39571-0', 30),
  ('8-220-39571-0', 7),
  ('8-220-39571-0', 1),
  ('8-220-39571-0', 9),
  ('3-344-62214-5', 16),
  ('3-344-62214-5', 18),
  ('0-254-90835-7', 19),
  ('4-558-36380-X', 7),
  ('4-558-36380-X', 24),
  ('4-558-36380-X', 17),
  ('0-203-36896-7', 22),
  ('9-962-09602-2', 15),
  ('9-962-09602-2', 3),
  ('9-962-09602-2', 28),
  ('9-962-09602-2', 21),
  ('8-968-57821-4', 18),
  ('8-968-57821-4', 7),
  ('7-201-89079-4', 4),
  ('0-435-32933-2', 13),
  ('4-321-24571-0', 28),
  ('4-321-24571-0', 12),
  ('4-107-14357-0', 30),
  ('0-723-96695-8', 4),
  ('9-888-50573-4', 28),
  ('9-888-50573-4', 11),
  ('9-888-50573-4', 4),
  ('9-108-32830-7', 18),
  ('9-108-32830-7', 2),
  ('9-108-32830-7', 21),
  ('6-514-03316-4', 21),
  ('6-514-03316-4', 24),
  ('7-703-49163-2', 16),
  ('7-639-10616-8', 8),
  ('7-639-10616-8', 24),
  ('7-639-10616-8', 2),
  ('7-639-10616-8', 21),
  ('4-889-45586-8', 26),
  ('9-850-78658-2', 10),
  ('9-850-78658-2', 2),
  ('6-199-99841-3', 16),
  ('1-385-35744-4', 20),
  ('4-823-14891-6', 5),
  ('4-823-14891-6', 9),
  ('4-823-14891-6', 8),
  ('4-823-14891-6', 11),
  ('5-631-10945-X', 2),
  ('5-631-10945-X', 19),
  ('5-631-10945-X', 7),
  ('5-423-19162-9', 14),
  ('2-830-18453-X', 16),
  ('2-830-18453-X', 12),
  ('5-340-78900-4', 5),
  ('5-340-78900-4', 11),
  ('5-340-78900-4', 6),
  ('5-340-78900-4', 14),
  ('9-418-18180-0', 30),
  ('9-418-18180-0', 27),
  ('9-418-18180-0', 27),
  ('8-476-58187-4', 2),
  ('8-476-58187-4', 11),
  ('7-149-94583-X', 19),
  ('6-618-28089-3', 14),
  ('2-270-93903-4', 20),
  ('2-270-93903-4', 15),
  ('8-134-87877-6', 7),
  ('8-134-87877-6', 25),
  ('3-200-29155-9', 32),
  ('8-713-17717-6', 10),
  ('8-713-17717-6', 17),
  ('8-713-17717-6', 4),
  ('7-319-19954-8', 2),
  ('0-922-19521-8', 25),
  ('0-922-19521-8', 29),
  ('5-670-07929-9', 15),
  ('5-670-07929-9', 9),
  ('5-670-07929-9', 22),
  ('7-098-24614-X', 3),
  ('7-098-24614-X', 10),
  ('7-098-24614-X', 2),
  ('7-098-24614-X', 23),
  ('7-570-37225-5', 24),
  ('7-856-14306-1', 8),
  ('3-807-39705-1', 19),
  ('3-807-39705-1', 6),
  ('3-807-39705-1', 6),
  ('3-807-39705-1', 4),
  ('2-855-68567-2', 6),
  ('2-986-00677-9', 3),
  ('5-663-80268-1', 2),
  ('6-338-00784-4', 10),
  ('6-338-00784-4', 27),
  ('8-775-85134-2', 29),
  ('4-041-74040-1', 19),
  ('4-041-74040-1', 32),
  ('3-765-10753-0', 29),
  ('3-765-10753-0', 6),
  ('7-876-60327-0', 2),
  ('9-884-08486-6', 7),
  ('9-123-13129-2', 32),
  ('4-227-72115-6', 9),
  ('4-227-72115-6', 15),
  ('4-227-72115-6', 5),
  ('9-233-09626-2', 10),
  ('9-233-09626-2', 1),
  ('1-724-12645-8', 32),
  ('9-358-58882-9', 7),
  ('7-069-96466-8', 6),
  ('7-069-96466-8', 12),
  ('7-069-96466-8', 29),
  ('6-584-45716-8', 13),
  ('2-161-12997-X', 16),
  ('0-104-24898-X', 22),
  ('0-104-24898-X', 24),
  ('0-104-24898-X', 24),
  ('0-839-35050-3', 32),
  ('0-839-35050-3', 16),
  ('5-226-83634-1', 31),
  ('4-043-11757-4', 23),
  ('4-043-11757-4', 12),
  ('4-015-25568-2', 12),
  ('8-520-18243-7', 30),
  ('8-520-18243-7', 25),
  ('1-946-93235-3', 27),
  ('8-322-15452-6', 8),
  ('8-690-97331-1', 6),
  ('8-690-97331-1', 28),
  ('1-234-84076-6', 19),
  ('4-058-46091-1', 19),
  ('9-157-89959-2', 31),
  ('4-967-97846-0', 12),
  ('4-967-97846-0', 16),
  ('3-591-03392-8', 2),
  ('3-591-03392-8', 18),
  ('8-624-67950-8', 16),
  ('1-702-29865-5', 9),
  ('9-259-66880-8', 15),
  ('3-262-45416-8', 5),
  ('3-262-45416-8', 10),
  ('3-262-45416-8', 6),
  ('8-582-01483-X', 24),
  ('8-582-01483-X', 28),
  ('3-968-14316-7', 23),
  ('3-968-14316-7', 16),
  ('6-521-87256-7', 12),
  ('6-347-50394-8', 18),
  ('6-347-50394-8', 12),
  ('6-347-50394-8', 32),
  ('2-738-42189-X', 22),
  ('2-738-42189-X', 19),
  ('3-331-27955-2', 27),
  ('3-331-27955-2', 20),
  ('3-331-27955-2', 19),
  ('3-331-27955-2', 10),
  ('3-337-68212-X', 14),
  ('3-337-68212-X', 32),
  ('3-337-68212-X', 2),
  ('0-731-78625-4', 26),
  ('3-038-63796-3', 3),
  ('3-530-47197-6', 11),
  ('1-196-14165-7', 31),
  ('7-737-66952-3', 10),
  ('0-829-20679-5', 31),
  ('0-829-20679-5', 16),
  ('3-319-24906-1', 27),
  ('3-319-24906-1', 29),
  ('7-127-05216-6', 6),
  ('2-048-61573-2', 19),
  ('2-048-61573-2', 31),
  ('2-048-61573-2', 12),
  ('3-741-86126-X', 5),
  ('5-543-99250-5', 7),
  ('5-543-99250-5', 19),
  ('8-502-96839-4', 15),
  ('8-502-96839-4', 15),
  ('9-510-81784-8', 28),
  ('8-552-55087-3', 11),
  ('0-953-85850-2', 13),
  ('0-953-85850-2', 12),
  ('0-953-85850-2', 12),
  ('5-543-46411-8', 25),
  ('1-814-79034-9', 2),
  ('1-814-79034-9', 32),
  ('3-134-24431-4', 14),
  ('5-824-98524-3', 19),
  ('4-402-67211-2', 5),
  ('8-107-25149-0', 19),
  ('4-800-68167-7', 27),
  ('9-371-58750-4', 28),
  ('9-371-58750-4', 30),
  ('9-371-58750-4', 6),
  ('9-371-58750-4', 13),
  ('8-236-05762-3', 24),
  ('6-079-88146-2', 16),
  ('6-079-88146-2', 31),
  ('9-578-81680-4', 30),
  ('8-354-47237-X', 11),
  ('8-512-01568-3', 29),
  ('8-880-52905-6', 1),
  ('1-057-03506-8', 19),
  ('1-057-03506-8', 15),
  ('1-057-03506-8', 4),
  ('2-070-18377-7', 19),
  ('8-251-27497-4', 24),
  ('8-204-38889-6', 8),
  ('9-605-31737-0', 11),
  ('9-605-31737-0', 27),
  ('5-912-82017-3', 11),
  ('6-174-64379-4', 8),
  ('6-174-64379-4', 1),
  ('7-506-37923-6', 29),
  ('7-506-37923-6', 7),
  ('9-513-28846-3', 29),
  ('9-513-28846-3', 7),
  ('6-492-08923-5', 10),
  ('6-492-08923-5', 29),
  ('6-492-08923-5', 12),
  ('3-613-08792-8', 10),
  ('0-013-74987-0', 18),
  ('9-807-42758-4', 12),
  ('9-807-42758-4', 6),
  ('9-807-42758-4', 30),
  ('9-807-42758-4', 4),
  ('8-383-50177-3', 25),
  ('2-232-84867-1', 25),
  ('2-232-84867-1', 2),
  ('2-232-84867-1', 5),
  ('2-232-84867-1', 22),
  ('4-922-04569-4', 19),
  ('4-922-04569-4', 4),
  ('4-080-42087-0', 14),
  ('4-080-42087-0', 14),
  ('5-815-07688-0', 10),
  ('3-884-13240-7', 29),
  ('3-884-13240-7', 26),
  ('8-612-67043-8', 29),
  ('8-612-67043-8', 31),
  ('8-612-67043-8', 30),
  ('8-612-67043-8', 26),
  ('3-964-97319-X', 2),
  ('3-964-97319-X', 26),
  ('2-566-50524-1', 19),
  ('4-209-12478-8', 8),
  ('4-209-12478-8', 18),
  ('0-583-04503-0', 21),
  ('0-583-04503-0', 22),
  ('9-233-66149-0', 3),
  ('9-233-66149-0', 25),
  ('4-247-25959-8', 26),
  ('4-247-25959-8', 27),
  ('6-234-08825-2', 14),
  ('6-234-08825-2', 32),
  ('6-234-08825-2', 16),
  ('6-234-08825-2', 12),
  ('0-593-75709-2', 13),
  ('4-673-19802-6', 7),
  ('3-344-18001-0', 25),
  ('3-344-18001-0', 17),
  ('3-344-18001-0', 15),
  ('5-137-56390-0', 32),
  ('5-137-56390-0', 25),
  ('1-113-86616-0', 19),
  ('9-058-27132-3', 11),
  ('9-058-27132-3', 16),
  ('3-106-32990-4', 11),
  ('9-895-72801-8', 24),
  ('9-895-72801-8', 9),
  ('7-044-43450-9', 5),
  ('7-044-43450-9', 16),
  ('9-232-82986-X', 26),
  ('9-232-82986-X', 22),
  ('6-887-79031-9', 14),
  ('3-366-44442-8', 13),
  ('7-296-64920-8', 5),
  ('7-296-64920-8', 16),
  ('7-296-64920-8', 22),
  ('7-652-12729-7', 13),
  ('7-652-12729-7', 2),
  ('7-652-12729-7', 22),
  ('9-197-68310-8', 32),
  ('9-197-68310-8', 23),
  ('8-518-62959-4', 31),
  ('1-769-65783-5', 3),
  ('1-769-65783-5', 19),
  ('1-769-65783-5', 10),
  ('7-488-61731-2', 32),
  ('3-481-97595-3', 13),
  ('4-222-57631-X', 26),
  ('7-432-20662-7', 30),
  ('7-432-20662-7', 15),
  ('1-521-90754-4', 21),
  ('4-489-09632-1', 10),
  ('4-489-09632-1', 18),
  ('4-489-09632-1', 28),
  ('1-950-71552-3', 25),
  ('1-950-71552-3', 1),
  ('0-718-04975-6', 27),
  ('0-718-04975-6', 9),
  ('8-141-05835-5', 13),
  ('8-141-05835-5', 26),
  ('6-908-30271-7', 26),
  ('5-322-51171-7', 27),
  ('5-322-51171-7', 9),
  ('9-919-32485-X', 6),
  ('8-684-07336-3', 27),
  ('8-684-07336-3', 30),
  ('8-051-73757-1', 8),
  ('0-916-71623-6', 17),
  ('1-134-05311-8', 17),
  ('1-134-05311-8', 22),
  ('1-134-05311-8', 31),
  ('1-134-05311-8', 11),
  ('4-390-72307-3', 14),
  ('2-424-06918-2', 17),
  ('8-253-20746-8', 32),
  ('8-253-20746-8', 1),
  ('8-253-20746-8', 25),
  ('7-484-76821-9', 21),
  ('7-484-76821-9', 13),
  ('7-484-76821-9', 6),
  ('7-484-76821-9', 9),
  ('7-981-25721-2', 32),
  ('7-981-25721-2', 23),
  ('7-981-25721-2', 10),
  ('6-861-84267-2', 26),
  ('6-861-84267-2', 23),
  ('6-861-84267-2', 6),
  ('5-963-33104-8', 5),
  ('6-801-78251-7', 17),
  ('6-801-78251-7', 2),
  ('6-801-78251-7', 21),
  ('5-816-29452-0', 24),
  ('5-816-29452-0', 21),
  ('9-029-79905-6', 13),
  ('6-994-61602-9', 2),
  ('6-994-61602-9', 4),
  ('6-994-61602-9', 25),
  ('6-994-61602-9', 10),
  ('6-321-10324-1', 9),
  ('1-854-33776-9', 16),
  ('1-909-63937-0', 6),
  ('1-909-63937-0', 9),
  ('9-952-66287-4', 13),
  ('9-952-66287-4', 27),
  ('0-427-53389-9', 28),
  ('9-191-30877-1', 13),
  ('1-699-78062-5', 29),
  ('1-699-78062-5', 32),
  ('2-573-20939-3', 19),
  ('2-573-20939-3', 20),
  ('4-327-27290-6', 29),
  ('4-327-27290-6', 2),
  ('4-327-27290-6', 5),
  ('7-079-92231-3', 9),
  ('4-762-83572-2', 7),
  ('1-494-73136-3', 14),
  ('1-947-88482-4', 8),
  ('1-947-88482-4', 6),
  ('6-239-56116-9', 22),
  ('7-079-53185-3', 30),
  ('7-079-53185-3', 12),
  ('7-138-40030-6', 30),
  ('4-643-04454-3', 17),
  ('4-643-04454-3', 23),
  ('4-643-04454-3', 25),
  ('0-057-60325-1', 29),
  ('0-669-62188-9', 6),
  ('2-071-77058-7', 12),
  ('2-071-77058-7', 28),
  ('1-192-93464-4', 6),
  ('7-807-49850-1', 12),
  ('7-807-49850-1', 22),
  ('4-568-03820-0', 27),
  ('7-215-78236-0', 6),
  ('7-215-78236-0', 31),
  ('0-583-56591-3', 30),
  ('6-679-98683-4', 21),
  ('6-679-98683-4', 32),
  ('6-679-98683-4', 31),
  ('7-125-60461-7', 15),
  ('8-768-33971-2', 18),
  ('8-498-68538-9', 14),
  ('3-581-27717-4', 19),
  ('3-581-27717-4', 12),
  ('3-581-27717-4', 4),
  ('9-532-28901-1', 7),
  ('2-250-46878-8', 25),
  ('2-250-46878-8', 28),
  ('9-479-91161-2', 22),
  ('8-408-71260-8', 29),
  ('8-408-71260-8', 22),
  ('8-408-71260-8', 8),
  ('8-408-71260-8', 29),
  ('9-360-34734-5', 25),
  ('3-080-89540-1', 26),
  ('3-080-89540-1', 21),
  ('3-172-52232-6', 2),
  ('3-172-52232-6', 4),
  ('5-674-30702-4', 16),
  ('5-674-30702-4', 13),
  ('6-821-69943-7', 19),
  ('6-821-69943-7', 16),
  ('3-614-19240-7', 11),
  ('3-968-90426-5', 32),
  ('1-457-20898-9', 29),
  ('1-457-20898-9', 4),
  ('1-457-20898-9', 28),
  ('9-001-63530-X', 15),
  ('7-852-24447-5', 7),
  ('2-071-86938-9', 32),
  ('4-655-67730-9', 3),
  ('8-217-15390-6', 18),
  ('8-217-15390-6', 4),
  ('8-217-15390-6', 20),
  ('9-927-52181-2', 3),
  ('3-028-32779-1', 14),
  ('0-005-16854-6', 13),
  ('0-005-16854-6', 5),
  ('0-005-16854-6', 22),
  ('3-728-85000-4', 17),
  ('8-999-44683-2', 32),
  ('9-837-31622-5', 6),
  ('8-942-26055-1', 5),
  ('8-942-26055-1', 8),
  ('0-168-81897-3', 31),
  ('0-168-81897-3', 26),
  ('4-204-21711-7', 13),
  ('0-363-51767-7', 16),
  ('9-405-22086-1', 29),
  ('5-722-84789-5', 9),
  ('5-722-84789-5', 32),
  ('8-049-59684-2', 8),
  ('8-049-59684-2', 32),
  ('8-049-59684-2', 18),
  ('4-245-44883-0', 3),
  ('4-245-44883-0', 1),
  ('4-245-44883-0', 4),
  ('1-291-03561-3', 8),
  ('5-336-74065-9', 14),
  ('5-336-74065-9', 2),
  ('5-336-74065-9', 24),
  ('5-902-87713-X', 5),
  ('5-902-87713-X', 31),
  ('4-941-31156-6', 4),
  ('4-941-31156-6', 21),
  ('4-941-31156-6', 16),
  ('4-941-31156-6', 31),
  ('7-245-55151-0', 30),
  ('7-245-55151-0', 29),
  ('8-806-09046-1', 28),
  ('7-567-36554-5', 26),
  ('7-567-36554-5', 29),
  ('2-234-21900-0', 24),
  ('5-167-40985-3', 27),
  ('2-979-92379-6', 29),
  ('1-228-87758-0', 32),
  ('0-779-98446-3', 28),
  ('0-779-98446-3', 2),
  ('5-626-04383-7', 17),
  ('5-626-04383-7', 22),
  ('5-626-04383-7', 29),
  ('5-626-04383-7', 9),
  ('1-550-22668-1', 17),
  ('9-650-16567-3', 11),
  ('3-306-81453-9', 7),
  ('1-096-52970-X', 31),
  ('1-644-07796-5', 25),
  ('1-644-07796-5', 25),
  ('0-408-82648-7', 3),
  ('1-552-37745-8', 18),
  ('1-552-37745-8', 7),
  ('1-552-37745-8', 16),
  ('7-525-58834-1', 31),
  ('4-070-24761-0', 27),
  ('4-070-24761-0', 12),
  ('4-070-24761-0', 7),
  ('4-070-24761-0', 20),
  ('8-916-05897-X', 7),
  ('8-916-05897-X', 7),
  ('8-916-05897-X', 3),
  ('6-854-25531-7', 20),
  ('4-444-82458-1', 25),
  ('4-444-82458-1', 8),
  ('4-444-82458-1', 4),
  ('0-270-72438-9', 24),
  ('9-785-60740-2', 12),
  ('7-541-03808-3', 27),
  ('7-541-03808-3', 23),
  ('7-541-03808-3', 26),
  ('7-541-03808-3', 25),
  ('1-651-23864-2', 20),
  ('1-651-23864-2', 5),
  ('3-594-12164-X', 32),
  ('3-594-12164-X', 19),
  ('3-594-12164-X', 13),
  ('5-984-73998-4', 32),
  ('1-119-39033-8', 28),
  ('3-814-82692-2', 3),
  ('4-197-92708-8', 6),
  ('4-197-92708-8', 24),
  ('4-197-92708-8', 3),
  ('4-197-92708-8', 27),
  ('5-299-25214-5', 22),
  ('6-267-11923-8', 16),
  ('6-267-11923-8', 22),
  ('8-137-61940-2', 9),
  ('6-976-87737-1', 15),
  ('6-744-70368-4', 28),
  ('3-611-79113-X', 27),
  ('8-011-74988-9', 22),
  ('8-011-74988-9', 13),
  ('5-897-59762-6', 12),
  ('5-897-59762-6', 13),
  ('5-429-77784-6', 15),
  ('3-195-07938-0', 21),
  ('3-195-07938-0', 13),
  ('8-782-53368-7', 28),
  ('3-881-76970-6', 24),
  ('9-884-17446-6', 7),
  ('3-873-78162-X', 9),
  ('3-873-78162-X', 10),
  ('3-873-78162-X', 19),
  ('8-188-73876-X', 2),
  ('8-188-73876-X', 28),
  ('8-188-73876-X', 26),
  ('2-948-83981-5', 18),
  ('5-096-83521-9', 14),
  ('5-096-83521-9', 28),
  ('1-402-20408-6', 1),
  ('0-261-97790-3', 3),
  ('2-924-44617-1', 27),
  ('2-924-44617-1', 28),
  ('2-924-44617-1', 3),
  ('2-924-44617-1', 27),
  ('6-612-06440-4', 9),
  ('1-986-07549-4', 19),
  ('5-208-61779-X', 23),
  ('5-208-61779-X', 32),
  ('5-208-61779-X', 11),
  ('0-028-37037-6', 3),
  ('0-028-37037-6', 1),
  ('1-358-37157-1', 15),
  ('1-358-37157-1', 2),
  ('0-085-09079-4', 3),
  ('0-085-09079-4', 3),
  ('0-085-09079-4', 3),
  ('9-327-64941-9', 14),
  ('2-456-24174-6', 16),
  ('2-456-24174-6', 25),
  ('2-456-24174-6', 13),
  ('1-679-21570-1', 25),
  ('1-679-21570-1', 9),
  ('7-484-69251-4', 23),
  ('7-484-69251-4', 10),
  ('7-484-69251-4', 22),
  ('8-727-70356-8', 3),
  ('4-689-48685-9', 9),
  ('4-689-48685-9', 11),
  ('9-026-07206-6', 6),
  ('9-026-07206-6', 26),
  ('9-026-07206-6', 13),
  ('8-649-13941-8', 17),
  ('3-018-89649-1', 16),
  ('1-484-41481-0', 8),
  ('1-484-41481-0', 3),
  ('1-484-41481-0', 15),
  ('8-885-60608-3', 23),
  ('3-400-70868-2', 14),
  ('0-487-51351-7', 14),
  ('8-388-80269-0', 17),
  ('0-760-95595-6', 28),
  ('0-760-95595-6', 30),
  ('0-760-95595-6', 27),
  ('8-074-77347-7', 7),
  ('2-118-40116-7', 24),
  ('0-567-40059-X', 7),
  ('3-206-42331-7', 14),
  ('8-537-68184-9', 23),
  ('8-537-68184-9', 29),
  ('0-875-07154-6', 13),
  ('0-875-07154-6', 3),
  ('4-744-06492-2', 16),
  ('4-735-37274-1', 1),
  ('4-735-37274-1', 10),
  ('1-458-49594-9', 7),
  ('1-458-49594-9', 5),
  ('0-328-75523-0', 12),
  ('5-365-59079-1', 3),
  ('5-109-26403-1', 9),
  ('4-957-12944-4', 22),
  ('2-129-56935-8', 12),
  ('1-822-66588-4', 30),
  ('0-910-24076-0', 20),
  ('5-164-26458-7', 7),
  ('5-164-26458-7', 4),
  ('1-141-32208-0', 14),
  ('1-141-32208-0', 23),
  ('1-141-32208-0', 22),
  ('1-141-32208-0', 18),
  ('5-052-26389-9', 29),
  ('5-052-26389-9', 22),
  ('7-440-29373-8', 4),
  ('7-440-29373-8', 5),
  ('7-440-29373-8', 7),
  ('8-846-63213-3', 29),
  ('6-303-48106-X', 8),
  ('0-887-85080-4', 5),
  ('8-229-95072-5', 24),
  ('8-229-95072-5', 16),
  ('9-648-62214-0', 19),
  ('0-013-30170-5', 32),
  ('9-143-26451-4', 17),
  ('9-143-26451-4', 2),
  ('1-644-23588-9', 23),
  ('1-644-23588-9', 17),
  ('1-644-23588-9', 12),
  ('1-410-82846-8', 19),
  ('5-957-37367-2', 15),
  ('5-957-37367-2', 14),
  ('5-957-37367-2', 30),
  ('2-086-91306-0', 22),
  ('1-932-25424-2', 25),
  ('1-932-25424-2', 18),
  ('1-932-25424-2', 16),
  ('3-276-50692-0', 2),
  ('3-276-50692-0', 17),
  ('3-276-50692-0', 28),
  ('3-276-50692-0', 1),
  ('0-117-47933-0', 17),
  ('3-179-67096-7', 30),
  ('3-179-67096-7', 24),
  ('9-994-02573-2', 18),
  ('1-528-83977-3', 30),
  ('1-881-81820-9', 11),
  ('1-881-81820-9', 1),
  ('6-815-62566-4', 22),
  ('6-815-62566-4', 25),
  ('8-109-66973-5', 11),
  ('1-065-77878-3', 26),
  ('5-733-04581-7', 21),
  ('0-375-35278-3', 18),
  ('3-926-24119-5', 2),
  ('2-267-90638-4', 2),
  ('2-267-90638-4', 12),
  ('8-423-07694-6', 7),
  ('8-423-07694-6', 29),
  ('0-998-27263-9', 7),
  ('2-737-93783-3', 11),
  ('3-295-04361-2', 16),
  ('1-823-77683-3', 3),
  ('2-026-65688-6', 24),
  ('2-026-65688-6', 21),
  ('0-810-54072-X', 10),
  ('0-810-54072-X', 16),
  ('0-810-54072-X', 17),
  ('2-419-31941-9', 20),
  ('9-837-56397-4', 31),
  ('9-837-56397-4', 13),
  ('3-968-76713-6', 9),
  ('3-968-76713-6', 32),
  ('2-513-64851-X', 25),
  ('6-187-82317-6', 6),
  ('7-132-37057-X', 1),
  ('7-132-37057-X', 26),
  ('9-292-65098-X', 4),
  ('9-292-65098-X', 2),
  ('4-307-61155-1', 13),
  ('4-428-58377-X', 30),
  ('4-428-58377-X', 30),
  ('4-428-58377-X', 2),
  ('0-546-58108-0', 19),
  ('7-821-92831-3', 26),
  ('7-821-92831-3', 20),
  ('7-821-92831-3', 31),
  ('8-970-44067-4', 13),
  ('9-270-75147-3', 6),
  ('0-189-78340-0', 13),
  ('0-189-78340-0', 24),
  ('1-363-38619-0', 24),
  ('4-710-44527-3', 12),
  ('1-868-13725-2', 10),
  ('6-454-08299-7', 8),
  ('6-454-08299-7', 3),
  ('9-340-02676-4', 22),
  ('9-340-02676-4', 32),
  ('0-937-04364-8', 20),
  ('6-110-33970-9', 28),
  ('4-942-40453-3', 6),
  ('2-226-81205-9', 26),
  ('7-050-19455-7', 7),
  ('6-355-05008-6', 23),
  ('6-355-05008-6', 19),
  ('4-187-76022-9', 23),
  ('0-190-95393-4', 24),
  ('6-463-08418-2', 9),
  ('6-463-08418-2', 11),
  ('3-501-49522-6', 19),
  ('4-597-22544-7', 26),
  ('4-597-22544-7', 23),
  ('4-597-22544-7', 23),
  ('1-196-66353-X', 28),
  ('4-049-45144-1', 21),
  ('0-689-62102-7', 27),
  ('8-332-45826-9', 17),
  ('8-796-78902-6', 24),
  ('4-162-06212-9', 1),
  ('9-129-46200-2', 12),
  ('7-728-53974-4', 12),
  ('6-008-07528-5', 26),
  ('3-782-44265-2', 16),
  ('3-782-44265-2', 6),
  ('3-782-44265-2', 23),
  ('4-731-46040-9', 27),
  ('7-107-56607-5', 3),
  ('7-107-56607-5', 32),
  ('9-487-25944-9', 32),
  ('8-871-98795-0', 9),
  ('3-767-14707-6', 4),
  ('2-900-04670-X', 24),
  ('6-835-65486-4', 23),
  ('6-835-65486-4', 15),
  ('1-017-27763-X', 8),
  ('1-017-27763-X', 30),
  ('1-779-50169-2', 3),
  ('1-779-50169-2', 8),
  ('9-619-32724-1', 2),
  ('9-619-32724-1', 17),
  ('4-297-39448-0', 16),
  ('4-297-39448-0', 10),
  ('1-087-25114-1', 10),
  ('1-087-25114-1', 6),
  ('4-550-88088-0', 15),
  ('4-550-88088-0', 28),
  ('6-578-61313-7', 19),
  ('8-162-02070-5', 9),
  ('2-999-77040-5', 16),
  ('2-999-77040-5', 19),
  ('7-292-04395-X', 10),
  ('7-292-04395-X', 1),
  ('7-292-04395-X', 8),
  ('7-546-47386-1', 9),
  ('7-546-47386-1', 15),
  ('7-546-47386-1', 30),
  ('5-143-32070-4', 7),
  ('8-125-77632-X', 16),
  ('8-125-77632-X', 28),
  ('8-786-86703-2', 10),
  ('2-398-64854-0', 4),
  ('2-398-64854-0', 19),
  ('2-398-64854-0', 8),
  ('8-721-96514-5', 18),
  ('8-721-96514-5', 25),
  ('8-721-96514-5', 11),
  ('6-016-71313-9', 11),
  ('6-016-71313-9', 13),
  ('6-016-71313-9', 23),
  ('9-914-79407-6', 27),
  ('4-825-64678-6', 24),
  ('4-825-64678-6', 7),
  ('4-825-64678-6', 24),
  ('9-705-25562-8', 5),
  ('6-705-31246-7', 9),
  ('6-705-31246-7', 31),
  ('1-612-09924-6', 9),
  ('7-879-38760-9', 16),
  ('7-879-38760-9', 27),
  ('7-879-38760-9', 21),
  ('9-765-95367-4', 31),
  ('5-477-86473-7', 10),
  ('6-979-43532-9', 28),
  ('6-979-43532-9', 28),
  ('6-345-82753-3', 21),
  ('6-345-82753-3', 18),
  ('7-619-68425-5', 15),
  ('7-411-09810-8', 28),
  ('5-525-89090-9', 26),
  ('0-321-99615-1', 3),
  ('1-889-38372-4', 18),
  ('2-018-22832-3', 19),
  ('9-099-29323-2', 24),
  ('9-099-29323-2', 9),
  ('5-416-62681-X', 8),
  ('5-416-62681-X', 18),
  ('3-179-52481-2', 7),
  ('6-588-21113-9', 3),
  ('3-420-51869-2', 27),
  ('0-330-76629-5', 10),
  ('0-330-76629-5', 12),
  ('0-330-76629-5', 22),
  ('0-330-76629-5', 25),
  ('6-534-25055-1', 12),
  ('6-534-25055-1', 6),
  ('6-534-25055-1', 9),
  ('6-534-25055-1', 25),
  ('9-557-61297-5', 24),
  ('9-557-61297-5', 1),
  ('9-557-61297-5', 19),
  ('9-557-61297-5', 32),
  ('6-353-66833-3', 7),
  ('6-353-66833-3', 8),
  ('6-353-66833-3', 30),
  ('0-158-31306-2', 22),
  ('0-158-31306-2', 25),
  ('0-158-31306-2', 17),
  ('0-956-17492-2', 12),
  ('4-227-23671-1', 21),
  ('5-718-67014-5', 14),
  ('5-718-67014-5', 3),
  ('1-573-64094-8', 8),
  ('6-394-82275-2', 27),
  ('7-285-77983-0', 28),
  ('7-285-77983-0', 22),
  ('7-285-77983-0', 8),
  ('7-285-77983-0', 18),
  ('4-059-64360-2', 26),
  ('4-059-64360-2', 14),
  ('2-811-77446-7', 3),
  ('4-084-41252-X', 28),
  ('4-084-41252-X', 6),
  ('9-977-81097-4', 26),
  ('9-977-81097-4', 24),
  ('9-977-81097-4', 31),
  ('9-199-61850-8', 1),
  ('9-199-61850-8', 3),
  ('9-199-61850-8', 29),
  ('1-350-74383-6', 13),
  ('1-350-74383-6', 3),
  ('1-350-74383-6', 15),
  ('1-350-74383-6', 20),
  ('9-972-40590-7', 27),
  ('5-206-01793-0', 9),
  ('6-468-53059-8', 29),
  ('9-798-80428-7', 10),
  ('9-798-80428-7', 7),
  ('9-798-80428-7', 31),
  ('7-067-67655-X', 7),
  ('2-608-79956-6', 5),
  ('9-266-20449-8', 6),
  ('9-266-20449-8', 14),
  ('9-266-20449-8', 32),
  ('9-266-20449-8', 13),
  ('3-000-61248-3', 15),
  ('1-745-97519-5', 12),
  ('1-745-97519-5', 12),
  ('1-745-97519-5', 26),
  ('1-745-97519-5', 27),
  ('9-697-20497-7', 2),
  ('9-697-20497-7', 32),
  ('1-901-31949-0', 3),
  ('1-810-49141-X', 1),
  ('1-810-49141-X', 23),
  ('1-810-49141-X', 31),
  ('8-768-47657-4', 31),
  ('8-768-47657-4', 12),
  ('8-768-47657-4', 11),
  ('5-094-49107-5', 24),
  ('5-089-06210-2', 17),
  ('8-248-22013-3', 24),
  ('7-167-67935-6', 3),
  ('7-167-67935-6', 6),
  ('7-167-67935-6', 17),
  ('1-836-11990-9', 19),
  ('5-798-22869-X', 3),
  ('3-082-15786-6', 25),
  ('6-682-51445-X', 23),
  ('6-682-51445-X', 9),
  ('6-682-51445-X', 2),
  ('9-882-64846-0', 12),
  ('0-922-42333-4', 4),
  ('5-907-00834-2', 20),
  ('3-041-00209-4', 11),
  ('3-041-00209-4', 16),
  ('3-041-00209-4', 2),
  ('3-041-00209-4', 13),
  ('9-602-73416-7', 13),
  ('0-548-05409-6', 13),
  ('0-073-97837-X', 14),
  ('0-073-97837-X', 12),
  ('0-073-97837-X', 31),
  ('7-792-12505-X', 21),
  ('7-792-12505-X', 25),
  ('6-602-70962-3', 12),
  ('6-602-70962-3', 27),
  ('6-068-84686-5', 30),
  ('6-068-84686-5', 23),
  ('6-068-84686-5', 16),
  ('6-068-84686-5', 17),
  ('2-076-53611-6', 27),
  ('9-380-52028-X', 7),
  ('4-423-53654-4', 20),
  ('7-328-18453-1', 32),
  ('7-328-18453-1', 23),
  ('6-940-81501-5', 2),
  ('1-926-71611-6', 15),
  ('1-262-97136-5', 30),
  ('1-262-97136-5', 20),
  ('4-443-95758-8', 19),
  ('6-551-31594-1', 9),
  ('1-476-24385-9', 2),
  ('8-917-07460-X', 11),
  ('1-913-11122-9', 7),
  ('1-913-11122-9', 1),
  ('1-913-11122-9', 27),
  ('1-913-11122-9', 30),
  ('4-110-32148-4', 20),
  ('8-562-53665-2', 21),
  ('8-562-53665-2', 32),
  ('6-776-75358-X', 10),
  ('6-776-75358-X', 22),
  ('4-863-24190-9', 22),
  ('9-492-53338-3', 4),
  ('6-537-14308-X', 2),
  ('6-537-14308-X', 21),
  ('3-741-20879-5', 21),
  ('0-499-95856-X', 28),
  ('0-499-95856-X', 9),
  ('8-127-97959-7', 6),
  ('4-678-17256-4', 26),
  ('4-678-17256-4', 8),
  ('4-678-17256-4', 21),
  ('4-980-22823-2', 22),
  ('1-585-86974-0', 12),
  ('4-184-70967-2', 1),
  ('4-184-70967-2', 10),
  ('7-417-67841-6', 24),
  ('7-417-67841-6', 16),
  ('0-601-28069-5', 8),
  ('4-218-23544-9', 9),
  ('0-974-83792-X', 17),
  ('2-007-70666-0', 23),
  ('7-214-03520-0', 16),
  ('0-130-12427-3', 29),
  ('5-386-49791-X', 14),
  ('7-149-92488-3', 31),
  ('6-346-81032-4', 8),
  ('1-604-46805-X', 32),
  ('1-604-46805-X', 5),
  ('5-353-18233-2', 12),
  ('3-246-89134-6', 21),
  ('4-917-74112-2', 5),
  ('8-554-62075-5', 27),
  ('7-364-46990-7', 10),
  ('1-996-57111-7', 7),
  ('1-996-57111-7', 4),
  ('1-423-55543-0', 20),
  ('1-423-55543-0', 8),
  ('1-423-55543-0', 18),
  ('1-423-55543-0', 15),
  ('4-590-51676-4', 4),
  ('0-765-53075-9', 9),
  ('0-765-53075-9', 15),
  ('0-765-53075-9', 3),
  ('4-642-57232-5', 13),
  ('4-642-57232-5', 8),
  ('4-642-57232-5', 10),
  ('4-642-57232-5', 19),
  ('4-502-31998-8', 10),
  ('2-014-65190-6', 1),
  ('2-499-53187-8', 11),
  ('9-045-09110-0', 30),
  ('9-045-09110-0', 10),
  ('8-740-96263-6', 27),
  ('2-712-61022-9', 19),
  ('2-712-61022-9', 19),
  ('2-712-61022-9', 18),
  ('3-019-84176-3', 1),
  ('2-384-41653-7', 8),
  ('2-580-40526-7', 17),
  ('3-897-24206-0', 16),
  ('3-897-24206-0', 21),
  ('7-970-23830-0', 21),
  ('7-970-23830-0', 24),
  ('7-970-23830-0', 2),
  ('7-970-23830-0', 31),
  ('2-135-28326-6', 28),
  ('6-941-78404-0', 32),
  ('6-941-78404-0', 17),
  ('5-922-81352-8', 4),
  ('9-495-36450-7', 14),
  ('6-820-92409-7', 26),
  ('3-035-59390-6', 18),
  ('3-035-59390-6', 12),
  ('3-035-59390-6', 9),
  ('7-791-42379-0', 24),
  ('0-654-83176-9', 15),
  ('0-654-83176-9', 6),
  ('3-329-05579-0', 5),
  ('3-329-05579-0', 25),
  ('3-329-05579-0', 30),
  ('3-329-05579-0', 32),
  ('3-517-85119-1', 32),
  ('3-517-85119-1', 32),
  ('3-517-85119-1', 9),
  ('3-517-85119-1', 30),
  ('3-638-19346-2', 14),
  ('3-638-19346-2', 16),
  ('6-859-18876-6', 9),
  ('6-859-18876-6', 22),
  ('2-929-00750-8', 1),
  ('5-422-27366-4', 13),
  ('4-534-68002-3', 32),
  ('8-623-26862-8', 11),
  ('8-623-26862-8', 19),
  ('9-705-18352-X', 17),
  ('9-705-18352-X', 17),
  ('5-569-07902-5', 16),
  ('5-569-07902-5', 18),
  ('5-569-07902-5', 4),
  ('4-779-23845-5', 27),
  ('4-285-32402-4', 26),
  ('4-285-32402-4', 25),
  ('3-400-26213-7', 14),
  ('6-813-15847-3', 11),
  ('4-581-54179-4', 31),
  ('5-510-86769-8', 2),
  ('7-507-25547-6', 21),
  ('8-413-68987-2', 5),
  ('8-413-68987-2', 19),
  ('8-413-68987-2', 26),
  ('5-490-80513-7', 11),
  ('5-490-80513-7', 4),
  ('5-490-80513-7', 16),
  ('9-066-71384-4', 10),
  ('5-346-30868-7', 2),
  ('3-793-54992-5', 15),
  ('3-793-54992-5', 21),
  ('3-793-54992-5', 19),
  ('1-962-62155-3', 13),
  ('7-068-87971-3', 6),
  ('4-707-09069-9', 10),
  ('8-539-07804-X', 17),
  ('2-608-80511-6', 10),
  ('0-143-96916-1', 21),
  ('2-972-10353-X', 19),
  ('2-972-10353-X', 17),
  ('2-972-10353-X', 21),
  ('2-972-10353-X', 21),
  ('2-416-74964-1', 3),
  ('5-398-38089-3', 23),
  ('5-398-38089-3', 29),
  ('5-398-38089-3', 30),
  ('8-249-99200-8', 21),
  ('0-971-96537-4', 13),
  ('0-971-96537-4', 2),
  ('3-232-45117-9', 9),
  ('3-232-45117-9', 8),
  ('8-310-87439-1', 18),
  ('8-779-37579-0', 6),
  ('9-355-44413-3', 24),
  ('4-150-64512-4', 13),
  ('2-133-47499-4', 15),
  ('6-860-28352-1', 6),
  ('6-186-84647-4', 13),
  ('1-173-86662-0', 8),
  ('1-890-70446-6', 9),
  ('1-890-70446-6', 22),
  ('5-901-41934-0', 29),
  ('5-901-41934-0', 25),
  ('3-047-11832-9', 19),
  ('3-047-11832-9', 19),
  ('8-659-50919-6', 28),
  ('8-659-50919-6', 11),
  ('8-659-50919-6', 28),
  ('6-493-77164-1', 30),
  ('5-079-85580-0', 11),
  ('0-665-64853-7', 19),
  ('2-903-30998-1', 4),
  ('2-903-30998-1', 6),
  ('5-662-88382-3', 28),
  ('5-662-88382-3', 6),
  ('5-670-26702-8', 23),
  ('5-191-96786-0', 11),
  ('5-191-96786-0', 1),
  ('4-963-81484-6', 19),
  ('4-864-30513-7', 29),
  ('4-864-30513-7', 15),
  ('4-864-30513-7', 18),
  ('4-864-30513-7', 19),
  ('0-169-80946-3', 24),
  ('0-169-80946-3', 22),
  ('0-169-80946-3', 5),
  ('7-735-43804-4', 1),
  ('7-361-54089-9', 6),
  ('3-688-95488-2', 1),
  ('5-495-92301-4', 11),
  ('1-785-24111-7', 13),
  ('3-284-59337-3', 2),
  ('2-083-91776-6', 21),
  ('2-083-91776-6', 13),
  ('2-290-83268-5', 30),
  ('2-290-83268-5', 23),
  ('2-290-83268-5', 14),
  ('2-533-15707-4', 4),
  ('6-347-23109-3', 12),
  ('7-050-03542-4', 23),
  ('3-972-24276-X', 3),
  ('5-946-09571-4', 5),
  ('5-946-09571-4', 16),
  ('4-707-36872-7', 29),
  ('4-707-36872-7', 24),
  ('9-433-47346-9', 13),
  ('9-433-47346-9', 21),
  ('3-023-11845-0', 24),
  ('4-428-55071-5', 14),
  ('4-428-55071-5', 1),
  ('4-428-55071-5', 19),
  ('3-459-41381-6', 19),
  ('3-459-41381-6', 9),
  ('3-459-41381-6', 15),
  ('8-049-34471-1', 5),
  ('8-049-34471-1', 25),
  ('8-049-34471-1', 3),
  ('8-049-34471-1', 7),
  ('9-115-09740-4', 11),
  ('9-115-09740-4', 14),
  ('9-115-09740-4', 16),
  ('2-379-07214-0', 7),
  ('2-379-07214-0', 17),
  ('6-887-42213-1', 5),
  ('6-887-42213-1', 24),
  ('6-887-42213-1', 11),
  ('1-819-30727-1', 1),
  ('1-819-30727-1', 10),
  ('1-819-30727-1', 12),
  ('2-606-91782-0', 15),
  ('9-187-70378-5', 30),
  ('9-187-70378-5', 25),
  ('9-649-55034-8', 17),
  ('9-649-55034-8', 26),
  ('8-228-12671-9', 11),
  ('1-955-64784-4', 26),
  ('1-955-64784-4', 22),
  ('4-152-64569-5', 6),
  ('4-152-64569-5', 13),
  ('7-667-41915-9', 4),
  ('7-667-41915-9', 28),
  ('5-827-69527-0', 29),
  ('9-069-71990-8', 15),
  ('9-069-71990-8', 18),
  ('3-392-90451-1', 30),
  ('3-392-90451-1', 5),
  ('3-392-90451-1', 12),
  ('3-392-90451-1', 21),
  ('4-256-18922-X', 14),
  ('4-256-18922-X', 15),
  ('3-200-94440-4', 1),
  ('8-636-66068-8', 23),
  ('8-636-66068-8', 13),
  ('1-137-96561-4', 25),
  ('1-137-96561-4', 1),
  ('1-137-96561-4', 6),
  ('1-137-96561-4', 28),
  ('1-446-66892-4', 10),
  ('1-446-66892-4', 24),
  ('1-446-66892-4', 25),
  ('4-246-57014-1', 10),
  ('6-158-50476-9', 7),
  ('6-158-50476-9', 15),
  ('8-082-55625-0', 21),
  ('0-303-58563-3', 3),
  ('0-303-58563-3', 12),
  ('2-046-26129-1', 19),
  ('2-046-26129-1', 15),
  ('2-046-26129-1', 26),
  ('7-202-32580-2', 21),
  ('7-202-32580-2', 23),
  ('7-202-32580-2', 30),
  ('3-631-20522-8', 26),
  ('3-631-20522-8', 4),
  ('3-024-58389-0', 28),
  ('4-467-12035-1', 6),
  ('7-305-64941-4', 12),
  ('2-835-57497-2', 7),
  ('3-728-16743-6', 14),
  ('5-683-73212-3', 13),
  ('5-683-73212-3', 17),
  ('2-403-96991-5', 10),
  ('2-403-96991-5', 18),
  ('2-403-96991-5', 25),
  ('7-210-93696-3', 22),
  ('7-210-93696-3', 24),
  ('6-699-98300-8', 27),
  ('4-310-68879-9', 23),
  ('2-006-07049-5', 28),
  ('2-006-07049-5', 26),
  ('2-354-87704-8', 16),
  ('9-045-48013-1', 26),
  ('5-615-02747-9', 7),
  ('8-087-25650-6', 23),
  ('8-087-25650-6', 6),
  ('1-428-97627-2', 24),
  ('3-347-37255-7', 31),
  ('3-381-53690-7', 24),
  ('3-381-53690-7', 29),
  ('3-381-53690-7', 15),
  ('7-806-66147-6', 5),
  ('7-806-66147-6', 30),
  ('7-806-66147-6', 18),
  ('7-806-66147-6', 32),
  ('2-444-83490-9', 7),
  ('5-677-31177-4', 19),
  ('5-677-31177-4', 31),
  ('7-670-24814-9', 6),
  ('0-382-56848-6', 28),
  ('0-382-56848-6', 26),
  ('0-382-56848-6', 20),
  ('0-158-15117-8', 12),
  ('9-145-57905-9', 26),
  ('5-680-77324-4', 23),
  ('8-431-01981-6', 18),
  ('0-970-28192-7', 3),
  ('0-970-28192-7', 31),
  ('0-970-28192-7', 5),
  ('9-469-88850-2', 10),
  ('6-994-30012-9', 9),
  ('5-820-21935-X', 14),
  ('5-820-21935-X', 32),
  ('5-820-21935-X', 23),
  ('5-820-21935-X', 9),
  ('1-424-88400-4', 4),
  ('4-971-58575-3', 28),
  ('1-443-31432-3', 8),
  ('1-443-31432-3', 29),
  ('0-576-48014-2', 15),
  ('2-405-62238-6', 29),
  ('2-405-62238-6', 25),
  ('2-345-19236-4', 18),
  ('2-345-19236-4', 5),
  ('0-803-15882-3', 28),
  ('0-803-15882-3', 19),
  ('0-803-15882-3', 7),
  ('7-464-56359-X', 6),
  ('7-464-56359-X', 21),
  ('8-471-77531-X', 30),
  ('3-774-57859-1', 19),
  ('3-774-57859-1', 8),
  ('4-851-50044-0', 15),
  ('4-209-16887-4', 17),
  ('9-076-11813-2', 18),
  ('9-788-87053-8', 18),
  ('9-788-87053-8', 5),
  ('5-611-70170-1', 15),
  ('5-611-70170-1', 30),
  ('4-807-69240-2', 5),
  ('7-883-12311-4', 10),
  ('7-883-12311-4', 4),
  ('7-883-12311-4', 9),
  ('1-403-48123-7', 21),
  ('6-342-87890-0', 28),
  ('8-029-50214-1', 10),
  ('6-151-15237-9', 27),
  ('8-921-00372-X', 12),
  ('9-673-65406-9', 29),
  ('9-673-65406-9', 15),
  ('1-991-78741-3', 30),
  ('3-818-82073-2', 31),
  ('3-818-82073-2', 6),
  ('0-856-90701-4', 16),
  ('7-065-16593-0', 23),
  ('7-065-16593-0', 20),
  ('7-065-16593-0', 28),
  ('7-065-16593-0', 3),
  ('5-840-81366-4', 12),
  ('5-840-81366-4', 25),
  ('1-832-18080-8', 16),
  ('8-439-84917-6', 32),
  ('8-439-84917-6', 6),
  ('5-368-76215-1', 2),
  ('5-368-76215-1', 13),
  ('5-368-76215-1', 5),
  ('1-728-71507-5', 7),
  ('1-728-71507-5', 21),
  ('0-153-36057-7', 5),
  ('0-153-36057-7', 7),
  ('0-153-36057-7', 27),
  ('0-153-36057-7', 24),
  ('6-601-33496-0', 12),
  ('4-782-66880-5', 18),
  ('3-012-05909-1', 10),
  ('6-931-37141-X', 25),
  ('6-354-13346-8', 24),
  ('6-354-13346-8', 29),
  ('6-403-96662-6', 30),
  ('5-632-70875-6', 17),
  ('2-923-38814-3', 6),
  ('5-805-20855-5', 10),
  ('7-408-18970-X', 2),
  ('6-766-85284-4', 13),
  ('3-074-44332-4', 30),
  ('8-450-39105-9', 7),
  ('8-450-39105-9', 16),
  ('8-450-39105-9', 21),
  ('0-007-54810-9', 18),
  ('0-007-54810-9', 23),
  ('0-007-54810-9', 3),
  ('6-711-75196-5', 1),
  ('1-641-00933-0', 17),
  ('1-641-00933-0', 7),
  ('9-521-74715-3', 32),
  ('9-521-74715-3', 28),
  ('7-034-53984-7', 5),
  ('7-034-53984-7', 1),
  ('7-034-53984-7', 11),
  ('9-153-92336-7', 31),
  ('3-599-10283-X', 17),
  ('3-599-10283-X', 20),
  ('7-032-38749-7', 8),
  ('5-092-28282-7', 25),
  ('5-092-28282-7', 6),
  ('8-329-57269-2', 20),
  ('8-329-57269-2', 10),
  ('0-282-38770-6', 26),
  ('0-282-38770-6', 2),
  ('8-295-61766-4', 1),
  ('0-091-72923-8', 32),
  ('0-091-72923-8', 12),
  ('0-091-72923-8', 15),
  ('1-327-64076-7', 27),
  ('7-670-18658-5', 4),
  ('7-237-92363-3', 19),
  ('9-062-85532-6', 2),
  ('5-144-24406-8', 7),
  ('3-149-41396-6', 26),
  ('9-641-27289-6', 25),
  ('2-212-02043-0', 5),
  ('2-212-02043-0', 26),
  ('2-212-02043-0', 6),
  ('8-724-95628-7', 5),
  ('8-724-95628-7', 24),
  ('8-724-95628-7', 22),
  ('8-724-95628-7', 15),
  ('7-019-22866-6', 23),
  ('7-019-22866-6', 18),
  ('7-019-22866-6', 19),
  ('7-019-22866-6', 15),
  ('3-964-66670-X', 8),
  ('3-964-66670-X', 2),
  ('1-689-72836-1', 6),
  ('4-386-50231-9', 15),
  ('8-703-64850-8', 19),
  ('8-703-64850-8', 30),
  ('4-252-05900-3', 2),
  ('4-252-05900-3', 4),
  ('7-177-13168-X', 11),
  ('7-177-13168-X', 2),
  ('7-110-61360-7', 16),
  ('4-699-52369-2', 6),
  ('4-699-52369-2', 21),
  ('4-699-52369-2', 3),
  ('4-699-52369-2', 21),
  ('8-094-46067-9', 28),
  ('8-094-46067-9', 12),
  ('8-094-46067-9', 14),
  ('1-814-42666-3', 26),
  ('3-533-76200-9', 31),
  ('3-533-76200-9', 15),
  ('3-533-76200-9', 18),
  ('1-601-93847-0', 9),
  ('2-803-93927-4', 6),
  ('2-467-38853-0', 8),
  ('2-467-38853-0', 15),
  ('2-591-41529-3', 19),
  ('3-619-55456-0', 7),
  ('4-989-62871-3', 17),
  ('3-011-31859-X', 28),
  ('3-011-31859-X', 11),
  ('1-097-42756-0', 4),
  ('9-679-99118-0', 3),
  ('9-679-99118-0', 10),
  ('9-679-99118-0', 28),
  ('2-927-17696-5', 4),
  ('2-927-17696-5', 28),
  ('2-927-17696-5', 28),
  ('8-169-40170-4', 1),
  ('1-810-91252-0', 6),
  ('5-689-09731-4', 26),
  ('5-689-09731-4', 3),
  ('5-689-09731-4', 14),
  ('6-638-20600-1', 30),
  ('3-551-74724-5', 26),
  ('3-551-74724-5', 25),
  ('0-833-38119-9', 28),
  ('4-733-85338-6', 30),
  ('4-857-10183-1', 28),
  ('4-857-10183-1', 15),
  ('5-992-53022-3', 10),
  ('5-992-53022-3', 23),
  ('3-663-33235-7', 7),
  ('3-663-33235-7', 18),
  ('1-284-74037-4', 25),
  ('1-284-74037-4', 8),
  ('9-695-22719-8', 24),
  ('9-695-22719-8', 2),
  ('4-126-02583-9', 32),
  ('4-126-02583-9', 28),
  ('2-874-33879-6', 1),
  ('8-828-96762-5', 15),
  ('1-531-53342-6', 25),
  ('1-531-53342-6', 18),
  ('0-174-08951-1', 9),
  ('5-922-85559-X', 6),
  ('5-922-85559-X', 27),
  ('3-115-68402-9', 9),
  ('3-115-68402-9', 14),
  ('2-329-98203-8', 29),
  ('3-272-09631-0', 31),
  ('2-002-13486-3', 30),
  ('8-850-80182-3', 6),
  ('8-850-80182-3', 19),
  ('8-850-80182-3', 3),
  ('0-953-53336-0', 25),
  ('6-918-31716-4', 10),
  ('5-361-45253-X', 19),
  ('5-361-45253-X', 8),
  ('2-785-36899-1', 2),
  ('2-276-89384-2', 11),
  ('8-377-92088-3', 27),
  ('8-377-92088-3', 4),
  ('5-663-24812-9', 2),
  ('5-663-24812-9', 9),
  ('5-533-68122-1', 27),
  ('3-595-64019-5', 13),
  ('5-676-72288-6', 13),
  ('7-120-99696-7', 6),
  ('7-120-99696-7', 28),
  ('5-627-89929-8', 14),
  ('5-848-39477-6', 5),
  ('7-243-96800-7', 20),
  ('4-352-22687-4', 17),
  ('4-352-22687-4', 6),
  ('4-352-22687-4', 32),
  ('4-352-22687-4', 3),
  ('5-669-11565-1', 11),
  ('2-803-35917-0', 5),
  ('2-803-35917-0', 13),
  ('5-379-89794-0', 7),
  ('6-669-21590-8', 24),
  ('1-729-88767-8', 19),
  ('1-729-88767-8', 23),
  ('8-235-36457-3', 23),
  ('3-007-64789-4', 24),
  ('3-652-20228-7', 4),
  ('3-652-20228-7', 16),
  ('3-652-20228-7', 8),
  ('3-652-20228-7', 9),
  ('9-746-47519-3', 16),
  ('9-746-47519-3', 15),
  ('1-407-10684-8', 14),
  ('4-543-55775-1', 17),
  ('4-543-55775-1', 8),
  ('7-839-00655-8', 5),
  ('7-839-00655-8', 15),
  ('7-839-00655-8', 8),
  ('0-498-38887-5', 30),
  ('0-498-38887-5', 10),
  ('2-647-04395-7', 9),
  ('4-474-20794-7', 29),
  ('7-930-70644-3', 12),
  ('7-930-70644-3', 4),
  ('5-302-27150-8', 13),
  ('5-302-27150-8', 6),
  ('6-606-35138-3', 11),
  ('1-614-77273-8', 28),
  ('1-614-77273-8', 6),
  ('4-057-38542-8', 16),
  ('4-057-38542-8', 4),
  ('4-057-38542-8', 1),
  ('0-590-75042-9', 2),
  ('0-590-75042-9', 20),
  ('0-453-16828-0', 7),
  ('0-453-16828-0', 27),
  ('6-067-86431-2', 23),
  ('6-067-86431-2', 3),
  ('6-067-86431-2', 31),
  ('8-024-31710-9', 21),
  ('8-024-31710-9', 27),
  ('2-486-46893-5', 3),
  ('6-799-53359-4', 24),
  ('9-215-77489-0', 29),
  ('9-215-77489-0', 9),
  ('6-308-51276-1', 12),
  ('1-369-03403-2', 20),
  ('6-183-59820-8', 6),
  ('6-183-59820-8', 22),
  ('6-183-59820-8', 29),
  ('4-207-46849-8', 14),
  ('2-996-65062-X', 13),
  ('2-996-65062-X', 25),
  ('2-996-65062-X', 3),
  ('4-440-69277-X', 21),
  ('0-000-96668-1', 6),
  ('0-000-96668-1', 31),
  ('0-000-96668-1', 12),
  ('3-148-34854-0', 9),
  ('3-148-34854-0', 23),
  ('1-780-91261-7', 2),
  ('1-780-91261-7', 1),
  ('5-556-16499-1', 20),
  ('5-556-16499-1', 13),
  ('5-556-16499-1', 27),
  ('7-767-03350-3', 27),
  ('9-483-67025-X', 18),
  ('9-483-67025-X', 2),
  ('9-483-67025-X', 3),
  ('1-015-00104-1', 4),
  ('1-015-00104-1', 28),
  ('4-491-53370-9', 17),
  ('4-491-53370-9', 30),
  ('9-020-76489-6', 12),
  ('6-815-72792-0', 3),
  ('6-815-72792-0', 9),
  ('8-897-87612-9', 9),
  ('8-897-87612-9', 15),
  ('8-897-87612-9', 25),
  ('8-897-87612-9', 28),
  ('2-527-41538-5', 4),
  ('0-649-88716-6', 7),
  ('0-649-88716-6', 27),
  ('3-588-58790-X', 29),
  ('7-731-66647-6', 32),
  ('7-731-66647-6', 4),
  ('7-731-66647-6', 3),
  ('7-731-66647-6', 30),
  ('1-380-25976-2', 26),
  ('1-380-25976-2', 15),
  ('1-380-25976-2', 12),
  ('1-380-25976-2', 19),
  ('9-188-41144-3', 27),
  ('9-188-41144-3', 10),
  ('9-188-41144-3', 17),
  ('0-831-74274-7', 10),
  ('0-831-74274-7', 30),
  ('0-831-74274-7', 19),
  ('8-778-97929-3', 22),
  ('2-544-84155-9', 16),
  ('2-544-84155-9', 9),
  ('8-288-90566-8', 16),
  ('5-378-56134-5', 19),
  ('5-378-56134-5', 29),
  ('1-627-59328-4', 28),
  ('9-267-80527-4', 7),
  ('7-652-04483-9', 20),
  ('8-149-72524-5', 5),
  ('8-149-72524-5', 18),
  ('2-053-46707-X', 15),
  ('2-053-46707-X', 26),
  ('3-404-04470-3', 15),
  ('3-404-04470-3', 19),
  ('1-537-98192-7', 27),
  ('1-537-98192-7', 5),
  ('1-537-98192-7', 11),
  ('3-846-55104-X', 22),
  ('6-716-94533-4', 31),
  ('3-431-49855-8', 32),
  ('3-431-49855-8', 23),
  ('1-604-03055-0', 29),
  ('6-224-65071-3', 12),
  ('6-224-65071-3', 20),
  ('6-224-65071-3', 20),
  ('2-241-22366-2', 2),
  ('6-380-42405-9', 17),
  ('6-380-42405-9', 27),
  ('7-405-57869-1', 25),
  ('2-026-52167-0', 3),
  ('2-026-52167-0', 1),
  ('2-026-52167-0', 10),
  ('5-571-59106-4', 4),
  ('5-571-59106-4', 22),
  ('7-125-69252-4', 22),
  ('9-608-27075-8', 9),
  ('0-536-05767-2', 11),
  ('2-400-02868-0', 30),
  ('7-258-29259-4', 32),
  ('3-838-30008-4', 16),
  ('3-838-30008-4', 21),
  ('7-388-71701-3', 13),
  ('3-041-12492-0', 15),
  ('7-068-60133-2', 7),
  ('9-941-02262-3', 28),
  ('9-941-02262-3', 17),
  ('7-589-08041-1', 6),
  ('7-742-31030-9', 23),
  ('7-742-31030-9', 31),
  ('5-563-63007-2', 22),
  ('5-563-63007-2', 2),
  ('5-563-63007-2', 3),
  ('5-563-63007-2', 14),
  ('3-680-23809-6', 16),
  ('6-982-73176-6', 13),
  ('6-982-73176-6', 6),
  ('7-171-65069-3', 7),
  ('5-644-71762-3', 17),
  ('6-396-94330-1', 30),
  ('6-396-94330-1', 14),
  ('6-396-94330-1', 24),
  ('3-074-96982-2', 29),
  ('3-074-96982-2', 30),
  ('3-074-96982-2', 24),
  ('2-634-28422-5', 27),
  ('2-634-28422-5', 7),
  ('2-634-28422-5', 17),
  ('2-634-28422-5', 28),
  ('3-133-77102-7', 28),
  ('7-312-44470-9', 12),
  ('6-283-25648-1', 17),
  ('6-283-25648-1', 20),
  ('2-441-43326-1', 32),
  ('2-441-43326-1', 16),
  ('2-441-43326-1', 8),
  ('7-720-25466-X', 6),
  ('7-720-25466-X', 31),
  ('0-236-99561-8', 29),
  ('9-153-31556-1', 20),
  ('9-153-31556-1', 29),
  ('8-199-50203-7', 3),
  ('3-978-72801-X', 11),
  ('9-832-38329-3', 15),
  ('9-832-38329-3', 28),
  ('5-495-78422-7', 22),
  ('0-091-36741-7', 16),
  ('8-384-30375-4', 31),
  ('8-384-30375-4', 32),
  ('8-384-30375-4', 8),
  ('2-820-50354-3', 6),
  ('8-863-68390-5', 3),
  ('2-515-59314-3', 22),
  ('2-515-59314-3', 6),
  ('1-833-77540-6', 8),
  ('1-833-77540-6', 2),
  ('4-403-23176-4', 17),
  ('4-403-23176-4', 19),
  ('7-391-33758-7', 3),
  ('7-391-33758-7', 4),
  ('7-391-33758-7', 1),
  ('7-391-33758-7', 3),
  ('5-703-69872-3', 27),
  ('7-099-37752-3', 26),
  ('1-335-81670-4', 30),
  ('1-335-81670-4', 30),
  ('1-592-40798-6', 32),
  ('1-592-40798-6', 11),
  ('6-422-53755-7', 16),
  ('6-422-53755-7', 12),
  ('6-422-53755-7', 25),
  ('9-997-85107-2', 6),
  ('9-997-85107-2', 8),
  ('9-059-74861-1', 7),
  ('5-816-61610-2', 11),
  ('1-400-37943-1', 5),
  ('2-921-75796-6', 22),
  ('1-726-94847-1', 13),
  ('8-147-95513-8', 10),
  ('8-147-95513-8', 8),
  ('9-900-41308-3', 18),
  ('4-637-64666-9', 1),
  ('4-637-64666-9', 26),
  ('3-582-14861-0', 7),
  ('6-311-97809-1', 3),
  ('6-311-97809-1', 18),
  ('6-311-97809-1', 5),
  ('1-384-05928-8', 15),
  ('1-384-05928-8', 20),
  ('1-384-05928-8', 6),
  ('3-382-59535-4', 28),
  ('3-382-59535-4', 8),
  ('8-106-25917-X', 21),
  ('3-515-61667-5', 30),
  ('3-515-61667-5', 31),
  ('4-118-34361-4', 17),
  ('1-001-54385-8', 17),
  ('0-202-21422-2', 8),
  ('1-415-61765-1', 5),
  ('1-415-61765-1', 27),
  ('1-415-61765-1', 4),
  ('7-683-00915-6', 14),
  ('4-306-29302-5', 19),
  ('9-522-06724-5', 14),
  ('3-346-23168-2', 24),
  ('3-010-16354-1', 13),
  ('9-952-31263-6', 22),
  ('5-454-74356-9', 14),
  ('0-088-85239-3', 32),
  ('0-088-85239-3', 4),
  ('9-189-80968-8', 22),
  ('3-387-59838-6', 25),
  ('5-159-81568-6', 6),
  ('5-159-81568-6', 20),
  ('8-506-88759-3', 29),
  ('6-848-33451-0', 14),
  ('6-848-33451-0', 3),
  ('1-812-87036-1', 13),
  ('5-406-81593-8', 21),
  ('0-800-15714-1', 14),
  ('0-800-15714-1', 12),
  ('2-616-93413-2', 11),
  ('2-616-93413-2', 10),
  ('3-896-29000-2', 31),
  ('8-699-22948-8', 23),
  ('2-748-92691-9', 28),
  ('2-748-92691-9', 12),
  ('2-748-92691-9', 19),
  ('6-866-68508-7', 2),
  ('6-866-68508-7', 25),
  ('6-866-68508-7', 21),
  ('6-866-68508-7', 4),
  ('3-386-54712-5', 16),
  ('2-645-90098-4', 5),
  ('7-132-05072-9', 18),
  ('7-132-05072-9', 5),
  ('8-388-65999-5', 15),
  ('8-388-65999-5', 6),
  ('8-388-65999-5', 14),
  ('8-388-65999-5', 16),
  ('2-139-93471-7', 1),
  ('2-139-93471-7', 27),
  ('2-139-93471-7', 32),
  ('2-139-93471-7', 7),
  ('0-696-51702-7', 25),
  ('9-424-52141-3', 27),
  ('7-790-78493-5', 30),
  ('4-134-61353-1', 14),
  ('0-769-30076-6', 18),
  ('9-130-86965-X', 3),
  ('9-130-86965-X', 15),
  ('9-130-86965-X', 23),
  ('4-656-76928-2', 28),
  ('4-656-76928-2', 23),
  ('0-263-52200-8', 30),
  ('0-785-61844-9', 29),
  ('9-758-68763-8', 7),
  ('9-758-68763-8', 11),
  ('9-758-68763-8', 23),
  ('6-130-62932-X', 24),
  ('2-549-12363-8', 12),
  ('2-549-12363-8', 11),
  ('2-549-12363-8', 16),
  ('1-301-84824-7', 1),
  ('1-297-32053-0', 3),
  ('1-152-58446-4', 12),
  ('0-843-86768-X', 2),
  ('0-843-86768-X', 30),
  ('1-746-54710-3', 10),
  ('6-376-58697-X', 28),
  ('6-376-58697-X', 1),
  ('1-104-76045-2', 23),
  ('9-348-85102-0', 14),
  ('0-367-48086-7', 26),
  ('0-227-04281-6', 22),
  ('0-227-04281-6', 18),
  ('7-869-76113-3', 28),
  ('7-869-76113-3', 30),
  ('7-869-76113-3', 16),
  ('7-869-76113-3', 28),
  ('3-935-10572-X', 23),
  ('5-206-43880-4', 16),
  ('0-324-37656-1', 2),
  ('1-298-74126-2', 2),
  ('1-298-74126-2', 5),
  ('1-298-74126-2', 10),
  ('1-298-74126-2', 25),
  ('5-901-83374-0', 6),
  ('5-901-83374-0', 22),
  ('5-901-83374-0', 1),
  ('4-371-86494-5', 29),
  ('4-371-86494-5', 20),
  ('5-940-08471-0', 15),
  ('7-927-89949-X', 31),
  ('7-927-89949-X', 31),
  ('0-657-94934-5', 21),
  ('0-657-94934-5', 8),
  ('5-221-34904-3', 16),
  ('5-221-34904-3', 6),
  ('2-195-34977-8', 10),
  ('8-009-14212-3', 19),
  ('1-371-75106-4', 7),
  ('1-371-75106-4', 5),
  ('8-355-98969-4', 3),
  ('8-355-98969-4', 2),
  ('0-922-45072-2', 10),
  ('0-922-45072-2', 27),
  ('0-922-45072-2', 5),
  ('4-533-54488-6', 3),
  ('2-523-33987-0', 2),
  ('2-523-33987-0', 31),
  ('6-144-88930-2', 2),
  ('6-443-72446-1', 7),
  ('7-566-83046-5', 14),
  ('7-566-83046-5', 12),
  ('2-037-02498-3', 1),
  ('0-022-04454-X', 11),
  ('9-403-00523-8', 12),
  ('1-123-72777-5', 21),
  ('1-961-37562-1', 1),
  ('8-191-30003-6', 11),
  ('8-191-30003-6', 8),
  ('8-191-30003-6', 17),
  ('5-777-70694-0', 16),
  ('4-613-78266-X', 21),
  ('9-994-02083-8', 2),
  ('8-354-48339-8', 2),
  ('8-354-48339-8', 9),
  ('8-740-34688-9', 25),
  ('0-120-23863-2', 11),
  ('0-120-23863-2', 21),
  ('4-283-99729-3', 9),
  ('4-283-99729-3', 18),
  ('8-775-63077-X', 12),
  ('8-775-63077-X', 14),
  ('8-775-63077-X', 19),
  ('6-143-75272-9', 27),
  ('6-143-75272-9', 15),
  ('6-143-75272-9', 14),
  ('2-998-67130-6', 2),
  ('2-998-67130-6', 20),
  ('2-254-47338-7', 17),
  ('4-540-28372-3', 26),
  ('6-695-76136-1', 18),
  ('6-695-76136-1', 8),
  ('5-117-08395-4', 28),
  ('5-117-08395-4', 9),
  ('5-117-08395-4', 14),
  ('7-735-20647-X', 12),
  ('7-735-20647-X', 12),
  ('2-410-58985-5', 30),
  ('2-697-51183-0', 24),
  ('2-697-51183-0', 7),
  ('2-697-51183-0', 5),
  ('2-697-51183-0', 28),
  ('5-552-09196-5', 15),
  ('5-552-09196-5', 20),
  ('5-552-09196-5', 10),
  ('2-812-26801-8', 14),
  ('2-812-26801-8', 25),
  ('2-812-26801-8', 18),
  ('2-812-26801-8', 27),
  ('0-087-93705-0', 29),
  ('0-087-93705-0', 5),
  ('4-180-23242-1', 18),
  ('5-249-49021-2', 29),
  ('6-495-34905-X', 22),
  ('6-495-34905-X', 2),
  ('9-095-95101-4', 25),
  ('1-995-99506-1', 20),
  ('1-995-99506-1', 19),
  ('3-076-28524-6', 6),
  ('3-076-28524-6', 1),
  ('3-076-28524-6', 2),
  ('7-663-31517-0', 26),
  ('3-098-46601-4', 3),
  ('8-748-29819-0', 7),
  ('8-748-29819-0', 24),
  ('8-748-29819-0', 8),
  ('8-748-29819-0', 24),
  ('7-761-57015-9', 20),
  ('8-987-46629-9', 10),
  ('8-987-46629-9', 21),
  ('8-987-46629-9', 32),
  ('6-983-66375-6', 31),
  ('4-999-66059-8', 17),
  ('4-999-66059-8', 30),
  ('8-492-76185-7', 30),
  ('8-492-76185-7', 4),
  ('9-127-43145-2', 29),
  ('9-127-43145-2', 25),
  ('9-127-43145-2', 19),
  ('3-189-27064-3', 23),
  ('6-850-78189-8', 30),
  ('1-256-22674-2', 3),
  ('1-256-22674-2', 15),
  ('1-256-22674-2', 22),
  ('1-364-00866-1', 10),
  ('2-081-53599-8', 22),
  ('2-081-53599-8', 6),
  ('6-443-66560-0', 22),
  ('6-443-66560-0', 18),
  ('6-620-90655-9', 15),
  ('6-620-90655-9', 27),
  ('6-620-90655-9', 25),
  ('3-615-69401-5', 17),
  ('3-242-27035-5', 12),
  ('0-253-43667-2', 31),
  ('0-253-43667-2', 32),
  ('0-253-43667-2', 20),
  ('8-937-13986-3', 3),
  ('3-399-89816-9', 26),
  ('3-399-89816-9', 31),
  ('7-522-76587-0', 20),
  ('8-706-38680-6', 10),
  ('0-249-32960-3', 1),
  ('0-249-32960-3', 22),
  ('1-688-50299-8', 14),
  ('1-688-50299-8', 20),
  ('3-933-74054-1', 32),
  ('5-357-40674-X', 2),
  ('7-734-38805-1', 1),
  ('1-863-93266-6', 3),
  ('6-927-13798-X', 12),
  ('2-817-10957-0', 29),
  ('9-942-36046-8', 18),
  ('4-021-01275-3', 29),
  ('3-212-67210-2', 18),
  ('3-212-67210-2', 19),
  ('7-265-11743-3', 6),
  ('9-346-03088-7', 5),
  ('0-648-65303-X', 6),
  ('5-506-42510-4', 7),
  ('4-457-52478-6', 9),
  ('4-457-52478-6', 15),
  ('4-457-52478-6', 18),
  ('6-127-68117-0', 13),
  ('4-254-62789-0', 27),
  ('0-461-30394-9', 18),
  ('7-278-80826-X', 9),
  ('7-278-80826-X', 15),
  ('9-384-57845-2', 13),
  ('9-384-57845-2', 16),
  ('2-810-01307-1', 20),
  ('2-810-01307-1', 10),
  ('2-080-02034-X', 18),
  ('2-080-02034-X', 29),
  ('4-321-96396-6', 18),
  ('9-931-37570-1', 4),
  ('9-931-37570-1', 27),
  ('9-931-37570-1', 23),
  ('2-817-70804-0', 7),
  ('2-817-70804-0', 10),
  ('2-817-70804-0', 12),
  ('6-720-36846-X', 9),
  ('8-203-28068-4', 23),
  ('8-203-28068-4', 6),
  ('8-203-28068-4', 30),
  ('9-629-52456-2', 29),
  ('3-466-47289-X', 6),
  ('3-466-47289-X', 27),
  ('3-466-47289-X', 1),
  ('3-466-47289-X', 24),
  ('8-213-46034-0', 4),
  ('8-213-46034-0', 9),
  ('8-213-46034-0', 7),
  ('8-213-46034-0', 30),
  ('7-263-25530-8', 21),
  ('7-263-25530-8', 27),
  ('0-995-16909-8', 4),
  ('0-995-16909-8', 23),
  ('0-995-16909-8', 32),
  ('0-845-56463-3', 27),
  ('9-266-88643-2', 32),
  ('5-876-28006-2', 20),
  ('3-714-46415-8', 28),
  ('3-714-46415-8', 32),
  ('9-771-52168-3', 23),
  ('9-281-06095-7', 26),
  ('9-281-06095-7', 29),
  ('9-281-06095-7', 2),
  ('9-281-06095-7', 24),
  ('3-717-30924-2', 12),
  ('3-717-30924-2', 3),
  ('3-717-30924-2', 14),
  ('1-605-65373-X', 4),
  ('1-605-65373-X', 5),
  ('8-905-03321-0', 32),
  ('8-905-03321-0', 4),
  ('4-165-96711-4', 1),
  ('9-489-84060-2', 27),
  ('1-005-22462-5', 27),
  ('1-005-22462-5', 11),
  ('1-127-06701-X', 31),
  ('1-264-42676-3', 27),
  ('1-264-42676-3', 6),
  ('1-264-42676-3', 2),
  ('6-296-33899-6', 13),
  ('6-296-33899-6', 4),
  ('6-131-59675-1', 10),
  ('6-131-59675-1', 25),
  ('6-174-46579-9', 27),
  ('1-314-17503-3', 16),
  ('1-314-17503-3', 20),
  ('3-998-32246-9', 6),
  ('3-998-32246-9', 11),
  ('3-998-32246-9', 10),
  ('3-998-32246-9', 19),
  ('8-229-27036-8', 28),
  ('2-059-43282-0', 31),
  ('8-485-12762-5', 4),
  ('8-485-12762-5', 32),
  ('8-485-12762-5', 14),
  ('5-361-78137-1', 18),
  ('5-361-78137-1', 1),
  ('5-361-78137-1', 30),
  ('5-361-78137-1', 27),
  ('7-948-01382-2', 7),
  ('9-110-28988-7', 22),
  ('9-110-28988-7', 3),
  ('0-693-09431-1', 30),
  ('5-132-85878-3', 8),
  ('0-208-05957-1', 28),
  ('0-208-05957-1', 15),
  ('0-208-05957-1', 8),
  ('3-105-13911-7', 6),
  ('3-105-13911-7', 26),
  ('9-241-10415-5', 7),
  ('4-004-71642-X', 24),
  ('7-371-51175-1', 18),
  ('7-371-51175-1', 21),
  ('3-872-76547-7', 7),
  ('6-888-24918-2', 9),
  ('7-646-62462-4', 7),
  ('2-623-30096-8', 14),
  ('2-623-30096-8', 25),
  ('2-891-31957-5', 8),
  ('6-134-02811-8', 21),
  ('6-134-02811-8', 31),
  ('7-192-85541-3', 4),
  ('8-004-67871-8', 21),
  ('5-574-10230-7', 2),
  ('8-910-39523-0', 3),
  ('8-910-39523-0', 22),
  ('9-760-18900-3', 2),
  ('9-760-18900-3', 31),
  ('9-760-18900-3', 15),
  ('0-847-43706-X', 20),
  ('0-847-43706-X', 19),
  ('0-847-43706-X', 18),
  ('6-862-99036-5', 26),
  ('9-157-21595-2', 15),
  ('9-157-21595-2', 8),
  ('8-841-84253-9', 12),
  ('6-952-44085-2', 12),
  ('6-952-44085-2', 20),
  ('7-578-73926-3', 21),
  ('7-578-73926-3', 27),
  ('9-416-69337-5', 16),
  ('9-416-69337-5', 13),
  ('5-257-80641-X', 12),
  ('5-257-80641-X', 16),
  ('8-045-29076-5', 4),
  ('8-045-29076-5', 22),
  ('8-045-29076-5', 2),
  ('8-045-29076-5', 16),
  ('1-499-39095-5', 3),
  ('5-335-04294-X', 10),
  ('0-622-36718-8', 21),
  ('0-622-36718-8', 18),
  ('0-622-36718-8', 23),
  ('9-419-81715-6', 20),
  ('0-700-11620-6', 15),
  ('0-887-30730-2', 30),
  ('0-887-30730-2', 11),
  ('1-460-28826-2', 22),
  ('8-935-04194-7', 5),
  ('8-935-04194-7', 3),
  ('8-935-04194-7', 8),
  ('1-571-56083-1', 2),
  ('1-571-56083-1', 1),
  ('5-362-77850-1', 10),
  ('5-362-77850-1', 29),
  ('5-362-77850-1', 10),
  ('5-362-77850-1', 15),
  ('9-471-93655-1', 6),
  ('3-211-52745-1', 25),
  ('5-976-80813-1', 7),
  ('5-210-88974-2', 5),
  ('3-829-39461-6', 19),
  ('3-829-39461-6', 21),
  ('3-829-39461-6', 22),
  ('7-388-01643-0', 25),
  ('5-920-59559-0', 10),
  ('0-748-99711-3', 30),
  ('1-979-79817-6', 26),
  ('2-897-62853-7', 11),
  ('1-153-97778-8', 28),
  ('0-220-26199-7', 20),
  ('0-220-26199-7', 31),
  ('0-220-26199-7', 27),
  ('0-220-26199-7', 10),
  ('3-055-29561-7', 9),
  ('2-078-61848-9', 30),
  ('8-823-04584-3', 23),
  ('8-823-04584-3', 8),
  ('6-378-88833-7', 18),
  ('7-331-99569-3', 15),
  ('7-331-99569-3', 19),
  ('7-050-30775-0', 1),
  ('7-050-30775-0', 17),
  ('7-050-30775-0', 19),
  ('4-233-42512-1', 14),
  ('4-233-42512-1', 17),
  ('8-608-45390-8', 15),
  ('8-608-45390-8', 26),
  ('3-655-65274-7', 24),
  ('3-655-65274-7', 19),
  ('8-413-56101-9', 16),
  ('4-069-34549-3', 6),
  ('0-300-54215-1', 27),
  ('0-300-54215-1', 21),
  ('5-178-87389-0', 3),
  ('5-178-87389-0', 31),
  ('2-305-95885-4', 31),
  ('2-305-95885-4', 25),
  ('3-328-94192-4', 4),
  ('3-328-94192-4', 10),
  ('3-328-94192-4', 24),
  ('3-328-94192-4', 3),
  ('3-196-94922-2', 28),
  ('3-196-94922-2', 21),
  ('1-671-23439-1', 7),
  ('1-671-23439-1', 4),
  ('1-671-23439-1', 27),
  ('0-762-59042-4', 23),
  ('0-762-59042-4', 28),
  ('0-762-59042-4', 3),
  ('1-409-00664-6', 23),
  ('6-605-93194-7', 25),
  ('6-605-93194-7', 30),
  ('6-605-93194-7', 11),
  ('1-974-93310-5', 3),
  ('7-030-37131-3', 6),
  ('7-030-37131-3', 7),
  ('8-317-71921-9', 17),
  ('5-678-48175-4', 5),
  ('1-027-49647-4', 11),
  ('0-927-03943-5', 1),
  ('3-334-94409-3', 29),
  ('5-028-63198-0', 18),
  ('0-978-92030-9', 21),
  ('0-978-92030-9', 11),
  ('8-131-95065-4', 13),
  ('8-131-95065-4', 20),
  ('8-131-95065-4', 1),
  ('7-846-54085-8', 6),
  ('7-846-54085-8', 16),
  ('4-155-82520-1', 32),
  ('4-155-82520-1', 19),
  ('4-155-82520-1', 18),
  ('3-747-09416-3', 8),
  ('3-747-09416-3', 14),
  ('3-747-09416-3', 7),
  ('1-054-60110-0', 1),
  ('1-054-60110-0', 30),
  ('1-054-60110-0', 11),
  ('8-900-84258-7', 28),
  ('3-521-22044-3', 16),
  ('3-521-22044-3', 27),
  ('3-521-22044-3', 10),
  ('4-537-96247-X', 30),
  ('2-137-29356-0', 21),
  ('2-137-29356-0', 20),
  ('3-631-30343-2', 1),
  ('3-631-30343-2', 30),
  ('0-125-37488-7', 1),
  ('3-111-93231-1', 14),
  ('9-846-87010-8', 28),
  ('9-846-87010-8', 10),
  ('9-706-10758-4', 7),
  ('9-706-10758-4', 6),
  ('2-455-25531-X', 24),
  ('8-472-82859-X', 1),
  ('5-319-89571-2', 30),
  ('5-319-89571-2', 12),
  ('5-319-89571-2', 6),
  ('0-927-47258-9', 4),
  ('0-274-17335-2', 1),
  ('0-274-17335-2', 17),
  ('0-274-17335-2', 17),
  ('0-274-17335-2', 1),
  ('4-082-98474-7', 14),
  ('4-082-98474-7', 29),
  ('1-925-98571-7', 6),
  ('9-745-97622-9', 13),
  ('0-860-97734-X', 3),
  ('8-620-24005-6', 19),
  ('5-905-70111-3', 9),
  ('5-905-70111-3', 32),
  ('5-905-70111-3', 10),
  ('8-902-97315-8', 9),
  ('8-902-97315-8', 17),
  ('9-929-80914-7', 17),
  ('9-250-66186-X', 17),
  ('7-700-61231-5', 30),
  ('1-615-78479-9', 7),
  ('1-615-78479-9', 14),
  ('1-765-17324-8', 26),
  ('9-704-31196-6', 28),
  ('2-168-86782-8', 14),
  ('2-168-86782-8', 13),
  ('2-168-86782-8', 3),
  ('6-013-26606-9', 13),
  ('6-938-71685-4', 21),
  ('6-938-71685-4', 19),
  ('6-938-71685-4', 6),
  ('9-458-11960-X', 31),
  ('9-458-11960-X', 19),
  ('9-458-11960-X', 19),
  ('1-225-01161-2', 16),
  ('1-225-01161-2', 18),
  ('9-576-71118-5', 31),
  ('8-400-29507-2', 24),
  ('8-400-29507-2', 20),
  ('9-684-59859-9', 31),
  ('9-684-59859-9', 21),
  ('9-684-59859-9', 32),
  ('2-451-39120-0', 21),
  ('5-541-19780-5', 23),
  ('5-541-19780-5', 20),
  ('5-541-19780-5', 23),
  ('2-298-15378-7', 18),
  ('5-723-95615-9', 5),
  ('1-006-15348-9', 24),
  ('7-767-90918-2', 4),
  ('7-767-90918-2', 2),
  ('5-119-00897-6', 13),
  ('5-119-00897-6', 7),
  ('0-617-68079-5', 25),
  ('5-464-79388-7', 24),
  ('0-600-77463-5', 12),
  ('7-458-36456-4', 2),
  ('1-985-25193-0', 10),
  ('1-985-25193-0', 13),
  ('1-985-25193-0', 18),
  ('1-985-25193-0', 20),
  ('4-585-11499-8', 4)
ON CONFLICT DO NOTHING;
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (32, '2017-04-17', 7, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-680-23809-6', 1, 3);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (147, '2015-06-11', 3, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-948-01382-2', 2, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-948-01382-2', 147, 8, DATE '2015-06-11' + INTERVAL '9 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-000-61248-3', 2, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-000-61248-3', 147, 9, DATE '2015-06-11' + INTERVAL '5 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (283, '2016-05-08', 4, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-258-29259-4', 3, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-247-25959-8', 3, 5);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('4-247-25959-8', 283, 3, DATE '2016-05-08' + INTERVAL '14 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-310-49550-1', 3, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-133-77102-7', 3, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (263, '2017-04-10', 3, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-145-57905-9', 4, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-145-57905-9', 263, 9, DATE '2017-04-10' + INTERVAL '6 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-703-64850-8', 4, 6);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-703-64850-8', 263, 10, DATE '2017-04-10' + INTERVAL '8 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-806-66147-6', 4, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-806-66147-6', 263, 8, DATE '2017-04-10' + INTERVAL '5 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-600-16291-0', 4, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('6-600-16291-0', 263, 5, DATE '2017-04-10' + INTERVAL '8 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (69, '2015-05-04', 9, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-590-31005-1', 5, 4);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (139, '2016-06-29', 5, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-079-53185-3', 6, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-110-28988-7', 6, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-110-28988-7', 139, 5, DATE '2016-06-29' + INTERVAL '21 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (139, '2015-02-15', 9, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-638-20600-1', 7, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-910-24076-0', 7, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-910-24076-0', 139, 9, DATE '2015-02-15' + INTERVAL '4 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (88, '2017-01-09', 4, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-132-85878-3', 8, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-132-85878-3', 88, 6, DATE '2017-01-09' + INTERVAL '9 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-235-36457-3', 8, 4);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-673-19802-6', 8, 4);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('4-673-19802-6', 88, 10, DATE '2017-01-09' + INTERVAL '8 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (68, '2017-06-15', 10, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-706-10758-4', 9, 5);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-706-10758-4', 68, 1, DATE '2017-06-15' + INTERVAL '3 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (94, '2015-05-19', 10, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-006-07049-5', 10, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('2-006-07049-5', 94, 5, DATE '2015-05-19' + INTERVAL '2 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-902-97315-8', 10, 3);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (190, '2015-05-04', 10, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-604-03055-0', 11, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-663-33235-7', 11, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-663-33235-7', 190, 2, DATE '2015-05-04' + INTERVAL '7 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (168, '2016-03-26', 5, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-533-15707-4', 12, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (115, '2017-04-23', 1, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-549-12363-8', 13, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('2-549-12363-8', 115, 4, DATE '2017-04-23' + INTERVAL '10 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-962-62155-3', 13, 5);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-962-62155-3', 115, 4, DATE '2017-04-23' + INTERVAL '3 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-082-55625-0', 13, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-082-55625-0', 115, 5, DATE '2017-04-23' + INTERVAL '10 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (8, '2017-01-23', 1, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-748-99711-3', 14, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-748-99711-3', 8, 4, DATE '2017-01-23' + INTERVAL '6 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (291, '2017-06-09', 6, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-533-76200-9', 15, 5);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-533-76200-9', 291, 4, DATE '2017-06-09' + INTERVAL '6 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (56, '2015-01-28', 6, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-367-48086-7', 16, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-367-48086-7', 56, 3, DATE '2015-01-28' + INTERVAL '9 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-149-72524-5', 16, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-149-72524-5', 56, 10, DATE '2015-01-28' + INTERVAL '2 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-823-04584-3', 16, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-823-04584-3', 56, 5, DATE '2015-01-28' + INTERVAL '3 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-027-49647-4', 16, 3);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-292-04395-X', 16, 5);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-292-04395-X', 56, 8, DATE '2015-01-28' + INTERVAL '4 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-601-93847-0', 16, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-601-93847-0', 56, 5, DATE '2015-01-28' + INTERVAL '6 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (295, '2017-05-31', 2, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-931-37141-X', 17, 7);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('6-931-37141-X', 295, 9, DATE '2017-05-31' + INTERVAL '18 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-921-75796-6', 17, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-030-37131-3', 17, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-030-37131-3', 295, 6, DATE '2017-05-31' + INTERVAL '5 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (45, '2017-04-29', 9, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-152-58446-4', 18, 3);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (88, '2017-05-15', 9, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-402-67211-2', 19, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (144, '2016-03-25', 8, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-120-23863-2', 20, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-626-04383-7', 20, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-626-04383-7', 144, 8, DATE '2016-03-25' + INTERVAL '3 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (100, '2016-03-27', 11, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-253-20746-8', 21, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-253-20746-8', 100, 2, DATE '2016-03-27' + INTERVAL '9 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (164, '2015-04-25', 6, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-922-42333-4', 22, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-760-95595-6', 22, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-386-49791-X', 22, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-386-49791-X', 164, 4, DATE '2015-04-25' + INTERVAL '4 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-765-53075-9', 22, 6);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-765-53075-9', 164, 10, DATE '2015-04-25' + INTERVAL '12 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-833-38119-9', 22, 3);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-800-15714-1', 22, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-800-15714-1', 164, 6, DATE '2015-04-25' + INTERVAL '4 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (219, '2015-04-19', 6, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-087-25650-6', 23, 3);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (253, '2016-04-09', 7, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-057-60325-1', 24, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-057-60325-1', 253, 4, DATE '2016-04-09' + INTERVAL '11 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (260, '2016-03-24', 6, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-925-98571-7', 25, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (115, '2017-01-18', 8, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-202-21422-2', 26, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-158-50476-9', 26, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('6-158-50476-9', 115, 6, DATE '2017-01-18' + INTERVAL '12 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (100, '2017-06-06', 10, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-091-72923-8', 27, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-091-72923-8', 100, 7, DATE '2017-06-06' + INTERVAL '9 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (110, '2015-06-17', 4, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-979-92379-6', 28, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('2-979-92379-6', 110, 4, DATE '2015-06-17' + INTERVAL '36 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-872-76547-7', 28, 8);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-872-76547-7', 110, 8, DATE '2015-06-17' + INTERVAL '11 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (247, '2016-02-17', 11, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-799-53359-4', 29, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-270-75147-3', 29, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-270-75147-3', 247, 4, DATE '2016-02-17' + INTERVAL '4 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (166, '2017-03-24', 10, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-591-41529-3', 30, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('2-591-41529-3', 166, 4, DATE '2017-03-24' + INTERVAL '3 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-699-22948-8', 30, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-699-22948-8', 166, 4, DATE '2017-03-24' + INTERVAL '9 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-999-66059-8', 30, 7);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (116, '2017-04-08', 2, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-226-69099-3', 31, 4);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-226-69099-3', 116, 4, DATE '2017-04-08' + INTERVAL '13 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-034-53984-7', 31, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-034-53984-7', 116, 9, DATE '2017-04-08' + INTERVAL '2 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (80, '2017-03-08', 8, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-074-44332-4', 32, 3);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-150-64512-4', 32, 10);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('4-150-64512-4', 80, 8, DATE '2017-03-08' + INTERVAL '5 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-905-70111-3', 32, 4);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-905-70111-3', 80, 6, DATE '2017-03-08' + INTERVAL '13 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (155, '2015-05-03', 4, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-241-10415-5', 33, 5);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-576-48014-2', 33, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-576-48014-2', 155, 10, DATE '2015-05-03' + INTERVAL '9 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-229-95072-5', 33, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-229-95072-5', 155, 6, DATE '2015-05-03' + INTERVAL '9 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (102, '2017-03-04', 11, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-839-00655-8', 34, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-839-00655-8', 102, 4, DATE '2017-03-04' + INTERVAL '12 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-999-66059-8', 34, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('4-999-66059-8', 102, 3, DATE '2017-03-04' + INTERVAL '5 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (149, '2016-01-07', 13, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-638-20600-1', 35, 3);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-080-02034-X', 35, 4);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('2-080-02034-X', 149, 3, DATE '2016-01-07' + INTERVAL '12 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-857-10183-1', 35, 7);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('4-857-10183-1', 149, 3, DATE '2016-01-07' + INTERVAL '2 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-999-44683-2', 35, 3);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (126, '2015-06-27', 5, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-464-56359-X', 36, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-464-56359-X', 126, 9, DATE '2015-06-27' + INTERVAL '6 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (162, '2016-05-28', 3, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-068-87971-3', 37, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-068-87971-3', 162, 4, DATE '2016-05-28' + INTERVAL '11 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-130-62932-X', 37, 4);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (99, '2016-02-25', 1, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-927-03943-5', 38, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-927-03943-5', 99, 5, DATE '2016-02-25' + INTERVAL '15 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-533-76200-9', 38, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-533-76200-9', 99, 4, DATE '2016-02-25' + INTERVAL '7 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (107, '2016-02-14', 6, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-127-97959-7', 39, 5);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-127-97959-7', 107, 10, DATE '2016-02-14' + INTERVAL '7 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (253, '2017-02-03', 4, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-737-93783-3', 40, 8);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('2-737-93783-3', 253, 6, DATE '2017-02-03' + INTERVAL '5 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (55, '2015-05-22', 7, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-141-32208-0', 41, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-141-32208-0', 55, 6, DATE '2015-05-22' + INTERVAL '2 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-631-20522-8', 41, 7);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-659-50919-6', 41, 3);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-846-63213-3', 41, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-846-63213-3', 55, 7, DATE '2015-05-22' + INTERVAL '2 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (136, '2017-03-21', 5, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-836-11990-9', 42, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-836-11990-9', 136, 7, DATE '2017-03-21' + INTERVAL '4 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (226, '2017-03-10', 8, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-619-68425-5', 43, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-619-68425-5', 226, 10, DATE '2017-03-10' + INTERVAL '4 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-212-02043-0', 43, 3);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (238, '2016-04-12', 1, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-428-97627-2', 44, 4);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-428-97627-2', 238, 0, DATE '2016-04-12' + INTERVAL '22 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-068-84686-5', 44, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('6-068-84686-5', 238, 6, DATE '2016-04-12' + INTERVAL '5 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (158, '2017-03-21', 1, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-803-35917-0', 45, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('2-803-35917-0', 158, 8, DATE '2017-03-21' + INTERVAL '13 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-296-33899-6', 45, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (245, '2017-01-13', 5, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-080-42087-0', 46, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-062-85532-6', 46, 6);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-961-37562-1', 46, 6);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-961-37562-1', 245, 1, DATE '2017-01-13' + INTERVAL '16 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (76, '2015-01-09', 7, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-454-08299-7', 47, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (78, '2017-02-26', 9, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-455-25531-X', 48, 6);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-952-66287-4', 48, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-952-66287-4', 78, 2, DATE '2017-02-26' + INTERVAL '8 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (113, '2017-02-08', 5, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-582-14861-0', 49, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-582-14861-0', 113, 10, DATE '2017-02-08' + INTERVAL '7 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (173, '2017-02-04', 9, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-986-07549-4', 50, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (159, '2015-06-23', 10, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-065-77878-3', 51, 3);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (47, '2015-06-02', 13, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-718-67014-5', 52, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-917-07460-X', 52, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-917-07460-X', 47, 10, DATE '2015-06-02' + INTERVAL '10 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (188, '2017-02-23', 8, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-464-56359-X', 53, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-464-56359-X', 188, 7, DATE '2017-02-23' + INTERVAL '2 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-263-25530-8', 53, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-263-25530-8', 188, 6, DATE '2017-02-23' + INTERVAL '2 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-213-46034-0', 53, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-213-46034-0', 188, 2, DATE '2017-02-23' + INTERVAL '7 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (230, '2017-06-03', 9, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-002-13486-3', 54, 8);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-188-73876-X', 54, 4);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-265-11743-3', 54, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-493-77164-1', 54, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('6-493-77164-1', 230, 3, DATE '2017-06-03' + INTERVAL '14 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (195, '2017-01-07', 8, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-106-25917-X', 55, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-850-80182-3', 55, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (191, '2017-04-25', 11, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-938-71685-4', 56, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-345-82753-3', 56, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('6-345-82753-3', 191, 2, DATE '2017-04-25' + INTERVAL '2 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-444-82458-1', 56, 3);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-835-65486-4', 56, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('6-835-65486-4', 191, 10, DATE '2017-04-25' + INTERVAL '3 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (198, '2016-05-14', 2, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-760-18900-3', 57, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (109, '2017-01-22', 13, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-910-24076-0', 58, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-910-24076-0', 109, 4, DATE '2017-01-22' + INTERVAL '2 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (188, '2016-05-05', 2, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-922-45072-2', 59, 2);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (69, '2016-05-30', 2, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-534-68002-3', 60, 4);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('4-534-68002-3', 69, 4, DATE '2016-05-30' + INTERVAL '8 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-499-53187-8', 60, 8);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-792-12505-X', 60, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (45, '2015-03-21', 9, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-901-31949-0', 61, 2);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (41, '2016-03-28', 9, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-035-59390-6', 62, 5);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-035-59390-6', 41, 1, DATE '2016-03-28' + INTERVAL '9 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (110, '2016-04-30', 4, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-846-55104-X', 63, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-298-74126-2', 63, 5);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-380-52028-X', 63, 5);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (198, '2015-04-01', 9, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-469-88850-2', 64, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-469-88850-2', 198, 7, DATE '2015-04-01' + INTERVAL '2 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-557-61297-5', 64, 3);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-779-50169-2', 64, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-617-68079-5', 64, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-617-68079-5', 198, 7, DATE '2015-04-01' + INTERVAL '12 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-246-89134-6', 64, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-246-89134-6', 198, 8, DATE '2015-04-01' + INTERVAL '27 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-702-29865-5', 64, 8);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-702-29865-5', 198, 2, DATE '2015-04-01' + INTERVAL '8 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-076-28524-6', 64, 4);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-076-28524-6', 198, 7, DATE '2015-04-01' + INTERVAL '7 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (24, '2017-03-21', 12, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-613-08792-8', 65, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-613-08792-8', 24, 3, DATE '2017-03-21' + INTERVAL '10 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-388-71701-3', 65, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-388-71701-3', 24, 9, DATE '2017-03-21' + INTERVAL '5 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (44, '2015-03-22', 9, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-977-81097-4', 66, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-977-81097-4', 44, 4, DATE '2015-03-22' + INTERVAL '9 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (79, '2015-01-19', 4, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-883-12311-4', 67, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-329-57269-2', 67, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-329-57269-2', 79, 6, DATE '2015-01-19' + INTERVAL '4 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-620-90655-9', 67, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('6-620-90655-9', 79, 4, DATE '2015-01-19' + INTERVAL '6 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-913-11122-9', 67, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-792-98025-0', 67, 4);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (198, '2015-02-08', 7, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-406-81593-8', 68, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-023-11845-0', 68, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (216, '2015-06-03', 2, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-924-44617-1', 69, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-779-23845-5', 69, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-905-30643-4', 69, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('4-905-30643-4', 216, 9, DATE '2015-06-03' + INTERVAL '2 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-718-67014-5', 69, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-718-67014-5', 216, 5, DATE '2015-06-03' + INTERVAL '7 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (176, '2017-04-15', 1, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-978-72801-X', 70, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-978-72801-X', 176, 6, DATE '2017-04-15' + INTERVAL '7 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-663-24812-9', 70, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-663-24812-9', 176, 9, DATE '2017-04-15' + INTERVAL '2 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-823-04584-3', 70, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-823-04584-3', 176, 8, DATE '2017-04-15' + INTERVAL '3 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (222, '2015-06-14', 3, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-796-78902-6', 71, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-184-70967-2', 71, 5);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (49, '2015-05-07', 6, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-149-92488-3', 72, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-155-82520-1', 72, 3);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (223, '2017-03-03', 12, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-851-84849-X', 73, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (49, '2015-01-31', 5, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-590-75042-9', 74, 4);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-590-75042-9', 49, 9, DATE '2015-01-31' + INTERVAL '5 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-543-55775-1', 74, 11);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('4-543-55775-1', 49, 5, DATE '2015-01-31' + INTERVAL '10 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-767-14707-6', 74, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-767-14707-6', 49, 10, DATE '2015-01-31' + INTERVAL '14 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (193, '2015-03-03', 9, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-392-90451-1', 75, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-392-90451-1', 193, 8, DATE '2015-03-03' + INTERVAL '7 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-815-62566-4', 75, 5);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('6-815-62566-4', 193, 6, DATE '2015-03-03' + INTERVAL '2 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (188, '2017-03-30', 1, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-670-26702-8', 76, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-134-61353-1', 76, 2);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (89, '2017-04-22', 10, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-011-31859-X', 77, 3);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (198, '2016-01-07', 1, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-206-42331-7', 78, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-206-42331-7', 198, 1, DATE '2016-01-07' + INTERVAL '3 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-459-41381-6', 78, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-459-41381-6', 198, 2, DATE '2016-01-07' + INTERVAL '9 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (134, '2017-05-28', 6, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-012-05909-1', 79, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-129-46200-2', 79, 7);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-665-64853-7', 79, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-665-64853-7', 134, 6, DATE '2017-05-28' + INTERVAL '5 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (43, '2017-01-04', 3, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-099-37752-3', 80, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-099-37752-3', 43, 9, DATE '2017-01-04' + INTERVAL '4 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (52, '2016-02-15', 11, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-457-52478-6', 81, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('4-457-52478-6', 52, 9, DATE '2016-02-15' + INTERVAL '3 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-815-72792-0', 81, 3);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-321-96396-6', 81, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (32, '2016-05-01', 4, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-202-32580-2', 82, 5);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (183, '2016-05-22', 6, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-484-69251-4', 83, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-484-69251-4', 183, 6, DATE '2016-05-22' + INTERVAL '3 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-457-52478-6', 83, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-910-24076-0', 83, 4);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-321-96396-6', 83, 2);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (256, '2016-06-19', 3, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-667-41915-9', 84, 5);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-963-81484-6', 84, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('4-963-81484-6', 256, 6, DATE '2016-06-19' + INTERVAL '6 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (217, '2015-06-25', 1, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-902-97315-8', 85, 3);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-677-31177-4', 85, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-677-31177-4', 217, 5, DATE '2015-06-25' + INTERVAL '21 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-149-94583-X', 85, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-149-94583-X', 217, 3, DATE '2015-06-25' + INTERVAL '17 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-767-03350-3', 85, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-767-03350-3', 217, 8, DATE '2015-06-25' + INTERVAL '3 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (240, '2015-03-29', 12, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-848-33451-0', 86, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-835-57497-2', 86, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('2-835-57497-2', 240, 6, DATE '2015-03-29' + INTERVAL '5 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (253, '2016-01-18', 5, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-884-17446-6', 87, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-884-17446-6', 253, 2, DATE '2016-01-18' + INTERVAL '6 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-854-25531-7', 87, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('6-854-25531-7', 253, 6, DATE '2016-01-18' + INTERVAL '8 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (12, '2017-03-22', 3, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-699-22948-8', 88, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-303-58563-3', 88, 4);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (91, '2015-04-29', 7, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-365-61449-X', 89, 8);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-365-61449-X', 91, 9, DATE '2015-04-29' + INTERVAL '11 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (299, '2017-04-07', 8, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-241-22366-2', 90, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('2-241-22366-2', 299, 9, DATE '2017-04-07' + INTERVAL '5 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-811-77446-7', 90, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (133, '2015-04-21', 3, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-997-36670-5', 91, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-997-36670-5', 133, 5, DATE '2015-04-21' + INTERVAL '11 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-644-23588-9', 91, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-644-23588-9', 133, 0, DATE '2015-04-21' + INTERVAL '6 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-362-77850-1', 91, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-362-77850-1', 133, 5, DATE '2015-04-21' + INTERVAL '6 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-733-85338-6', 91, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-838-30008-4', 91, 2);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (36, '2015-05-12', 11, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-782-53368-7', 92, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-782-53368-7', 36, 4, DATE '2015-05-12' + INTERVAL '3 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (154, '2016-01-12', 3, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-247-25959-8', 93, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('4-247-25959-8', 154, 9, DATE '2016-01-12' + INTERVAL '3 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (71, '2016-05-06', 8, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-125-37488-7', 94, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-143-26451-4', 94, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-143-26451-4', 71, 5, DATE '2016-05-06' + INTERVAL '3 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-186-84647-4', 94, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('6-186-84647-4', 71, 5, DATE '2016-05-06' + INTERVAL '11 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-712-61022-9', 94, 6);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('2-712-61022-9', 71, 7, DATE '2016-05-06' + INTERVAL '10 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (292, '2017-06-02', 8, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-689-62102-7', 95, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-689-62102-7', 292, 6, DATE '2017-06-02' + INTERVAL '2 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (69, '2015-03-17', 8, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-073-97837-X', 96, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-073-97837-X', 69, 8, DATE '2015-03-17' + INTERVAL '17 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (187, '2017-01-07', 7, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-887-79031-9', 97, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('6-887-79031-9', 187, 9, DATE '2017-01-07' + INTERVAL '7 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-695-76136-1', 97, 5);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (197, '2017-05-05', 2, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-549-12363-8', 98, 5);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-889-45586-8', 98, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('4-889-45586-8', 197, 7, DATE '2017-05-05' + INTERVAL '2 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-921-75796-6', 98, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('2-921-75796-6', 197, 8, DATE '2017-05-05' + INTERVAL '8 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-765-17324-8', 98, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-765-17324-8', 197, 6, DATE '2017-05-05' + INTERVAL '4 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (79, '2015-04-18', 6, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-823-04584-3', 99, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-823-04584-3', 79, 5, DATE '2015-04-18' + INTERVAL '4 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-190-95393-4', 99, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-190-95393-4', 79, 7, DATE '2015-04-18' + INTERVAL '16 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-206-01793-0', 99, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-206-01793-0', 79, 5, DATE '2015-04-18' + INTERVAL '2 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (25, '2016-01-10', 8, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-019-84176-3', 100, 4);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-697-20497-7', 100, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-697-20497-7', 25, 9, DATE '2016-01-10' + INTERVAL '14 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-525-58834-1', 100, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-525-58834-1', 25, 9, DATE '2016-01-10' + INTERVAL '5 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (208, '2016-01-26', 5, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-932-25424-2', 101, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-932-25424-2', 208, 6, DATE '2016-01-26' + INTERVAL '3 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-024-31710-9', 101, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-024-31710-9', 208, 7, DATE '2016-01-26' + INTERVAL '8 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (17, '2017-02-14', 6, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-253-43667-2', 102, 4);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-253-43667-2', 17, 10, DATE '2017-02-14' + INTERVAL '5 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-817-70804-0', 102, 3);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-860-97734-X', 102, 4);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-860-97734-X', 17, 10, DATE '2017-02-14' + INTERVAL '7 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (37, '2016-04-26', 12, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-491-53370-9', 103, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('4-491-53370-9', 37, 8, DATE '2016-04-26' + INTERVAL '19 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-298-15378-7', 103, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('2-298-15378-7', 37, 6, DATE '2016-04-26' + INTERVAL '9 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-000-96668-1', 103, 7);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-000-96668-1', 37, 4, DATE '2016-04-26' + INTERVAL '22 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (242, '2015-05-15', 7, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-741-20879-5', 104, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-741-20879-5', 242, 6, DATE '2015-05-15' + INTERVAL '8 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (89, '2017-02-21', 9, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-713-17717-6', 105, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (221, '2017-02-11', 6, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-723-95615-9', 106, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-723-95615-9', 221, 3, DATE '2017-02-11' + INTERVAL '2 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-455-25531-X', 106, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('2-455-25531-X', 221, 6, DATE '2017-02-11' + INTERVAL '17 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (273, '2017-03-03', 8, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-213-46034-0', 107, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-213-46034-0', 273, 4, DATE '2017-03-03' + INTERVAL '3 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-379-89794-0', 107, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-011-74988-9', 107, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-011-74988-9', 273, 7, DATE '2017-03-03' + INTERVAL '14 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-459-41381-6', 107, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (31, '2015-02-05', 4, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-369-03403-2', 108, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-369-03403-2', 31, 5, DATE '2015-02-05' + INTERVAL '7 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-517-85119-1', 108, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-517-85119-1', 31, 10, DATE '2015-02-05' + INTERVAL '2 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (43, '2016-02-04', 4, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-159-81568-6', 109, 4);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-159-81568-6', 43, 3, DATE '2016-02-04' + INTERVAL '9 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-129-56935-8', 109, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('2-129-56935-8', 43, 9, DATE '2016-02-04' + INTERVAL '4 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-024-58389-0', 109, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-024-58389-0', 43, 1, DATE '2016-02-04' + INTERVAL '7 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (164, '2016-02-16', 3, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-914-39484-4', 110, 3);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-811-77446-7', 110, 7);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('2-811-77446-7', 164, 7, DATE '2016-02-16' + INTERVAL '5 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (35, '2017-01-14', 6, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-254-47338-7', 111, 3);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-568-03820-0', 111, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (130, '2016-04-25', 3, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-484-69251-4', 112, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-786-86703-2', 112, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-738-42189-X', 112, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (76, '2016-05-19', 9, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-413-56101-9', 113, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-413-56101-9', 76, 2, DATE '2016-05-19' + INTERVAL '7 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-131-62625-2', 113, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-131-62625-2', 76, 10, DATE '2016-05-19' + INTERVAL '4 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (175, '2015-05-21', 2, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-199-99841-3', 114, 5);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('6-199-99841-3', 175, 1, DATE '2015-05-21' + INTERVAL '2 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (42, '2015-02-13', 7, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-200-94440-4', 115, 4);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-151-86773-9', 115, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-151-86773-9', 42, 3, DATE '2015-02-13' + INTERVAL '5 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (274, '2017-01-08', 10, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-821-69943-7', 116, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-307-61155-1', 116, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-092-28282-7', 116, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-092-28282-7', 274, 6, DATE '2017-01-08' + INTERVAL '3 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (196, '2015-02-12', 5, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-546-47386-1', 117, 7);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (186, '2016-05-16', 12, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-627-89929-8', 118, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-627-89929-8', 186, 4, DATE '2016-05-16' + INTERVAL '2 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (282, '2015-02-10', 3, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-258-29259-4', 119, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-258-29259-4', 282, 7, DATE '2015-02-10' + INTERVAL '22 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-076-28524-6', 119, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-728-71507-5', 119, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-728-71507-5', 282, 10, DATE '2015-02-10' + INTERVAL '6 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (187, '2016-04-05', 2, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-198-84377-6', 120, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-198-84377-6', 187, 8, DATE '2016-04-05' + INTERVAL '11 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-380-42405-9', 120, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-649-13941-8', 120, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-768-33971-2', 120, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-768-33971-2', 187, 10, DATE '2016-04-05' + INTERVAL '4 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-305-64941-4', 120, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-305-64941-4', 187, 9, DATE '2016-04-05' + INTERVAL '4 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-533-25938-7', 120, 13);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-533-25938-7', 187, 10, DATE '2016-04-05' + INTERVAL '3 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (148, '2017-05-18', 12, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-335-81670-4', 121, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-335-81670-4', 148, 7, DATE '2017-05-18' + INTERVAL '29 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-132-05072-9', 121, 3);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-141-05835-5', 121, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-913-11122-9', 121, 2);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (38, '2015-03-06', 1, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-957-37367-2', 122, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-957-37367-2', 38, 9, DATE '2015-03-06' + INTERVAL '10 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-342-87890-0', 122, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('6-342-87890-0', 38, 4, DATE '2015-03-06' + INTERVAL '2 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-024-31710-9', 122, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-024-31710-9', 38, 10, DATE '2015-03-06' + INTERVAL '3 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-403-48123-7', 122, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-403-48123-7', 38, 6, DATE '2015-03-06' + INTERVAL '9 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (78, '2015-01-12', 11, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-071-77058-7', 123, 6);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('2-071-77058-7', 78, 4, DATE '2015-01-12' + INTERVAL '4 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-823-77683-3', 123, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-823-77683-3', 78, 5, DATE '2015-01-12' + INTERVAL '10 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-167-67935-6', 123, 2);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (165, '2016-05-17', 13, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-560-14566-2', 124, 10);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (27, '2016-03-19', 5, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-074-77347-7', 125, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-074-77347-7', 27, 5, DATE '2016-03-19' + INTERVAL '4 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-034-53984-7', 125, 7);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (217, '2016-05-24', 4, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-881-81820-9', 126, 4);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-881-81820-9', 217, 5, DATE '2016-05-24' + INTERVAL '3 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-923-38814-3', 126, 5);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('2-923-38814-3', 217, 5, DATE '2016-05-24' + INTERVAL '10 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (103, '2015-05-09', 7, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-278-80826-X', 127, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-278-80826-X', 103, 10, DATE '2015-05-09' + INTERVAL '5 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-091-36741-7', 127, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-091-36741-7', 103, 5, DATE '2015-05-09' + INTERVAL '7 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (31, '2016-04-05', 6, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-994-30012-9', 128, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-606-91782-0', 128, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('2-606-91782-0', 31, 6, DATE '2016-04-05' + INTERVAL '4 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-604-03055-0', 128, 4);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-604-03055-0', 31, 10, DATE '2016-04-05' + INTERVAL '38 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (216, '2015-03-23', 4, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-537-14308-X', 129, 10);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (75, '2015-06-13', 8, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-159-81568-6', 130, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-288-90566-8', 130, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (244, '2016-05-03', 5, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-816-61610-2', 131, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-816-61610-2', 244, 8, DATE '2016-05-03' + INTERVAL '2 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-137-61940-2', 131, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-137-61940-2', 244, 7, DATE '2016-05-03' + INTERVAL '5 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (198, '2017-04-20', 8, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-295-04361-2', 132, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-680-23809-6', 132, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-423-55543-0', 132, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-423-55543-0', 198, 10, DATE '2017-04-20' + INTERVAL '8 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-276-89384-2', 132, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-371-51175-1', 132, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-215-77489-0', 132, 4);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-215-77489-0', 198, 5, DATE '2017-04-20' + INTERVAL '11 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (85, '2016-01-16', 5, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-663-80268-1', 133, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-254-62789-0', 133, 3);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (179, '2016-03-26', 4, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-196-94922-2', 134, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-196-94922-2', 179, 6, DATE '2016-03-26' + INTERVAL '18 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-777-70694-0', 134, 4);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (12, '2017-03-20', 7, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-593-75709-2', 135, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-593-75709-2', 12, 5, DATE '2017-03-20' + INTERVAL '5 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-576-71118-5', 135, 4);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (267, '2015-01-19', 10, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-649-55034-8', 136, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-649-55034-8', 267, 1, DATE '2015-01-19' + INTERVAL '9 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (101, '2016-03-22', 11, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-721-65323-1', 137, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-721-65323-1', 101, 9, DATE '2016-03-22' + INTERVAL '32 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (270, '2017-04-28', 7, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-982-73176-6', 138, 11);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (144, '2015-05-15', 9, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-937-04364-8', 139, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-731-46040-9', 139, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('4-731-46040-9', 144, 10, DATE '2015-05-15' + INTERVAL '4 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-510-86769-8', 139, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-510-86769-8', 144, 4, DATE '2015-05-15' + INTERVAL '13 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-777-70694-0', 139, 4);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-777-70694-0', 144, 9, DATE '2015-05-15' + INTERVAL '36 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-159-81568-6', 139, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-159-81568-6', 144, 7, DATE '2015-05-15' + INTERVAL '6 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (78, '2015-01-14', 5, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-403-96662-6', 140, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-400-02868-0', 140, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-810-91252-0', 140, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-810-91252-0', 78, 9, DATE '2015-01-14' + INTERVAL '12 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (280, '2015-03-07', 5, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-423-19162-9', 141, 2);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (264, '2017-04-09', 7, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-734-38805-1', 142, 6);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-734-38805-1', 264, 4, DATE '2017-04-09' + INTERVAL '4 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (152, '2015-02-19', 6, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-068-87971-3', 143, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-068-87971-3', 152, 10, DATE '2015-02-19' + INTERVAL '9 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (296, '2015-04-08', 3, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-536-05767-2', 144, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-836-11990-9', 144, 11);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (202, '2017-05-18', 7, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-996-57111-7', 145, 6);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-332-25156-2', 145, 11);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (174, '2016-01-08', 8, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-528-83977-3', 146, 9);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (257, '2017-02-07', 9, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-846-87010-8', 147, 8);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (84, '2015-05-31', 3, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-461-30394-9', 148, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-798-80428-7', 148, 2);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (183, '2017-05-11', 12, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-384-57845-2', 149, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-384-57845-2', 183, 7, DATE '2017-05-11' + INTERVAL '4 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-734-38805-1', 149, 5);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-769-65783-5', 149, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-769-65783-5', 183, 4, DATE '2017-05-11' + INTERVAL '15 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (76, '2015-02-14', 5, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-562-53665-2', 150, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-531-53342-6', 150, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-531-53342-6', 76, 0, DATE '2015-02-14' + INTERVAL '26 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-459-41381-6', 150, 2);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (266, '2017-04-18', 8, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-676-72288-6', 151, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-676-72288-6', 266, 9, DATE '2017-04-18' + INTERVAL '2 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (179, '2016-02-03', 8, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-081-53599-8', 152, 3);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-199-99841-3', 152, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (184, '2015-04-17', 8, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-537-14308-X', 153, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('6-537-14308-X', 184, 8, DATE '2015-04-17' + INTERVAL '19 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-368-76215-1', 153, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-368-76215-1', 184, 4, DATE '2015-04-17' + INTERVAL '3 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (103, '2016-01-01', 3, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-815-62566-4', 154, 13);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (8, '2017-05-06', 4, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-693-09431-1', 155, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-693-09431-1', 8, 6, DATE '2017-05-06' + INTERVAL '26 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (229, '2016-02-18', 9, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-179-52481-2', 156, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-179-52481-2', 229, 8, DATE '2016-02-18' + INTERVAL '4 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-761-57015-9', 156, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-761-57015-9', 229, 9, DATE '2016-02-18' + INTERVAL '3 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (225, '2017-01-03', 4, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-608-80511-6', 157, 6);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('2-608-80511-6', 225, 0, DATE '2017-01-03' + INTERVAL '10 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (63, '2016-02-26', 8, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-927-13798-X', 158, 24);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('6-927-13798-X', 63, 7, DATE '2016-02-26' + INTERVAL '2 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-267-80527-4', 158, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-267-80527-4', 63, 10, DATE '2016-02-26' + INTERVAL '10 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (288, '2016-03-21', 11, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-705-25562-8', 159, 9);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-302-27150-8', 159, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-302-27150-8', 288, 1, DATE '2016-03-21' + INTERVAL '8 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-180-23242-1', 159, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (158, '2017-04-02', 3, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-566-50524-1', 160, 12);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('2-566-50524-1', 158, 7, DATE '2017-04-02' + INTERVAL '3 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-328-18453-1', 160, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-328-18453-1', 158, 10, DATE '2017-04-02' + INTERVAL '4 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (159, '2016-06-14', 6, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-246-89134-6', 161, 2);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (122, '2015-05-15', 2, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-009-14212-3', 162, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-009-14212-3', 122, 10, DATE '2015-05-15' + INTERVAL '3 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-252-05900-3', 162, 6);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('4-252-05900-3', 122, 7, DATE '2015-05-15' + INTERVAL '2 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (254, '2016-03-04', 4, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-492-06235-5', 163, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-492-06235-5', 254, 9, DATE '2016-03-04' + INTERVAL '11 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-812-87036-1', 163, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-956-17492-2', 163, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-589-08041-1', 163, 3);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (8, '2016-04-02', 2, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-011-31859-X', 164, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-011-31859-X', 8, 9, DATE '2016-04-02' + INTERVAL '3 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-657-94934-5', 164, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-657-94934-5', 8, 6, DATE '2016-04-02' + INTERVAL '7 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-812-26801-8', 164, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('2-812-26801-8', 8, 8, DATE '2016-04-02' + INTERVAL '3 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (43, '2016-03-18', 8, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-336-74065-9', 165, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-336-74065-9', 43, 5, DATE '2016-03-18' + INTERVAL '31 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-838-26036-5', 165, 5);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (89, '2017-01-17', 5, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-663-33235-7', 166, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-646-62462-4', 166, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-646-62462-4', 89, 10, DATE '2017-01-17' + INTERVAL '5 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (250, '2016-03-16', 8, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-032-38749-7', 167, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-032-38749-7', 250, 8, DATE '2016-03-16' + INTERVAL '9 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-059-64360-2', 167, 3);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-518-62959-4', 167, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-431-49855-8', 167, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-431-49855-8', 250, 3, DATE '2016-03-16' + INTERVAL '9 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-568-03820-0', 167, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-585-11499-8', 167, 2);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (203, '2017-02-02', 8, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-091-72923-8', 168, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-091-72923-8', 203, 8, DATE '2017-02-02' + INTERVAL '2 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-229-95072-5', 168, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-229-95072-5', 203, 6, DATE '2017-02-02' + INTERVAL '7 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (253, '2015-01-16', 7, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-378-56134-5', 169, 6);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-378-56134-5', 253, 4, DATE '2015-01-16' + INTERVAL '10 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-267-80527-4', 169, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-638-19346-2', 169, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-638-19346-2', 253, 8, DATE '2015-01-16' + INTERVAL '4 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-522-06724-5', 169, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-522-06724-5', 253, 2, DATE '2015-01-16' + INTERVAL '6 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-718-67014-5', 169, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-336-74065-9', 169, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-336-74065-9', 253, 10, DATE '2015-01-16' + INTERVAL '2 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-202-21422-2', 169, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-202-21422-2', 253, 6, DATE '2015-01-16' + INTERVAL '3 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (75, '2017-02-08', 9, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-151-15237-9', 170, 4);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-573-64094-8', 170, 7);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-043-11757-4', 170, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-364-46990-7', 170, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-364-46990-7', 75, 5, DATE '2017-02-08' + INTERVAL '2 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-363-51767-7', 170, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-363-51767-7', 75, 8, DATE '2017-02-08' + INTERVAL '7 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-637-64666-9', 170, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-017-27763-X', 170, 8);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-017-27763-X', 75, 6, DATE '2017-02-08' + INTERVAL '5 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (207, '2016-02-03', 5, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-380-25976-2', 171, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-380-25976-2', 207, 5, DATE '2016-02-03' + INTERVAL '3 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-006-15348-9', 171, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-006-15348-9', 207, 5, DATE '2016-02-03' + INTERVAL '16 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-398-64854-0', 171, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('2-398-64854-0', 207, 5, DATE '2016-02-03' + INTERVAL '10 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-362-77850-1', 171, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-362-77850-1', 207, 8, DATE '2016-02-03' + INTERVAL '4 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (2, '2015-03-23', 7, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-186-84647-4', 172, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-533-15707-4', 172, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-798-22869-X', 172, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-798-22869-X', 2, 9, DATE '2015-03-23' + INTERVAL '25 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (140, '2016-02-07', 10, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-282-38770-6', 173, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (180, '2015-04-13', 3, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-285-55949-2', 174, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-285-55949-2', 180, 1, DATE '2015-04-13' + INTERVAL '11 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-646-62462-4', 174, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-646-62462-4', 180, 10, DATE '2015-04-13' + INTERVAL '4 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (125, '2015-04-03', 5, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-741-86126-X', 175, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-741-86126-X', 125, 6, DATE '2015-04-03' + INTERVAL '5 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (82, '2016-03-09', 8, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-253-20746-8', 176, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-253-20746-8', 82, 5, DATE '2016-03-09' + INTERVAL '17 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-832-38329-3', 176, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (183, '2015-01-16', 4, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-153-92336-7', 177, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-153-92336-7', 183, 3, DATE '2015-01-16' + INTERVAL '6 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-297-39448-0', 177, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-887-42213-1', 177, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('6-887-42213-1', 183, 3, DATE '2015-01-16' + INTERVAL '13 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (141, '2016-04-26', 9, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('978-50-79860-65-4', 178, 2);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (236, '2017-05-27', 6, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-082-15786-6', 179, 3);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-225-01161-2', 179, 4);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-225-01161-2', 236, 8, DATE '2017-05-27' + INTERVAL '15 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-129-46200-2', 179, 5);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-129-46200-2', 236, 7, DATE '2017-05-27' + INTERVAL '10 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (293, '2015-04-27', 2, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-258-29259-4', 180, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-258-29259-4', 293, 3, DATE '2015-04-27' + INTERVAL '7 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-722-84789-5', 180, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-722-84789-5', 293, 8, DATE '2015-04-27' + INTERVAL '6 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (91, '2016-05-23', 9, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-866-69289-5', 181, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-866-69289-5', 91, 5, DATE '2016-05-23' + INTERVAL '13 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (280, '2015-01-28', 7, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-785-36899-1', 182, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('2-785-36899-1', 280, 10, DATE '2015-01-28' + INTERVAL '24 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-900-84258-7', 182, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (17, '2015-06-26', 2, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-162-02070-5', 183, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (27, '2016-01-04', 11, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-613-78266-X', 184, 4);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-807-42758-4', 184, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-807-42758-4', 27, 7, DATE '2016-01-04' + INTERVAL '21 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (233, '2015-05-08', 9, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-106-25917-X', 185, 15);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-242-27035-5', 185, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-242-27035-5', 233, 8, DATE '2015-05-08' + INTERVAL '5 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-257-80641-X', 185, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-257-80641-X', 233, 2, DATE '2015-05-08' + INTERVAL '8 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-890-70446-6', 185, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (82, '2015-01-03', 10, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-643-04454-3', 186, 4);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('4-643-04454-3', 82, 4, DATE '2015-01-03' + INTERVAL '5 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-129-46200-2', 186, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-129-46200-2', 82, 10, DATE '2015-01-03' + INTERVAL '3 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (41, '2015-03-15', 7, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-020-76489-6', 187, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (56, '2016-06-01', 8, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-702-29865-5', 188, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-702-29865-5', 56, 7, DATE '2016-06-01' + INTERVAL '9 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-386-50231-9', 188, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('4-386-50231-9', 56, 9, DATE '2016-06-01' + INTERVAL '3 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-019-84176-3', 188, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-019-84176-3', 56, 5, DATE '2016-06-01' + INTERVAL '10 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (69, '2017-02-05', 11, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-379-07214-0', 189, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('2-379-07214-0', 69, 4, DATE '2017-02-05' + INTERVAL '2 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (264, '2015-01-14', 2, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-011-31859-X', 190, 2);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (7, '2015-05-21', 3, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-629-52456-2', 191, 6);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-629-52456-2', 7, 7, DATE '2015-05-21' + INTERVAL '3 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-644-23588-9', 191, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-644-23588-9', 7, 10, DATE '2015-05-21' + INTERVAL '13 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (190, '2016-02-26', 8, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-765-17324-8', 192, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-765-17324-8', 190, 10, DATE '2016-02-26' + INTERVAL '17 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-888-24918-2', 192, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('6-888-24918-2', 190, 6, DATE '2016-02-26' + INTERVAL '3 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-758-68763-8', 192, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-758-68763-8', 190, 8, DATE '2016-02-26' + INTERVAL '7 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-917-74112-2', 192, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('4-917-74112-2', 190, 4, DATE '2016-02-26' + INTERVAL '18 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-716-94533-4', 192, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('6-716-94533-4', 190, 7, DATE '2016-02-26' + INTERVAL '4 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-018-89649-1', 192, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (205, '2015-06-29', 8, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-048-61573-2', 193, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('2-048-61573-2', 205, 10, DATE '2015-06-29' + INTERVAL '13 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (104, '2016-01-22', 5, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-803-15882-3', 194, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-803-15882-3', 104, 10, DATE '2016-01-22' + INTERVAL '8 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-129-46200-2', 194, 5);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-129-46200-2', 104, 3, DATE '2016-01-22' + INTERVAL '8 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-428-58377-X', 194, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('4-428-58377-X', 104, 10, DATE '2016-01-22' + INTERVAL '6 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (74, '2016-04-20', 4, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-546-47386-1', 195, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-546-47386-1', 74, 9, DATE '2016-04-20' + INTERVAL '6 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (119, '2017-01-09', 8, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-346-81032-4', 196, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('6-346-81032-4', 119, 7, DATE '2017-01-09' + INTERVAL '11 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-548-05409-6', 196, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-548-05409-6', 119, 4, DATE '2017-01-09' + INTERVAL '8 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-684-59859-9', 196, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-684-59859-9', 119, 10, DATE '2017-01-09' + INTERVAL '6 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-445-42162-X', 196, 3);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (128, '2016-03-11', 6, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-852-24447-5', 197, 2);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (2, '2016-06-18', 3, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-045-48013-1', 198, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-234-08825-2', 198, 4);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('6-234-08825-2', 2, 9, DATE '2016-06-18' + INTERVAL '14 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (85, '2017-01-26', 4, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-029-50214-1', 199, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-029-50214-1', 85, 6, DATE '2017-01-26' + INTERVAL '11 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (179, '2017-03-05', 7, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-202-21422-2', 200, 21);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-202-21422-2', 179, 4, DATE '2017-03-05' + INTERVAL '7 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-917-07460-X', 200, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-917-07460-X', 179, 2, DATE '2017-03-05' + INTERVAL '6 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (173, '2017-05-15', 12, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-588-21113-9', 201, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-663-33235-7', 201, 3);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-604-03055-0', 201, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (240, '2017-02-15', 6, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-527-41538-5', 202, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-058-27132-3', 202, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-058-27132-3', 240, 9, DATE '2017-02-15' + INTERVAL '6 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (95, '2015-01-19', 1, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-192-85541-3', 203, 7);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-707-36872-7', 203, 16);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('4-707-36872-7', 95, 3, DATE '2015-01-19' + INTERVAL '11 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-863-44648-9', 203, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('4-863-44648-9', 95, 10, DATE '2015-01-19' + INTERVAL '13 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-602-70962-3', 203, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (217, '2016-02-23', 8, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-386-49791-X', 204, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-133-47499-4', 204, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-134-02811-8', 204, 11);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (154, '2015-04-23', 6, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-600-77463-5', 205, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-600-77463-5', 154, 5, DATE '2015-04-23' + INTERVAL '11 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-926-24119-5', 205, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-926-24119-5', 154, 9, DATE '2015-04-23' + INTERVAL '2 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-707-09069-9', 205, 3);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-455-25531-X', 205, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (55, '2016-02-03', 10, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-551-74724-5', 206, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-551-74724-5', 55, 1, DATE '2016-02-03' + INTERVAL '26 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-267-80527-4', 206, 9);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-267-80527-4', 55, 2, DATE '2016-02-03' + INTERVAL '8 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (170, '2015-06-14', 5, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-063-13740-7', 207, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-063-13740-7', 170, 6, DATE '2015-06-14' + INTERVAL '3 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-935-10572-X', 207, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-468-53059-8', 207, 2);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (60, '2015-04-14', 9, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-298-74126-2', 208, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-298-74126-2', 60, 3, DATE '2015-04-14' + INTERVAL '11 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (175, '2017-03-19', 8, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-471-77531-X', 209, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-382-56848-6', 209, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-382-56848-6', 175, 5, DATE '2017-03-19' + INTERVAL '2 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-400-26213-7', 209, 4);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-400-26213-7', 175, 7, DATE '2017-03-19' + INTERVAL '7 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-082-55625-0', 209, 4);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-082-55625-0', 175, 6, DATE '2017-03-19' + INTERVAL '28 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (10, '2017-01-03', 9, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-723-95615-9', 210, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-723-95615-9', 10, 1, DATE '2017-01-03' + INTERVAL '6 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (80, '2016-01-24', 7, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-616-00327-5', 211, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-616-00327-5', 80, 8, DATE '2016-01-24' + INTERVAL '10 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (171, '2015-05-10', 8, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-955-64784-4', 212, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (42, '2017-02-03', 8, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-130-12427-3', 213, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-384-05928-8', 213, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-384-05928-8', 42, 10, DATE '2017-02-03' + INTERVAL '3 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-821-69943-7', 213, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-590-75042-9', 213, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-525-58834-1', 213, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-525-58834-1', 42, 5, DATE '2017-02-03' + INTERVAL '11 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (287, '2016-02-15', 2, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-655-65274-7', 214, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-655-65274-7', 287, 7, DATE '2016-02-15' + INTERVAL '9 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (89, '2015-06-11', 5, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-346-30868-7', 215, 3);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (228, '2015-05-25', 4, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-306-29302-5', 216, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('4-306-29302-5', 228, 9, DATE '2015-05-25' + INTERVAL '3 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-208-61779-X', 216, 7);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-208-61779-X', 228, 6, DATE '2015-05-25' + INTERVAL '3 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (49, '2015-01-16', 3, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-191-96786-0', 217, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-191-96786-0', 49, 7, DATE '2015-01-16' + INTERVAL '10 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-211-52745-1', 217, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-211-52745-1', 49, 7, DATE '2015-01-16' + INTERVAL '7 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-153-92336-7', 217, 2);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (272, '2015-02-12', 1, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-236-99561-8', 218, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-236-99561-8', 272, 4, DATE '2015-02-12' + INTERVAL '19 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-191-30003-6', 218, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-191-30003-6', 272, 7, DATE '2015-02-12' + INTERVAL '8 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-860-97734-X', 218, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-860-97734-X', 272, 4, DATE '2015-02-12' + INTERVAL '4 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-731-66647-6', 218, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-731-66647-6', 272, 8, DATE '2015-02-12' + INTERVAL '2 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-092-28282-7', 218, 2);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (159, '2017-03-04', 4, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-502-60483-6', 219, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (159, '2015-01-23', 7, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-196-94922-2', 220, 3);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-295-04361-2', 220, 7);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (106, '2016-04-28', 6, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-678-48175-4', 221, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (209, '2016-03-22', 4, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-068-87971-3', 222, 7);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-068-87971-3', 209, 2, DATE '2016-03-22' + INTERVAL '8 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-600-77463-5', 222, 5);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (161, '2016-04-17', 6, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-210-93696-3', 223, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-210-93696-3', 161, 4, DATE '2016-04-17' + INTERVAL '4 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (242, '2016-01-26', 9, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-144-88930-2', 224, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-177-13168-X', 224, 2);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (277, '2017-05-02', 6, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-232-84867-1', 225, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-459-41381-6', 225, 2);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (174, '2016-02-04', 13, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-151-15237-9', 226, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('6-151-15237-9', 174, 9, DATE '2016-02-04' + INTERVAL '5 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-540-28372-3', 226, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('4-540-28372-3', 174, 2, DATE '2016-02-04' + INTERVAL '9 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (286, '2015-05-02', 3, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-110-28988-7', 227, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-978-92030-9', 227, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-978-92030-9', 286, 8, DATE '2015-05-02' + INTERVAL '9 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (300, '2016-04-24', 13, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-833-38119-9', 228, 13);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-833-38119-9', 300, 1, DATE '2016-04-24' + INTERVAL '10 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (114, '2016-06-08', 5, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-094-46067-9', 229, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (39, '2015-06-04', 8, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-523-33987-0', 230, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('2-523-33987-0', 39, 9, DATE '2015-06-04' + INTERVAL '9 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (234, '2015-01-02', 6, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-024-31710-9', 231, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-024-31710-9', 234, 10, DATE '2015-01-02' + INTERVAL '22 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-158-50476-9', 231, 2);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (114, '2017-02-07', 7, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-492-53338-3', 232, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-492-53338-3', 114, 3, DATE '2017-02-07' + INTERVAL '9 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-537-96247-X', 232, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('4-537-96247-X', 114, 6, DATE '2017-02-07' + INTERVAL '6 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-002-13486-3', 232, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('2-002-13486-3', 114, 10, DATE '2017-02-07' + INTERVAL '6 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-453-16828-0', 232, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-453-16828-0', 114, 8, DATE '2017-02-07' + INTERVAL '7 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-821-92831-3', 232, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-821-92831-3', 114, 7, DATE '2017-02-07' + INTERVAL '4 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-403-23176-4', 232, 3);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (180, '2016-06-19', 12, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-113-86616-0', 233, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-113-86616-0', 180, 7, DATE '2016-06-19' + INTERVAL '15 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-423-07694-6', 233, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-423-07694-6', 180, 4, DATE '2016-06-19' + INTERVAL '8 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-590-75042-9', 233, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-049-59684-2', 233, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-724-12645-8', 233, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-724-12645-8', 180, 5, DATE '2016-06-19' + INTERVAL '6 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-188-41144-3', 233, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-188-41144-3', 180, 5, DATE '2016-06-19' + INTERVAL '13 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-876-28006-2', 233, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-876-28006-2', 180, 7, DATE '2016-06-19' + INTERVAL '10 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-922-45072-2', 233, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-922-45072-2', 180, 5, DATE '2016-06-19' + INTERVAL '2 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-817-10957-0', 233, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (211, '2015-04-24', 11, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-839-35050-3', 234, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-728-53974-4', 234, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-327-64941-9', 234, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-327-64941-9', 211, 8, DATE '2015-04-24' + INTERVAL '5 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (75, '2016-04-25', 3, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-400-26213-7', 235, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-400-26213-7', 75, 2, DATE '2016-04-25' + INTERVAL '8 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (16, '2016-04-15', 2, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-314-17503-3', 236, 3);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-688-50299-8', 236, 5);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-688-50299-8', 16, 5, DATE '2016-04-15' + INTERVAL '9 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-125-77632-X', 236, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-125-77632-X', 16, 9, DATE '2016-04-15' + INTERVAL '2 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (33, '2016-01-21', 5, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-141-95713-5', 237, 5);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('4-141-95713-5', 33, 10, DATE '2016-01-21' + INTERVAL '7 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (57, '2015-04-07', 8, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-483-67025-X', 238, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-399-89816-9', 238, 7);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-536-05767-2', 238, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-837-56397-4', 238, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-765-17324-8', 238, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-765-17324-8', 57, 3, DATE '2015-04-07' + INTERVAL '21 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-369-03403-2', 238, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-369-03403-2', 57, 9, DATE '2015-04-07' + INTERVAL '13 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (21, '2016-06-22', 9, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-226-81205-9', 239, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-683-73212-3', 239, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-683-73212-3', 21, 7, DATE '2016-06-22' + INTERVAL '10 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (12, '2016-02-14', 9, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-806-66147-6', 240, 3);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (252, '2015-06-19', 5, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-550-22668-1', 241, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-550-22668-1', 252, 7, DATE '2015-06-19' + INTERVAL '10 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-046-26129-1', 241, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('2-046-26129-1', 252, 9, DATE '2015-06-19' + INTERVAL '4 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (24, '2017-03-08', 10, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-631-30343-2', 242, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-631-30343-2', 24, 9, DATE '2017-03-08' + INTERVAL '2 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-762-83572-2', 242, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (72, '2016-05-30', 3, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-673-19802-6', 243, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('4-673-19802-6', 72, 8, DATE '2016-05-30' + INTERVAL '20 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (87, '2015-06-17', 3, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-827-69527-0', 244, 4);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-827-69527-0', 87, 8, DATE '2015-06-17' + INTERVAL '9 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-384-30375-4', 244, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-669-11565-1', 244, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-669-11565-1', 87, 8, DATE '2015-06-17' + INTERVAL '4 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-059-64360-2', 244, 2);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (247, '2015-01-29', 10, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-556-16499-1', 245, 4);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-556-16499-1', 247, 6, DATE '2015-01-29' + INTERVAL '23 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (255, '2015-04-17', 1, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-590-75042-9', 246, 5);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-590-75042-9', 255, 8, DATE '2015-04-17' + INTERVAL '6 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-408-71260-8', 246, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-001-54385-8', 246, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-001-54385-8', 255, 9, DATE '2015-04-17' + INTERVAL '14 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-998-67130-6', 246, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('2-998-67130-6', 255, 8, DATE '2015-04-17' + INTERVAL '5 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-731-46040-9', 246, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-296-33899-6', 246, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('6-296-33899-6', 255, 10, DATE '2015-04-17' + INTERVAL '4 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (58, '2017-03-20', 11, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-298-74126-2', 247, 2);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (89, '2015-06-25', 9, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-533-15707-4', 248, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('2-533-15707-4', 89, 8, DATE '2015-06-25' + INTERVAL '3 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (7, '2015-01-02', 9, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-839-00655-8', 249, 4);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-839-00655-8', 7, 1, DATE '2015-01-02' + INTERVAL '2 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-317-71921-9', 249, 4);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (107, '2016-05-16', 10, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-533-76200-9', 250, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-533-76200-9', 107, 4, DATE '2016-05-16' + INTERVAL '11 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (294, '2016-06-13', 8, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-914-79407-6', 251, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-914-79407-6', 294, 5, DATE '2016-06-13' + INTERVAL '9 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (127, '2015-06-18', 11, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-386-50231-9', 252, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('4-386-50231-9', 127, 6, DATE '2015-06-18' + INTERVAL '2 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-335-04294-X', 252, 2);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (198, '2017-05-22', 7, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-087-25114-1', 253, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (95, '2016-06-25', 4, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-143-96916-1', 254, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-143-96916-1', 95, 6, DATE '2016-06-25' + INTERVAL '14 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (13, '2017-03-13', 6, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-378-88833-7', 255, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('6-378-88833-7', 13, 3, DATE '2017-03-13' + INTERVAL '3 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-179-67096-7', 255, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-179-67096-7', 13, 10, DATE '2017-03-13' + INTERVAL '6 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-256-18922-X', 255, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('4-256-18922-X', 13, 4, DATE '2017-03-13' + INTERVAL '2 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-311-97809-1', 255, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('6-311-97809-1', 13, 6, DATE '2017-03-13' + INTERVAL '6 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-010-16354-1', 255, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-010-16354-1', 13, 7, DATE '2017-03-13' + INTERVAL '4 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (139, '2017-01-27', 8, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-941-78404-0', 256, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('6-941-78404-0', 139, 2, DATE '2017-01-27' + INTERVAL '8 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-984-73998-4', 256, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-984-73998-4', 139, 8, DATE '2017-01-27' + INTERVAL '9 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (89, '2016-04-17', 9, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-548-05409-6', 257, 3);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-601-28069-5', 257, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-601-28069-5', 89, 5, DATE '2016-04-17' + INTERVAL '15 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-131-62625-2', 257, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-388-71701-3', 257, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-793-54992-5', 257, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-793-54992-5', 89, 10, DATE '2016-04-17' + INTERVAL '26 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-054-60110-0', 257, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-390-72307-3', 257, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (116, '2016-02-15', 10, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-267-80527-4', 258, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-953-53336-0', 258, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-953-53336-0', 116, 5, DATE '2016-02-15' + INTERVAL '9 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-172-52232-6', 258, 6);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-172-52232-6', 116, 8, DATE '2016-02-15' + INTERVAL '20 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-416-74964-1', 258, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('2-416-74964-1', 116, 5, DATE '2016-02-15' + INTERVAL '10 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-190-95393-4', 258, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-761-57015-9', 258, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-761-57015-9', 116, 5, DATE '2016-02-15' + INTERVAL '4 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-384-57845-2', 258, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (73, '2017-05-29', 7, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-927-13798-X', 259, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('6-927-13798-X', 73, 1, DATE '2017-05-29' + INTERVAL '4 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (283, '2017-04-17', 9, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-620-90655-9', 260, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('6-620-90655-9', 283, 9, DATE '2017-04-17' + INTERVAL '9 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-644-71762-3', 260, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-644-71762-3', 283, 9, DATE '2017-04-17' + INTERVAL '21 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (189, '2016-02-08', 7, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-780-91261-7', 261, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-780-91261-7', 189, 8, DATE '2016-02-08' + INTERVAL '18 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-183-59820-8', 261, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('6-183-59820-8', 189, 6, DATE '2016-02-08' + INTERVAL '15 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (13, '2016-01-06', 3, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-860-28352-1', 262, 4);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('6-860-28352-1', 13, 7, DATE '2016-01-06' + INTERVAL '2 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (172, '2016-04-25', 10, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-265-11743-3', 263, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-265-11743-3', 172, 3, DATE '2016-04-25' + INTERVAL '18 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-897-62853-7', 263, 3);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (91, '2017-02-17', 4, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-167-67935-6', 264, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-929-00750-8', 264, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-521-87256-7', 264, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('6-521-87256-7', 91, 4, DATE '2017-02-17' + INTERVAL '4 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (44, '2015-05-05', 8, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-086-91306-0', 265, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('2-086-91306-0', 44, 3, DATE '2015-05-05' + INTERVAL '3 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-779-50169-2', 265, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-779-50169-2', 44, 4, DATE '2015-05-05' + INTERVAL '7 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (294, '2016-03-07', 6, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-443-66560-0', 266, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-331-99569-3', 266, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-331-99569-3', 294, 8, DATE '2016-03-07' + INTERVAL '3 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (135, '2016-01-04', 1, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-788-87053-8', 267, 4);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-788-87053-8', 135, 0, DATE '2016-01-04' + INTERVAL '25 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-506-37923-6', 267, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-506-37923-6', 135, 7, DATE '2016-01-04' + INTERVAL '27 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (79, '2017-05-24', 8, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-978-92030-9', 268, 2);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (130, '2017-06-04', 9, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-638-20600-1', 269, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('6-638-20600-1', 130, 10, DATE '2017-06-04' + INTERVAL '7 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-347-50394-8', 269, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('6-347-50394-8', 130, 1, DATE '2017-06-04' + INTERVAL '13 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (194, '2016-05-24', 12, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-599-10283-X', 270, 7);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (190, '2017-04-23', 9, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-638-20600-1', 271, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-068-60133-2', 271, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-423-07694-6', 271, 6);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (202, '2016-03-01', 6, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-669-11565-1', 272, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-790-78493-5', 272, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-441-04041-9', 272, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-441-04041-9', 202, 10, DATE '2016-03-01' + INTERVAL '4 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (281, '2016-06-23', 6, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-256-22674-2', 273, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (46, '2016-03-01', 12, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-069-71990-8', 274, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-069-71990-8', 46, 4, DATE '2016-03-01' + INTERVAL '5 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-158-15117-8', 274, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-158-15117-8', 46, 2, DATE '2016-03-01' + INTERVAL '7 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-767-90918-2', 274, 3);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-162-02070-5', 274, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-162-02070-5', 46, 10, DATE '2016-03-01' + INTERVAL '14 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-863-93266-6', 274, 7);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-863-93266-6', 46, 2, DATE '2016-03-01' + INTERVAL '17 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-483-67025-X', 274, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-483-67025-X', 46, 7, DATE '2016-03-01' + INTERVAL '17 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (102, '2016-06-02', 8, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-606-35138-3', 275, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (212, '2017-03-07', 12, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-833-77540-6', 276, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-833-77540-6', 212, 0, DATE '2017-03-07' + INTERVAL '7 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-796-78902-6', 276, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-796-78902-6', 212, 8, DATE '2017-03-07' + INTERVAL '10 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-321-10324-1', 276, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (3, '2017-06-12', 5, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-184-70967-2', 277, 6);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('4-184-70967-2', 3, 8, DATE '2017-06-12' + INTERVAL '5 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-167-67935-6', 277, 3);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (47, '2015-06-18', 3, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-571-56083-1', 278, 4);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-571-56083-1', 47, 5, DATE '2015-06-18' + INTERVAL '5 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-379-89794-0', 278, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-379-89794-0', 47, 8, DATE '2015-06-18' + INTERVAL '5 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (18, '2017-04-16', 9, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-123-72777-5', 279, 3);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-045-48013-1', 279, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-045-48013-1', 18, 10, DATE '2017-04-16' + INTERVAL '2 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (132, '2015-01-02', 4, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-143-32070-4', 280, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-143-32070-4', 132, 9, DATE '2015-01-02' + INTERVAL '2 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-450-39105-9', 280, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-696-51702-7', 280, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-696-51702-7', 132, 0, DATE '2015-01-02' + INTERVAL '6 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (270, '2016-01-29', 2, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-210-88974-2', 281, 4);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (121, '2015-01-10', 10, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-638-19346-2', 282, 6);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-179-67096-7', 282, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-179-67096-7', 121, 5, DATE '2015-01-10' + INTERVAL '3 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (230, '2016-02-26', 1, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-095-95101-4', 283, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-095-95101-4', 230, 10, DATE '2016-02-26' + INTERVAL '11 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-057-38542-8', 283, 4);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('4-057-38542-8', 230, 9, DATE '2016-02-26' + INTERVAL '6 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-104-24898-X', 283, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-104-24898-X', 230, 7, DATE '2016-02-26' + INTERVAL '2 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (189, '2016-02-18', 2, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-423-19162-9', 284, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (2, '2016-06-22', 10, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-801-78251-7', 285, 3);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (69, '2017-03-09', 10, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-832-38329-3', 286, 5);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (6, '2016-02-28', 4, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-531-53342-6', 287, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-531-53342-6', 6, 7, DATE '2016-02-28' + INTERVAL '2 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-327-64941-9', 287, 4);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-388-65999-5', 287, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-594-91254-5', 287, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-594-91254-5', 6, 6, DATE '2016-02-28' + INTERVAL '4 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (142, '2017-05-31', 6, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-985-25193-0', 288, 4);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-985-25193-0', 142, 2, DATE '2017-05-31' + INTERVAL '12 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (57, '2017-04-09', 8, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-329-57269-2', 289, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (43, '2015-03-16', 3, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-895-72801-8', 290, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-895-72801-8', 43, 6, DATE '2015-03-16' + INTERVAL '2 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (70, '2015-01-11', 6, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-115-68402-9', 291, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-120-23863-2', 291, 8);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-620-90655-9', 291, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('6-620-90655-9', 70, 10, DATE '2015-01-11' + INTERVAL '4 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (284, '2015-03-03', 10, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-138-40030-6', 292, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-138-40030-6', 284, 4, DATE '2015-03-03' + INTERVAL '6 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-483-67025-X', 292, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-550-22668-1', 292, 3);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (84, '2017-06-18', 11, 'PAID');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-045-48013-1', 293, 6);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-742-31030-9', 293, 11);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-742-31030-9', 84, 6, DATE '2017-06-18' + INTERVAL '2 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-132-85878-3', 293, 3);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-601-33496-0', 293, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (19, '2017-03-22', 5, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-921-75796-6', 294, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-699-22948-8', 294, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-699-22948-8', 19, 10, DATE '2017-03-22' + INTERVAL '8 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-388-01643-0', 294, 9);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (216, '2015-03-18', 9, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-371-51175-1', 295, 2);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (28, '2017-01-25', 9, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-930-70644-3', 296, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-930-70644-3', 28, 7, DATE '2017-01-25' + INTERVAL '10 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-779-23845-5', 296, 5);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (32, '2017-01-20', 8, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-777-70694-0', 297, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-777-70694-0', 32, 5, DATE '2017-01-20' + INTERVAL '33 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-994-30012-9', 297, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-970-23830-0', 297, 5);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-970-23830-0', 32, 1, DATE '2017-01-20' + INTERVAL '5 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-606-91782-0', 297, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('2-606-91782-0', 32, 8, DATE '2017-01-20' + INTERVAL '9 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-690-97331-1', 297, 3);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-839-00655-8', 297, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-839-00655-8', 32, 6, DATE '2017-01-20' + INTERVAL '3 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (197, '2017-04-05', 10, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-606-35138-3', 298, 2);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (101, '2016-01-27', 3, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-422-27366-4', 299, 4);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-422-27366-4', 101, 9, DATE '2016-01-27' + INTERVAL '21 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (142, '2015-04-22', 12, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-026-52167-0', 300, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('2-026-52167-0', 142, 1, DATE '2015-04-22' + INTERVAL '20 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-531-95869-8', 300, 2);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (127, '2016-02-01', 10, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-400-29507-2', 301, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-400-29507-2', 127, 5, DATE '2016-02-01' + INTERVAL '8 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-890-70446-6', 301, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-890-70446-6', 127, 4, DATE '2016-02-01' + INTERVAL '7 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-578-61313-7', 301, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-288-90566-8', 301, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-288-90566-8', 127, 6, DATE '2016-02-01' + INTERVAL '2 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (119, '2015-02-22', 3, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-720-36846-X', 302, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('6-720-36846-X', 119, 10, DATE '2015-02-22' + INTERVAL '3 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (250, '2016-05-21', 3, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-998-27263-9', 303, 3);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-216-74894-7', 303, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (43, '2017-01-12', 5, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-324-37656-1', 304, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-833-77540-6', 304, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-833-77540-6', 43, 10, DATE '2017-01-12' + INTERVAL '15 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-232-84867-1', 304, 7);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('2-232-84867-1', 43, 9, DATE '2017-01-12' + INTERVAL '19 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (275, '2015-06-23', 10, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-897-24206-0', 305, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-998-32246-9', 305, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-998-32246-9', 275, 3, DATE '2015-06-23' + INTERVAL '5 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (90, '2016-05-10', 11, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-591-41529-3', 306, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('2-591-41529-3', 90, 7, DATE '2016-05-10' + INTERVAL '2 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-233-42512-1', 306, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('4-233-42512-1', 90, 7, DATE '2016-05-10' + INTERVAL '9 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (36, '2015-01-15', 7, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-454-74356-9', 307, 9);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-153-31556-1', 307, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-011-13440-X', 307, 6);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (109, '2017-06-09', 5, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-728-16743-6', 308, 7);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-571-59106-4', 308, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (199, '2017-06-03', 9, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-848-39477-6', 309, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-711-75196-5', 309, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (121, '2016-06-19', 6, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-229-27036-8', 310, 26);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-366-44442-8', 310, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-366-44442-8', 121, 7, DATE '2016-06-19' + INTERVAL '2 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (226, '2016-01-26', 9, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-674-30702-4', 311, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-501-49522-6', 311, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-501-49522-6', 226, 9, DATE '2016-01-26' + INTERVAL '4 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-256-22674-2', 311, 3);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (245, '2016-03-09', 6, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-085-09079-4', 312, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-085-09079-4', 245, 2, DATE '2016-03-09' + INTERVAL '2 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (62, '2017-05-17', 12, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-062-85532-6', 313, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-062-85532-6', 62, 8, DATE '2017-05-17' + INTERVAL '2 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-254-62789-0', 313, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-332-25156-2', 313, 8);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (43, '2016-04-18', 10, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-942-26055-1', 314, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-068-60133-2', 314, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-068-60133-2', 43, 7, DATE '2016-04-18' + INTERVAL '2 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-167-67935-6', 314, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-167-67935-6', 43, 10, DATE '2016-04-18' + INTERVAL '2 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (281, '2015-01-04', 2, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-791-42379-0', 315, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (131, '2016-06-26', 2, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-225-01161-2', 316, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-225-01161-2', 131, 2, DATE '2016-06-26' + INTERVAL '14 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-188-73876-X', 316, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-968-57821-4', 316, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-968-57821-4', 131, 3, DATE '2016-06-26' + INTERVAL '11 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-608-27075-8', 316, 4);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-608-27075-8', 131, 5, DATE '2016-06-26' + INTERVAL '5 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (152, '2015-04-28', 3, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-592-40798-6', 317, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-820-50354-3', 317, 4);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('2-820-50354-3', 152, 7, DATE '2015-04-28' + INTERVAL '3 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (140, '2017-05-15', 5, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-921-00372-X', 318, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-921-00372-X', 140, 8, DATE '2017-05-15' + INTERVAL '10 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (190, '2016-02-01', 1, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-062-85532-6', 319, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-062-85532-6', 190, 2, DATE '2016-02-01' + INTERVAL '2 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (14, '2016-03-16', 9, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-570-37225-5', 320, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-458-11960-X', 320, 3);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-815-72792-0', 320, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('6-815-72792-0', 14, 5, DATE '2016-03-16' + INTERVAL '5 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (13, '2016-01-20', 8, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-644-07796-5', 321, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-644-07796-5', 13, 6, DATE '2016-01-20' + INTERVAL '21 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (74, '2015-02-10', 5, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-810-91252-0', 322, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-810-91252-0', 74, 3, DATE '2015-02-10' + INTERVAL '2 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (49, '2015-05-28', 7, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-189-27064-3', 323, 4);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-189-27064-3', 49, 5, DATE '2015-05-28' + INTERVAL '9 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-971-58575-3', 323, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('4-971-58575-3', 49, 10, DATE '2015-05-28' + INTERVAL '3 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (278, '2017-03-11', 8, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-854-33776-9', 324, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-854-33776-9', 278, 3, DATE '2017-03-11' + INTERVAL '4 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-627-59328-4', 324, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-604-03055-0', 324, 6);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (270, '2015-02-24', 3, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-507-25547-6', 325, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-507-25547-6', 270, 5, DATE '2015-02-24' + INTERVAL '4 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-679-99118-0', 325, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-679-99118-0', 270, 8, DATE '2015-02-24' + INTERVAL '19 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (287, '2015-02-09', 10, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-703-64850-8', 326, 4);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-703-64850-8', 287, 9, DATE '2015-02-09' + INTERVAL '4 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-074-44332-4', 326, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-074-44332-4', 287, 10, DATE '2015-02-09' + INTERVAL '7 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (283, '2015-03-19', 5, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-605-93194-7', 327, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('6-605-93194-7', 283, 9, DATE '2015-03-19' + INTERVAL '2 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-191-96786-0', 327, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-191-96786-0', 283, 8, DATE '2015-03-19' + INTERVAL '6 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-765-10753-0', 327, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (214, '2016-01-30', 5, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-874-33879-6', 328, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('2-874-33879-6', 214, 2, DATE '2016-01-30' + INTERVAL '2 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (93, '2017-04-25', 8, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-125-77632-X', 329, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-125-77632-X', 93, 2, DATE '2017-04-25' + INTERVAL '9 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (1, '2017-04-20', 5, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-720-25466-X', 330, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-720-25466-X', 1, 6, DATE '2017-04-20' + INTERVAL '11 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-699-98300-8', 330, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('6-699-98300-8', 1, 1, DATE '2017-04-20' + INTERVAL '4 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (41, '2015-01-16', 5, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-069-79234-1', 331, 2);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (296, '2016-04-26', 3, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-459-41381-6', 332, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-459-41381-6', 296, 7, DATE '2016-04-26' + INTERVAL '2 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (291, '2015-05-17', 11, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-267-11923-8', 333, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (13, '2017-05-04', 8, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-646-62462-4', 334, 5);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-646-62462-4', 13, 1, DATE '2017-05-04' + INTERVAL '10 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-375-35278-3', 334, 4);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (255, '2015-01-04', 5, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-716-94533-4', 335, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('6-716-94533-4', 255, 8, DATE '2015-01-04' + INTERVAL '3 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-364-46990-7', 335, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (277, '2017-02-21', 3, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-443-72446-1', 336, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (81, '2017-06-12', 9, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-807-69240-2', 337, 16);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('4-807-69240-2', 81, 8, DATE '2017-06-12' + INTERVAL '4 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (73, '2017-02-17', 9, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-703-64850-8', 338, 11);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-703-64850-8', 73, 10, DATE '2017-02-17' + INTERVAL '2 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-998-67130-6', 338, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('2-998-67130-6', 73, 6, DATE '2017-02-17' + INTERVAL '8 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (270, '2017-01-05', 2, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-148-34854-0', 339, 4);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-125-60461-7', 339, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-125-60461-7', 270, 4, DATE '2017-01-05' + INTERVAL '3 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (137, '2016-02-08', 10, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-261-97790-3', 340, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-261-97790-3', 137, 8, DATE '2016-02-08' + INTERVAL '7 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (141, '2015-05-24', 6, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-573-20939-3', 341, 12);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-157-21595-2', 341, 3);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-138-40030-6', 341, 3);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-150-64512-4', 341, 7);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (269, '2016-01-03', 11, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-057-60325-1', 342, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-057-60325-1', 269, 9, DATE '2016-01-03' + INTERVAL '15 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-157-89959-2', 342, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-157-89959-2', 269, 8, DATE '2016-01-03' + INTERVAL '9 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (67, '2015-06-07', 4, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-316-73710-3', 343, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-316-73710-3', 67, 7, DATE '2015-06-07' + INTERVAL '4 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-379-07214-0', 343, 8);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('2-379-07214-0', 67, 3, DATE '2015-06-07' + INTERVAL '4 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-533-15707-4', 343, 4);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('2-533-15707-4', 67, 7, DATE '2015-06-07' + INTERVAL '2 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (286, '2017-04-29', 5, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-367-48086-7', 344, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-367-48086-7', 286, 5, DATE '2017-04-29' + INTERVAL '12 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (124, '2017-03-25', 6, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-970-28192-7', 345, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-970-28192-7', 124, 7, DATE '2017-03-25' + INTERVAL '2 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-779-37579-0', 345, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-779-37579-0', 124, 6, DATE '2017-03-25' + INTERVAL '11 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-460-28826-2', 345, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-460-28826-2', 124, 8, DATE '2017-03-25' + INTERVAL '8 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (72, '2017-05-17', 3, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-502-96839-4', 346, 3);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (112, '2016-06-25', 4, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-531-53342-6', 347, 4);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (237, '2015-02-12', 6, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-999-66059-8', 348, 7);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-746-54710-3', 348, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-440-69277-X', 348, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-322-51171-7', 348, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-322-51171-7', 237, 8, DATE '2015-02-12' + INTERVAL '3 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-594-12164-X', 348, 4);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-594-12164-X', 237, 4, DATE '2015-02-12' + INTERVAL '8 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (114, '2016-01-08', 2, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-945-40660-4', 349, 7);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-945-40660-4', 114, 2, DATE '2016-01-08' + INTERVAL '3 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-398-64854-0', 349, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('2-398-64854-0', 114, 8, DATE '2016-01-08' + INTERVAL '7 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (60, '2015-05-28', 11, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-498-68538-9', 350, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-632-70875-6', 350, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (150, '2016-05-11', 2, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-733-04581-7', 351, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-800-68167-7', 351, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('4-800-68167-7', 150, 6, DATE '2016-05-11' + INTERVAL '9 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (233, '2016-02-27', 3, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-467-38853-0', 352, 4);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-266-88643-2', 352, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-266-88643-2', 233, 9, DATE '2016-02-27' + INTERVAL '4 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-546-47386-1', 352, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (135, '2015-01-27', 10, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-266-88643-2', 353, 2);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (225, '2015-02-27', 11, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-534-99459-3', 354, 3);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (69, '2016-05-27', 8, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-978-92030-9', 355, 9);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-978-92030-9', 69, 7, DATE '2016-05-27' + INTERVAL '4 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (237, '2015-05-10', 13, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-862-99036-5', 356, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('6-862-99036-5', 237, 7, DATE '2015-05-10' + INTERVAL '9 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-120-99696-7', 356, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (206, '2017-05-28', 5, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-922-85559-X', 357, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-922-85559-X', 206, 10, DATE '2017-05-28' + INTERVAL '19 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-862-99036-5', 357, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-798-80428-7', 357, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (90, '2016-04-16', 9, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-979-79817-6', 358, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-979-79817-6', 90, 6, DATE '2016-04-16' + INTERVAL '23 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-815-72792-0', 358, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (218, '2016-01-18', 12, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-153-31556-1', 359, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-695-22719-8', 359, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-450-39105-9', 359, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-450-39105-9', 218, 6, DATE '2016-01-18' + INTERVAL '7 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-979-79817-6', 359, 2);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (116, '2015-01-07', 6, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-200-94440-4', 360, 5);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-200-94440-4', 116, 10, DATE '2015-01-07' + INTERVAL '6 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (195, '2015-06-19', 5, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-249-99200-8', 361, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-249-99200-8', 195, 4, DATE '2015-06-19' + INTERVAL '7 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-394-82275-2', 361, 7);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (188, '2015-05-30', 3, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-663-80268-1', 362, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-663-80268-1', 188, 10, DATE '2015-05-30' + INTERVAL '12 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (92, '2016-06-12', 9, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-018-89649-1', 363, 4);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-018-89649-1', 92, 8, DATE '2016-06-12' + INTERVAL '5 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-354-13346-8', 363, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-371-86494-5', 363, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('4-371-86494-5', 92, 7, DATE '2016-06-12' + INTERVAL '4 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (128, '2015-06-18', 2, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-403-00523-8', 364, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-107-25149-0', 364, 2);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (223, '2017-01-23', 5, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-657-94934-5', 365, 5);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-657-94934-5', 223, 1, DATE '2017-01-23' + INTERVAL '3 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (201, '2016-02-07', 6, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-057-03506-8', 366, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-971-58575-3', 366, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('4-971-58575-3', 201, 5, DATE '2016-02-07' + INTERVAL '4 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-916-71623-6', 366, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-916-71623-6', 201, 8, DATE '2016-02-07' + INTERVAL '2 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-081-53599-8', 366, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('2-081-53599-8', 201, 3, DATE '2016-02-07' + INTERVAL '22 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-410-82846-8', 366, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-410-82846-8', 201, 5, DATE '2016-02-07' + INTERVAL '11 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-215-77489-0', 366, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-215-77489-0', 201, 8, DATE '2016-02-07' + INTERVAL '7 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (293, '2015-01-18', 8, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-011-74585-7', 367, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('6-011-74585-7', 293, 10, DATE '2015-01-18' + INTERVAL '4 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (124, '2015-04-07', 3, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-551-31594-1', 368, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('6-551-31594-1', 124, 6, DATE '2015-04-07' + INTERVAL '6 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (206, '2017-03-09', 5, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-724-95628-7', 369, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-724-95628-7', 206, 7, DATE '2017-03-09' + INTERVAL '8 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-344-62214-5', 369, 3);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (185, '2016-05-13', 7, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-413-56101-9', 370, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (61, '2015-04-26', 8, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-566-83046-5', 371, 2);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (62, '2015-01-04', 6, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-748-92691-9', 372, 3);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-528-83977-3', 372, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-528-83977-3', 62, 5, DATE '2015-01-04' + INTERVAL '16 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (166, '2017-03-24', 7, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-964-97319-X', 373, 3);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-487-25944-9', 373, 2);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (67, '2017-02-05', 9, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-684-59859-9', 374, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-684-59859-9', 67, 3, DATE '2017-02-05' + INTERVAL '14 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-956-17492-2', 374, 6);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (90, '2015-04-25', 7, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-706-10758-4', 375, 4);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-612-09924-6', 375, 3);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (256, '2015-03-06', 5, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-068-87971-3', 376, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-013-30170-5', 376, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-013-30170-5', 256, 8, DATE '2015-03-06' + INTERVAL '3 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-800-68167-7', 376, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('4-800-68167-7', 256, 5, DATE '2015-03-06' + INTERVAL '12 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (293, '2015-03-08', 4, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-866-68508-7', 377, 4);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('6-866-68508-7', 293, 9, DATE '2015-03-08' + INTERVAL '11 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-254-62789-0', 377, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('4-254-62789-0', 293, 7, DATE '2015-03-08' + INTERVAL '5 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (10, '2016-06-21', 8, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-901-83374-0', 378, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-321-10324-1', 378, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-446-66892-4', 378, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-446-66892-4', 10, 7, DATE '2016-06-21' + INTERVAL '8 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (108, '2015-04-18', 4, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-627-59328-4', 379, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-627-59328-4', 108, 7, DATE '2015-04-18' + INTERVAL '9 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (74, '2016-03-18', 4, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-423-53654-4', 380, 4);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-067-67655-X', 380, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-119-00897-6', 380, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-119-00897-6', 74, 9, DATE '2016-03-18' + INTERVAL '5 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (249, '2015-01-17', 5, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-226-81205-9', 381, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('2-226-81205-9', 249, 5, DATE '2015-01-17' + INTERVAL '12 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-910-39523-0', 381, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-910-39523-0', 249, 7, DATE '2015-01-17' + INTERVAL '9 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-267-11923-8', 381, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('6-267-11923-8', 249, 1, DATE '2015-01-17' + INTERVAL '12 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (169, '2016-02-10', 5, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-562-53665-2', 382, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-562-53665-2', 169, 5, DATE '2016-02-10' + INTERVAL '2 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-929-80914-7', 382, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-929-80914-7', 169, 4, DATE '2016-02-10' + INTERVAL '4 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (138, '2015-01-21', 2, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-267-80527-4', 383, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-267-80527-4', 138, 10, DATE '2015-01-21' + INTERVAL '3 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (25, '2016-03-24', 8, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-076-28524-6', 384, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-076-28524-6', 25, 6, DATE '2016-03-24' + INTERVAL '6 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-614-19240-7', 384, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-614-19240-7', 25, 8, DATE '2016-03-24' + INTERVAL '2 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (37, '2017-04-11', 1, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-616-00327-5', 385, 16);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-305-95885-4', 385, 4);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-308-51276-1', 385, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-932-25424-2', 385, 7);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-775-85134-2', 385, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-775-85134-2', 37, 6, DATE '2017-04-11' + INTERVAL '2 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-310-87439-1', 385, 3);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-297-32053-0', 385, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-297-32053-0', 37, 5, DATE '2017-04-11' + INTERVAL '13 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (246, '2015-06-25', 5, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-218-23544-9', 386, 2);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (21, '2016-02-23', 6, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-082-55625-0', 387, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-082-55625-0', 21, 5, DATE '2016-02-23' + INTERVAL '4 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-771-86453-7', 387, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('6-771-86453-7', 21, 6, DATE '2016-02-23' + INTERVAL '3 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (248, '2017-03-28', 4, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-051-73757-1', 388, 13);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (100, '2015-05-15', 3, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-307-61155-1', 389, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-398-64854-0', 389, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-246-89134-6', 389, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-246-89134-6', 100, 7, DATE '2015-05-15' + INTERVAL '3 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-298-15378-7', 389, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('2-298-15378-7', 100, 8, DATE '2015-05-15' + INTERVAL '22 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (165, '2015-03-03', 10, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-388-65999-5', 390, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-388-65999-5', 165, 5, DATE '2015-03-03' + INTERVAL '18 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (283, '2016-03-24', 10, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-663-31517-0', 391, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-663-31517-0', 283, 8, DATE '2016-03-24' + INTERVAL '13 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-050-30775-0', 391, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-050-30775-0', 283, 1, DATE '2016-03-24' + INTERVAL '20 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-897-59762-6', 391, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-897-59762-6', 283, 6, DATE '2016-03-24' + INTERVAL '4 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-921-00372-X', 391, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-921-00372-X', 283, 8, DATE '2016-03-24' + INTERVAL '3 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (116, '2016-01-26', 12, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-137-61940-2', 392, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-137-61940-2', 116, 4, DATE '2016-01-26' + INTERVAL '12 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-656-76928-2', 392, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('4-656-76928-2', 116, 8, DATE '2016-01-26' + INTERVAL '10 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-253-43667-2', 392, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-253-43667-2', 116, 2, DATE '2016-01-26' + INTERVAL '3 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (264, '2016-05-02', 3, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-937-04364-8', 393, 4);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-937-04364-8', 264, 5, DATE '2016-05-02' + INTERVAL '3 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-962-62155-3', 393, 5);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-962-62155-3', 264, 5, DATE '2016-05-02' + INTERVAL '9 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-848-33451-0', 393, 9);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (221, '2015-05-27', 2, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-546-47386-1', 394, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (280, '2017-03-07', 6, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-499-95856-X', 395, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-499-95856-X', 280, 6, DATE '2017-03-07' + INTERVAL '6 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (24, '2016-04-05', 5, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-029-50214-1', 396, 5);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (196, '2017-06-03', 9, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-303-48106-X', 397, 3);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-454-74356-9', 397, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-454-74356-9', 196, 8, DATE '2017-06-03' + INTERVAL '12 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-608-27075-8', 397, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-608-27075-8', 196, 1, DATE '2017-06-03' + INTERVAL '2 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-940-81501-5', 397, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (196, '2015-02-04', 2, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-069-71990-8', 398, 4);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-004-67871-8', 398, 11);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-004-67871-8', 196, 7, DATE '2015-02-04' + INTERVAL '12 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-457-20898-9', 398, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-457-20898-9', 196, 4, DATE '2015-02-04' + INTERVAL '20 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (194, '2015-02-15', 3, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-066-46271-2', 399, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-066-46271-2', 194, 9, DATE '2015-02-15' + INTERVAL '14 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (151, '2017-05-13', 9, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-840-81366-4', 400, 5);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-840-81366-4', 151, 6, DATE '2017-05-13' + INTERVAL '14 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-702-29865-5', 400, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-522-76587-0', 400, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-522-76587-0', 151, 5, DATE '2017-05-13' + INTERVAL '2 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (16, '2015-04-02', 10, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-306-81453-9', 401, 10);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (253, '2017-05-02', 8, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-888-50573-4', 402, 5);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-134-87877-6', 402, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-125-60461-7', 402, 6);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-125-60461-7', 253, 7, DATE '2017-05-02' + INTERVAL '4 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (17, '2017-01-27', 8, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-028-63198-0', 403, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-015-25568-2', 403, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('4-015-25568-2', 17, 4, DATE '2017-01-27' + INTERVAL '8 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-424-06918-2', 403, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('2-424-06918-2', 17, 10, DATE '2017-01-27' + INTERVAL '14 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (284, '2016-04-19', 5, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-995-99506-1', 404, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-431-49855-8', 404, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-431-49855-8', 284, 2, DATE '2016-04-19' + INTERVAL '17 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-576-48014-2', 404, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-576-48014-2', 284, 5, DATE '2016-04-19' + INTERVAL '7 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (273, '2016-06-18', 7, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-835-57497-2', 405, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-005-16854-6', 405, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-005-16854-6', 273, 3, DATE '2016-06-18' + INTERVAL '6 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-066-46271-2', 405, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (104, '2017-06-08', 4, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-023-11845-0', 406, 11);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-023-11845-0', 104, 4, DATE '2017-06-08' + INTERVAL '7 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-984-73998-4', 406, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-984-73998-4', 104, 3, DATE '2017-06-08' + INTERVAL '10 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-390-72307-3', 406, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('4-390-72307-3', 104, 6, DATE '2017-06-08' + INTERVAL '2 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (132, '2017-05-02', 10, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-495-78422-7', 407, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-495-78422-7', 132, 8, DATE '2017-05-02' + INTERVAL '2 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-835-57497-2', 407, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('2-835-57497-2', 132, 4, DATE '2017-05-02' + INTERVAL '12 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (158, '2015-03-23', 2, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-745-97519-5', 408, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-502-31998-8', 408, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-491-71939-9', 408, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-491-71939-9', 158, 5, DATE '2015-03-23' + INTERVAL '3 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-486-46893-5', 408, 15);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('2-486-46893-5', 158, 10, DATE '2015-03-23' + INTERVAL '5 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-576-71118-5', 408, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-667-41915-9', 408, 4);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-851-50044-0', 408, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('4-851-50044-0', 158, 7, DATE '2015-03-23' + INTERVAL '9 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (219, '2016-03-04', 6, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-667-41915-9', 409, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (260, '2017-01-13', 4, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-319-89571-2', 410, 3);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-144-88930-2', 410, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (129, '2015-05-07', 3, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-673-65406-9', 411, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-673-65406-9', 129, 2, DATE '2015-05-07' + INTERVAL '2 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-544-84155-9', 411, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('2-544-84155-9', 129, 3, DATE '2015-05-07' + INTERVAL '3 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-814-42666-3', 411, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-814-42666-3', 129, 10, DATE '2015-05-07' + INTERVAL '6 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (172, '2017-03-21', 3, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-180-23242-1', 412, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('4-180-23242-1', 172, 4, DATE '2017-03-21' + INTERVAL '5 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-340-02676-4', 412, 6);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (281, '2016-02-25', 7, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-676-72288-6', 413, 5);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-029-50214-1', 413, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-029-50214-1', 281, 10, DATE '2016-02-25' + INTERVAL '3 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-068-87971-3', 413, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-253-20746-8', 413, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-253-20746-8', 281, 7, DATE '2016-02-25' + INTERVAL '3 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-498-68538-9', 413, 8);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-498-68538-9', 281, 10, DATE '2016-02-25' + INTERVAL '13 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-779-98446-3', 413, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-779-98446-3', 281, 4, DATE '2016-02-25' + INTERVAL '15 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (125, '2015-05-28', 3, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-771-52168-3', 414, 5);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-168-81897-3', 414, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-408-82648-7', 414, 3);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (94, '2016-04-05', 4, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-682-51445-X', 415, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('6-682-51445-X', 94, 2, DATE '2016-04-05' + INTERVAL '7 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-761-57015-9', 415, 3);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (34, '2015-01-31', 4, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-970-28192-7', 416, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-970-28192-7', 34, 5, DATE '2015-01-31' + INTERVAL '6 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-982-73176-6', 416, 4);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('6-982-73176-6', 34, 6, DATE '2015-01-31' + INTERVAL '15 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (223, '2016-02-13', 5, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-210-88974-2', 417, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-210-88974-2', 223, 4, DATE '2016-02-13' + INTERVAL '3 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (229, '2017-02-02', 6, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-902-87713-X', 418, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-902-87713-X', 229, 2, DATE '2017-02-02' + INTERVAL '5 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-605-65373-X', 418, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-605-65373-X', 229, 5, DATE '2017-02-02' + INTERVAL '11 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-079-85580-0', 418, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-706-38680-6', 418, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-706-38680-6', 229, 9, DATE '2017-02-02' + INTERVAL '4 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (207, '2017-01-31', 9, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-477-86473-7', 419, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-424-52141-3', 419, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-424-52141-3', 207, 9, DATE '2017-01-31' + INTERVAL '6 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-424-52141-3', 419, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-424-52141-3', 207, 9, DATE '2017-01-31' + INTERVAL '2 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-626-04383-7', 419, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-626-04383-7', 207, 8, DATE '2017-01-31' + INTERVAL '9 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (196, '2015-03-05', 11, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-134-02811-8', 420, 4);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-493-77164-1', 420, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('6-493-77164-1', 196, 7, DATE '2015-03-05' + INTERVAL '14 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-803-93927-4', 420, 2);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (113, '2015-05-06', 5, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-460-28826-2', 421, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-460-28826-2', 113, 9, DATE '2015-05-06' + INTERVAL '5 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (51, '2017-04-09', 2, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-199-50203-7', 422, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-199-50203-7', 51, 6, DATE '2017-04-09' + INTERVAL '20 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-068-60133-2', 422, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-068-60133-2', 51, 6, DATE '2017-04-09' + INTERVAL '5 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (45, '2015-02-04', 10, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-848-39477-6', 423, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-848-39477-6', 45, 9, DATE '2015-02-04' + INTERVAL '4 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-183-59820-8', 423, 3);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (58, '2016-06-20', 10, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-669-11565-1', 424, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-669-11565-1', 58, 3, DATE '2016-06-20' + INTERVAL '8 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (123, '2015-02-10', 11, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-188-41144-3', 425, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-188-41144-3', 123, 8, DATE '2015-02-10' + INTERVAL '8 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (41, '2017-04-21', 3, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-024-58389-0', 426, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-024-58389-0', 41, 10, DATE '2017-04-21' + INTERVAL '8 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-303-48106-X', 426, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('6-303-48106-X', 41, 5, DATE '2017-04-21' + INTERVAL '9 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (141, '2017-03-24', 9, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-897-62853-7', 427, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (29, '2017-06-02', 6, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-200-94440-4', 428, 4);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-200-94440-4', 29, 5, DATE '2017-06-02' + INTERVAL '7 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-380-25976-2', 428, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-937-13986-3', 428, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-937-13986-3', 29, 4, DATE '2017-06-02' + INTERVAL '3 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-376-58697-X', 428, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('6-376-58697-X', 29, 6, DATE '2017-06-02' + INTERVAL '2 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (60, '2016-02-05', 3, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-493-77164-1', 429, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('6-493-77164-1', 60, 1, DATE '2016-02-05' + INTERVAL '12 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-188-41144-3', 429, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-188-41144-3', 60, 4, DATE '2016-02-05' + INTERVAL '17 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (279, '2017-04-03', 6, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-050-19455-7', 430, 16);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-050-19455-7', 279, 6, DATE '2017-04-03' + INTERVAL '8 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-086-91306-0', 430, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('2-086-91306-0', 279, 8, DATE '2017-04-03' + INTERVAL '4 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (26, '2015-04-22', 7, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-699-52369-2', 431, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('4-699-52369-2', 26, 9, DATE '2015-04-22' + INTERVAL '11 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-026-07206-6', 431, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-705-31246-7', 431, 4);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-162-02070-5', 431, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-612-06440-4', 431, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('6-612-06440-4', 26, 9, DATE '2015-04-22' + INTERVAL '4 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (214, '2015-01-28', 12, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-522-06724-5', 432, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-522-06724-5', 214, 8, DATE '2015-01-28' + INTERVAL '11 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-986-07549-4', 432, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-986-07549-4', 214, 4, DATE '2015-01-28' + INTERVAL '11 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-355-98969-4', 432, 6);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (90, '2016-06-20', 9, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-007-70666-0', 433, 2);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (268, '2017-01-19', 7, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-329-98203-8', 434, 6);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-648-65303-X', 434, 10);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-648-65303-X', 268, 5, DATE '2017-01-19' + INTERVAL '8 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-357-40674-X', 434, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-357-40674-X', 268, 1, DATE '2017-01-19' + INTERVAL '25 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (103, '2015-05-29', 7, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-215-78236-0', 435, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-215-78236-0', 103, 8, DATE '2015-05-29' + INTERVAL '5 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (61, '2016-04-26', 9, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-879-38760-9', 436, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-879-38760-9', 61, 10, DATE '2016-04-26' + INTERVAL '5 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (196, '2015-03-08', 11, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-342-87890-0', 437, 8);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-803-15882-3', 437, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-803-15882-3', 196, 3, DATE '2015-03-08' + INTERVAL '11 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (289, '2016-03-11', 10, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-885-60608-3', 438, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-885-60608-3', 289, 3, DATE '2016-03-11' + INTERVAL '7 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-541-03808-3', 438, 8);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-541-03808-3', 289, 6, DATE '2016-03-11' + INTERVAL '4 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-548-05409-6', 438, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-330-76629-5', 438, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (113, '2017-01-23', 2, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-968-76713-6', 439, 7);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-803-93927-4', 439, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (95, '2017-04-01', 7, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-916-71623-6', 440, 17);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-916-71623-6', 95, 8, DATE '2017-04-01' + INTERVAL '7 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-539-07804-X', 440, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-539-07804-X', 95, 8, DATE '2017-04-01' + INTERVAL '6 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (181, '2015-03-20', 8, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-107-56607-5', 441, 6);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (270, '2016-01-21', 4, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-329-98203-8', 442, 3);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (153, '2016-01-16', 5, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-869-76113-3', 443, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-957-54517-9', 443, 5);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('2-957-54517-9', 153, 7, DATE '2016-01-16' + INTERVAL '8 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (30, '2017-02-06', 3, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-403-00523-8', 444, 5);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (151, '2016-06-10', 5, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-970-23830-0', 445, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-224-65071-3', 445, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('6-224-65071-3', 151, 2, DATE '2016-06-10' + INTERVAL '4 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-344-62214-5', 445, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (189, '2017-03-12', 12, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-785-60740-2', 446, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-881-76970-6', 446, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-881-76970-6', 189, 8, DATE '2017-03-12' + INTERVAL '14 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (28, '2016-05-28', 4, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-589-08041-1', 447, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-506-42510-4', 447, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-964-66670-X', 447, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-964-66670-X', 28, 4, DATE '2016-05-28' + INTERVAL '9 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (181, '2016-02-15', 2, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-817-70804-0', 448, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('2-817-70804-0', 181, 8, DATE '2016-02-15' + INTERVAL '7 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-546-58108-0', 448, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-546-58108-0', 181, 7, DATE '2016-02-15' + INTERVAL '14 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-127-43145-2', 448, 6);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-411-09810-8', 448, 6);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-411-09810-8', 181, 8, DATE '2016-02-15' + INTERVAL '2 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (9, '2017-04-06', 1, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-153-97778-8', 449, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-217-15390-6', 449, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-217-15390-6', 9, 5, DATE '2017-04-06' + INTERVAL '11 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-180-59114-5', 449, 8);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-180-59114-5', 9, 8, DATE '2017-04-06' + INTERVAL '6 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (27, '2015-05-23', 13, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-600-77463-5', 450, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-600-77463-5', 27, 2, DATE '2015-05-23' + INTERVAL '12 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-011-74988-9', 450, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-011-74988-9', 27, 4, DATE '2015-05-23' + INTERVAL '9 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-474-20794-7', 450, 6);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-693-09431-1', 450, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-693-09431-1', 27, 7, DATE '2015-05-23' + INTERVAL '5 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (39, '2016-06-10', 10, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-245-44883-0', 451, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('4-245-44883-0', 39, 4, DATE '2016-06-10' + INTERVAL '8 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (191, '2016-05-17', 8, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-106-25917-X', 452, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-106-25917-X', 191, 10, DATE '2016-05-17' + INTERVAL '2 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-295-04361-2', 452, 6);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (256, '2015-06-12', 11, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-696-51702-7', 453, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-696-51702-7', 256, 10, DATE '2015-06-12' + INTERVAL '14 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-020-76489-6', 453, 4);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-962-62155-3', 453, 11);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (45, '2015-01-23', 10, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-024-58389-0', 454, 5);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-024-58389-0', 45, 8, DATE '2015-01-23' + INTERVAL '20 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (287, '2017-04-25', 2, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-106-25917-X', 455, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-106-25917-X', 287, 1, DATE '2017-04-25' + INTERVAL '2 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-978-72801-X', 455, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-978-72801-X', 287, 9, DATE '2017-04-25' + INTERVAL '6 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (46, '2017-05-08', 8, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-930-70644-3', 456, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-930-70644-3', 46, 10, DATE '2017-05-08' + INTERVAL '6 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-179-52481-2', 456, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (248, '2015-04-26', 8, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-883-12311-4', 457, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-883-12311-4', 248, 5, DATE '2015-04-26' + INTERVAL '22 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (260, '2017-02-23', 5, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-246-89134-6', 458, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-591-03392-8', 458, 4);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (207, '2016-05-23', 7, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-276-50692-0', 459, 4);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-697-20497-7', 459, 9);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-327-27290-6', 459, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('4-327-27290-6', 207, 1, DATE '2016-05-23' + INTERVAL '4 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (198, '2015-06-03', 4, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-946-09571-4', 460, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-946-09571-4', 198, 8, DATE '2015-06-03' + INTERVAL '11 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (11, '2015-05-11', 12, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-670-18658-5', 461, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-670-18658-5', 11, 5, DATE '2015-05-11' + INTERVAL '2 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-798-22869-X', 461, 7);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-798-22869-X', 11, 6, DATE '2015-05-11' + INTERVAL '4 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (273, '2015-05-19', 11, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-413-68987-2', 462, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-413-68987-2', 273, 8, DATE '2015-05-19' + INTERVAL '4 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-902-97315-8', 462, 25);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-902-97315-8', 273, 8, DATE '2015-05-19' + INTERVAL '5 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-724-95628-7', 462, 7);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-724-95628-7', 273, 5, DATE '2015-05-19' + INTERVAL '9 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (78, '2015-04-04', 5, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-159-81568-6', 463, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-159-81568-6', 78, 8, DATE '2015-04-04' + INTERVAL '3 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (111, '2017-03-21', 2, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-074-44332-4', 464, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-074-44332-4', 111, 7, DATE '2017-03-21' + INTERVAL '3 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-861-84267-2', 464, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('6-861-84267-2', 111, 8, DATE '2017-03-21' + INTERVAL '7 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (34, '2017-05-19', 6, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-546-58108-0', 465, 3);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (296, '2015-01-07', 7, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-284-74037-4', 466, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-283-25648-1', 466, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('6-283-25648-1', 296, 6, DATE '2015-01-07' + INTERVAL '2 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (44, '2016-04-08', 6, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-608-45390-8', 467, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-608-45390-8', 44, 5, DATE '2016-04-08' + INTERVAL '14 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-023-11845-0', 467, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-023-11845-0', 44, 3, DATE '2016-04-08' + INTERVAL '7 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-467-38853-0', 467, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('2-467-38853-0', 44, 6, DATE '2016-04-08' + INTERVAL '2 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (59, '2016-05-08', 10, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-353-66833-3', 468, 3);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-674-30702-4', 468, 4);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (42, '2016-06-01', 9, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-125-69252-4', 469, 8);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (66, '2016-02-14', 2, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-247-25959-8', 470, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('4-247-25959-8', 66, 10, DATE '2016-02-14' + INTERVAL '7 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (75, '2015-01-22', 3, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-712-61022-9', 471, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-022-04454-X', 471, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-022-04454-X', 75, 8, DATE '2015-01-22' + INTERVAL '4 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-466-47289-X', 471, 3);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-189-80968-8', 471, 6);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-189-80968-8', 75, 9, DATE '2015-01-22' + INTERVAL '7 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-087-25114-1', 471, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-087-25114-1', 75, 8, DATE '2015-01-22' + INTERVAL '5 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (279, '2017-03-29', 6, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-897-24206-0', 472, 5);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-897-24206-0', 279, 10, DATE '2017-03-29' + INTERVAL '4 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-232-82986-X', 472, 3);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (97, '2015-02-18', 1, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-026-52167-0', 473, 2);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (221, '2016-03-23', 11, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-813-15847-3', 474, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('6-813-15847-3', 221, 10, DATE '2016-03-23' + INTERVAL '2 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-624-67950-8', 474, 4);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-624-67950-8', 221, 1, DATE '2016-03-23' + INTERVAL '7 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-815-07688-0', 474, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-815-07688-0', 221, 8, DATE '2016-03-23' + INTERVAL '4 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-409-00664-6', 474, 3);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-057-38542-8', 474, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-085-09079-4', 474, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-085-09079-4', 221, 6, DATE '2016-03-23' + INTERVAL '16 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-881-81820-9', 474, 2);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (202, '2015-06-13', 11, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-134-02811-8', 475, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-605-65373-X', 475, 3);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (201, '2016-02-13', 10, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-400-37943-1', 476, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-400-37943-1', 201, 10, DATE '2016-02-13' + INTERVAL '12 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-846-63213-3', 476, 8);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-846-63213-3', 201, 10, DATE '2016-02-13' + INTERVAL '25 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-308-51276-1', 476, 2);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (297, '2015-04-27', 5, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-115-09740-4', 477, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-115-09740-4', 297, 7, DATE '2015-04-27' + INTERVAL '4 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-820-44196-1', 477, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (251, '2017-01-22', 11, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-856-90701-4', 478, 2);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (250, '2015-06-23', 10, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-129-46200-2', 479, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-019-22866-6', 479, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-019-22866-6', 250, 10, DATE '2015-06-23' + INTERVAL '2 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-078-08505-9', 479, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('4-078-08505-9', 250, 7, DATE '2015-06-23' + INTERVAL '4 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-364-46990-7', 479, 4);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (252, '2015-06-09', 10, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-976-80813-1', 480, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-082-15786-6', 480, 8);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-704-31196-6', 480, 2);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (13, '2016-02-06', 13, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-510-86769-8', 481, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-581-54179-4', 481, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('4-581-54179-4', 13, 3, DATE '2016-02-06' + INTERVAL '7 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (190, '2017-02-11', 5, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-417-67841-6', 482, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('7-417-67841-6', 190, 8, DATE '2017-02-11' + INTERVAL '12 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-828-96762-5', 482, 2);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (36, '2017-05-20', 5, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-840-81366-4', 483, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-840-81366-4', 36, 6, DATE '2017-05-20' + INTERVAL '14 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (190, '2016-03-28', 3, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-711-75196-5', 484, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (100, '2017-02-16', 10, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-590-75042-9', 485, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-001-54385-8', 485, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-001-54385-8', 100, 4, DATE '2017-02-16' + INTERVAL '4 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-728-16743-6', 485, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-483-67025-X', 485, 4);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-483-67025-X', 100, 8, DATE '2017-02-16' + INTERVAL '5 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-884-17446-6', 485, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-884-17446-6', 100, 5, DATE '2017-02-16' + INTERVAL '3 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (164, '2016-03-10', 3, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-931-37141-X', 486, 4);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('6-931-37141-X', 164, 9, DATE '2016-03-10' + INTERVAL '2 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-942-40453-3', 486, 9);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('4-942-40453-3', 164, 4, DATE '2016-03-10' + INTERVAL '13 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-568-03820-0', 486, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('4-568-03820-0', 164, 10, DATE '2016-03-10' + INTERVAL '2 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-135-28326-6', 486, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('5-976-80813-1', 486, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('5-976-80813-1', 164, 4, DATE '2016-03-10' + INTERVAL '22 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (16, '2015-01-05', 5, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-748-99711-3', 487, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-748-99711-3', 16, 8, DATE '2015-01-05' + INTERVAL '10 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-312-44470-9', 487, 3);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('7-265-11743-3', 487, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (287, '2017-06-02', 2, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-540-28372-3', 488, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('4-540-28372-3', 287, 8, DATE '2017-06-02' + INTERVAL '14 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-024-30160-4', 488, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-024-30160-4', 287, 10, DATE '2017-06-02' + INTERVAL '4 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (260, '2016-04-23', 9, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-424-06918-2', 489, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('2-424-06918-2', 260, 1, DATE '2016-04-23' + INTERVAL '8 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-823-04584-3', 489, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-823-04584-3', 260, 5, DATE '2016-04-23' + INTERVAL '8 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-995-16909-8', 489, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (63, '2015-04-04', 4, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-974-83792-X', 490, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (294, '2017-05-13', 4, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-363-51767-7', 491, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('0-363-51767-7', 294, 10, DATE '2017-05-13' + INTERVAL '4 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (103, '2016-04-23', 10, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('0-097-31291-6', 492, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-174-46579-9', 492, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (69, '2016-06-10', 8, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-236-05762-3', 493, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-236-05762-3', 69, 2, DATE '2016-06-10' + INTERVAL '13 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-650-16567-3', 493, 1);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('9-650-16567-3', 69, 3, DATE '2016-06-10' + INTERVAL '13 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-534-68002-3', 493, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (30, '2017-04-30', 5, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-284-59337-3', 494, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('3-284-59337-3', 30, 9, DATE '2017-04-30' + INTERVAL '4 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-377-92088-3', 494, 2);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (168, '2015-04-23', 6, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('9-695-22719-8', 495, 2);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-014-65190-6', 495, 4);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('2-014-65190-6', 168, 9, DATE '2015-04-23' + INTERVAL '23 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (209, '2017-01-30', 4, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-921-75796-6', 496, 1);
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-778-97929-3', 496, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('8-778-97929-3', 209, 8, DATE '2017-01-30' + INTERVAL '3 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('1-604-03055-0', 496, 3);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('1-604-03055-0', 209, 8, DATE '2017-01-30' + INTERVAL '4 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-922-04569-4', 496, 14);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('4-922-04569-4', 209, 8, DATE '2017-01-30' + INTERVAL '3 days');
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (58, '2015-06-20', 10, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-310-68879-9', 497, 1);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (4, '2016-02-03', 8, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('2-080-02034-X', 498, 5);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('2-080-02034-X', 4, 5, DATE '2016-02-03' + INTERVAL '4 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('3-846-55104-X', 498, 2);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (121, '2016-01-25', 11, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('4-823-14891-6', 499, 2);
INSERT INTO reviews (book_id, customer_id, review, date)
VALUES ('4-823-14891-6', 121, 10, DATE '2016-01-25' + INTERVAL '26 days');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('6-403-96662-6', 499, 3);
INSERT INTO orders (customer_id, date, shipper, state)
VALUES (219, '2017-05-06', 7, 'SENT');
INSERT INTO orders_details (book_id, order_id, amount)
VALUES ('8-850-80182-3', 500, 1);

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