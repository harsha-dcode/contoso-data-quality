# DAX measures

> Build these **after** the model exists (`07_PowerBI_Build_Guide.md` Part B).
> Put every one in a dedicated `_Measures` table so they don't clutter the fact.
>
> Each measure carries its trap. The formulas are mostly obvious; the failure
> modes are not.

**Setup:** `Home → Enter Data` → name it `_Measures` → Load. Create one measure
in it, delete the dummy column. Everything else goes there.

---

## ⚠️ 0 · Read this before writing a single measure

`fact_sales` holds **all three order statuses**. Cancelled orders carry
**₹6.02 Cr of revenue and ₹1.06 Cr of profit that never happened**; returns
carry a further ₹8.50 Cr.

**Every money measure must filter to Completed.** Omitting it overstates revenue
by 8% — and that is not hypothetical. It is the bug that forced a full revision
of this analysis, caught only in review.

Three populations, and they are not interchangeable:

| Basis | Filter | Rows | Used for |
|---|---|---:|---|
| **Net** | `OrderStatus = "Completed"` | 146,055 | **All money metrics** |
| **Placed** | `OrderStatus <> "Cancelled"` | 152,274 | Return rate, demand |
| **All** | *(no filter)* | 157,108 | Cancellation rate only |

**The structural fix:** put the filter in the **base** measures only. Everything
derived from them inherits it, so you write it seven times instead of forty —
and you can't forget it halfway down the file.

---

## 1 · Base measures — the filter lives here

```dax
Revenue =
CALCULATE ( SUM ( fact_sales[SalesAmount] ),
            fact_sales[OrderStatus] = "Completed" )

Cost =
CALCULATE ( SUM ( fact_sales[CostAmount] ),
            fact_sales[OrderStatus] = "Completed" )

Profit =
CALCULATE ( SUM ( fact_sales[ProfitAmount] ),
            fact_sales[OrderStatus] = "Completed" )

Units Sold =
CALCULATE ( SUM ( fact_sales[Quantity] ),
            fact_sales[OrderStatus] = "Completed" )

Total Lines =
CALCULATE ( COUNTROWS ( fact_sales ),
            fact_sales[OrderStatus] = "Completed" )

Total Orders =
CALCULATE ( DISTINCTCOUNT ( fact_sales[OrderID] ),
            fact_sales[OrderStatus] = "Completed" )

Total Customers =
CALCULATE ( DISTINCTCOUNT ( fact_sales[CustomerID] ),
            fact_sales[OrderStatus] = "Completed" )
```

**Check before going further:** Revenue = **₹176.85 Cr**, Total Orders =
**68,817**, Total Lines = **146,055**.

> If Revenue reads **₹191.34 Cr**, the status filter is missing somewhere.
> That's the exact figure the bug produced.

> **⚠️ `Total Orders` vs `Total Lines`.** `OrderID` repeats across a basket, so
> `COUNTROWS` counts line items. At 2.12 lines per order, using the wrong one
> makes AOV roughly half its true value and nothing warns you.

---

## 2 · Ratios

These need **no status filter** — they inherit it from the base measures.

```dax
Margin %             = DIVIDE ( [Profit], [Revenue] )
AOV                  = DIVIDE ( [Revenue], [Total Orders] )
ASP                  = DIVIDE ( [Revenue], [Units Sold] )
Avg Profit per Order = DIVIDE ( [Profit], [Total Orders] )
Avg Lines per Order  = DIVIDE ( [Total Lines], [Total Orders] )
```

**Check:** Margin % = **13.67%**, AOV = **₹25,698**.

> **⚠️ Always `DIVIDE()`, never `/`.** The `/` operator errors or returns
> infinity on a zero denominator. Filter to a category with no sales and `/`
> paints a red error across the report; `DIVIDE` returns blank. There is no case
> where `/` is the better choice.
>
> The optional third argument sets the alternate result:
> `DIVIDE ( [Profit], [Revenue], 0 )`. Use blank in visuals — an empty cell is
> honest — and 0 only when a downstream calculation needs a number.

---

## 3 · Loss measures — the spine of this project

`LossFlag` is already a column in `fact_sales`, computed in `02_cleaning.ipynb`
as `ProfitAmount < 0`. Nothing to add in DAX.

```dax
Loss Lines =
CALCULATE ( COUNTROWS ( fact_sales ),
            fact_sales[OrderStatus] = "Completed",
            fact_sales[LossFlag] = TRUE )

Loss-line Rate    = DIVIDE ( [Loss Lines], [Total Lines] )

Revenue at Risk =
CALCULATE ( SUM ( fact_sales[SalesAmount] ),
            fact_sales[OrderStatus] = "Completed",
            fact_sales[LossFlag] = TRUE )

Revenue at Risk % = DIVIDE ( [Revenue at Risk], [Revenue] )

Loss Value =
-CALCULATE ( SUM ( fact_sales[ProfitAmount] ),
             fact_sales[OrderStatus] = "Completed",
             fact_sales[LossFlag] = TRUE )
```

**Check:** Loss-line Rate = **11.1%**, Revenue at Risk % = **18.4%**,
Loss Value = **₹2.59 Cr**.

> **⚠️ Both filters, every time.** These can't derive from the base measures,
> because `CALCULATE` needs the loss condition *and* the status condition in the
> same call. This is the one place the filter gets repeated — check each of the
> three.
>
> **⚠️ The minus sign on `Loss Value`.** Profit on those rows is negative, so
> the raw sum is negative. Negating gives a positive "amount lost", which reads
> correctly on a chart — a taller bar meaning *more loss*.
>
> **⚠️ Three different questions.** `Loss-line Rate` is a **count** (how often it
> goes wrong), `Revenue at Risk` is **revenue** on those lines, `Loss Value` is
> **money actually lost**. In this data they point in different directions.
> Never quote the rate alone — that's the mistake the whole project exposes.

---

## 4 · Discount

```dax
Weighted Discount % =
VAR Net = CALCULATETABLE ( fact_sales, fact_sales[OrderStatus] = "Completed" )
RETURN
DIVIDE (
    SUMX ( Net, fact_sales[Quantity] * fact_sales[UnitPrice] * fact_sales[DiscountPercent] ),
    SUMX ( Net, fact_sales[Quantity] * fact_sales[UnitPrice] )
)
```

**Check:** **12.18%**.

> **⚠️ Why not `AVERAGE ( fact_sales[DiscountPercent] )`?** That treats 20% off
> a ₹200 pen as equal to 20% off a ₹90,000 laptop. The weighted version answers
> *"of every rupee we could have billed, what share did we give away"* — which
> is what a CFO means by "our discount rate".
>
> **Honest note:** in this data the two come out at **12.18% weighted vs 12.38%
> naive** — 0.2 points apart, because discount depth doesn't correlate strongly
> with price here. The weighted figure is still the defensible one to quote, but
> don't present the difference as a finding.
>
> `SUMX` is needed because you multiply **row by row** before summing.
> `SUM(Qty) * SUM(Price)` would be nonsense — it multiplies two totals.
>
> `CALCULATETABLE` applies the status filter to the table `SUMX` iterates. A
> plain `CALCULATE` wrapper wouldn't reach inside the iterator.

---

## 5 · Returns and cancellations — **different populations**

```dax
Placed Orders =
CALCULATE ( DISTINCTCOUNT ( fact_sales[OrderID] ),
            fact_sales[OrderStatus] <> "Cancelled" )

Returned Orders =
CALCULATE ( DISTINCTCOUNT ( fact_sales[OrderID] ),
            fact_sales[OrderStatus] = "Returned" )

Return Rate = DIVIDE ( [Returned Orders], [Placed Orders] )

All Orders =
DISTINCTCOUNT ( fact_sales[OrderID] )          -- no filter: all three statuses

Cancelled Orders =
CALCULATE ( DISTINCTCOUNT ( fact_sales[OrderID] ),
            fact_sales[OrderStatus] = "Cancelled" )

Cancellation Rate = DIVIDE ( [Cancelled Orders], [All Orders] )
```

> **⚠️ This is where the three populations matter most.**
>
> **Return rate** divides by *placed* orders — an order has to have been placed
> to be returned. Dividing by net (Completed) would exclude the returns
> themselves from the denominator and inflate the rate.
>
> **Cancellation rate** divides by *all* orders, because a cancelled order is
> only cancellable if it existed.
>
> **Write the population into the measure description**
> (`Modeling → Description`). Six months later, nobody remembers which
> denominator you chose — including you.
>
> **⚠️ Grain.** These are order-level. A line-level return rate gives a
> different number, because returned orders tend to have more lines. Pick one,
> label the visual, never mix them in one chart.

---

## 6 · Shipping

```dax
Avg Shipping Days =
CALCULATE ( AVERAGE ( fact_sales[ShippingDays] ),
            fact_sales[OrderStatus] = "Completed" )

Lines Missing Shipping Data =
CALCULATE ( COUNTROWS ( fact_sales ),
            fact_sales[OrderStatus] = "Completed",
            fact_sales[IsShippingKnown] = FALSE )

Shipping Coverage % =
DIVIDE ( [Total Lines] - [Lines Missing Shipping Data], [Total Lines] )
```

> **⚠️ `AVERAGE` silently skips blanks.** That's correct here — you must not
> invent delivery times — but it means the denominator is smaller than the row
> count. Show `Shipping Coverage %` beside the average so the reader knows what
> share of data it rests on. **An average quoted without its coverage is an
> unlabelled guess.**
>
> `IsShippingKnown` comes from `02_cleaning.ipynb`. If you took the CSV route
> into Power BI, confirm it's typed **True/False** and not text — a text column
> fails `= FALSE` silently and this measure returns blank.

---

## 7 · Time intelligence

**Requires `dim_date` marked as the date table.** These return wrong answers
otherwise — no error, just bad numbers.

```dax
Revenue YTD = TOTALYTD ( [Revenue], dim_date[Date] )
Revenue QTD = TOTALQTD ( [Revenue], dim_date[Date] )
Revenue MTD = TOTALMTD ( [Revenue], dim_date[Date] )

Revenue PY    = CALCULATE ( [Revenue], SAMEPERIODLASTYEAR ( dim_date[Date] ) )
Revenue YoY   = [Revenue] - [Revenue PY]
Revenue YoY % = DIVIDE ( [Revenue YoY], [Revenue PY] )

Margin % PY          = CALCULATE ( [Margin %], SAMEPERIODLASTYEAR ( dim_date[Date] ) )
Margin pt change YoY = [Margin %] - [Margin % PY]
```

**Check by year:** Revenue ₹25.78 → 37.71 → 51.25 → **₹62.10 Cr**;
Margin 13.45 → 12.91 → 14.43 → **13.59%**.

> **⚠️ Margin change is in percentage POINTS.** 12.91% → 14.43% is **+1.52
> points**, or +11.8% *relative*. Saying "margin rose 11.8%" when you mean
> points is a classic way to mislead a stakeholder and a classic thing to be
> caught on. The measure is named `Margin pt change YoY` so the unit can't be
> mistaken.

```dax
Revenue Running Total =
CALCULATE ( [Revenue],
    FILTER ( ALLSELECTED ( dim_date[Date] ),
             dim_date[Date] <= MAX ( dim_date[Date] ) ) )

Revenue 3M Moving Avg =
VAR Period = DATESINPERIOD ( dim_date[Date], MAX ( dim_date[Date] ), -3, MONTH )
RETURN DIVIDE ( CALCULATE ( [Revenue], Period ), 3 )
```

> **⚠️ `ALLSELECTED` vs `ALL`.** `ALL` ignores every filter including slicers —
> pick 2024 and the running total still starts from 2022. `ALLSELECTED` respects
> the user's selection and removes only the row-level date filter from the
> visual. Inside a filtered report, `ALLSELECTED` is almost always right.

---

## 8 · Ranking and contribution

```dax
Product Rank  = RANKX ( ALL ( dim_product[ProductName] ),  [Revenue], , DESC, DENSE )
Customer Rank = RANKX ( ALL ( dim_customer[CustomerID] ),  [Revenue], , DESC, DENSE )

Revenue % of Total = DIVIDE ( [Revenue], CALCULATE ( [Revenue], ALLSELECTED () ) )

Cumulative Revenue % =
VAR CurrentRev = [Revenue]
RETURN
DIVIDE (
    SUMX ( FILTER ( ALLSELECTED ( dim_product[ProductName] ), [Revenue] >= CurrentRev ),
           [Revenue] ),
    CALCULATE ( [Revenue], ALLSELECTED ( dim_product[ProductName] ) )
)
```

> **`Cumulative Revenue %` is your Pareto measure** — put it as a line over a
> bar chart of revenue by product sorted descending, and you get the 80/20 curve
> for Q5 and Q11.
>
> **⚠️ `DENSE` vs `SKIP` in RANKX.** With ties, `DENSE` gives 1,2,2,3 and `SKIP`
> gives 1,2,2,4. For "top 10 products" either works; for counting distinct rank
> positions they differ. Know which you chose.

---

## 9 · The What-If simulator *(Page 4)*

**Modeling → New parameter → Numeric range** — `Discount Cap`, Min `0`,
Max `0.40`, Increment `0.01`, default `0.10`. Tick *Add slicer to this page*.

Power BI creates a table and a measure `Discount Cap Value`.

```dax
Simulated Revenue =
VAR Net = CALCULATETABLE ( fact_sales, fact_sales[OrderStatus] = "Completed" )
RETURN
SUMX ( Net,
    fact_sales[Quantity] * fact_sales[UnitPrice] *
        ( 1 - MIN ( fact_sales[DiscountPercent], [Discount Cap Value] ) ) )

Simulated Profit   = [Simulated Revenue] - [Cost]
Margin Recovered   = [Simulated Profit] - [Profit]
Simulated Margin % = DIVIDE ( [Simulated Profit], [Simulated Revenue] )

Revenue Affected =
CALCULATE ( SUM ( fact_sales[SalesAmount] ),
            fact_sales[OrderStatus] = "Completed",
            fact_sales[DiscountPercent] > [Discount Cap Value] )
```

> **How it works:** `MIN(actual, cap)` leaves lines already below the cap
> untouched and pulls the rest down to it. `SUMX` re-prices each line
> individually; `Margin Recovered` is the difference against actual.
>
> **⚠️ `CALCULATETABLE`, not `CALCULATE`.** The status filter has to apply to
> the table `SUMX` iterates. Wrapping the whole thing in `CALCULATE` would not
> reach inside the iterator, and cancelled lines would get re-priced into your
> recovery number.
>
> **⚠️ State the assumption on the page.** This holds **volume constant** — it
> assumes every unit still sells at the higher price. Some wouldn't. So
> `Margin Recovered` is a **ceiling, not a forecast**; the honest label is
> *"maximum recoverable if volume holds."*
>
> A stakeholder who discovers a hidden assumption stops trusting the whole
> report; one who reads it in your subtitle trusts everything else more.
>
> **Anchor:** capping Technology at 10% is worth **₹0.67 Cr/year** at the 2025
> run-rate. `Revenue Affected` sizes the exposure — how much revenue the cap
> actually touches.

---

## 10 · Formatting

| Measure type | Format |
|---|---|
| Revenue, Cost, Profit, Loss Value, AOV, ASP | Currency, ₹, 0 decimals |
| Margin %, rates, YoY %, contribution | Percentage, 1 decimal |
| Counts (orders, lines, customers, units) | Whole number, thousands separator |
| Avg Shipping Days, Avg Lines per Order | Decimal, 1 place |

> On a KPI card use the custom format `#,0,,.0 "Cr"` to show **₹176.9 Cr**
> instead of ₹1,768,500,000. Executives read crores, and the card stops
> overflowing.
>
> The underlying figure is ₹176.85 Cr; the card shows one decimal. Keep full
> precision wherever a number has to reconcile, round only for display.

---

## Build order

| | | Check |
|---|---|---|
| 1 | §1 base measures | Revenue **₹176.85 Cr** · Orders **68,817** · Lines **146,055** |
| 2 | §2 ratios | Margin % **13.67%** · AOV **₹25,698** |
| 3 | §3 loss measures | Loss-line Rate **11.1%** · Loss Value **₹2.59 Cr** |
| 4 | §5 returns | *needs the placed population — check the denominator* |
| 5 | §7 time intelligence | *needs `dim_date` marked as the date table* |
| 6 | §9 simulator | last, for Page 4 |

> **Gate: if Margin % isn't 13.67%, stop.**
>
> - **13.81%** → the status filter is missing from at least one base measure
> - **anything else** → a relationship is wrong, or Power Query filtered
>   something it shouldn't have
>
> Don't build visuals on a number that doesn't reconcile with
> `03_analysis.sql`. Finding the break now costs minutes; finding it after four
> pages costs the afternoon.
