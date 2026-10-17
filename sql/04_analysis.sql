/* =====================================================================
   sql/04_analysis.sql   —   WORKFLOW STEPS 9 & 10 : THE ANALYSIS
   Contoso Profitability
   ---------------------------------------------------------------------
   Answers Q1-Q15 in order. Results are recorded under each query as I
   found them, so anything here can be re-run and checked.

   Where I tried a worse version first, I have said so and kept the
   reason.
   ===================================================================== */

USE ContosoRetail;
GO


/* =====================================================================
   THE TWO POPULATIONS  —  decided once, used everywhere
   ---------------------------------------------------------------------
   fact_sales holds three kinds of line, and they answer different
   questions:

     Completed  146,055 lines   money that was actually earned
     Returned     6,219 lines   a real purchase that was reversed
     Cancelled    4,834 lines   never became a sale

   sales_net     Completed only.  Every revenue, profit, margin, loss
                                  and AOV figure.
   sales_placed  Completed + Returned.  Return rates, order counts per
                                  customer, cohort activity - anything
                                  about what customers DID.

   fact_sales itself is only used for data-quality checks (Q14/Q15).

   Without this split the cancelled lines added Rs 6.02 Cr of revenue
   and Rs 1.06 Cr of profit that never existed - profit on orders nobody
   paid for. See the reconciliation query right below.
   ===================================================================== */
CREATE OR ALTER VIEW sales_net AS
    SELECT * FROM fact_sales WHERE OrderStatus = 'Completed';
GO
CREATE OR ALTER VIEW sales_placed AS
    SELECT * FROM fact_sales WHERE OrderStatus IN ('Completed', 'Returned');
GO


/* =====================================================================
   STEP 9  —  WHAT HAPPENED  (the baseline, before any explanation)
   ===================================================================== */

-- 9a. Gross to net: what each status contributes
SELECT OrderStatus,
       COUNT(*)                                                      AS Lines,
       COUNT(DISTINCT OrderID)                                       AS Orders,
       CAST(SUM(SalesAmount)  / 10000000.0 AS DECIMAL(10,2))         AS Revenue_Cr,
       CAST(SUM(ProfitAmount) / 10000000.0 AS DECIMAL(10,2))         AS Profit_Cr
FROM   fact_sales
GROUP  BY OrderStatus
ORDER  BY Revenue_Cr DESC;
/*  EXPECT:
      Completed   146,055   68,817   176.85   24.17
      Returned      6,219    2,940     8.50    1.20
      Cancelled     4,834    2,242     6.02    1.06

    Gross revenue across all three is Rs 191.36 Cr; net is Rs 176.85 Cr.
    Margin barely moves (13.81% gross, 13.67% net), so the story survives,
    but every rupee figure is about 8% lower. No order mixes statuses
    across its lines, so order counts split cleanly too.                */

-- 9b. The baseline
SELECT
    CAST(SUM(SalesAmount)  / 10000000.0 AS DECIMAL(10,2))            AS Revenue_Cr,
    CAST(SUM(CostAmount)   / 10000000.0 AS DECIMAL(10,2))            AS Cost_Cr,
    CAST(SUM(ProfitAmount) / 10000000.0 AS DECIMAL(10,2))            AS Profit_Cr,
    CAST(100.0 * SUM(ProfitAmount) / SUM(SalesAmount) AS DECIMAL(5,2)) AS MarginPct,
    COUNT(DISTINCT OrderID)                                          AS Orders,
    CAST(SUM(SalesAmount) / COUNT(DISTINCT OrderID) AS DECIMAL(10,0)) AS AOV
FROM sales_net;
/*  EXPECT: 176.85 | 152.67 | 24.17 | 13.67 | 68817 | 25698

    AOV uses COUNT(DISTINCT OrderID). I had COUNT(*) here first and got
    a figure that looked perfectly reasonable until I noticed it was
    almost exactly half. Nothing errors when this is wrong.              */


/* =====================================================================
   Q1 / Q2  —  IS GROWTH IMPROVING THE ECONOMICS?
   ---------------------------------------------------------------------
   I started with a self-join to (year - 1). It worked, but it was long
   and it returned nothing for a year with no prior-year row rather than a
   blank. LAG says the same thing in one line and fails visibly.
   ===================================================================== */
WITH yearly AS (
    SELECT YEAR(OrderDate)                                             AS Yr,
           SUM(SalesAmount)                                            AS Revenue,
           SUM(ProfitAmount)                                           AS Profit,
           100.0 * SUM(ProfitAmount) / SUM(SalesAmount)                AS MarginPct,
           COUNT(DISTINCT OrderID)                                     AS Orders
    FROM   sales_net
    GROUP  BY YEAR(OrderDate)
)
SELECT Yr,
       CAST(Revenue/10000000.0 AS DECIMAL(10,2))                       AS Revenue_Cr,
       CAST(MarginPct AS DECIMAL(5,2))                                 AS MarginPct,
       Orders,
       CAST(100.0 * (Revenue - LAG(Revenue) OVER (ORDER BY Yr))
            / LAG(Revenue) OVER (ORDER BY Yr) AS DECIMAL(6,1))         AS RevenueYoYPct,
       CAST(MarginPct - LAG(MarginPct) OVER (ORDER BY Yr) AS DECIMAL(5,2)) AS MarginPointChange
FROM   yearly
ORDER  BY Yr;
/*  EXPECT:
      2022   25.78   13.45   10165     -      -
      2023   37.71   12.91   14540   +46.3  -0.54
      2024   51.25   14.43   19842   +35.9  +1.52
      2025   62.10   13.59   24270   +21.2  -0.83

    This is where my plan turned out to be wrong. I had written the thesis
    as "margin is declining" and set out to confirm it. Revenue grew 141%,
    but margin ends HIGHER than it started (13.45 -> 13.59). It is flat
    and noisy, not falling.

    I rewrote the claim to "margin is structurally capped at ~14% while
    revenue grew 2.4x", which is both true and a better story - growth is
    not improving the economics at all. Had I presented the original
    version, this table would have contradicted me.

    MarginPointChange is in percentage POINTS. 12.91 -> 14.43 is +1.52
    points, or +11.8% relative. I named the column so I cannot confuse the
    two later.                                                           */


/* =====================================================================
   Q3  —  HOW MUCH REVENUE IS LOSS-MAKING?
   ---------------------------------------------------------------------
   My first version was two queries - one filtered to loss rows, one not -
   and I divided the results by hand. They drifted the moment I changed a
   filter in one and forgot the other. Conditional aggregation keeps
   numerator and denominator in the same scan, so they cannot disagree.
   ===================================================================== */
SELECT
    CAST(100.0 * SUM(CASE WHEN LossFlag=1 THEN SalesAmount ELSE 0 END)
         / SUM(SalesAmount) AS DECIMAL(5,1))                      AS RevenueAtRiskPct,
    CAST(100.0 * SUM(CAST(LossFlag AS FLOAT)) / COUNT(*) AS DECIMAL(5,1)) AS LossLineRatePct,
    CAST(-SUM(CASE WHEN LossFlag=1 THEN ProfitAmount ELSE 0 END)
         / 10000000.0 AS DECIMAL(10,2))                           AS LossValue_Cr
FROM sales_net;
/*  EXPECT:  18.4 | 11.1 | 2.59

    THREE DIFFERENT NUMBERS, THREE DIFFERENT MEANINGS:
      18.4%  of REVENUE sits on loss-making lines
      11.1%  of LINES lose money          (a count)
      Rs 2.59 Cr is what is actually LOST (the money)

    Quoting the rate alone is the mistake this project exists to expose.

    The loss-line rate is 11.0-11.1% in EVERY year. Real businesses do not
    hold a rate that steady; it is a fingerprint of generated data, and
    I disclose it rather than wait for someone to spot it.               */


/* =====================================================================
   Q4  —  WHICH CATEGORIES LOSE THE MOST?
   ===================================================================== */
SELECT p.Category,
       CAST(-SUM(CASE WHEN f.LossFlag=1 THEN f.ProfitAmount ELSE 0 END)
            /10000000.0 AS DECIMAL(10,2))                         AS Loss_Cr,
       CAST(100.0 * -SUM(CASE WHEN f.LossFlag=1 THEN f.ProfitAmount ELSE 0 END)
            / SUM(-SUM(CASE WHEN f.LossFlag=1 THEN f.ProfitAmount ELSE 0 END)) OVER ()
            AS DECIMAL(5,1))                                      AS ShareOfLossPct,
       CAST(SUM(f.SalesAmount)/10000000.0 AS DECIMAL(10,2))       AS Revenue_Cr,
       CAST(100.0*SUM(f.ProfitAmount)/SUM(f.SalesAmount) AS DECIMAL(5,2)) AS MarginPct
FROM   sales_net f
JOIN   dim_product p ON p.ProductID = f.ProductID
GROUP  BY p.Category
ORDER  BY Loss_Cr DESC;
/*  EXPECT:
      Technology       2.14   82.6%   112.45 Cr    9.98%
      Appliances       0.38   14.6%    25.56 Cr   10.98%
      Office Supplies  0.06    2.2%     7.07 Cr   14.82%
      Furniture        0.01    0.4%    16.09 Cr   26.00%
      Accessories      0.00    0.1%    15.67 Cr   31.31%
      (plus a near-zero 'Unknown' row for the orphan products)

    Technology = 64% of revenue but 83% of all losses. At a 10% margin on
    64% of revenue, it is also the main reason the overall margin cannot
    get far above 14%.

    SUM(...) OVER () with empty parentheses puts the grand total on every
    row, so the share column needs no subquery and no second pass. I had
    been writing a correlated subquery for this until I found it.        */


/* =====================================================================
   Q5  —  A FEW PRODUCTS, OR THE WHOLE CATEGORY?   (the Pareto)
   ---------------------------------------------------------------------
   The shape of this Pareto decided the recommendation. A few bad SKUs
   means repricing twelve products; a category-wide failure means
   restructuring the pricing model. Same finding, very different ask.

   I left the frame clause off first time. SUM(x) OVER (ORDER BY y)
   defaults to RANGE, which collapses tied values into one step - so two
   products with the same loss produced a jump in the running total and a
   Pareto that did not reach 100% cleanly. ROWS walks row by row.

   The self-join version of a running total is O(n^2). Fine on 267
   products, not fine on the fact table.
   ===================================================================== */
WITH prod AS (
    SELECT f.ProductID, p.ProductName,
           SUM(f.ProfitAmount) AS Profit,
           SUM(f.SalesAmount)  AS Revenue
    FROM   sales_net f
    JOIN   dim_product p ON p.ProductID = f.ProductID
    WHERE  p.Category = 'Technology'
    GROUP  BY f.ProductID, p.ProductName
),
losers AS (
    SELECT ProductID, ProductName, Revenue, Profit,
           -Profit AS Loss,
           SUM(-Profit) OVER (ORDER BY Profit ASC
                              ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS CumLoss,
           SUM(-Profit) OVER ()                                   AS TotalLoss,
           ROW_NUMBER()  OVER (ORDER BY Profit ASC)               AS Rnk
    FROM   prod
    WHERE  Profit < 0
)
SELECT Rnk, ProductName,
       CAST(Revenue/100000.0 AS DECIMAL(10,1))   AS Revenue_Lakh,
       CAST(Loss/100000.0    AS DECIMAL(10,1))   AS Loss_Lakh,
       CAST(100.0*CumLoss/TotalLoss AS DECIMAL(5,1)) AS CumulativeLossPct
FROM   losers
ORDER  BY Rnk;
/*  Result: Technology has 267 SKUs. 34 lose money in total. The worst 12
    of those reach 82% of all net Technology product losses.

    Note the denominator: this is the loss of products that are
    loss-making OVERALL, not the line-level loss in Q4. A product can be
    profitable in total and still carry losing lines.

    12 products out of 1,400. I had assumed a category-wide pricing problem
    before running this, and the answer turned R2 into a SKU review rather
    than a pricing restructure.                                          */


/* =====================================================================
   Q6 / Q7  —  DISCOUNT BAND: RATE vs VALUE   *** THE KEY QUERY ***
   ---------------------------------------------------------------------
   WHY BOTH IN ONE QUERY AND NOT TWO?
     Because the finding IS the divergence. Side by side, the rate climbs
     while the value collapses. Run as two separate queries, I read the
     rate first, thought I was done, and drafted the wrong recommendation.
   ===================================================================== */
SELECT DiscountBand,
       COUNT(*)                                                   AS Lines,
       CAST(100.0*SUM(CAST(LossFlag AS FLOAT))/COUNT(*) AS DECIMAL(5,1)) AS LossRatePct,
       CAST(-SUM(CASE WHEN LossFlag=1 THEN ProfitAmount ELSE 0 END)
            /10000000.0 AS DECIMAL(10,2))                         AS LossValue_Cr,
       CAST(100.0 * -SUM(CASE WHEN LossFlag=1 THEN ProfitAmount ELSE 0 END)
            / SUM(-SUM(CASE WHEN LossFlag=1 THEN ProfitAmount ELSE 0 END)) OVER ()
            AS DECIMAL(5,1))                                      AS ShareOfLossPct,
       CAST(100.0*SUM(ProfitAmount)/SUM(SalesAmount) AS DECIMAL(5,1)) AS MarginPct
FROM   sales_net
GROUP  BY DiscountBand
ORDER  BY DiscountBand;
/*  EXPECT:
      Band     Lines   LossRate%   LossValue   Share%   Margin%
      0%         517       0.2       0.00       0.0      22.2
      0-10%   69,625       2.4       0.30      11.6      19.3
      10-20%  54,933      12.7       2.08      80.3       8.3   <<<
      20-30%  17,221      29.3       0.18       7.0       8.4
      30-40%   3,759      64.4       0.03       1.2       3.4

    The two middle columns disagree, and that disagreement is the project.

    Loss RATE rises with discount depth exactly as I expected - 0.2% up to
    64.4%. I had already drafted "deep discounts destroy margin" off the
    back of it.

    Loss VALUE does the opposite. The 30-40% band holds 1.2% of the money
    lost. The 10-20% band holds 80.3% - Rs 2.08 Cr of Rs 2.59 Cr, across
    54,933 lines at 8.3% margin.

    Why: Technology is NEVER discounted above 20% in this data (see the
    Simpson's paradox query at the end). Its losses can only come from
    routine 10-20% discounts on thin markup. Deep discounts fail far more
    often but happen only in Accessories, Office Supplies, Furniture and
    Appliances, where the margin can absorb more of them.

    Both columns are in one query because separately I would have read the
    rate, stopped, and recommended capping deep discounts - which addresses
    1% of the problem and touches no Technology line at all.             */


/* =====================================================================
   Q7b  —  THE HEADLINE NUMBER            *** RUN THIS ONE ***
   ---------------------------------------------------------------------
   Q4 said Technology carries 83% of the loss. Q6/Q7 said the 10-20% band
   carries 80% of it. Those are the same money seen from two angles, and
   quoting them separately invites someone to add them up.

   So I intersected them. This query produces the number in my summary,
   and until I wrote it that figure had no query behind it, which made
   it indefensible however true it was.
   ===================================================================== */
SELECT p.Category,
       f.DiscountBand,
       COUNT(*)                                                   AS Lines,
       CAST(SUM(f.SalesAmount)/10000000.0 AS DECIMAL(10,2))       AS Revenue_Cr,
       CAST(100.0*SUM(f.ProfitAmount)/SUM(f.SalesAmount) AS DECIMAL(5,1)) AS MarginPct,
       CAST(-SUM(CASE WHEN f.LossFlag=1 THEN f.ProfitAmount ELSE 0 END)
            /10000000.0 AS DECIMAL(10,2))                         AS Loss_Cr,
       CAST(100.0 * -SUM(CASE WHEN f.LossFlag=1 THEN f.ProfitAmount ELSE 0 END)
            / (SELECT -SUM(CASE WHEN LossFlag=1 THEN ProfitAmount ELSE 0 END)
               FROM sales_net) AS DECIMAL(5,1))                   AS PctOfAllLoss
FROM   sales_net f
JOIN   dim_product p ON p.ProductID = f.ProductID
GROUP  BY p.Category, f.DiscountBand
HAVING -SUM(CASE WHEN f.LossFlag=1 THEN f.ProfitAmount ELSE 0 END) > 100000
ORDER  BY Loss_Cr DESC;
/*  Result - top rows:
      Technology       10-20%   10,331   Rs 58.80 Cr    4.6%   1.90   73.2%
      Technology        0-10%    8,492                         0.24    9.4%
      Appliances       10-20%    3,473                         0.18    6.8%
      Appliances       20-30%    1,771                         0.15    5.7%

    One cell of the grid holds 73.2% of every rupee lost. 10,331 lines -
    7.1% of net sale lines - carrying Rs 58.8 Cr of revenue at 4.6%
    margin.

    The HAVING clause exists so the output is the handful of cells worth
    acting on rather than the whole grid. I set the threshold at Rs 1 lakh
    before running it, not after seeing the results.

    NOTE ON PERIOD: Rs 1.90 Cr is the FOUR-YEAR cumulative figure. The
    2025-only equivalent is Rs 0.67 Cr. Anything I describe as "per year"
    has to be the second number - see the annualisation query below.     */


/* =====================================================================
   Q7c  —  ANNUALISING, so "per year" means per year
   ---------------------------------------------------------------------
   I got this wrong first time: I quoted four-year cumulative totals and
   labelled them annual, which overstated every recommendation by ~3x.
   Anything sized as a run-rate has to come off a single year.
   ===================================================================== */
SELECT YEAR(f.OrderDate)                                          AS Yr,
       CAST(SUM(f.SalesAmount)/10000000.0 AS DECIMAL(10,2))       AS TotalRevenue_Cr,
       CAST(SUM(CASE WHEN c.Channel='Marketplace' THEN f.SalesAmount ELSE 0 END)
            /10000000.0 AS DECIMAL(10,2))                         AS MarketplaceRev_Cr,
       CAST(100.0*SUM(CASE WHEN c.Channel='Marketplace' THEN f.ProfitAmount ELSE 0 END)
            /NULLIF(SUM(CASE WHEN c.Channel='Marketplace' THEN f.SalesAmount ELSE 0 END),0)
            AS DECIMAL(5,1))                                      AS MarketplaceMarginPct,
       CAST(100.0*SUM(CASE WHEN c.Channel='Website' THEN f.ProfitAmount ELSE 0 END)
            /NULLIF(SUM(CASE WHEN c.Channel='Website' THEN f.SalesAmount ELSE 0 END),0)
            AS DECIMAL(5,1))                                      AS WebsiteMarginPct
FROM   sales_net f
JOIN   dim_channel c ON c.ChannelID = f.ChannelID
GROUP  BY YEAR(f.OrderDate)
ORDER  BY Yr;
/*  Result:
      2022   25.78 Cr    4.38 Cr   11.0%   15.0%
      2023   37.71 Cr    7.44 Cr    9.5%   14.5%
      2024   51.25 Cr    9.21 Cr   10.1%   16.0%
      2025   62.10 Cr   10.70 Cr    8.9%   14.9%

    2025 run-rate figures, which are the ones to quote forward:
      one margin point on Rs 62.10 Cr            = Rs 0.62 Cr / year
      Marketplace gap 6.0 pts on Rs 10.70 Cr     = Rs 0.64 Cr / year
      Technology 10-20% band loss, 2025 only     = Rs 0.67 Cr / year

    The four-year cumulative versions (Rs 1.77 Cr, Rs 1.73 Cr, Rs 1.90 Cr)
    are real, but they are history, not a forward estimate. Label which
    one is meant, every time.                                            */


/* =====================================================================
   Q8  —  CHANNEL: LESS PROFITABLE, OR JUST SMALLER?
   ---------------------------------------------------------------------
   Money columns come from Completed lines; the return rate needs
   Returned lines in the denominator too, so this reads sales_placed and
   filters money with CASE. Cancelled lines are in neither: a cancelled
   order cannot be returned, and counting it would dilute the rate.

   The status test is written out rather than read from a flag column.
   sales_net and sales_placed already encode "what counts as revenue";
   a boolean column repeating that rule is a second source of truth for
   it, and the two drift the moment one is edited and the other is not.
   ===================================================================== */
SELECT c.Channel, c.ChannelType,
       COUNT(DISTINCT CASE WHEN f.OrderStatus='Completed'
                           THEN f.OrderID END)                    AS Orders,
       CAST(SUM(CASE WHEN f.OrderStatus='Completed'
                     THEN f.SalesAmount END)/10000000.0
            AS DECIMAL(10,2))                                      AS Revenue_Cr,
       CAST(100.0*SUM(CASE WHEN f.OrderStatus='Completed'
                           THEN f.ProfitAmount END)
            /SUM(CASE WHEN f.OrderStatus='Completed'
                      THEN f.SalesAmount END)
            AS DECIMAL(5,1))                                       AS MarginPct,
       CAST(100.0*SUM(CASE WHEN f.OrderStatus='Returned' THEN 1.0 ELSE 0 END)
            /COUNT(*) AS DECIMAL(5,2))                            AS ReturnRatePct,
       CAST(AVG(CAST(f.ShippingDays AS FLOAT)) AS DECIMAL(5,2))   AS AvgShipDays
FROM   sales_placed f
JOIN   dim_channel c ON c.ChannelID = f.ChannelID
GROUP  BY c.Channel, c.ChannelType
ORDER  BY Revenue_Cr DESC;
/*  EXPECT:
      Website       22,835   60.00 Cr   15.1%   4.66%   4.50 days
      Retail Store  18,429   50.13 Cr   13.7%   1.94%   1.70 days
      Mobile App    15,642   34.99 Cr   14.7%   4.56%   4.30 days
      Marketplace   11,911   31.73 Cr    9.7%   5.73%   5.90 days

    Marketplace: 5.5 points below Website on Rs 31.73 Cr of revenue.

    The return rate is per LINE. Per order or per rupee would give
    different numbers; line is used because returns are recorded per line.

    Before writing this up I had to rule out product mix - Marketplace
    might simply sell more thin-margin Technology. That would mean a
    different recommendation, so the decomposition below runs first.    */

-- Hold category constant. If the gap survives, it is the channel.
SELECT p.Category, c.Channel,
       CAST(100.0*SUM(f.ProfitAmount)/SUM(f.SalesAmount) AS DECIMAL(5,1)) AS MarginPct,
       COUNT(*) AS Lines
FROM   sales_net f
JOIN   dim_product p ON p.ProductID = f.ProductID
JOIN   dim_channel c ON c.ChannelID = f.ChannelID
GROUP  BY p.Category, c.Channel
ORDER  BY p.Category, MarginPct DESC;
/*  Result: Marketplace trails Website in ALL FIVE categories -
      Technology 6.2 vs 11.3 | Appliances 6.0 vs 13.5 | Office Supplies
      11.0 vs 16.1 | Furniture 22.6 vs 26.9 | Accessories 28.7 vs 32.3

    And the revenue mixes are near-identical: Technology is 63.7% of
    Marketplace revenue and 63.3% of Website's. Mix is ruled out, so the
    gap is channel economics.

    If the gap had vanished here, R3 would have been "fix the product mix"
    instead of "renegotiate commission".                                 */


/* =====================================================================
   Q9  —  RETURNS BY CATEGORY
   ===================================================================== */
SELECT p.Category,
       CAST(100.0*SUM(CASE WHEN f.OrderStatus='Returned' THEN 1.0 ELSE 0 END)
            /COUNT(*) AS DECIMAL(5,2))                            AS ReturnRatePct,
       CAST(SUM(CASE WHEN f.OrderStatus='Returned' THEN f.SalesAmount ELSE 0 END)
            /10000000.0 AS DECIMAL(10,2))                         AS ReturnedRevenue_Cr
FROM   sales_placed f
JOIN   dim_product p ON p.ProductID = f.ProductID
GROUP  BY p.Category
ORDER  BY ReturnRatePct DESC;
/*  EXPECT: Furniture 6.12 | Appliances 5.87 | Technology 4.39
            Accessories 4.30 | Office Supplies 3.33
            (the 'Unknown' row shows 6.67% on 15 lines - too small to read)

    I can count returns but not cost them - reverse logistics and
    restocking are not in CostAmount. So this supports "returns concentrate
    in Furniture and Appliances" and nothing about what they cost.       */


/* =====================================================================
   Q10  —  REPEAT vs ONE-TIME CUSTOMERS
   ---------------------------------------------------------------------
   Counting orders, not lines. An 8-line basket is one order, and my
   first pass counted lines - which made almost everyone a repeat buyer.

   Orders come from sales_placed (a returned order was still a purchase
   decision); revenue counts Completed lines only.

   Window bias I could not fix: a customer who joined in December 2025 had
   weeks to repeat, not years, so the "1 order" band is inflated. Fixing it
   properly needs a tenure-matched cohort, which is why Insight 5 is
   flagged as not actionable yet.
   ===================================================================== */
WITH per_customer AS (
    SELECT CustomerID,
           COUNT(DISTINCT OrderID)                                AS Orders,
           SUM(CASE WHEN OrderStatus='Completed'
                    THEN SalesAmount ELSE 0 END)                   AS Revenue
    FROM   sales_placed
    WHERE  CustomerID <> 'UNKNOWN'
    GROUP  BY CustomerID
)
SELECT CASE WHEN Orders = 1 THEN '1 order'
            WHEN Orders <= 3 THEN '2-3 orders'
            WHEN Orders <= 9 THEN '4-9 orders'
            ELSE '10+ orders' END                                 AS Band,
       COUNT(*)                                                   AS Customers,
       CAST(100.0*COUNT(*)/SUM(COUNT(*)) OVER () AS DECIMAL(5,1)) AS PctOfCustomers,
       CAST(100.0*SUM(Revenue)/SUM(SUM(Revenue)) OVER () AS DECIMAL(5,1)) AS PctOfRevenue
FROM   per_customer
GROUP  BY CASE WHEN Orders = 1 THEN '1 order'
               WHEN Orders <= 3 THEN '2-3 orders'
               WHEN Orders <= 9 THEN '4-9 orders'
               ELSE '10+ orders' END
ORDER  BY MIN(Orders);
/*  EXPECT:
      Band        Customers   %Customers   %Revenue
      1 order         774        10.4         1.6
      2-3 orders    1,626        21.8         7.5
      4-9 orders    3,004        40.3        26.4
      10+ orders    2,050        27.5        64.5
      (7,454 customers in total)

    The 27.5% of customers who order 10+ times drive 64.5% of revenue,
    while the 10.4% who ordered once contribute 1.6%. Retention is worth
    far more than acquisition here - and that is a different investment
    case.                                                                */


/* =====================================================================
   Q11  —  CUSTOMER PARETO
   ===================================================================== */
WITH per_customer AS (
    SELECT CustomerID, SUM(SalesAmount) AS Revenue
    FROM   sales_net WHERE CustomerID <> 'UNKNOWN'
    GROUP  BY CustomerID
),
ranked AS (
    SELECT CustomerID, Revenue,
           ROW_NUMBER() OVER (ORDER BY Revenue DESC)               AS Rnk,
           SUM(Revenue) OVER (ORDER BY Revenue DESC
                              ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS CumRevenue,
           SUM(Revenue) OVER ()                                    AS TotalRevenue,
           COUNT(*)     OVER ()                                    AS TotalCustomers
    FROM   per_customer
)
SELECT MIN(CASE WHEN CumRevenue >= 0.50*TotalRevenue THEN Rnk END)  AS CustomersFor50Pct,
       MIN(CASE WHEN CumRevenue >= 0.80*TotalRevenue THEN Rnk END)  AS CustomersFor80Pct,
       MAX(TotalCustomers)                                          AS TotalCustomers
FROM   ranked;
/*  EXPECT: 847 | 2635 | 7416

    847 customers (11.4%) generate half the revenue.
    2,635 (35.5%) generate 80%.
    Concentrated, but not extreme — a broad base, not a whale business.

    7,416 here vs 7,454 in Q10: 38 customers placed orders but every one
    was returned, so they have no net revenue to rank.                   */


/* =====================================================================
   Q12  —  SEGMENTS
   ===================================================================== */
SELECT c.Segment,
       COUNT(DISTINCT f.CustomerID)                               AS Customers,
       COUNT(DISTINCT f.OrderID)                                  AS Orders,
       CAST(SUM(f.SalesAmount)/10000000.0 AS DECIMAL(10,2))       AS Revenue_Cr,
       CAST(SUM(f.SalesAmount)/COUNT(DISTINCT f.OrderID) AS DECIMAL(10,0)) AS AOV,
       CAST(1.0*COUNT(DISTINCT f.OrderID)/COUNT(DISTINCT f.CustomerID) AS DECIMAL(5,2)) AS OrdersPerCustomer,
       CAST(100.0*SUM(f.ProfitAmount)/SUM(f.SalesAmount) AS DECIMAL(5,1)) AS MarginPct
FROM   sales_net f
JOIN   dim_customer c ON c.CustomerID = f.CustomerID
WHERE  c.Segment IS NOT NULL AND c.Segment <> 'Unknown'
GROUP  BY c.Segment
ORDER  BY Revenue_Cr DESC;
/*  EXPECT:
      Consumer        4448  49,281   98.38 Cr  AOV 19,963  11.08/cust  12.3%
      Small Business  1675  13,506   45.00 Cr  AOV 33,318   8.06/cust  13.9%
      Corporate        973   4,877   24.10 Cr  AOV 49,419   5.01/cust  16.7%
      Enterprise       320   1,153    9.35 Cr  AOV 81,078   3.60/cust  19.0%

    A clean monotonic pattern: as segments get larger, orders per
    customer FALL and both AOV and MARGIN RISE. Enterprise buys rarely,
    buys big, and is the most profitable per rupee.                     */


/* =====================================================================
   Q13  —  COHORT RETENTION       (the hardest query here)
   ---------------------------------------------------------------------
   The date spine is here because my first version was wrong and looked
   fine. A cohort with no orders in month 3 produced no row for month 3, so
   month 4 shifted left and the retention curve came out smooth, plausible
   and false. The CROSS JOIN builds every cohort x month cell first and
   LEFT JOINs activity onto it, so a dead month reads as zero instead of
   disappearing.

   The spine has a trap of its own: it also builds cells that are in the
   FUTURE. A June 2025 cohort's month 7 is January 2026, after the data
   ends. ISNULL(..., 0) would report those as 0% retention - customers
   who "left" in months that have not happened. 78 of the 624 cells are
   like that. They are set to NULL, so they render as blanks in the
   triangle instead of as a collapse in retention.

   So: a missing month inside the data window means 0; a month outside it
   means unknown. The spine handles the first, IsObservable the second.

   DATEDIFF(MONTH,...) rather than subtracting dates, because cohorts are
   compared on calendar boundaries, not 30-day blocks.
   ===================================================================== */
WITH bounds AS (
    SELECT DATEFROMPARTS(YEAR(MAX(OrderDate)), MONTH(MAX(OrderDate)), 1) AS LastMonth
    FROM   fact_sales
),
cust_cohort AS (
    SELECT c.CustomerID,
           DATEFROMPARTS(YEAR(c.JoinDate), MONTH(c.JoinDate), 1) AS CohortMonth
    FROM   dim_customer c
    WHERE  c.JoinDate IS NOT NULL AND c.CustomerID <> 'UNKNOWN'
),
activity AS (
    SELECT cc.CohortMonth,
           DATEDIFF(MONTH, cc.CohortMonth,
                    DATEFROMPARTS(YEAR(f.OrderDate), MONTH(f.OrderDate), 1)) AS MonthsSince,
           COUNT(DISTINCT f.CustomerID) AS ActiveCustomers
    FROM   sales_placed f
    JOIN   cust_cohort cc ON cc.CustomerID = f.CustomerID
    GROUP  BY cc.CohortMonth,
             DATEDIFF(MONTH, cc.CohortMonth,
                      DATEFROMPARTS(YEAR(f.OrderDate), MONTH(f.OrderDate), 1))
),
cohort_size AS (
    SELECT CohortMonth, COUNT(*) AS CohortCustomers
    FROM   cust_cohort GROUP BY CohortMonth
),
spine AS (                       -- the grid: every cohort x every month 0..12
    SELECT s.CohortMonth, m.MonthsSince
    FROM   cohort_size s
    CROSS  JOIN (SELECT 0 AS MonthsSince UNION ALL SELECT 1 UNION ALL SELECT 2
                 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5
                 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8
                 UNION ALL SELECT 9 UNION ALL SELECT 10 UNION ALL SELECT 11
                 UNION ALL SELECT 12) m
)
SELECT sp.CohortMonth,
       cs.CohortCustomers,
       sp.MonthsSince,
       o.IsObservable,
       CASE WHEN o.IsObservable = 1
            THEN ISNULL(a.ActiveCustomers, 0) END                 AS ActiveCustomers,
       CASE WHEN o.IsObservable = 1
            THEN CAST(100.0*ISNULL(a.ActiveCustomers,0)/cs.CohortCustomers
                      AS DECIMAL(5,1)) END                        AS RetentionPct
FROM   spine sp
JOIN   cohort_size cs ON cs.CohortMonth = sp.CohortMonth
CROSS  JOIN bounds b
CROSS  APPLY (SELECT CASE WHEN DATEADD(MONTH, sp.MonthsSince, sp.CohortMonth) <= b.LastMonth
                          THEN 1 ELSE 0 END AS IsObservable) o
LEFT   JOIN activity a ON a.CohortMonth = sp.CohortMonth
                      AND a.MonthsSince = sp.MonthsSince
WHERE  sp.CohortMonth >= '2022-01-01'
ORDER  BY sp.CohortMonth, sp.MonthsSince;
/*  CHECK: 48 cohorts x 13 months = 624 rows. 546 observable, 78 NULL.
    Every cohort still has exactly 13 rows.

    Pivot CohortMonth down and MonthsSince across in any reporting tool for the
    classic retention triangle - the NULLs form the empty corner.

    ⚠️  Even with the NULLs, compare cohorts only on months they all have.
        A 2025 cohort has no month-12 value; that is not the same as a
        low one.                                                         */


/* =====================================================================
   Q14 / Q15  —  CAN I TRUST THE NUMBERS?
   ---------------------------------------------------------------------
   Data quality is judged on every row, so this one reads fact_sales.
   ===================================================================== */
SELECT COUNT(*)                                                   AS CleanRows,
       SUM(FailsPricingRule)                                      AS PricingRuleBreaches,
       SUM(FailsProfitRule)                                       AS ProfitRuleBreaches,
       SUM(CASE WHEN FailsPricingRule=1 OR FailsProfitRule=1 THEN 1 ELSE 0 END) AS EitherBreach,
       CAST(100.0*(COUNT(*)-SUM(CASE WHEN FailsPricingRule=1 OR FailsProfitRule=1
                                     THEN 1 ELSE 0 END))/COUNT(*) AS DECIMAL(5,2)) AS PctReconciling,
       SUM(CASE WHEN IsShippingKnown=0 THEN 1 ELSE 0 END)         AS ShippingUnknown,
       SUM(CASE WHEN CustomerID='UNKNOWN' OR ProductID='UNKNOWN'
                  OR RegionID='UNKNOWN' THEN 1 ELSE 0 END)        AS RowsOnUnknownMembers,
       SUM(CASE WHEN RecoveredField IS NOT NULL THEN 1 ELSE 0 END) AS RecoveredRows
FROM   fact_sales;
/*  Result: 157108 | 700 | 349 | 1049 | 99.33 | 4713 | 34 | 16

    99.33% reconciles against BOTH money rules. I use that one figure
    everywhere. Quoting 99.55% - the pricing rule on its own - would be
    quietly flattering, because it ignores 349 rows where profit does not
    equal sales minus cost. Picking the kinder of two true numbers is how
    small dishonesties get into reports.                                 */


/* =====================================================================
   BONUS  —  WEIGHTED vs NAIVE DISCOUNT
   ===================================================================== */
SELECT CAST(100.0*SUM(Quantity*UnitPrice*DiscountPercent)
            /SUM(Quantity*UnitPrice) AS DECIMAL(5,2))             AS WeightedDiscountPct,
       CAST(100.0*AVG(DiscountPercent) AS DECIMAL(5,2))           AS NaiveAvgDiscountPct
FROM   sales_net;
/*  EXPECT: 12.18 | 12.38

    The two barely differ here - 0.20 points - because discount depth does
    not correlate strongly with price in this data. The weighted version is
    still the right one to quote, but I nearly wrote this up as a finding
    before checking the size of the gap.                                */


/* =====================================================================
   BONUS  —  SIMPSON'S PARADOX CHECK   (feeds the statistics section)
   ===================================================================== */
SELECT p.Category, f.DiscountBand,
       COUNT(*) AS Lines,
       CAST(100.0*SUM(f.ProfitAmount)/SUM(f.SalesAmount) AS DECIMAL(5,1)) AS MarginPct
FROM   sales_net f
JOIN   dim_product p ON p.ProductID = f.ProductID
WHERE  p.Category <> 'Unknown'
GROUP  BY p.Category, f.DiscountBand
ORDER  BY p.Category, f.DiscountBand;
/*  WITHIN every category, margin falls monotonically as discount deepens
    (Accessories 37.7 -> 35.4 -> 29.7 -> 22.0 -> 11.3).

    But look at the ALL-CATEGORY table in Q6: the 20-30% band (8.4%) is
    slightly ABOVE the 10-20% band (8.3%). In aggregate, a deeper
    discount looks like it does no harm.

    WHY: the bands contain different categories. Technology appears only
    in 0%, 0-10% and 10-20% - it is never discounted deeper. Furniture
    and Appliances stop at 30%. The 20-30% and 30-40% bands are made up
    of higher-margin categories, so their averages are propped up by mix.
    That is a MIX EFFECT / Simpson's paradox: the aggregate and the
    segments tell opposite stories.                                   */


/* =====================================================================
   STEP 10 GATE: every question Q1-Q15 has a number against it.
   Write them into docs/findings_and_recommendations.md, ranked by rupees.
   ===================================================================== */
