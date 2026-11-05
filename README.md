# Advanced Database Systems Portfolio: KashLink Mobile Money

**Course:** MIT 8103 Advanced Database Systems, Miva Open University (2026/2027, First Semester)
**Student:** Balogun Yusuf (Student ID: _add here_)
**Case study:** KashLink Mobile Money Ltd, a **simulated** mobile money operator in Nigeria, Ghana and Uganda. Customers hold phone-number-linked wallets, deposit and withdraw cash through agents, send money to each other, and pay bills over USSD, app, agent and API channels.

## Portfolio index

| # | Activity | Folder | Status |
|---|---|---|---|
| 1 | Database Design and Modelling | [portfolio-1-database-design](portfolio-1-database-design/) | Complete |
| 2 | Query Processing and Optimisation | portfolio-2-query-optimisation | Pending |
| 3 | Transactions and Concurrency | portfolio-3-transactions-concurrency | Pending |
| 4 | NoSQL and Advanced Data Models | portfolio-4-nosql | Pending |
| 5 | Distributed and Cloud Database | portfolio-5-distributed-cloud | Pending |

## Technology

- **PostgreSQL 16** for the relational model, query optimisation and transactions (Portfolios 1–3)
- **MongoDB 7** for the document model (Portfolio 4)
- **Docker Compose** for a reproducible local environment ([SETUP.md](SETUP.md))

## Quick start

```bash
docker compose up -d
docker exec -it kashlink-postgres psql -U postgres -d kashlink -f /portfolio/portfolio-1-database-design/01_schema.sql
```
Each portfolio folder has its own README covering what was built, how to run it, the expected output and the evidence.

## Data notice

All organisations, people, phone numbers and documents in this repository are fictional and were created for academic purposes.

## AI use declaration

_To be completed. State the tool used, what it was used for, and how you reviewed, tested and verified its output._
