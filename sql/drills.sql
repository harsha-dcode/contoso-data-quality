/* =====================================================================
   04_drills.sql   —   Rebuild-from-blank practice
   ---------------------------------------------------------------------
   Three queries from sql/04_analysis.sql that I should be able to write
   without looking: Q5, Q11 and Q13.

   Each drill below gives the business question, the shape of the output,
   and the answer to check against. No SQL. If I can't produce the query
   from this alone, I don't own it yet - I've only read it.

   Q5 and Q11 are the same window-function pattern; Q13 is the one I got
   wrong the first time.
   ===================================================================== */

USE ContosoRetail;
GO


/* =====================================================================
   DRILL 1  —  Q5 : Loss Pareto within a category
   ---------------------------------------------------------------------
   QUESTION
     Within Technology, which products lose money, and how few of them
     account for most of the loss?

   OUTPUT SHAPE
     One row per loss-making Technology SKU, worst first:
       Rank | ProductName | Revenue | Loss | CumulativeLossPct

   WHAT IT HAS TO DO
     1. Aggregate profit and revenue per ProductID, Technology only,
        from sales_net (Completed lines - cancelled orders earned nothing)
     2. Keep only SKUs with negative total profit
     3. Order by profit ascending (biggest loser first)
     4. Running total of loss down that order
     5. Express the running total as a % of total loss

   TRAPS I ALREADY HIT
     - The frame clause. SUM(...) OVER (ORDER BY x) defaults to RANGE,
       which collapses tied values into one step. Two SKUs with equal
       loss made the running total jump. It needs ROWS.
     - Filtering to Profit < 0 before or after the window changes the
       denominator. Decide which total the % is "of" and be consistent.

   CHECK
     267 Technology SKUs. 34 lose money. The worst 12 reach ~82%
     cumulative loss.
   ===================================================================== */

-- write it here




/* =====================================================================
   DRILL 2  —  Q11 : Customer revenue Pareto
   ---------------------------------------------------------------------
   QUESTION
     How many customers generate half the revenue? How many generate 80%?

   OUTPUT SHAPE
     A single row:
       CustomersFor50Pct | CustomersFor80Pct | TotalCustomers

   WHAT IT HAS TO DO
     1. Revenue per CustomerID from sales_net, excluding the UNKNOWN
        member
     2. Rank customers by revenue descending
     3. Running total of revenue down that order
     4. Grand total on every row, to compare against
     5. Collapse to one row: the lowest rank where the running total
        crosses 50%, and where it crosses 80%

   TRAPS
     - Excluding 'UNKNOWN' matters. It is one synthetic customer holding
       15 real orders, and leaving it in puts a fake customer in the
       ranking.
     - Step 4 is SUM(...) OVER () with empty parentheses - grand total on
       every row, no subquery needed.
     - Step 5 is MIN(CASE WHEN cum >= 0.5*total THEN rank END). That
       pattern - conditional aggregate over a window result - is worth
       knowing; it turns "find the first row where X" into one pass.

   CHECK
     847 customers for 50%, 2,635 for 80%, out of 7,416.
   ===================================================================== */

-- write it here




/* =====================================================================
   DRILL 3  —  Q13 : Cohort retention          (the hard one)
   ---------------------------------------------------------------------
   QUESTION
     Do customers who joined recently retain worse than older cohorts?

   OUTPUT SHAPE
       CohortMonth | CohortCustomers | MonthsSince | Active | RetentionPct
     One row per cohort per month 0-12, pivoted into a triangle later.

   WHAT IT HAS TO DO
     1. Cohort = month of JoinDate, per customer
     2. Cohort size = customers per cohort month
     3. Activity = distinct customers ordering (sales_placed - a returned
        order still counts as activity), by cohort and by months elapsed
        since the cohort month
     4. A full grid of every cohort x every month 0-12
     5. LEFT JOIN activity onto the grid; missing = 0, not absent
     6. Retention % = active / cohort size
     7. Cells after the last month of data -> NULL, not 0

   WHY STEP 4 EXISTS - THE MISTAKE I MADE
     My first version skipped it and grouped activity directly. A cohort
     with no orders in month 3 produced NO ROW for month 3, so month 4
     slid into its place. The curve came out smooth, plausible and wrong,
     and nothing flagged it. The CROSS JOIN forces every cell to exist.

   OTHER TRAPS
     - DATEDIFF(MONTH, ...) not date subtraction. Cohorts compare on
       calendar boundaries, not 30-day blocks.
     - The spine also builds cells in the FUTURE. A June 2025 cohort's
       month 7 is January 2026. ISNULL(...,0) turns those into 0%
       retention - customers "leaving" in months that have not happened.
       Missing inside the data window = 0; outside it = NULL. That is the
       second half of the same mistake, and the easier one to miss.

   CHECK
     48 cohorts x 13 = 624 rows. Every cohort has exactly 13 rows
     (months 0-12), including cohorts with zero activity in some months.
     If any cohort has fewer than 13, the spine is missing and the curve
     is wrong. 78 of the 624 cells must be NULL (the 2025 cohorts'
     future months). If none are NULL, the future is being reported as
     churn.
   ===================================================================== */

-- write it here




/* =====================================================================
   SELF-CHECK

   Before treating any of these as known:
     - written from the drill text alone, no scrolling to sql/04_analysis.sql
     - runs first time
     - numbers match the CHECK line
     - I can say out loud why ROWS and not RANGE, why the spine exists,
       and why the spine's future cells must be NULL, without rehearsing it

   If the window-function syntax is the blocker rather than the logic,
   that is worth knowing too - it means practising the pattern, not
   re-reading the project.
   ===================================================================== */
