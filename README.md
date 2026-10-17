# Contoso India — retail data quality and profitability review

Four years of sales (2022-2025, about 157,000 order lines) coming out of three systems
that were never reconciled with each other: a web platform, in-store POS, and a
marketplace feed that was onboarded in a hurry. Nobody owned data quality. The finance
team didn't trust the extract and kept their own numbers in Excel.

The business question was whether revenue growth was actually profitable and where margin
was leaking. Most of the work turned out to be upstream of that, in deciding which rows
we were allowed to count.

Stack: SQL Server, Python (pandas, numpy, matplotlib).

## Running it

```
sql/01_load_staging.sql       load 7 CSVs into staging, everything NVARCHAR
sql/02_validation.sql         count defects on the raw data, change nothing
notebooks/03_cleaning.ipynb   clean, recover, write data/clean/
sql/04_analysis.sql           Q1-Q15
notebooks/05_statistics.ipynb Simpson's, confounders, bootstrap
```

The number is the run order; the folders are just tidiness. `data/clean/` is committed,
so if you only want the analysis you can start at step 4.

`sql/drills.sql` isn't part of the pipeline, it's rebuild-from-blank practice.

## Why revenue had two different values

The finance director's opening complaint:

> I've seen two "total revenue" figures this year that didn't match and nobody could
> tell me why.

Both figures were correct. They counted different sets of rows. Nobody had written down
which set "revenue" meant, so two people could each be right and disagree by crores.

That needed a definition before it needed a query:

| Basis | Includes | Lines | Used for |
|---|---|---:|---|
| Net | Completed only | 146,055 | all money metrics: revenue, profit, margin, loss |
| Placed | Completed + Returned | 152,274 | return rate, demand |
| All | + Cancelled | 157,108 | cancellation rate only |

Cancelled orders carry ₹6.02 Cr of revenue and ₹1.06 Cr of profit that never happened.
Returns carry another ₹8.50 Cr. `sql/04_analysis.sql` defines `sales_net` and
`sales_placed` as views so you can't pick the wrong population by accident.

## Validation runs before cleaning and changes nothing

`sql/02_validation.sql` reads the staging tables (all NVARCHAR, nothing cast or cleaned)
and counts every defect. Two reasons for that order. First, how you handle something
depends on how much of it there is: 8 bad rows get fixed by hand, 4,000 get a rule.
Second, a count taken before cleaning is the only way to show afterwards that the
cleaning did anything.

One SQL Server detail that cost me a while: the distinct-value counts need
`COLLATE Latin1_General_BIN2` and an appended delimiter. On a case-insensitive database
`'Completed'` and `'COMPLETED'` collapse into one value and trailing spaces disappear, so
the obvious query reports 6 distinct order statuses when there are 15.

## What was wrong, and what I did about it

| Issue | Rows | Decision | Why |
|---|---:|---|---|
| `ShippingDays` placeholders, 7 distinct forms | 4,713 | null + `IsShippingKnown` flag | don't invent a delivery time; the flag keeps coverage visible |
| `OrderDate` in 5 formats | 1,571 | parse each explicitly | recoverable, and dropping 1% would bias by date |
| `PaymentMethod` missing | 1,571 | null | the sale is valid, only the tender is unknown |
| casing / whitespace variants | ~1.5% | map to canonical values | `M` and `MALE` need a lookup, not a trim |
| `Quantity = 0` | 8 | recovered | `Sales / (Price * (1-Disc))` gives it exactly |
| `DiscountPercent > 1` | 8 | recovered | `1 - Sales / (Qty * Price)` gives it exactly |
| `Quantity < 0` | 8 | excluded | credit notes, money negated to match, not recoverable |
| duplicate dimension keys | 15 | dedupe identical, survivorship for conflicting | two different problems with opposite fixes |
| orphan foreign keys | 34 | map to Unknown members | never drop silently |
| money-rule breaches | 1,049 | flag, don't correct | no way to tell which side of the equation is wrong |
| negative profit | 17,418 | keep, it isn't an error | it's what the analysis is about |
| cancelled + returned | 11,053 | exclude from money metrics | ₹14.5 Cr that never happened |

Where a value was reconstructed, `RecoveredField` says which field, so it isn't a silent
change.

99.33% of the money reconciles against both the pricing formula and
`Profit = Sales - Cost`.

### Two numbers that look inconsistent and aren't

`sql/02_validation.sql` reports 724 pricing breaches and 17,425 negative-profit rows. The
table above says 700 and 17,418. The validation script measures the staging table and the
table measures the clean one. The gap is the 24 recovered-or-excluded rows: recovering a
quantity fixes the pricing formula it was breaking, and 7 of the 8 excluded credit notes
had negative profit.

Both numbers are right, they answer different questions, and a report that doesn't say
which one it's quoting is useless.

### One thing I'd do differently from the start

My first pass at the `ShippingDays` placeholders listed three junk values I'd noticed and
found 2,213 rows. Asking the data to show me everything that wouldn't cast to a number
found seven forms and 4,713 rows, roughly double. Writing the list from memory was the
mistake.

## What the clean data showed

Revenue grew 141% between 2022 and 2025. Margin stayed around 13.7% the whole time, and
18.4% of revenue is loss-making: ₹2.59 Cr cumulative, ₹0.92 Cr in 2025.

The director expected the problem to be clearance events, where merchandising discounts
30-40% to shift old stock, and expected the recommendation to be a cap on deep discounts.

Loss *rate* does behave that way. It climbs with discount depth and peaks at 64.4% in the
30-40% band. But that band only holds 1.2% of the money lost.

| Discount band | Lines | Loss rate | Loss value | Share of loss |
|---|---:|---:|---:|---:|
| 0% | 517 | 0.2% | ₹0.00 Cr | 0.0% |
| 0-10% | 69,625 | 2.4% | ₹0.30 Cr | 11.6% |
| 10-20% | 54,933 | 12.7% | ₹2.08 Cr | 80.3% |
| 20-30% | 17,221 | 29.3% | ₹0.18 Cr | 7.0% |
| 30-40% | 3,759 | 64.4% | ₹0.03 Cr | 1.2% |

73.2% of every rupee lost comes from ordinary 10-20% discounts on Technology: 10,331
order lines running at 4.8% margin, with 12 SKUs accounting for 82% of it.

The rate column says where failure is likely. The value column says where the money is.
They point at different recommendations, and acting on the rate column alone would have
addressed about a fiftieth of the problem.

No Technology line in this dataset is discounted above 20% at all, so the deep-discount
cap couldn't have touched a single losing Technology line even in principle.

### Recommendations

| | Action | Worth (2025) | Guardrail |
|---|---|---:|---|
| R1 | cap discounts at 10% on Technology SKUs below 15% list margin | ₹0.67 Cr/yr | unit volume, reverse if it drops more than 8% |
| R2 | review the 12 SKUs behind 82% of Technology loss | mostly the same money as R1 | basket attach rate before delisting |
| R3 | renegotiate or reprice Marketplace (9.7% margin vs Website 15.1%) | ₹0.64 Cr/yr | new-customer count |

Only R3 is additive to R1. The defensible combined ceiling is about ₹1.31 Cr/year, which
is more than the ₹0.92 Cr actually lost in 2025 because R3 is margin opportunity on
profitable revenue, not loss recovery. It's a ceiling, not a forecast.

Full reasoning and limits: [docs/findings_and_recommendations.md](docs/findings_and_recommendations.md)

## What I got wrong

The analysis was revised once after review. Fifteen defects came out of it. Three were
worth recording:

1. Cancelled and returned orders were in every revenue total, overstating revenue by
   ₹14.5 Cr (8%). I'd written the exclusion into my assumptions document and never
   implemented it in the cleaning script. The document was fine and the code was fine;
   nothing compared the two.

2. I set out to confirm that margin was declining, and it isn't. It ends slightly higher
   than it started (13.45% to 13.59%). The honest version, that margin is stuck around
   13.7% while the business tripled, is a more interesting problem than the one I went
   looking for.

3. The statistics notebook couldn't run. Every line break in every code cell had been
   stripped at some point. My test for this rejoined the source with `\n` before
   executing it, which meant it was testing my reconstruction instead of the file.

Every finding survived. Every rupee figure changed. [docs/CHANGES.md](docs/CHANGES.md)
has the before and after.

I've left this section in because an analysis that shows its own correction is easier to
trust than one that was never checked.

## Limits

- Correlation, not causation. A discount on a thin markup compresses margin by
  definition. Whether those units would have sold at full price isn't established here.
  Two alternative explanations survive: slow stock gets discounted because it isn't
  selling (reverse causation), and thin-markup categories are both discounted more and
  less profitable (common cause). Separating them needs a controlled price test.
- Simpson's paradox. Margin by discount band looks weak and non-monotonic in aggregate
  but is monotonic inside every category. Deep discounts mostly happen in high-margin
  categories, and the mix hides the effect.
- This is a population, not a sample. Every transaction for four years, so p-values don't
  mean what they usually mean. Bootstrap CI on the loss-line rate is [10.91%, 11.24%],
  narrow because n = 146,055. Tight confidence intervals aren't evidence of importance.
- The loss-line rate is 11.1% in all four years, the same to one decimal. Real businesses
  move around more than that. It's an artifact of the simulated data.
- Out of scope: marketing spend and CAC, basket composition, returns processing cost,
  competitor pricing, stock-outs.

## About the data

This is a simulated retail environment I built for the project: 157,116 raw order lines
(157,108 after the 8 credit notes are excluded), seven tables, 2022-2025, with the
data-quality problems put in on purpose so I could practise the whole workflow. It isn't
client data and I'm not presenting it as such. The findings test the method, not the
Indian retail market.

The generator isn't in this repo. The clean tables are committed, so everything from step
4 onward reproduces, but you can't rebuild `data/clean/` from source here.

## Layout

```
sql/
  01_load_staging.sql    staging tables + BULK INSERT
  02_validation.sql      defect counts on raw data
  04_analysis.sql        Q1-Q15, windows, cohorts, Pareto, the net/placed views
  drills.sql             practice, not part of the pipeline
notebooks/
  03_cleaning.ipynb      cleaning and recovery, writes data/clean/
  05_statistics.ipynb    Simpson's, confounders, bootstrap CIs
data/clean/              7 tables, 157,108 fact rows
docs/
  findings_and_recommendations.md
  CHANGES.md
reference/
  cleaning_in_sql.sql    the same cleaning written in SQL, for comparison
```

SQL does the raw validation and the analysis; counting defects across seven staging
tables and then running window functions and cohorts is what it's for. pandas does the
cleaning and the statistics; string and date normalisation is shorter there, and the
bootstrap work isn't SQL at all. The cleaning exists in both, under `reference/`, mostly
because I wanted to see the difference.
