# Changes to the SQL and notebook files

Every number below was checked by re-running the full cleaning and analysis in Python against the raw CSVs. The old numbers reproduce exactly from the original files, so the differences come only from the changes listed here.

## What changed and why

| File | Change | Why |
|---|---|---|
| 02_validation | Raw distinct counts use `COLLATE Latin1_General_BIN2` and an appended `'|'` | On a case-insensitive database, SQL Server treats `'Completed'` and `'COMPLETED'` as one value and ignores trailing spaces. The original query returns 6, not the recorded 15. |
| 02_validation | New 6.5b: implied quantity and discount for the 24 bad rows | It shows 16 rows are recoverable and 8 are not. |
| 02_validation | New 6.9b: revenue and profit by order status | Cancelled orders carry ₹6.02 Cr revenue and ₹1.06 Cr profit. |
| 03_cleaning | `dbo.CleanText()` nulls all 8 placeholder forms | `NULLIF(x,'')` left `'NA'`, `'-'` and `'NULL'` in CustomerName, City, State and Brand, which also blocked the City/State recovery. |
| 03_cleaning | Brand mapped to one spelling (30 brands) | `'bajaj'`/`'Bajaj'` and `'classmate'`/`'Classmate'` were split. |
| 03_cleaning | 8 zero-quantity and 8 bad-discount rows recovered; 8 negative-quantity rows excluded | The money columns imply exact values; the old reason ("money was not recalculated") was wrong. |
| 03_cleaning | Survivorship sorts ListPrice as a number and adds tie-breakers | Text sort puts `'9.99'` after `'10.00'`, and ties were nondeterministic. |
| 03_cleaning | `RecoveredField` column records which field was recovered per row | This records a decision that was previously made silently. |
| 03_cleaning | `ReturnFlag` retained in the clean data but marked not-authoritative | `OrderStatus` is the system of record and 12 rows disagree with it. The column stays in `fact_sales.csv` as an audit trail of the disagreement rather than being deleted, and any downstream model must read `OrderStatus`. Deleting it would have hidden the conflict; keeping it unlabelled would have let someone count it. |
| 03_cleaning | `DiscountBand` has no `ELSE` | Anything above 40% would have been silently labelled `'30-40%'`. |
| 04_analysis | Views `sales_net` (Completed) and `sales_placed` (Completed + Returned) | Money metrics no longer include cancelled or returned orders. |
| 04_analysis | Q13 cohort cells after Dec 2025 are NULL, not 0 | 78 of 624 cells were reporting future months as 0% retention. |
| 05_statistics | Every code cell had its line breaks stripped | `import pandas as pdimport numpy as np` is a syntax error, so the notebook could not run at all. |
| 05_statistics | Same recovery, survivorship and net/placed split as the SQL | Its headline numbers now match `sql/04_analysis.sql`. |

## Numbers restated in the README and the findings document

| Metric | Old (all statuses) | New (net) |
|---|---|---|
| Clean rows | 157,092 (24 excluded) | 157,108 (8 excluded, 16 recovered) |
| Revenue | ₹191.34 Cr | ₹176.85 Cr |
| Profit | ₹26.43 Cr | ₹24.17 Cr |
| Margin | 13.81% | 13.67% |
| Orders / AOV | 73,995 / ₹25,859 | 68,817 / ₹25,698 |
| Yearly margin | 13.45 / 12.96 / 14.74 / 13.71 | 13.45 / 12.91 / 14.43 / 13.59 |
| Revenue by year | 28.03 / 40.59 / 55.55 / 67.18 Cr | 25.78 / 37.71 / 51.25 / 62.10 Cr |
| Loss value | ₹2.80 Cr | ₹2.59 Cr |
| Technology share of loss / margin | 82.0% / 10.19% | 82.6% / 9.98% |
| 10–20% band share of loss | 80.3% (₹2.25 Cr) | 80.3% (₹2.08 Cr) |
| Technology × 10–20% cell | ₹2.04 Cr, 72.8% | ₹1.90 Cr, 73.2% |
| Same cell, 2025 only | ₹0.72 Cr | ₹0.67 Cr |
| Marketplace vs Website margin | 9.8% vs 15.3% | 9.7% vs 15.1% |
| Marketplace gap, 2025 run-rate | ₹0.72 Cr / year | ₹0.64 Cr / year |
| One margin point, 2025 | ₹0.67 Cr | ₹0.62 Cr |
| Loss-making Technology SKUs | 35 (worst 12 = ~80%) | 34 (worst 12 = 82%) |
| Customer Pareto (50% / 80% / total) | 862 / 2,682 / 7,489 | 847 / 2,635 / 7,416 |
| Weighted vs naive discount | 12.18 / 12.37 | 12.18 / 12.38 |

These are unchanged: the loss-line rate (11.1%), revenue at risk (18.4%), 99.33% reconciliation, and the 30–40% band's 64.4% loss rate.

## A finding worth adding to the write-up

Technology is never discounted above 20% in this data. Its losses can only come from routine 10–20% discounts, so a cap on deep discounts would not touch a single Technology line. This makes the case for R2 sharper than the band table alone.
