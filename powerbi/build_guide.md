# Power BI build guide

**Workflow Steps 8 and 13** — the model and the report.

```
01_validation.sql    SQL     count defects on raw stg_ tables
02_cleaning.ipynb    pandas  clean → data/clean/ + SQL Server
03_analysis.sql      SQL     Q1–Q15
04_statistics.ipynb  pandas  Simpson's, confounders, bootstrap
07 (this file)       Power BI ← model · DAX · RLS · report
```

> **The data arrives clean.** Cleaning moved to pandas, so Power Query does
> almost nothing here — shaping and type confirmation, not repair. That is the
> realistic pattern: transform upstream, let the BI tool read.

---

# PART A · Connect

## A1 · Pick a source

| | Source | When |
|---|---|---|
| **A** | SQL Server `ContosoRetail` → `dim_*` / `fact_sales` | The notebook's SQL write succeeded. Preferred — one chain, Power BI reads what `03_analysis.sql` reads |
| **B** | `contoso-profitability\data\clean\*.csv` | SQL Server isn't set up, or `sqlalchemy` isn't installed |

**A:** `Get Data → SQL Server` → your instance → `ContosoRetail` → select the
seven tables → **Import**.

**B:** `Get Data → Folder` → `C:\Users\koush\contoso-profitability\data\clean`
→ or seven separate `Text/CSV` imports.

Seven tables either way:

```
fact_sales   157,108 rows
dim_customer   8,001      dim_product   1,401      dim_region       91
dim_channel        4      dim_date      1,461      dim_userregion  270
```

## A2 · Confirm types — don't repair

Everything is already cleaned. Just check Power Query read it correctly:

| Column | Should be |
|---|---|
| `OrderDate`, `dim_date[Date]`, `LaunchDate`, `JoinDate`, `DateOfBirth` | **Date** |
| `Quantity`, `ShippingDays`, `Age`, all `dim_date` numbers | **Whole number** |
| `UnitPrice`, `DiscountPercent`, `SalesAmount`, `CostAmount`, `ProfitAmount`, `ListPrice`, `StandardCost`, `LineMarginPct` | **Decimal** |
| `LossFlag`, `IsShippingKnown`, `FailsPricingRule`, `FailsProfitRule`, `IsWeekend`, `IsHoliday` | **True/False** |

> **If you took route B**, booleans come in as the text `"True"`/`"False"`.
> Convert them — a text column silently fails every `= TRUE` filter and your
> loss measures return blank.

## A3 · Remove what the report doesn't need

In `fact_sales`:

- **`ReturnFlag`** — **remove it.** `OrderStatus` is the system of record and 12
  rows disagree. Leaving both in the model invites someone to use the wrong one
- `RecoveredField` — audit trail, keep only if you want it on a tooltip
- `OrderLineID` — high-cardinality text, large in the model, no measure uses it.
  Dropping it is a real size win and a good Performance Analyzer talking point

## A4 · Sort `DiscountBand`

It's text, so it sorts `0%`, `0-10%`, `10-20%`, `20-30%`, `30-40%` alphabetically
— which happens to be right here, but don't rely on luck. Add an index column
in Power Query (0–4) and set `Sort by column`.

**Gate:** 7 tables · 157,108 fact rows · correct types · `Close & Apply` clean.

---

# PART B · The model

## B1 · Relationships

| From (1) | To (\*) | Cross-filter | Active |
|---|---|---|---|
| `dim_date[Date]` | `fact_sales[OrderDate]` | Single | ✅ |
| `dim_customer[CustomerID]` | `fact_sales[CustomerID]` | Single | ✅ |
| `dim_product[ProductID]` | `fact_sales[ProductID]` | Single | ✅ |
| `dim_region[RegionID]` | `fact_sales[RegionID]` | Single | ✅ |
| `dim_channel[ChannelID]` | `fact_sales[ChannelID]` | Single | ✅ |
| `dim_region[RegionID]` | `dim_userregion[RegionID]` | **Both** | ✅ |
| `dim_region[RegionID]` | `dim_customer[RegionID]` | Single | ❌ **inactive** |

> **Why single everywhere except one?** Bidirectional filters create ambiguous
> paths, slow queries, and results that change with visual order. The
> `dim_region ↔ dim_userregion` relationship **must** be Both or the RLS filter
> stops at `dim_region` and never reaches the fact table.
>
> **Why is `dim_customer[RegionID]` inactive?** Second path to `dim_region`. An
> order shipped to Chennai for a customer living in Pune belongs to Chennai for
> sales reporting. Two active paths is an ambiguity error.

All dimensions should now join cleanly — the `UNKNOWN` members are already
there, so no blank rows on the one side.

## B2 · Date table

`Table view → dim_date → Table tools → Mark as date table` → `Date`.

| Column | Sort by |
|---|---|
| `Month` | `MonthNumber` |
| `Quarter` | `QuarterNumber` |
| `DayName` | `DayOfWeekNumber` |

Skip this and every axis sorts alphabetically — April, August, December.

## B3 · ⚠️ The measure filter that matters most

**`fact_sales` contains all three order statuses.** Cancelled orders carry
**₹6.02 Cr of revenue and ₹1.06 Cr of profit that never happened**, and returns
a further ₹8.50 Cr.

**Every money measure must filter to Completed.** This is the single bug that
forced a full revision of the analysis — revenue was overstated by 8%.

```dax
Revenue = CALCULATE ( SUM ( fact_sales[SalesAmount] ),
                      fact_sales[OrderStatus] = "Completed" )

Cost    = CALCULATE ( SUM ( fact_sales[CostAmount] ),
                      fact_sales[OrderStatus] = "Completed" )

Profit  = CALCULATE ( SUM ( fact_sales[ProfitAmount] ),
                      fact_sales[OrderStatus] = "Completed" )

Total Orders = CALCULATE ( DISTINCTCOUNT ( fact_sales[OrderID] ),
                           fact_sales[OrderStatus] = "Completed" )
```

> **Rate measures are different.** Return rate needs returned orders to exist,
> so it uses the *placed* population — Completed + Returned:
>
> ```dax
> Return Rate =
> VAR Placed = CALCULATE ( DISTINCTCOUNT ( fact_sales[OrderID] ),
>                          fact_sales[OrderStatus] <> "Cancelled" )
> VAR Returned = CALCULATE ( DISTINCTCOUNT ( fact_sales[OrderID] ),
>                            fact_sales[OrderStatus] = "Returned" )
> RETURN DIVIDE ( Returned, Placed )
> ```
>
> Cancellation rate is the only one that uses all three statuses. **Write the
> population into the measure name or description so nobody guesses later.**

Build the rest from `04c_DAX_Measures.md` into a dedicated `_Measures` table.

**Checkpoints — these must match `03_analysis.sql` exactly:**

| Measure | Expected |
|---|---|
| Revenue | **₹176.85 Cr** |
| Profit | **₹24.17 Cr** |
| Margin % | **13.67%** |
| Total Orders | **68,817** |
| AOV | **₹25,698** |

> If Revenue reads **₹191.34 Cr**, the status filter is missing. That's the
> exact figure the bug produced.

## B4 · Row-level security

`Modeling → Manage roles → Create` → `RegionalManager` → table `dim_userregion`:

```dax
[UserPrincipalName] = USERPRINCIPALNAME()
```

Test with `Modeling → View as → Other user`:

| User | Should see |
|---|---|
| `kerala.rm@contoso-retail.in` | Kerala only |
| `south.head@contoso-retail.in` | The South zone |
| `national.head@contoso-retail.in` | Everything |

**📸 Screenshot this.** Almost no fresher portfolio has a working RLS test, and
it's the cheapest credibility in the whole project.

---

# PART C · The report

Four pages. Every title states a **finding**, never a field name.

## Page 1 · "Is our growth profitable?"

**KPI strip** — Revenue ₹176.9 Cr · Margin 13.67% · Revenue at Risk 18.4% ·
Loss Value ₹2.59 Cr · Orders 68,817
*(all cumulative 2022–25, net of cancelled and returned)*

**Combo chart** — Revenue columns + Margin % line by Year
Title: *"Revenue grew 141%. Margin didn't move."*

**🎯 The hero visual** — Discount band on X. **Loss rate as a line** (right
axis), **loss value as columns** (left axis).

| Band | Lines | Loss rate | Loss value |
|---|---:|---:|---:|
| 0% | 517 | 0.2% | ₹0.00 Cr |
| 0–10% | 69,625 | 2.4% | ₹0.30 Cr |
| **10–20%** | **54,933** | **12.7%** | **₹2.08 Cr** |
| 20–30% | 17,221 | 29.3% | ₹0.18 Cr |
| 30–40% | 3,759 | **64.4%** | ₹0.03 Cr |

Title: *"80% of losses come from routine 10–20% discounts, not deep ones"*

> The line rises left to right while the columns collapse. **That crossing is
> the whole project in one image.** Build this visual first — if it doesn't read
> instantly, nothing else on the page will.

## Page 2 · "Where does it leak?"

- Category loss Pareto — columns + cumulative % line *(Technology 82.6%)*
- **Scatter:** Revenue (X) vs Margin % (Y) per product, bubble = units. Loss-making SKUs sit bottom-right
- Table of the 12 worst Technology SKUs *(82% of that category's loss)*
- **Max discount by category** — a small bar chart showing Technology capped at 20%. It's the fact that proves a deep-discount policy couldn't help
- Drill-through target: product detail

## Page 3 · "Channel & customer"

- Channel margin, return rate, shipping days *(Marketplace 9.7% vs Website 15.1%)*
- **The decomposition:** margin by channel *within* category — the visual that proves it isn't mix
- Segment: AOV vs orders-per-customer
- Cohort retention matrix

## Page 4 · "Decision"

`Modeling → New parameter → Numeric range`: `Discount Cap`, 0 to 0.40, step
0.01, default 0.10, *Add slicer to this page*.

Cards: **Margin Recovered** · **Revenue Affected** · **Simulated Margin %**
(DAX in `04c_DAX_Measures.md` §9 — remember the Completed filter there too).

> ⚠️ **Put the assumption on the page:** *"Assumes volume holds. A ceiling, not
> a forecast."* A stakeholder who finds a hidden assumption stops trusting the
> whole report; one who reads it in your subtitle trusts everything else more.

Anchor it: R1 is worth **₹0.67 Cr/year** at the 2025 run-rate.

## Every page

Footer strip:

> *157,108 rows · cleaned in pandas · 8 excluded, 16 recovered · 99.33% reconciles
> · money metrics exclude cancelled and returned · RLS active*

**Cheap, high-signal additions:** field parameters for a metric switcher ·
custom tooltip page · Performance Analyzer screenshot with one documented
optimisation and model size before/after.

---

# PART D · Publish

1. `Home → Publish` → new workspace
2. Dataset → **Settings → Scheduled refresh** → daily
3. Dataset → **Security** → assign a test user to `RegionalManager`
4. Open in the Service and confirm the role still filters

📸 Screenshot the refresh schedule and the role assignment.

> **Route A note:** a SQL Server source needs an **on-premises data gateway**
> for scheduled refresh in the Service. If that's a hurdle, publish from the
> CSV route instead — the model and RLS are identical, and refresh works
> straight away with the files in OneDrive.

---

## Checklist

- [ ] 7 tables loaded · 157,108 fact rows · types confirmed
- [ ] `ReturnFlag` removed · `OrderLineID` dropped
- [ ] `dim_date` marked as date table · sort columns set
- [ ] `dim_customer[RegionID]` relationship **inactive**
- [ ] **Revenue = ₹176.85 Cr** *(not 191.34 — that means the status filter is missing)*
- [ ] Margin % = **13.67%** · Orders = **68,817**
- [ ] Return rate uses the *placed* population, not net
- [ ] RLS tested with *View as* — 📸
- [ ] Page 1 hero visual reads in under 5 seconds
- [ ] Page 2 carries the "Technology never above 20%" chart
- [ ] Page 4 carries the volume-assumption caveat
- [ ] Data-quality footer on every page
- [ ] Published with scheduled refresh — 📸
