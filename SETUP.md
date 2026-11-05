# Environment setup

## Option A: Docker (recommended)

1. Install **Docker Desktop** (https://www.docker.com/products/docker-desktop/) and start it.
2. From the repository root:
   ```bash
   docker compose up -d
   docker ps                      # kashlink-postgres and kashlink-mongo should be "Up"
   ```
3. Run the Portfolio 1 scripts inside the Postgres container:
   ```bash
   docker exec -it kashlink-postgres psql -U postgres -d kashlink -f /portfolio/portfolio-1-database-design/01_schema.sql
   docker exec -it kashlink-postgres psql -U postgres -d kashlink -f /portfolio/portfolio-1-database-design/02_seed.sql
   docker exec -it kashlink-postgres psql -U postgres -d kashlink -f /portfolio/portfolio-1-database-design/03_constraint_tests.sql
   ```
4. Open an interactive SQL prompt:
   ```bash
   docker exec -it kashlink-postgres psql -U postgres -d kashlink
   kashlink=# SET search_path TO kashlink;
   kashlink=# \dt
   ```

## Option B: Native install

- PostgreSQL 16: https://www.postgresql.org/download/ (macOS: `brew install postgresql@16`)
- MongoDB Community 7 + `mongosh`: https://www.mongodb.com/try/download/community

Then run `createdb kashlink` and the `psql -d kashlink -f ...` commands shown in each portfolio README.

## Optional GUI

pgAdmin or DBeaver connect to `localhost:5432` with user `postgres`, password `postgres`. A GUI makes it easier to take clear screenshots of query plans.

## Versions used

| Component | Version |
|---|---|
| PostgreSQL | 16 |
| MongoDB | 7 |
