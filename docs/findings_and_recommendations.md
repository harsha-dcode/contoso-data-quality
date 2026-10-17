# Findings and recommendations

Contoso India Retail, profitability review, FY2022-FY2025.

Every number here comes from `sql/04_analysis.sql` and
`notebooks/05_statistics.ipynb`.

This is revision 2. The first version included cancelled and returned orders in every
revenue total, which overstated revenue by ₹14.5 Cr (8%). A review caught it. The
direction of every finding held up but all the rupee figures moved. `docs/CHANGES.md` has
the before and after.

## 0. How money is counted

Three populations. Mixing them is the easiest way to get this wrong.

| Basis | Includes | Used for |
|---|---|---|
| Net | Completed only, 146,055 lines | all money metrics: revenue, profit, margin, loss |
| Placed | Completed + Returned, 152,274 lines | return rate, demand analysis |
| All | + Cancelled, 157,108 lines | cancellation rate only |

Cancelled orders carry ₹6.02 Cr of revenue and ₹1.06 Cr of profit that never happened.
Returns carry another ₹8.50 Cr. Unless a table says otherwise, everything below is net.

## 1. Summary

Revenue grew 141% between 2022 and 2025 but margin never moved off about 13.7%. 18.4% of
revenue is loss-making, costing ₹2.59 Cr cumulative over 2022-25 and ₹0.92 Cr in 2025.

The loss isn't where you'd expect. Deep discounts fail most often, but 73.2% of every
rupee lost comes from routine 10-20% discounts on Technology, and within that, twelve
SKUs drive 82% of it.

A deep-discount policy couldn't have helped either way: no Technology line in this
dataset is discounted above 20% at all.

Every rupee figure below is labelled either "cumulative 2022-25" or "2025". Anything
forward-looking uses 2025; anything describing what happened uses the cumulative.

## 2. What happened

| Year | Revenue | Margin % | Orders | Loss value |
|---|---:|---:|---:|---:|
| 2022 | ₹25.78 Cr | 13.45% | 10,165 | ₹0.37 Cr |
| 2023 | ₹37.71 Cr | 12.91% | 14,540 | ₹0.59 Cr |
| 2024 | ₹51.25 Cr | 14.43% | 19,842 | ₹0.71 Cr |
| 2025 | ₹62.10 Cr | 13.59% | 24,270 | ₹0.92 Cr |

Four-year totals, net: revenue ₹176.85 Cr, cost ₹152.68 Cr, profit ₹24.17 Cr, margin
13.67%, AOV ₹25,698, orders 68,817, revenue at risk 18.4%, loss value ₹2.59 Cr.

Revenue grew 141% and the economics didn't improve. Margin actually ends higher than it
started (13.45% to 13.59%), so it's flat and noisy rather than declining. I'd describe it
as margin being stuck around 13.7% while the business tripled, which is a more
interesting problem than a downward trend because it means growth isn't fixing anything.

One thing to be careful about when quoting these: the 2024 figure of 14.43% is 1.52
percentage points above 2023, not 11.8%. Say which unit you mean.

## 3. Ranked insights

These overlap, so don't add them up. Insights 1 and 2 are mostly the same money at
different resolution. Insight 3 is independent, and it's opportunity rather than loss
recovery. Section 6 has the sizing note.

### Insight 1. Routine discounting on one category is three-quarters of the loss

Technology lines discounted 10-20% account for ₹1.90 Cr cumulative 2022-25, which is
73.2% of every rupee the business loses. In 2025 alone that's 3,663 lines, ₹20.26 Cr of
revenue at 4.7% margin, ₹0.67 Cr lost, or 73% of that year's ₹0.92 Cr. The concentration
holds across all four years, so it isn't a one-off.

The intuitive culprit is the opposite of this. Loss rate does rise with discount depth,
exactly as you'd expect. But the deepest band holds 1.2% of the money lost.

Lines and loss value are cumulative 2022-25.

| Discount band | Lines | Loss rate | Loss value | Share of loss | Margin |
|---|---:|---:|---:|---:|---:|
| 0% | 517 | 0.2% | ₹0.00 Cr | 0.0% | 22.2% |
| 0-10% | 69,625 | 2.4% | ₹0.30 Cr | 11.6% | 19.3% |
| 10-20% | 54,933 | 12.7% | ₹2.08 Cr | 80.3% | 8.3% |
| 20-30% | 17,221 | 29.3% | ₹0.18 Cr | 7.0% | 8.4% |
| 30-40% | 3,759 | 64.4% | ₹0.03 Cr | 1.2% | 3.4% |

What settles it is that Technology's maximum discount in this dataset is exactly 20.0%.
Not one line goes deeper. A policy capping deep discounts wouldn't touch a single
Technology transaction and couldn't recover a rupee of the 73%. For this category the
deep-discount explanation isn't just incomplete, it's arithmetically impossible.

Why it happens: Technology carries roughly a 21% list markup. A routine 15% discount
leaves about 6 points before any cost variance, so the line tips negative on almost any
adverse movement. Each individual loss is trivial. Across 54,933 lines it becomes the
dominant leak. Deep discounts fail far more often but they land on Accessories, which
runs at 31.3% margin and absorbs them.

Worth ₹1.90 Cr of the ₹2.59 Cr cumulative loss, or ₹0.67 Cr per year at the 2025
run-rate. That's the figure to plan against.

Action: cap discounting at 10% on Technology SKUs with list margin below 15%. Owner is
Merchandising, next pricing cycle.

Guardrail: unit volume and conversion rate, monthly. If Technology volume falls more than
about 8%, those discounts were buying incremental demand and the cap should reverse.

What would change this: the arithmetic is solid but the counterfactual isn't established.
I can see discount and margin but not the basket. If these discounts drive attach rate or
repeat purchase, capping them costs more than it saves. Testing that needs basket-level
data or a controlled price test, and neither exists here. That's a limit of the data
rather than the analysis.

### Insight 2. Inside that, it's twelve products

Technology has 267 SKUs. Only 34 lose money, and the worst 12 account for 82% of all
Technology losses.

The Pareto shape is what decides the recommendation. A category-wide margin failure would
mean restructuring the pricing model, which is slow, political and expensive. Twelve
products means a SKU review one person finishes in a week.

Worth about ₹1.75 Cr cumulative 2022-25, but this is mostly the same money as Insight 1,
not additional to it. That's why I'm not quoting a separate annual figure.

Action: review those 12 individually and either reprice, renegotiate cost, or delist.
`sql/04_analysis.sql` Q5 returns them ranked with a cumulative loss column.

Guardrail: check basket attach rate before delisting any of them.

A SKU can be unprofitable and still worth stocking if it pulls profitable baskets, and
that's untestable without basket data. So the recommendation is review, not delist.

### Insight 3. Marketplace is genuinely less profitable, and it isn't mix

Marketplace runs at 9.7% margin against Website's 15.1%, a 5.4 point gap on ₹31.73 Cr
cumulative. The gap is widening: in 2025 it's 8.9% against 14.9%, 6.0 points on ₹10.70 Cr.

Cumulative 2022-25, net.

| Channel | Orders | Revenue | Margin | Return rate* |
|---|---:|---:|---:|---:|
| Website | 22,835 | ₹60.00 Cr | 15.1% | 4.66% |
| Retail Store | 18,429 | ₹50.13 Cr | 13.7% | 1.94% |
| Mobile App | 15,642 | ₹34.99 Cr | 14.7% | 4.56% |
| Marketplace | 11,911 | ₹31.73 Cr | 9.7% | 5.73% |

\* Return rate is on the placed basis, since an order has to exist before it can be
returned.

The obvious alternative explanation was product mix, that Marketplace just sells more
thin-margin Technology. It doesn't. Technology is 63.7% of Marketplace revenue and 63.3%
of Website's. And Marketplace trails in every single category:

| Category | Marketplace | Website | Gap |
|---|---:|---:|---:|
| Technology | 6.2% | 11.3% | -5.1 |
| Appliances | 6.0% | 13.5% | -7.5 |
| Office Supplies | 11.0% | 16.1% | -5.1 |
| Furniture | 22.6% | 26.9% | -4.3 |
| Accessories | 28.7% | 32.3% | -3.6 |

The gap survives controlling for category, so this is channel economics rather than
composition. Commission and higher return handling are the plausible mechanism.

Worth ₹1.71 Cr cumulative. At the 2025 run-rate, 6.0 points on ₹10.70 Cr, that's ₹0.64 Cr
per year, and it's independent of Insights 1 and 2.

Action: renegotiate commission, or reprice to recover it. If neither is possible, shift
acquisition spend toward Website and Mobile App.

Guardrail: total revenue and new-customer count. Marketplace may be an acquisition
channel whose customers become profitable elsewhere.

`CostAmount` doesn't itemise commission, so the mechanism is inferred rather than
measured. The gap is measured; the cause is reasoned. I also haven't tested whether
marketplace customers later purchase direct.

### Insight 4. Growth isn't improving the economics

Revenue grew 141% (₹25.78 Cr to ₹62.10 Cr) while margin moved from 13.45% to 13.59%. No
trend. The loss-line rate is 11.1% in all four years.

Nothing structural changed. Category mix, discount policy and channel economics are all
stable, so the business scaled its cost structure proportionally. At 13.7%, every ₹100 of
new revenue returns ₹13.70, and three years of growth didn't move that.

As a target rather than a recovery, one margin point is ₹0.62 Cr per year on 2025 revenue.

Action: set an explicit margin target alongside the revenue target. Growth on its own
won't produce one.

Guardrail: revenue growth rate. A margin target pursued carelessly is easy to hit by
shrinking.

A caveat on this one. The loss-line rate being identical to one decimal place across four
separate years isn't realistic for a real business. It's a fingerprint of the simulated
data, and no conclusion about trend stability should rest on it. The cross-sectional
findings in 1 to 3 don't depend on it.

### Insight 5. Revenue is concentrated in repeat buyers

26.2% of customers order 10 or more times and generate 63.0% of revenue. The 10.7% who
ordered once contribute 1.7%.

| Orders | Customers | % of customers | % of revenue |
|---|---:|---:|---:|
| 1 | 791 | 10.7% | 1.7% |
| 2-3 | 1,703 | 22.9% | 8.1% |
| 4-9 | 2,987 | 40.2% | 27.2% |
| 10+ | 1,941 | 26.2% | 63.0% |

The concentration is real but not extreme: 847 customers produce half the revenue and
2,635 produce 80%, out of 7,416.

Segments point the same way. Enterprise orders 3.6 times per customer at ₹81,078 AOV and
19.0% margin; Consumer orders 11.1 times at ₹19,963 and 12.3%.

| Segment | Customers | Orders | Revenue | AOV | Orders/cust | Margin |
|---|---:|---:|---:|---:|---:|---:|
| Consumer | 4,448 | 49,281 | ₹98.38 Cr | ₹19,963 | 11.08 | 12.3% |
| Small Business | 1,675 | 13,506 | ₹45.00 Cr | ₹33,318 | 8.06 | 13.9% |
| Corporate | 973 | 4,877 | ₹24.10 Cr | ₹49,419 | 5.01 | 16.7% |
| Enterprise | 320 | 1,153 | ₹9.35 Cr | ₹81,078 | 3.60 | 19.0% |

Not sized, because retention economics need CAC and that's out of scope. No action
recommended; flagged as the next investigation.

There's also a window bias here: recent joiners have had less time to repeat, which
inflates the single-order band. This needs a tenure-matched cohort before anyone acts
on it.

## 4. Root cause

Technology operates at 9.98% realised margin on a roughly 21% list markup, because
routine discounting of 10-20% consumes half the markup before any cost variance. Against
that thin base, 54,933 lines run at 8.3% margin, and small negative outcomes on
individually trivial transactions accumulate to ₹1.90 Cr cumulative, 73.2% of all losses,
running at ₹0.67 Cr per year by 2025. Because the loss concentrates in 12 SKUs rather
than spreading across 267, the driver is product-level pricing rather than a
category-wide structural failure.

The explanation I rejected was that deep discounting is the problem. The 30-40% band has
by far the worst loss rate at 64.4%, but it holds 1.2% of the loss value. And Technology
is never discounted above 20% at all, so no deep-discount policy could reach the 73%.
Acting on rate alone would have addressed about a fiftieth of the problem.

## 5. What I can't conclude

### Correlation, not causation

Deeper discounts coincide with lower margin, and arithmetically a discount on a thin
markup has to compress margin, so that part is definitional. What isn't established is
the counterfactual: would those units have sold at full price? Two alternatives survive.
Reverse causation, where slow-moving stock gets discounted because it isn't selling. And
common cause, where thin-markup categories are both heavily discounted and structurally
unprofitable. Distinguishing them needs a controlled price test.

### Missing data, and what each blocks

| Absent | Question it blocks |
|---|---|
| basket-level detail | do these discounts drive attach rate or repeat purchase? (the biggest limit on Insight 1) |
| marketing spend / CAC | is Marketplace an acquisition channel worth its margin? Is retention worth funding? |
| returns processing cost | what do returns actually cost? They're counted, never costed |
| competitor pricing | were the discounts defensive? |
| inventory / stock-outs | is a low-selling SKU unwanted, or unavailable? |

### Mix effects

Aggregate margin by discount band is misleading. The 20-30% band at 8.4% looks no worse
than 10-20% at 8.3%, because deep discounts happen mostly in high-margin categories.
Within every category the relationship is monotonic. It's a Simpson's paradox, and
reading the aggregate alone understates the effect.

### Population, not sample

This is every transaction for four years, so significance tests don't apply in the usual
sense. A p-value asks whether a pattern could arise by chance in a sample, and a census
has no sampling error. If you treat the period as a sample of an ongoing process, the
loss-line rate's 95% bootstrap interval is narrow, but only because n is large. A tight
interval isn't evidence that the effect matters.

### The environment is simulated

I built and documented this dataset. The findings test the method, not the Indian retail
market. The identically flat loss-line rate across four years is an artefact of how it
was built.

### Data handling

157,116 raw rows became 157,108. Only 8 rows were excluded: negative quantities keyed as
credit notes, with their money columns negated to match, which makes them unrecoverable
as sales. 16 rows were recovered, 8 with zero quantity and 8 with impossible discounts.
Both groups had internally consistent money columns, so quantity and discount could be
back-solved exactly instead of discarded. 34 rows with orphan keys were mapped to Unknown
members rather than dropped. 1,049 rows fail a money rule and are flagged, not corrected.
99.33% reconciles against both the pricing formula and `Profit = Sales - Cost`.

An earlier draft excluded all 24 rows on the grounds that "the money was not
recalculated". That reasoning was backwards. The money columns were the intact part.
Recovering 16 of them is both more accurate and less destructive.

## 6. Recommendations

### R1. Cap discounting on thin-margin Technology SKUs

| | |
|---|---|
| Do | cap discounts at 10% on Technology SKUs with list margin below 15% |
| Because | 54,933 such lines run at 8.3% margin and cause 73.2% of all losses, and no Technology line is discounted above 20%, so a deep-discount policy can't reach them |
| Expected impact | ₹0.67 Cr/year at 2025 run-rate (₹1.90 Cr cumulative 2022-25). A ceiling, not a forecast |
| Guardrail | Technology unit volume and conversion rate, monthly |
| Owner | Merchandising |
| Reverses if | Technology volume falls more than 8% within two months |

### R2. Review the twelve worst SKUs individually

| | |
|---|---|
| Do | reprice, renegotiate cost, or delist the 12 SKUs driving 82% of Technology loss |
| Because | the loss is concentrated in 12 of 267 SKUs, so a SKU review beats a pricing restructure |
| Expected impact | about ₹1.75 Cr cumulative, which is mostly the same money as R1 |
| Guardrail | basket attach rate before any delisting |
| Owner | Category Manager |
| Reverses if | any of the 12 turns out to be a traffic driver |

### R3. Renegotiate or reprice Marketplace

| | |
|---|---|
| Do | renegotiate commission; failing that, reprice or shift spend to Website |
| Because | 6.0 points below Website on ₹10.70 Cr in 2025, and it's channel economics rather than mix |
| Expected impact | ₹0.64 Cr/year at 2025 run-rate (₹1.71 Cr cumulative). Independent of R1 and R2 |
| Guardrail | total revenue and new-customer count |
| Owner | Channel Lead |
| Reverses if | Marketplace customers convert to direct purchase later |

### Sizing, read this before quoting any number

| | 2025 | Basis |
|---|---:|---|
| R1, cap Technology discounts | ₹0.67 Cr | loss on Technology 10-20% lines, 2025 |
| R2, the 12 SKUs | — | mostly R1, not additive |
| R3, Marketplace | ₹0.64 Cr | 6.0 pt gap on ₹10.70 Cr, 2025 |
| Ceiling | ₹1.31 Cr/yr | |

Cumulative 2022-25 equivalents are ₹1.90 Cr, ₹1.75 Cr and ₹1.71 Cr, a ceiling of about
₹3.6 Cr. That's history, not a forward estimate.

₹1.31 Cr is more than the ₹0.92 Cr actually lost in 2025, which needs explaining. R1
recovers loss. R3 doesn't: Marketplace is profitable at 8.9%, just less profitable than
Website, so closing that gap is margin opportunity on already-profitable revenue rather
than loss elimination. Adding the two together is legitimate only if you state the
distinction, which is why it's stated here.

All of these are ceilings, not forecasts. Every figure assumes volume holds, and some
discounted units wouldn't sell at full price, so realistic recovery is lower in every
case.

## 7. Baselines to monitor

2025 actuals, net basis.

| Metric | Baseline | Target | Review |
|---|---:|---|---|
| overall margin % | 13.59% | 15.0% | monthly |
| Technology margin % | 9.98% | 12.5% | monthly |
| loss-line rate | 11.1% | < 8% | monthly |
| revenue at risk % | 18.4% | < 14% | quarterly |
| Marketplace margin % | 8.9% | 11.5% | monthly |
| weighted discount % | 12.18% | < 10% | monthly |
| guardrail: Technology unit volume | 2025 actual | watch, no target | monthly |
| guardrail: conversion rate | baseline TBD | watch, no target | monthly |

The guardrails deliberately have no target. You're not trying to move them, you're making
sure they don't move. Treating one as a KPI is how a discount cap quietly destroys volume
for two quarters before anyone notices.

Use the weighted discount figure (12.18%), not the naive average (12.38%). They're close
in this data, but the weighted one is the defensible version.

## 8. The next question

Does retention justify investment? 26% of customers drive 63% of revenue, and Enterprise
is both the smallest and the most profitable segment at 19.0% margin. Without CAC I can't
compare the cost of retaining a repeat buyer against acquiring a new one, and the
single-order band is inflated by recent joiners. A tenure-matched cohort analysis with
acquisition cost is the next piece of work.

## Reproducibility

| Output | Source |
|---|---|
| sections 2, 3, 4 | `sql/04_analysis.sql`, views `sales_net` and `sales_placed` |
| Simpson's paradox, confounders, bootstrap CI | `notebooks/05_statistics.ipynb` |
| section 5 data handling | `sql/02_validation.sql`, `reference/cleaning_in_sql.sql` |
| what changed in revision 2 | `docs/CHANGES.md` |

Every number above was checked against the delivered data.
