Mikołaj Kondratek, Bartłomiej Jachowicz, Tomasz Homoncik

OPIS TABEL
books - tabela z danymi książek
authors - autorzy, osoba lub grupa
publishers - wydawcy
genres - gatunki
books_genres - tabela mówiąca o gatunkach książek
books_discounts - zniżki książek
customers_discounts - zniżki klientów
discounts - wartości zniżek
customers - klienci 
orders - zamówienia
orders_details - szczegóły zamówień
shippers - dostawcy/kurierzy
reviews - oceny użytkowników

WIDOKI
book_adder - widok służący do dodawania nowych książek
books_rank - ranking książek, zawiera informacje
	o ilości sprzedanych egzemplarzy i średniej ocenie

DODATKOWE
Te same książki od różnych wydawców mają rózne ISBNy (źródło: https://www.isbn-international.org/content/what-isbn).
Sprawdzane są poprawność numerów telefonów, isbn'ów (w obu wersjach), NIPów.
W przypadku dodawania oceny sprawdzane jest, czy użytkownik kupił książkę oraz jeśli tak, wystawiona ocena jest "aktualizowana" (zawsze istnieje najwyżej jedna ocena wystawiona przez danego użytkownika na daną książkę).
W przypadku usuwania użytkownika z bazy, usuwane są również jego zamówienia i oceny (tj. wszystko).
Jeśli nie uda się dodawanie książki to, ani wydawca, ani autor nie zostaną dodani.

Aplikacja
http://php.net/manual/en/pgsql.setup.php
środowisko php
W pliku config należy ustawić połączenie dla bazy.
Możliwość podglądu tabel i widoków.
Dodawanie użytkowników i książek.
